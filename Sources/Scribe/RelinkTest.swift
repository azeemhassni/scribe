import Foundation

/// `Scribe --relink` — recomputes every action's link to the transcript.
/// Useful after the matcher changes; harmless to run repeatedly.
enum RelinkTest {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        var finished = false

        Task { @MainActor in
            defer { finished = true }
            let library = MeetingLibrary.shared
            library.reload()

            for meeting in library.meetings {
                guard !meeting.utterances.isEmpty, !meeting.actionItems.isEmpty else { continue }
                var updated = meeting
                updated.actionItems = ActionLinker.link(meeting.actionItems, to: meeting.utterances)
                library.save(updated)

                print("\(meeting.title)")
                for item in updated.actionItems {
                    guard let start = item.sourceStart else {
                        print("   [unlinked] \(item.owner) — \(item.text)")
                        continue
                    }
                    let line = meeting.utterances.min { abs($0.start - start) < abs($1.start - start) }
                    print("   \(MeetingSession.timecode(start))  \(item.owner) — \(item.text)")
                    print("        heard: \(line?.text ?? "")")
                }
                print()
            }
            print(CLIStatus.successMarker)
        }

        _ = CLIWait.until({ finished }, timeout: 120)
        exit(0)
    }
}
