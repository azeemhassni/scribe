import AVFoundation
import Foundation

/// One recording: two audio streams, rotating segments, and the transcript that
/// accumulates while the meeting is still running.
final class MeetingSession {

    let id = UUID()
    let startedAt = Date()
    let directory: URL
    private(set) var platforms: [String]
    private(set) var calendarTitle: String?

    private let mic = MicrophoneCapture()
    private let systemTap = SystemAudioTap()
    private var micWriter: AudioSegmentWriter?
    private var systemWriter: AudioSegmentWriter?
    private let transcriber: Transcriber
    private let segmentSeconds: Double

    private let lock = NSLock()
    private var utterances: [Utterance] = []
    private var errors: [String] = []

    private(set) var systemAudioAvailable = false
    private(set) var microphoneAvailable = false

    var duration: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Loudest sample seen on each stream so far, 0...1.
    var systemPeak: Float { systemWriter?.peakLevel ?? 0 }
    var micPeak: Float { micWriter?.peakLevel ?? 0 }

    /// Number of transcribed lines so far — the menu bar shows this so you can
    /// tell at a glance that it is actually working.
    var utteranceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return utterances.count
    }

    init(platforms: [String], calendarTitle: String?, settings: Prefs, segmentSeconds: Int? = nil) {
        self.platforms = platforms
        self.calendarTitle = calendarTitle
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        self.directory = Paths.sessions.appendingPathComponent(stamp.string(from: startedAt), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.segmentSeconds = Double(segmentSeconds ?? settings.segmentSeconds)
        self.transcriber = Transcriber(
            binary: URL(fileURLWithPath: settings.whisperBinary),
            model: URL(fileURLWithPath: settings.whisperModel),
            threads: settings.whisperThreads,
            language: settings.language,
            hindustaniScript: HindustaniScript(rawValue: settings.hindustaniScript) ?? .systemDefault)
    }

    // MARK: - Lifecycle

    /// Starts both streams. Succeeds if at least one of them came up; a missing
    /// system tap (permission not granted yet) still gives you your own side.
    func start() throws {
        // Both writers share one clock origin: that shared reference is what
        // keeps the two streams aligned with each other.
        micWriter = AudioSegmentWriter(directory: directory,
                                       prefix: "mic",
                                       segmentSeconds: segmentSeconds,
                                       clockStart: startedAt) { [weak self] segment in
            self?.transcribe(segment, speaker: .me)
        }
        systemWriter = AudioSegmentWriter(directory: directory,
                                          prefix: "sys",
                                          segmentSeconds: segmentSeconds,
                                          clockStart: startedAt) { [weak self] segment in
            self?.transcribe(segment, speaker: .others)
        }

        do {
            try mic.start { [weak self] buffer in self?.micWriter?.append(buffer) }
            microphoneAvailable = true
        } catch {
            record(error: "Microphone: \(error.localizedDescription)")
        }

        do {
            try systemTap.start { [weak self] buffer in self?.systemWriter?.append(buffer) }
            systemAudioAvailable = true
        } catch {
            record(error: "System audio: \(error.localizedDescription)")
        }

        guard microphoneAvailable || systemAudioAvailable else {
            throw NSError(domain: "Scribe", code: 10, userInfo: [
                NSLocalizedDescriptionKey: errors.joined(separator: "\n")
            ])
        }
    }

    struct Result {
        let transcript: String
        let utterances: [Utterance]
        let duration: TimeInterval
        let warnings: [String]
        /// Mixed, compressed audio for playback, if it could be produced.
        let audioURL: URL?
    }

    /// Stops capture, transcribes whatever is left, and returns the transcript.
    func finish() -> Result {
        mic.stop()
        systemTap.stop()
        micWriter?.finish()
        systemWriter?.finish()
        transcriber.drain()

        lock.lock()
        let sorted = Self.deduplicate(utterances.sorted { $0.start < $1.start })
        var warnings = errors
        lock.unlock()

        if systemAudioAvailable, (systemWriter?.peakLevel ?? 0) < 0.001 {
            warnings.append("The other participants' audio came through completely silent. Allow Scribe under System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        if microphoneAvailable, (micWriter?.peakLevel ?? 0) < 0.001 {
            warnings.append("The microphone recorded silence for the whole meeting.")
        }

        var audioURL: URL?
        do {
            let sources = [micWriter?.continuousURL, systemWriter?.continuousURL].compactMap { $0 }
            audioURL = try AudioMixer.mix(sources, to: directory.appendingPathComponent("audio.m4a"))
        } catch {
            warnings.append("Could not build the playback audio: \(error.localizedDescription)")
        }

        return Result(transcript: Self.format(sorted),
                      utterances: sorted,
                      duration: Date().timeIntervalSince(startedAt),
                      warnings: warnings,
                      audioURL: audioURL)
    }

    /// Called when a meeting is abandoned before it was worth keeping.
    func discardAudio() {
        try? FileManager.default.removeItem(at: directory)
    }

    func removeAudioKeepingFolder() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Internals

    private func transcribe(_ segment: AudioSegment, speaker: Speaker) {
        transcriber.enqueue(segment, speaker: speaker) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let new):
                self.lock.lock()
                self.utterances.append(contentsOf: new)
                self.lock.unlock()
            case .failure(let error):
                self.record(error: error.localizedDescription)
                Log.error("transcription failed for \(segment.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func record(error message: String) {
        lock.lock()
        if !errors.contains(message) { errors.append(message) }
        lock.unlock()
        Log.error(message)
    }

    /// Each segment repeats the last couple of seconds of the previous one so
    /// that words are not clipped at a cut. Whisper therefore transcribes that
    /// tail twice; this removes the repeat by matching words rather than
    /// timestamps, which is what actually survives a boundary.
    static func deduplicate(_ utterances: [Utterance]) -> [Utterance] {
        func normalise(_ words: [String]) -> [String] {
            words.map { word in
                word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            }
        }

        var kept: [Utterance] = []
        var history: [Speaker: [String]] = [:]
        var lastEnd: [Speaker: TimeInterval] = [:]

        for utterance in utterances {
            var words = utterance.text.split(separator: " ").map(String.init)

            // Only consider trimming where two segments genuinely overlap in time.
            if let previousEnd = lastEnd[utterance.speaker], utterance.start < previousEnd {
                let previous = history[utterance.speaker] ?? []
                let limit = min(40, min(previous.count, words.count))
                var length = limit
                while length >= 3 {
                    if normalise(Array(previous.suffix(length))) == normalise(Array(words.prefix(length))) {
                        words.removeFirst(length)
                        break
                    }
                    length -= 1
                }
            }

            lastEnd[utterance.speaker] = max(lastEnd[utterance.speaker] ?? 0, utterance.end)
            guard !words.isEmpty else { continue }

            history[utterance.speaker, default: []].append(contentsOf: words)
            kept.append(Utterance(start: utterance.start,
                                  end: utterance.end,
                                  speaker: utterance.speaker,
                                  text: words.joined(separator: " "),
                                  language: utterance.language))
        }
        return removeSpeakerBleed(kept)
    }

    /// On laptop speakers the microphone also picks up the remote participants,
    /// so the same sentence is transcribed on both streams and the transcript
    /// reads double. Your own voice never comes back out of your own speakers,
    /// so when a "Me" line closely matches an overlapping "Others" line it is
    /// bleed, and the system-audio copy is the better one to keep.
    static func removeSpeakerBleed(_ utterances: [Utterance]) -> [Utterance] {
        let others = utterances.filter { $0.speaker == .others }
        guard !others.isEmpty else { return utterances }

        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 2 })
        }

        return utterances.filter { utterance in
            guard utterance.speaker == .me else { return true }
            let mine = tokens(utterance.text)
            // A single word is kept: a bare "yes" may be a real answer, and
            // losing it costs more than an occasional echoed word.
            guard mine.count >= 2 else { return true }

            // Pool every remote line that overlaps in time. Bleed regularly
            // straddles a segment boundary, so comparing against one line at a
            // time misses half of it. Allow slack: the two capture paths are
            // not sample-aligned.
            var remoteWords: Set<String> = []
            for other in others where other.start < utterance.end + 2 && other.end > utterance.start - 2 {
                remoteWords.formUnion(tokens(other.text))
            }
            guard !remoteWords.isEmpty else { return true }

            // How much of *my* line is explained by what was playing? Dividing
            // by my own word count (rather than the smaller of the two) keeps a
            // brief remote line from swallowing a long one of mine.
            let explained = Double(mine.intersection(remoteWords).count) / Double(mine.count)
            return explained < 0.7
        }
    }

    /// Merges the two streams into one readable, timestamped transcript,
    /// collapsing consecutive lines from the same side of the call.
    static func format(_ utterances: [Utterance]) -> String {
        var lines: [String] = []
        var currentSpeaker: Speaker?
        var currentStart: TimeInterval = 0
        var buffer: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, !buffer.isEmpty else { return }
            lines.append("[\(timecode(currentStart))] **\(speaker.rawValue)**: \(buffer.joined(separator: " "))")
            buffer.removeAll()
        }

        for utterance in utterances {
            if utterance.speaker != currentSpeaker {
                flush()
                currentSpeaker = utterance.speaker
                currentStart = utterance.start
            }
            buffer.append(utterance.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
