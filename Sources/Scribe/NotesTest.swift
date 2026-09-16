import Foundation

/// `Scribe --test-notes` — runs the summariser and vault writer over a sample
/// transcript, so you can see what your chosen model produces (and confirm the
/// note lands in the vault) without sitting through a meeting.
enum NotesTest {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let prefs = Prefs.shared
        var summarizer: Summarizer?
        var exitCode: Int32 = 0
        var finished = false

        let started = Date()

        Task {
            defer { finished = true }
            do {
                let client = try await NotesEngineFactory.makeClient(prefs: prefs)
                print("Summarising a sample transcript with \(client.label)…\n")
                summarizer = Summarizer(client: client)
                let body = try await summarizer!.notes(for: sampleTranscript,
                                                      title: "Q4 launch sync",
                                                      participantsHint: "Platform: Zoom")
                print(body)
                print("\n--- generated in \(Int(Date().timeIntervalSince(started)))s ---\n")

                let parsed = NotesParser.parse(body)
                print("--- parsed structure ---")
                print("summary: \(parsed.summary.prefix(80))…")
                print("sections: \(parsed.sections.map(\.heading).joined(separator: ", "))")
                for item in parsed.actions {
                    print("  [\(item.done ? "x" : " ")] \(item.owner) — \(item.text)")
                }

                guard let directory = prefs.notesDirectory else {
                    print("\nNo vault configured; not writing a file.")
                    return
                }
                let meeting = Meeting(title: "Scribe test note",
                                      started: started,
                                      ended: Date(),
                                      platforms: ["Zoom"],
                                      model: prefs.ollamaModel,
                                      summary: parsed.summary,
                                      sections: parsed.sections,
                                      actionItems: parsed.actions,
                                      utterances: [],
                                      audioFileName: nil,
                                      vaultNotePath: nil)
                let url = try VaultWriter.write(meeting, into: directory)
                print("\nWrote \(url.path)")
                print(CLIStatus.successMarker)
            } catch {
                print("Failed: \(error.localizedDescription)")
                exitCode = 1
            }
        }

        if !CLIWait.until({ finished }) {
            print("Timed out waiting for the model.")
            exitCode = 1
        }
        exit(exitCode)
    }

    private static let sampleTranscript = """
    [00:00] **Others**: Alright, everyone here? Let\'s start with the launch date. \
    Marketing wants the twelfth of October but engineering flagged the migration.

    [00:14] **Me**: The migration is the risk. The script works on staging but I \
    have not run it against production volume yet. I need until the eighth to be \
    confident.

    [00:31] **Others**: That still leaves four days of buffer. Can you have a \
    dry run done by Wednesday?

    [00:38] **Me**: Yes, Wednesday works. I will post the numbers in the channel.

    [00:44] **Others**: Good. Then we are locking October twelfth. Priya, you own \
    the customer comms — the email needs to go out three days before, so the ninth.

    [00:58] **Others**: Understood, I will draft it by Monday and send it round \
    for review.

    [01:05] **Others**: Last thing, pricing. We still have not decided whether the \
    new tier is thirty or thirty-five dollars.

    [01:14] **Me**: I would rather not decide that in this call. Can we take it to \
    next Tuesday with the actual conversion data?

    [01:22] **Others**: Fine, Tuesday. Someone pull the cohort numbers before then.
    """
}
