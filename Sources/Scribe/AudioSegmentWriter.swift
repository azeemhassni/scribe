import AVFoundation
import Foundation

/// Converts arbitrary input audio to the 16 kHz mono PCM that whisper.cpp wants.
final class Resampler {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000,
                                            channels: 1,
                                            interleaved: true)!

    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = Self.targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// One closed WAV chunk, positioned on the session timeline.
struct AudioSegment {
    let url: URL
    let index: Int
    /// Seconds from the start of the session to this file's first sample.
    let startTime: TimeInterval
    /// Leading seconds duplicated from the previous segment.
    let headOverlap: TimeInterval
}

/// Writes a continuous 16 kHz mono stream to rotating WAV segments so the
/// transcriber can start working while the meeting is still going.
///
/// Segments rotate on a *pause*, not on a stopwatch: once a segment is long
/// enough the writer waits for a quiet buffer before cutting. Cutting mid-word
/// makes whisper guess at both halves and produces a garbled seam, and no
/// amount of downstream de-duplication recovers a word that was never heard
/// whole. If no pause turns up within a grace period the writer cuts anyway and
/// carries a short overlap into the next segment so the seam is at least
/// recoverable.
final class AudioSegmentWriter {

    let overlapSeconds: Double
    private let directory: URL
    private let prefix: String
    private let segmentFrames: AVAudioFrameCount
    private let overlapFrames: Int
    private let clockStart: Date
    private let onSegmentClosed: (AudioSegment) -> Void

    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var index = 0
    private var framesInSegment: AVAudioFrameCount = 0
    private var tail: [Int16] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var segmentStart: TimeInterval = 0
    private var segmentHeadOverlap: TimeInterval = 0
    private var peak: Int16 = 0
    private var continuousFile: AVAudioFile?
    private var seekingCut = false
    private var lastCutWasForced = false
    private let maxSegmentFrames: AVAudioFrameCount

    init(directory: URL,
         prefix: String,
         segmentSeconds: Double = 120,
         overlapSeconds: Double = 2,
         clockStart: Date,
         onSegmentClosed: @escaping (AudioSegment) -> Void) {
        self.directory = directory
        self.prefix = prefix
        self.overlapSeconds = overlapSeconds
        self.clockStart = clockStart
        self.segmentFrames = AVAudioFrameCount(segmentSeconds * Resampler.targetFormat.sampleRate)
        // Never let the hunt for a pause stretch a segment indefinitely.
        self.maxSegmentFrames = AVAudioFrameCount(min(segmentSeconds * 1.25, segmentSeconds + 20)
                                                  * Resampler.targetFormat.sampleRate)
        self.overlapFrames = Int(overlapSeconds * Resampler.targetFormat.sampleRate)
        self.onSegmentClosed = onSegmentClosed
        self.queue = DispatchQueue(label: "scribe.segment.\(prefix)")
    }

    /// Seconds of audio written so far, across all segments.
    var duration: TimeInterval {
        queue.sync { Double(totalFrames) / Resampler.targetFormat.sampleRate }
    }

    /// One unbroken file for the whole session, used for playback. The rotating
    /// segments are for the transcriber; this is the timeline.
    var continuousURL: URL { directory.appendingPathComponent("\(prefix)-full.wav") }

    /// Loudest sample seen, 0...1. Stays at zero when a stream is connected but
    /// delivering nothing but silence — which is how a denied system-audio
    /// permission presents itself.
    var peakLevel: Float {
        queue.sync { Float(peak) / 32768 }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copyInt16() else { return }
        queue.async { [weak self] in
            self?.write(copy)
        }
    }

    func finish() {
        queue.sync {
            closeCurrentSegment()
            continuousFile = nil
        }
    }

    // MARK: - Queue-confined

    private func write(_ samples: [Int16]) {
        // Sampled rather than exhaustive: enough to tell silence from speech.
        for i in stride(from: 0, to: samples.count, by: 16) {
            let magnitude = samples[i] == Int16.min ? Int16.max : abs(samples[i])
            if magnitude > peak { peak = magnitude }
        }
        padToWallClock(incoming: samples.count)
        if file == nil { openSegment(seedingOverlap: index > 0 && lastCutWasForced) }
        guard let file, let buffer = Self.buffer(from: samples) else { return }
        do {
            try file.write(from: buffer)
            framesInSegment += buffer.frameLength
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            Log.error("segment write failed: \(error.localizedDescription)")
        }

        appendToContinuousFile(samples)

        tail.append(contentsOf: samples)
        if tail.count > overlapFrames { tail.removeFirst(tail.count - overlapFrames) }

        if framesInSegment >= segmentFrames { seekingCut = true }
        guard seekingCut else { return }

        if isQuiet(samples) {
            lastCutWasForced = false
            closeCurrentSegment()
        } else if framesInSegment >= maxSegmentFrames {
            lastCutWasForced = true
            closeCurrentSegment()
        }
    }

