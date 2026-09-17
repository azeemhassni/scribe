import Foundation

/// `Scribe --setup-check [--choose ollama:<name>|builtin:<id>]` — prints what
/// the setup window's notes step would list and select on this Mac.
///
/// Settings can be overridden for one run with `-key value` arguments, and any
/// setting the check writes is restored afterwards.
enum SetupCheck {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let domain = Bundle.main.bundleIdentifier ?? "com.azeemhassni.scribe"
        let saved = UserDefaults.standard.persistentDomain(forName: domain)
        var finished = false

        Task { @MainActor in
            defer { finished = true }
            let model = SetupModel()
            await model.refresh()
            report(model, heading: "after opening setup")

            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--choose"), i + 1 < args.count {
                let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
                let source: NotesOption.Source = parts[0] == "ollama" ? .ollama(parts[1]) : .builtIn(parts[1])
                model.chooseNotes(source)
                report(model, heading: "after choosing \(args[i + 1])")
                await model.refresh()
                report(model, heading: "after re-checking")
            }
            print(CLIStatus.successMarker)
        }

        _ = CLIWait.until({ finished }, timeout: 60)
        if let saved {
            UserDefaults.standard.setPersistentDomain(saved, forName: domain)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        exit(0)
    }

    @MainActor
    private static func report(_ model: SetupModel, heading: String) {
        print("— \(heading)")
        print("  ollama: \(model.ollamaStatus) · setup completed: \(Prefs.shared.hasCompletedSetup)")
        for option in model.notesOptions {
            let mark = option.source == model.notesSelection ? "(•)" : "( )"
            print("  \(mark) \(option.title) · \(option.detail)")
        }
        print("  step: \(model.notes)\n")
    }
}
