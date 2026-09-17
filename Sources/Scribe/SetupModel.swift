import AVFoundation
import Foundation

/// State of one thing Scribe needs before it can record a meeting.
enum StepState: Equatable {
    case checking
    case needsAction(String)
    case working(String, Double?)
    case done(String)
    case failed(String)

    var isDone: Bool { if case .done = self { return true }; return false }
    var isBusy: Bool {
        switch self {
        case .working, .checking: return true
        default: return false
        }
    }
}

/// Drives first-run setup: what is missing, and how to get it.
///
/// Doubles as the repair screen — every step re-checks and can be run again, so
/// this is also where you come back when something breaks later.
@MainActor
final class SetupModel: ObservableObject {

    @Published var speechBinary: StepState = .checking
    @Published var speechModel: StepState = .checking
    @Published var notes: StepState = .checking
    @Published var microphone: StepState = .checking
    @Published var vault: StepState = .checking

    /// Every model the notes can be written with, installed or not.
    @Published var notesOptions: [NotesOption] = []
    @Published var notesSelection: NotesOption.Source?
    @Published var ollamaStatus: OllamaStatus = .notInstalled

    enum OllamaStatus { case notInstalled, notRunning, running }

    private let prefs = Prefs.shared
    /// Set once the user picks a model, so a re-check never overrides them.
    private var notesWereChosen = false

    var isReady: Bool {
        speechBinary.isDone && speechModel.isDone && notes.isDone && microphone.isDone
    }

    var isBusy: Bool {
        [speechBinary, speechModel, notes, microphone, vault].contains { $0.isBusy }
    }

    // MARK: - Checks

    func refresh() async {
        checkSpeechBinary()
        checkSpeechModel()
        checkMicrophone()
        checkVault()
        await checkNotes()
    }

