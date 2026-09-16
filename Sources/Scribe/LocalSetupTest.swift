import Foundation

/// `Scribe --setup-local` — installs the built-in engine and proves it answers.
/// Also the headless path for anyone who would rather not use the setup window.
enum LocalSetupTest {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        var finished = false
        var failed = false

        Task { @MainActor in
            defer { finished = true }
            let prefs = Prefs.shared
            prefs.notesEngine = NotesEngineKind.local.rawValue
            let model = LocalRuntime.model(id: prefs.localModelID)

            do {
                if LocalRuntime.isRuntimeInstalled {
                    print("runtime: already installed")
                } else {
                    print("runtime: downloading llama.cpp \(LocalRuntime.build)…")
                    try await LocalRuntime.shared.installRuntime { progress in
                        report("runtime", progress)
                    }
                    print("\nruntime: installed at \(LocalRuntime.serverBinary.path)")
                }

                if model.isDownloaded {
                    print("model:   \(model.name) already downloaded")
                } else {
                    print("model:   downloading \(model.name) (\(Downloader.humanBytes(model.downloadBytes)))…")
                    try await Downloader.download(from: model.url, to: model.localURL) { progress in
                        report("model", progress)
                    }
                    print()
                }

                print("server:  starting…")
                let started = Date()
                try await LocalRuntime.shared.ensureServerRunning(model: model,
                                                                  contextTokens: prefs.contextTokens)
                print("server:  ready in \(Int(Date().timeIntervalSince(started)))s on port \(LocalRuntime.port)")

                let client = try await NotesEngineFactory.makeClient(prefs: prefs)
                print("engine:  \(client.label)\n")

                let reply = try await client.chat(
                    system: "You write meeting notes. Reply with markdown only.",
                    user: "Summarise in one sentence and list the action item:\n\nAlex: I'll send the invoice on Friday.")
                print(reply)
                print("\n\(CLIStatus.successMarker)")
            } catch {
                print("failed: \(error.localizedDescription)")
                failed = true
            }
        }

        _ = CLIWait.until({ finished }, timeout: 3600)
        exit(failed ? 1 : 0)
    }

    private static var lastPrint = Date.distantPast

    private static func report(_ label: String, _ progress: Downloader.Progress) {
        guard Date().timeIntervalSince(lastPrint) > 2 else { return }
        lastPrint = Date()
        let percent = Int(progress.fraction * 100)
        print("\r\(label):   \(percent)%  \(Downloader.humanBytes(progress.completed)) of \(Downloader.humanBytes(progress.total))",
              terminator: "")
        fflush(stdout)
    }
}
