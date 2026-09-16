import Foundation

/// `Scribe --record <seconds> [--segment <seconds>]` — runs a complete capture →
/// segment → transcribe → merge cycle headlessly and prints the transcript.
/// Used to verify the pipeline without joining a real meeting.
enum RecordTest {

    static func run(seconds: Double, segmentSeconds: Int?) -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let prefs = Prefs.shared

        let session = MeetingSession(platforms: ["Test"], calendarTitle: nil, settings: prefs,
                                     segmentSeconds: segmentSeconds)
        do {
            try session.start()
        } catch {
            print("Could not start: \(error.localizedDescription)")
            exit(1)
        }

        print("Recording \(Int(seconds))s "
              + "(mic: \(session.microphoneAvailable ? "yes" : "no"), "
              + "system: \(session.systemAudioAvailable ? "yes" : "no"))…")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        print("Transcribing…\n")
        let result = session.finish()

        if CommandLine.arguments.contains("--verbose") {
            print("--- utterances ---")
            for u in result.utterances {
                print(String(format: "%7.2f–%7.2f  %-7@  %@",
                             u.start, u.end,
                             u.speaker.rawValue as NSString,
                             u.text as NSString))
            }
            print()
        }
        print("--- transcript (\(Int(result.duration))s, \(result.utterances.count) utterances) ---")
        print(result.transcript.isEmpty ? "(nothing transcribed)" : result.transcript)
        if !result.warnings.isEmpty {
            print("\n--- warnings ---")
            result.warnings.forEach { print("• \($0)") }
        }
        guard CommandLine.arguments.contains("--summarise") else {
            print("\nAudio kept at \(session.directory.path)")
            if !result.transcript.isEmpty { print(CLIStatus.successMarker) }
            exit(result.transcript.isEmpty ? 1 : 0)
        }

        // Same components the app uses when a real meeting ends, so this
        // exercises the production path rather than a parallel one.
        var failed = false
        var finished = false

        Task { @MainActor in
            defer { finished = true }
            let draft = Meeting(title: NotesGenerator.placeholderTitle(platforms: session.platforms),
                                started: session.startedAt,
                                ended: session.startedAt.addingTimeInterval(result.duration),
                                platforms: session.platforms,
                                model: "",
                                summary: "",
                                sections: [],
                                actionItems: [],
                                utterances: result.utterances,
                                audioFileName: nil,
                                vaultNotePath: nil,
                                warnings: result.warnings,
                                language: Language.dominant(in: result.utterances),
                                titleIsPlaceholder: true)
            let library = MeetingLibrary.shared
            let filed = library.add(draft, audioSource: result.audioURL)
            session.discardAudio()

            guard let stored = await library.generateNotes(for: filed.id) else {
                failed = true
                return
            }
            print("language: \(stored.language ?? "unknown")")
            print("title:    \(stored.title)")
            if let error = stored.notesError {
                print("notes:    FAILED — \(error)")
                failed = true
                return
            }
            print("model:    \(stored.model)")
            print("summary:  \(stored.summary.prefix(160))")
            print("sections: \(stored.sections.map(\.heading).joined(separator: ", "))")
            print("actions:")
            for item in stored.actionItems {
                let at = item.sourceStart.map { MeetingSession.timecode($0) } ?? "unlinked"
                let heard = item.sourceStart.flatMap { start in
                    stored.utterances.min { abs($0.start - start) < abs($1.start - start) }?.text
                } ?? ""
                print("  [\(at)] \(item.owner) — \(item.text)")
                if !heard.isEmpty { print("           heard: \(heard)") }
            }
            print("audio:    \(stored.audioFileName ?? "none")")
            print(CLIStatus.successMarker)
        }

        if !CLIWait.until({ finished }) { print("Timed out waiting for the model.") }
        exit(failed || !finished ? 1 : 0)
    }
}
