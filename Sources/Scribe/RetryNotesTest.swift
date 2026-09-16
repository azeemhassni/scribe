import Foundation

/// `Scribe --retry-notes` — retries notes for every meeting whose notes failed.
enum RetryNotesTest {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        var finished = false
        var failures = 0

        Task { @MainActor in
            defer { finished = true }
            let library = MeetingLibrary.shared
            library.reload()
            let pending = library.meetings.filter { $0.notesError != nil }
            print("\(pending.count) meeting(s) without notes")

            for meeting in pending {
                print("\n\(meeting.title) — \(meeting.platforms.joined(separator: ", "))")
                print("  was:  \(meeting.notesError ?? "")")
                guard let result = await library.generateNotes(for: meeting.id) else { continue }
                if let error = result.notesError {
                    failures += 1
                    print("  now:  FAILED — \(error)")
                } else {
                    print("  now:  \(result.title) · \(result.actionItems.count) actions · \(result.model)")
                    print("        \(result.summary.prefix(200))")
                }
            }
            if failures == 0 { print("\n\(CLIStatus.successMarker)") }
        }

        _ = CLIWait.until({ finished }, timeout: 3600)
        exit(failures == 0 ? 0 : 1)
    }
}