    /// CoreAudio's process tap only delivers buffers while something is
    /// actually playing — a silent stretch produces no callbacks at all, not
    /// callbacks full of zeros. Left alone, the stream would close up like a
    /// concertina and every timestamp after a pause would drift earlier than it
    /// really happened. Inserting the missing silence keeps the file's timeline
    /// equal to wall-clock time, which is what makes the two streams line up
    /// with each other and with playback.
    private func padToWallClock(incoming: Int) {
        let rate = Resampler.targetFormat.sampleRate
        let expected = AVAudioFramePosition(Date().timeIntervalSince(clockStart) * rate)
        let deficit = expected - totalFrames - AVAudioFramePosition(incoming)
        // Ignore ordinary buffer latency; only fill a real hole.
        guard deficit > AVAudioFramePosition(0.25 * rate) else { return }

        // Only the playback timeline gets the silence. Feeding it to whisper
        // too would be actively harmful: given a long silent lead-in it emits
        // one coarse segment spanning the whole thing, so a sentence that was
        // said at 00:10 gets stamped 00:00 and clicking it plays the wrong
        // moment. The segments stay dense; each one is instead re-anchored to
        // the clock when it opens, which bounds any drift to a single segment.
        appendToContinuousFile([Int16](repeating: 0, count: Int(deficit)))
        totalFrames += deficit

        // A gap this long is the best cut point we will ever get, and closing
        // here is what lets the next segment pick up an accurate start time.
        lastCutWasForced = false
        closeCurrentSegment()
    }

    private func appendToContinuousFile(_ samples: [Int16]) {
        if continuousFile == nil {
            continuousFile = try? AVAudioFile(forWriting: continuousURL,
                                              settings: Resampler.targetFormat.settings,
                                              commonFormat: .pcmFormatInt16,
                                              interleaved: true)
        }
        guard let continuousFile, let buffer = Self.buffer(from: samples) else { return }
        try? continuousFile.write(from: buffer)
    }

    /// True when this buffer holds no speech, judged against the loudest audio
    /// seen so far rather than an absolute level, so it adapts to a quiet mic or
    /// a hot one.
    private func isQuiet(_ samples: [Int16]) -> Bool {
        let threshold = max(Int16(400), Int16(Float(peak) * 0.06))
        for sample in samples {
            let magnitude = sample == Int16.min ? Int16.max : abs(sample)
            if magnitude > threshold { return false }
        }
        return true
    }

    private func openSegment(seedingOverlap: Bool) {
        let url = directory.appendingPathComponent(String(format: "%@-%03d.wav", prefix, index))
        do {
            let newFile = try AVAudioFile(forWriting: url,
                                          settings: Resampler.targetFormat.settings,
                                          commonFormat: .pcmFormatInt16,
                                          interleaved: true)
            file = newFile
            framesInSegment = 0
            let seedFrames = seedingOverlap ? min(tail.count, overlapFrames) : 0
            segmentHeadOverlap = Double(seedFrames) / Resampler.targetFormat.sampleRate
            segmentStart = Double(totalFrames) / Resampler.targetFormat.sampleRate - segmentHeadOverlap
            if seedFrames > 0, let seed = Self.buffer(from: Array(tail.suffix(seedFrames))) {
                try newFile.write(from: seed)
                framesInSegment += seed.frameLength
            }
        } catch {
            Log.error("could not open segment \(url.lastPathComponent): \(error.localizedDescription)")
            file = nil
        }
    }

    private func closeCurrentSegment() {
        guard let file else { return }
        seekingCut = false
        let url = file.url
        let segment = AudioSegment(url: url,
                                   index: index,
                                   startTime: segmentStart,
                                   headOverlap: segmentHeadOverlap)
        // A segment holding nothing but the carried-over overlap has no new speech.
        let newFrames = framesInSegment - AVAudioFrameCount(segmentHeadOverlap * Resampler.targetFormat.sampleRate)
        let hadAudio = newFrames > AVAudioFrameCount(Resampler.targetFormat.sampleRate / 2)
        self.file = nil
        self.framesInSegment = 0
        self.index += 1
        if hadAudio {
            onSegmentClosed(segment)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func buffer(from samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.targetFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.int16ChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

extension AVAudioPCMBuffer {
    /// Detaches the Int16 samples so they survive past the CoreAudio callback.
    func copyInt16() -> [Int16]? {
        guard let channel = int16ChannelData, frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(frameLength)))
    }
}