    func checkSpeechBinary() {
        if FileManager.default.isExecutableFile(atPath: prefs.whisperBinary) {
            speechBinary = .done(prefs.whisperBinary)
            return
        }
        // Homebrew is the only supported source today, and its prefix differs
        // between Apple Silicon and Intel.
        for candidate in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            prefs.whisperBinary = candidate
            speechBinary = .done(candidate)
            return
        }
        speechBinary = .needsAction("whisper.cpp is not installed")
    }

    func checkSpeechModel() {
        let path = prefs.whisperModel
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64,
           size > 1_000_000 {
            speechModel = .done("\(Downloader.humanBytes(size)) · \((path as NSString).lastPathComponent)")
        } else {
            speechModel = .needsAction("Whisper large-v3-turbo · 547 MB download")
        }
    }

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .done("Granted")
        case .denied, .restricted:
            microphone = .failed("Denied — allow Scribe under System Settings › Privacy & Security › Microphone")
        default: microphone = .needsAction("Scribe records your side of the call")
        }
    }

    func checkVault() {
        guard !prefs.vaultPath.isEmpty else {
            vault = .done("Meetings stay in Scribe only")
            return
        }
        vault = .done(prefs.vaultPath)
    }

    /// Lists the models the notes can be written with and settles which one is
    /// selected.
    ///
    /// Models already in Ollama come first and need nothing downloaded; the
    /// built-in engine's models follow with their download size. One list, one
    /// selection: choosing an installed model completes the step on the spot.
    func checkNotes() async {
        if notesOptions.isEmpty { notes = .checking }

        let running = await OllamaService.isRunning(host: prefs.ollamaHost)
        ollamaStatus = running ? .running : (OllamaService.isInstalled ? .notRunning : .notInstalled)
        let installed = running ? await OllamaService.chatModels(host: prefs.ollamaHost) : []

        var options = installed.map { model in
            NotesOption(source: .ollama(model.name),
                        title: model.name,
                        detail: "In Ollama · \(Downloader.humanBytes(model.sizeBytes))",
                        isReady: true)
        }
        // Ollama with nothing in it: offer the recommended model as a pull.
        if running && installed.isEmpty {
            let name = Prefs.defaultOllamaModel
            options.append(NotesOption(source: .ollama(name), title: name,
                                       detail: "Ollama · 13 GB download", isReady: false))
        }
        for model in LocalRuntime.models {
            let ready = LocalRuntime.isRuntimeInstalled && model.isDownloaded
            options.append(NotesOption(source: .builtIn(model.id),
                                       title: model.name,
                                       detail: ready ? "Built in · downloaded" : "Built in · \(Downloader.humanBytes(model.downloadBytes)) download",
                                       isReady: ready))
        }
        notesOptions = options

        let valid = Set(options.map(\.source))
        if let current = notesSelection, valid.contains(current), notesWereChosen {
            // keep the user's choice
        } else if let saved = savedSelection(installed: installed), valid.contains(saved),
                  notesWereChosen || prefs.hasCompletedSetup || isReady(saved) {
            notesSelection = saved
        } else {
            notesSelection = recommendedSelection(installed: installed)
            if let selection = notesSelection { save(selection) }
        }
        updateNotesState()
    }

    /// What the preferences currently point at, if anything.
    private func savedSelection(installed: [OllamaService.Model]) -> NotesOption.Source? {
        switch NotesEngineKind(rawValue: prefs.notesEngine) ?? .ollama {
        case .ollama:
            let match = installed.first { OllamaService.sameModel($0.name, prefs.ollamaModel) }
            return .ollama(match?.name ?? prefs.ollamaModel)
        case .local:
            return .builtIn(prefs.localModelID)
        }
    }

    /// First-run default: a model the user already has, then the built-in tier
    /// that suits this Mac.
    private func recommendedSelection(installed: [OllamaService.Model]) -> NotesOption.Source? {
        if let preferred = installed.first(where: { OllamaService.sameModel($0.name, Prefs.defaultOllamaModel) }) {
            return .ollama(preferred.name)
        }
        // The largest installed model that leaves room for everything else.
        let budget = Int64(ProcessInfo.processInfo.physicalMemory / 2)
        let fitting = installed.filter { $0.sizeBytes <= budget }.max { $0.sizeBytes < $1.sizeBytes }
        if let model = fitting ?? installed.min(by: { $0.sizeBytes < $1.sizeBytes }) {
            return .ollama(model.name)
        }
        return .builtIn(LocalRuntime.recommendedModel().id)
    }

    private func isReady(_ source: NotesOption.Source) -> Bool {
        notesOptions.first { $0.source == source }?.isReady ?? false
    }

    private func save(_ source: NotesOption.Source) {
        switch source {
        case .ollama(let name):
            prefs.notesEngine = NotesEngineKind.ollama.rawValue
            prefs.ollamaModel = name
        case .builtIn(let id):
            prefs.notesEngine = NotesEngineKind.local.rawValue
            prefs.localModelID = id
        }
    }

    private func updateNotesState() {
        guard let selection = notesSelection,
              let option = notesOptions.first(where: { $0.source == selection }) else {
            notes = .needsAction("Choose a model")
            return
        }
        if option.isReady {
            switch selection {
            case .ollama: notes = .done("\(option.title), in Ollama")
            case .builtIn: notes = .done("\(option.title), built in")
            }
        } else {
            notes = .needsAction("\(option.title) · \(option.detail.components(separatedBy: " · ").last ?? "")")
        }
    }

    // MARK: - Actions

    func installSpeechBinary() async {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            speechBinary = .failed("Homebrew not found. Install it from brew.sh, then run `brew install whisper-cpp`.")
            return
        }
        speechBinary = .working("Installing whisper.cpp with Homebrew…", nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "whisper-cpp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        } catch {
            speechBinary = .failed(error.localizedDescription)
            return
        }
        checkSpeechBinary()
        if case .needsAction = speechBinary {
            speechBinary = .failed("Homebrew finished but whisper-cli is still missing.")
        }
    }

    func downloadSpeechModel() async {
        let destination = URL(fileURLWithPath: prefs.whisperModel)
        let source = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
        speechModel = .working("Downloading the speech model…", 0)
        do {
            try await Downloader.download(from: source, to: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.speechModel = .working(
                        "\(Downloader.humanBytes(progress.completed)) of \(Downloader.humanBytes(progress.total))",
                        progress.fraction)
                }
            }
            checkSpeechModel()
        } catch {
            speechModel = .failed(error.localizedDescription)
        }
    }

    func setUpNotes() async {
        switch notesSelection {
        case .ollama(let name): await pullOllamaModel(name)
        case .builtIn(let id): await installLocalEngine(LocalRuntime.model(id: id))
        case nil: break
        }
    }

    private func pullOllamaModel(_ name: String) async {
        notes = .working("Downloading \(name) into Ollama…", 0)
        do {
            try await OllamaService.pull(model: name, host: prefs.ollamaHost) { [weak self] status, fraction in
                Task { @MainActor in self?.notes = .working(status, fraction) }
            }
            await checkNotes()
        } catch {
            notes = .failed(error.localizedDescription)
        }
    }

    private func installLocalEngine(_ localModel: LocalModel) async {
        do {
            if !LocalRuntime.isRuntimeInstalled {
                notes = .working("Downloading the inference runtime…", 0)
                try await LocalRuntime.shared.installRuntime { [weak self] progress in
                    Task { @MainActor in
                        self?.notes = .working("Runtime · \(Downloader.humanBytes(progress.completed))",
                                               progress.fraction)
                    }
                }
            }
            if !localModel.isDownloaded {
                let model = localModel
                notes = .working("Downloading \(model.name)…", 0)
                try await Downloader.download(from: model.url, to: model.localURL) { [weak self] progress in
                    Task { @MainActor in
                        self?.notes = .working(
                            "\(model.name) · \(Downloader.humanBytes(progress.completed)) of \(Downloader.humanBytes(progress.total))",
                            progress.fraction)
                    }
                }
            }
            await checkNotes()
        } catch {
            notes = .failed(error.localizedDescription)
        }
    }

    func requestMicrophone() async {
        microphone = .working("Waiting for permission…", nil)
        _ = await MicrophoneCapture.requestPermission()
        checkMicrophone()
    }

    func chooseNotes(_ source: NotesOption.Source) {
        notesWereChosen = true
        notesSelection = source
        save(source)
        updateNotesState()
    }

    /// Opens Ollama so its models appear in the list.
    func startOllama() async {
        notes = .working("Starting Ollama…", nil)
        do {
            try await OllamaService.launch(host: prefs.ollamaHost)
        } catch {
            notes = .failed(error.localizedDescription)
            return
        }
        await checkNotes()
    }
}

/// One way to write notes: a model in Ollama or one of the built-in engine's.
struct NotesOption: Identifiable, Hashable {
    enum Source: Hashable {
        case ollama(String)
        case builtIn(String)
    }

    let source: Source
    let title: String
    let detail: String
    /// Usable now, with nothing to download.
    let isReady: Bool

    var id: Source { source }
}
