import AVFoundation
import Foundation

/// `Scribe --transcribe-file <audio> [--segment <seconds>]` — runs an audio
/// file through segmentation, transcription and notes exactly as a meeting
/// would, without the microphone or system audio.
///
/// Live test recordings pick up whatever else the Mac is playing; this is the
/// repeatable way to check transcription and notes for a given recording.
enum FileTest {

    static func run(path: String, segmentSeconds: Int?) -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let prefs = Prefs.shared
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        let workDirectory = Paths.sessions.appendingPathComponent("file-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        // exit() skips defer, so every way out goes through here.
        func finish(_ code: Int32) -> Never {
            try? FileManager.default.removeItem(at: workDirectory)
            exit(code)
        }

        let transcriber = Transcriber(
            binary: URL(fileURLWithPath: prefs.whisperBinary),
            model: URL(fileURLWithPath: prefs.whisperModel),
            threads: prefs.whisperThreads,
            language: prefs.language,
            hindustaniScript: HindustaniScript(rawValue: prefs.hindustaniScript) ?? .systemDefault)

        let lock = NSLock()
        var utterances: [Utterance] = []
        let writer = AudioSegmentWriter(directory: workDirectory,
                                        prefix: "file",
                                        segmentSeconds: Double(segmentSeconds ?? prefs.segmentSeconds),
                                        clockStart: Date()) { segment in
            transcriber.enqueue(segment, speaker: .others) { result in
                if case .success(let lines) = result {
                    lock.lock(); utterances.append(contentsOf: lines); lock.unlock()
                }
            }
        }

        let duration: TimeInterval
        do {
            let file = try AVAudioFile(forReading: source)
            guard let resampler = Resampler(from: file.processingFormat) else {
                print("Unsupported audio format."); finish(1)
            }
            duration = Double(file.length) / file.processingFormat.sampleRate
            // Fed far faster than real time, so the writer never pads silence;
            // pauses in the recording itself still drive the segment cuts.
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try file.read(into: buffer, frameCount: 4096)
                if let converted = resampler.convert(buffer) { writer.append(converted) }
            }
        } catch {
            print("Could not read \(source.lastPathComponent): \(error.localizedDescription)")
            finish(1)
        }
        writer.finish()
        transcriber.drain()

        lock.lock()
        let lines = MeetingSession.deduplicate(utterances.sorted { $0.start < $1.start })
        lock.unlock()

        print("--- transcript (\(lines.count) lines) ---")
        for line in lines {
            print(String(format: "%6.1f  %@  %@", line.start, (line.language ?? "??") as NSString, line.text as NSString))
        }
        print()

        var finished = false
        var failed = false
        Task { @MainActor in
            defer { finished = true }
            let draft = Meeting(title: NotesGenerator.placeholderTitle(platforms: []),
                                started: Date(),
                                ended: Date().addingTimeInterval(duration),
                                platforms: [],
                                model: "",
                                summary: "",
                                sections: [],
                                actionItems: [],
                                utterances: lines,
                                audioFileName: nil,
                                vaultNotePath: nil,
                                language: Language.dominant(in: lines),
                                titleIsPlaceholder: true)
            let library = MeetingLibrary.shared
            let filed = library.add(draft, audioSource: nil)
            guard let stored = await library.generateNotes(for: filed.id) else { failed = true; return }

            print("language: \(stored.language ?? "unknown")")
            print("title:    \(stored.title)")
            if let error = stored.notesError {
                print("notes:    FAILED — \(error)"); failed = true; return
            }
            print("\n\(stored.summary)\n")
            for section in stored.sections { print("## \(section.heading)\n\(section.body)\n") }
            print("actions:")
            for item in stored.actionItems {
                let at = item.sourceStart.map { MeetingSession.timecode($0) } ?? "unlinked"
                let heard = item.sourceStart.flatMap { start in
                    stored.utterances.min { abs($0.start - start) < abs($1.start - start) }?.text
                } ?? ""
                print("  [\(at)] \(item.owner) — \(item.text)")
                if !heard.isEmpty { print("           heard: \(heard)") }
            }
            if CommandLine.arguments.contains("--keep") {
                print("\nfiled in library as \(stored.id)")
            } else {
                library.delete(stored)
            }
            print(CLIStatus.successMarker)
        }
        _ = CLIWait.until({ finished }, timeout: 1800)
        finish(failed ? 1 : 0)
    }
}
