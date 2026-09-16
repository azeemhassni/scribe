import Foundation

enum Speaker: String, Codable {
    case me = "Me"
    case others = "Others"
}

struct Utterance: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Speaker
    let text: String
    /// Whisper language code the line was transcribed as, e.g. "en" or "ur".
    var language: String? = nil
}

/// Drives whisper.cpp's `whisper-cli` over the rotating WAV segments.
///
/// Work is serialised on one queue: two parallel whisper runs would double GPU
/// pressure for no wall-clock gain, and this is meant to sit quietly in the
/// background while you are in the meeting.
final class Transcriber {

    enum TranscribeError: LocalizedError {
        case binaryMissing(String)
        case modelMissing(String)
        case failed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing(let path):
                return "whisper-cli not found at \(path). Open Setup to install it, or set the path in Settings › Models."
            case .modelMissing(let path):
                return "Whisper model not found at \(path). Open Setup to download it."
            case .failed(let code, let output):
                return "whisper-cli exited with \(code): \(output.suffix(400))"
            }
        }
    }

    private struct WhisperJSON: Decodable {
        struct Result: Decodable { let language: String? }
        let result: Result?
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }

    private let binary: URL
    private let model: URL
    private let threads: Int
    private let language: String
    private let queue = DispatchQueue(label: "scribe.transcribe", qos: .utility)
    private let maxSegmentCharacters = 150

    private let hindustaniScript: HindustaniScript

    init(binary: URL, model: URL, threads: Int, language: String, hindustaniScript: HindustaniScript) {
        self.binary = binary
        self.model = model
        self.threads = threads
        self.language = language
        self.hindustaniScript = hindustaniScript
    }

    /// Settles which language to transcribe a segment as.
    ///
    /// Detection is its own cheap pass (under a second, mostly model load) so
    /// the answer can be corrected before transcribing: Hindi and Urdu share
    /// one spoken language, and which script it is written in is the user's
    /// call, not Whisper's. Each segment is judged separately, so a meeting
    /// that moves between English and Urdu gets both right.
    private func resolveLanguage(for segment: AudioSegment) -> String {
        guard language == "auto" else { return language }
        guard let detected = detectLanguage(segment.url) else { return "auto" }
        if detected == "hi" || detected == "ur" { return hindustaniScript.whisperCode }
        return detected
    }

    private func detectLanguage(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "-f", url.path, "-t", String(threads), "-dl"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        // "auto-detected language: ur (p = 0.93)"
        guard let range = output.range(of: #"auto-detected language: ([a-z]+)"#, options: .regularExpression)
        else { return nil }
        return output[range].split(separator: " ").last.map(String.init)
    }

    /// Noise whisper emits over silence or music; never useful in notes.
    private static let junk: Set<String> = [
        "[blank_audio]", "[ silence ]", "(silence)", "[music]", "(music)",
        "[inaudible]", "thank you.", "thanks for watching!", "you", ".", "...",
        "[sound]", "(buzzing)", "[typing]",
    ]

    /// Whisper was trained on subtitled video, so on trailing silence it likes
    /// to emit subtitle credits that were never spoken. These are always
    /// artefacts, never meeting content.
    private static let hallucinationMarkers: [String] = [
        "castingwords", "amara.org", "subtitles by", "subtitled by",
        "transcription by", "transcribed by", "subs by", "captions by",
        "thanks for watching", "please subscribe", "like and subscribe",
        "www.", "http",
    ]

    private static func isArtefact(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if junk.contains(lowered) { return true }
        return hallucinationMarkers.contains { lowered.contains($0) }
    }

    func enqueue(_ segment: AudioSegment,
                 speaker: Speaker,
                 completion: @escaping (Result<[Utterance], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let utterances = try self.run(segment, speaker: speaker)
                completion(.success(utterances))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Blocks until every already-queued segment has been transcribed.
    func drain() {
        queue.sync { }
    }

    private func run(_ segment: AudioSegment, speaker: Speaker) throws -> [Utterance] {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TranscribeError.binaryMissing(binary.path)
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscribeError.modelMissing(model.path)
        }

        let segmentLanguage = resolveLanguage(for: segment)
        let outputBase = segment.url.deletingPathExtension()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", model.path,
            "-f", segment.url.path,
            "-t", String(threads),
            "-l", segmentLanguage,
            "-np",              // no progress spam
            "-oj",              // JSON output
            // Left alone, whisper emits a whole paragraph as one segment —
            // 25-second "utterances" that are useless to click on and too
            // coarse to locate anything in. Capping the length gives roughly
            // sentence-sized lines with timestamps worth trusting; splitting on
            // words rather than tokens stops it cutting mid-word to obey the cap.
            "-ml", String(maxSegmentCharacters),
            "-sow",
            "-of", outputBase.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscribeError.failed(process.terminationStatus, output)
        }

        let jsonURL = URL(fileURLWithPath: outputBase.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(WhisperJSON.self, from: data)
        let transcribedAs = decoded.result?.language ?? (segmentLanguage == "auto" ? nil : segmentLanguage)

        let lines = decoded.transcription.compactMap { raw -> Utterance? in
            let start = Double(raw.offsets.from) / 1000
            let end = Double(raw.offsets.to) / 1000
            // Drop anything that lives entirely inside the overlap we already
            // transcribed as part of the previous segment.
            if end <= segment.headOverlap { return nil }

            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isArtefact(text) else { return nil }

            return Utterance(start: segment.startTime + start,
                             end: segment.startTime + end,
                             speaker: speaker,
                             text: text,
                             language: transcribedAs)
        }
        return Self.collapsingLoops(lines)
    }

    /// Whisper sometimes gets stuck and emits one line over and over, a second
    /// apart, across a stretch it could not make sense of. Keep the first of a
    /// run of three or more identical lines. Two in a row is left alone: people
    /// do say "okay, okay".
    private static func collapsingLoops(_ lines: [Utterance]) -> [Utterance] {
        var kept: [Utterance] = []
        var index = 0
        while index < lines.count {
            let key = lines[index].text.lowercased()
            var runEnd = index
            while runEnd + 1 < lines.count, lines[runEnd + 1].text.lowercased() == key { runEnd += 1 }
            let runLength = runEnd - index + 1
            kept.append(contentsOf: runLength >= 3 ? [lines[index]] : Array(lines[index...runEnd]))
            index = runEnd + 1
        }
        return kept
    }
}
