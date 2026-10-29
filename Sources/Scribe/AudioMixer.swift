import AVFoundation
import Foundation

/// Combines the microphone and system streams into a single compressed file for
/// playback in the library.
///
/// Both inputs are wall-clock aligned by `AudioSegmentWriter`, so mixing is a
/// straight sample-wise sum — position in the mixed file equals position in the
/// transcript, which is what makes click-a-line-to-hear-it work.
enum AudioMixer {

    /// AAC at 32 kbit/s mono: about 14 MB for an eight-hour day of meetings,
    /// against ~1.8 GB for the raw 16 kHz WAVs.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    /// Speech level each stream is brought to before the streams are summed,
    /// as RMS of full scale — about -20 dBFS, which leaves room for the two
    /// sides to land on top of each other without the sum clipping.
    private static let targetLevel: Float = 0.1
    /// A stream is never lifted so far that its loud moments crowd full scale.
    private static let peakCeiling: Float = 0.7
    private static let gainRange: ClosedRange<Float> = 0.25...12
    /// Below this a stream holds no speech at all, only room tone or a dead
    /// capture; amplifying that would just make the hiss loud.
    private static let speechFloor: Float = 0.002

    @discardableResult
    static func mix(_ inputs: [URL], to destination: URL) throws -> URL? {
        let files = inputs.compactMap { url -> AVAudioFile? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }
        guard !files.isEmpty else { return nil }

        // Conferencing apps run their output through automatic gain control, so
        // the remote side always arrives at a healthy, consistent level. A
        // laptop microphone gets no such treatment and lands 10-13 dB quieter.
        // Summed raw, you are a faint voice in your own recording, so measure
        // each stream and match them before mixing.
        let sources = files.map { (file: $0, gain: gain(for: $0)) }

        let output = try AVAudioFile(forWriting: destination, settings: outputSettings)
        let format = output.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)   // one second at a time
        let longest = files.map(\.length).max() ?? 0
        var position: AVAudioFramePosition = 0

        while position < longest {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk), longest - position))
            guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let target = mixed.floatChannelData else { break }
            mixed.frameLength = frames
            memset(target[0], 0, Int(frames) * MemoryLayout<Float>.size)

            for source in sources where source.file.framePosition < source.file.length {
                guard let scratch = AVAudioPCMBuffer(pcmFormat: source.file.processingFormat,
                                                     frameCapacity: frames) else { continue }
                try source.file.read(into: scratch, frameCount: frames)
                guard let samples = scratch.floatChannelData else { continue }
                for i in 0..<Int(scratch.frameLength) {
                    target[0][i] += samples[0][i] * source.gain
                }
            }

            // Two people rarely peak together, but clamp so a clash cannot wrap.
            for i in 0..<Int(frames) {
                target[0][i] = max(-1, min(1, target[0][i]))
            }

            try output.write(from: mixed)
            position += AVAudioFramePosition(frames)
        }
        return destination
    }

    /// How much this stream has to be lifted (or held back) to sit at the same
    /// level as the other side of the call.
    private static func gain(for file: AVAudioFile) -> Float {
        defer { file.framePosition = 0 }
        guard let profile = profile(file), profile.speech > speechFloor else { return 1 }
        var gain = targetLevel / profile.speech
        if profile.peak > 0 { gain = min(gain, peakCeiling / profile.peak) }
        gain = min(max(gain, gainRange.lowerBound), gainRange.upperBound)
        Log.info(String(format: "mixing %@ at %+.1f dB (speech %.1f dBFS)",
                        file.url.lastPathComponent,
                        20 * log10(gain),
                        20 * log10(profile.speech)))
        return gain
    }

    /// Measures how loud a stream is *when someone is talking*. A plain average
    /// over the whole file would mostly measure the silence between turns, and
    /// so would read a stream quieter the less its owner said.
    private static func profile(_ file: AVAudioFile) -> (speech: Float, peak: Float)? {
        let format = file.processingFormat
        let window = AVAudioFrameCount(format.sampleRate * 0.02)   // 20 ms
        guard window > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return nil }

        var levels: [Float] = []
        var peaks: [Float] = []
        file.framePosition = 0
        while file.framePosition < file.length {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(window), file.length - file.framePosition))
            guard (try? file.read(into: buffer, frameCount: frames)) != nil,
                  buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            var energy: Float = 0
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                let sample = samples[0][i]
                energy += sample * sample
                peak = max(peak, abs(sample))
            }
            levels.append((energy / Float(buffer.frameLength)).squareRoot())
            peaks.append(peak)
        }

        guard let loudest = levels.max(), loudest > 0 else { return nil }
        // Anything within 20 dB of the loudest moment counts as speech; the
        // gaps and the room tone fall below that.
        let gate = loudest * 0.1
        var energy: Float = 0
        var count = 0
        for level in levels where level > gate {
            energy += level * level
            count += 1
        }
        guard count > 0 else { return nil }

        // A high percentile rather than the outright maximum, so one cough or
        // a knocked desk cannot hold the whole stream down.
        let sorted = peaks.sorted()
        let peak = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.995))]
        return ((energy / Float(count)).squareRoot(), peak)
    }
}
