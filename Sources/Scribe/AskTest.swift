import Foundation

/// `Scribe --ask "<question>" [--meeting "<title substring>"]` — the same
/// question-answering the chat panel does, without the window.
enum AskTest {

    static func run(question: String, titleMatch: String?) -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        var finished = false
        var failed = false

        Task { @MainActor in
            defer { finished = true }
            let library = MeetingLibrary.shared
            library.reload()

            let meeting = titleMatch
                .flatMap { needle in
                    library.meetings.first { $0.title.localizedCaseInsensitiveContains(needle) }
                } ?? library.meetings.first

            guard let meeting else {
                print("no meetings in the library")
                failed = true
                return
            }

            print("meeting:  \(meeting.title)")
            print("length:   \(meeting.utterances.count) lines, \(MeetingTime.duration(meeting.duration))")

            do {
                let client = try await NotesEngineFactory.makeClient(prefs: Prefs.shared)
                let budget = max(4000, (client.contextWindow - 1500) * 4)
                let context = MeetingChatStore.context(for: meeting,
                                                       question: question,
                                                       budgetChars: budget)
                print("context:  \(context.count) of \(budget) chars"
                      + (context.contains("\n…\n") ? " (transcript trimmed to relevant parts)" : " (whole transcript)"))
                print("engine:   \(client.label)\n")
                print("Q: \(question)")

                let started = Date()
                let store = MeetingChatStore()
                store.load(meeting, folder: nil)      // folder nil: do not persist a test
                store.ask(question, prefs: Prefs.shared)

                while store.isAnswering || store.turns.count < 2 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    if Date().timeIntervalSince(started) > 300 { break }
                }

                if let error = store.error {
                    print("\nfailed: \(error)")
                    failed = true
                } else if let answer = store.turns.last, answer.role == .scribe {
                    print("\nA: \(answer.text)")
                    print("\n(\(Int(Date().timeIntervalSince(started)))s)")
                    print(CLIStatus.successMarker)
                } else {
                    print("\nno answer came back")
                    failed = true
                }
            } catch {
                print("failed: \(error.localizedDescription)")
                failed = true
            }
        }

        _ = CLIWait.until({ finished }, timeout: 420)
        exit(failed ? 1 : 0)
    }
}
