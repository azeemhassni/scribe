import Foundation

/// `Scribe --search <query>` — the same search the library window runs, from the
/// command line. Useful on its own, and the only way to check the snippet and
/// index arithmetic without clicking through the UI.
enum SearchTest {

    static func run(query: String) -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        var finished = false

        Task { @MainActor in
            defer { finished = true }
            let library = MeetingLibrary.shared
            library.reload()

            let results = MeetingSearch.search(library.meetings, query: query)
            let total = results.reduce(0) { $0 + $1.hits.count }
            print("\(total) result(s) in \(results.count) of \(library.meetings.count) meeting(s)\n")

            for result in results {
                print("\(result.meeting.title)  —  \(MeetingTime.summary(result.meeting))")
                for hit in result.hits.prefix(6) {
                    let where_ = hit.time.map { MeetingSession.timecode($0) } ?? hit.field.label
                    // Snippets are one line by construction; collapse any
                    // newlines a notes section brought with it.
                    let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
                    print("   [\(where_)] \(snippet)")
                }
                if result.hits.count > 6 { print("   … \(result.hits.count - 6) more") }
                print()
            }
            print(CLIStatus.successMarker)
        }

        _ = CLIWait.until({ finished }, timeout: 120)
        exit(0)
    }
}
