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

    @Published var engine: NotesEngineKind = .ollama
    @Published var localModel: LocalModel = LocalRuntime.recommendedModel()
    @Published var ollamaDetected = false

    private let prefs = Prefs.shared
    /// Set once the user picks an engine, so detection stops overriding them.
    private var engineWasChosen = false

    var isReady: Bool {
        speechBinary.isDone && speechModel.isDone && notes.isDone && microphone.isDone
    }

    var isBusy: Bool {
        [speechBinary, speechModel, notes, microphone, vault].contains { $0.isBusy }
    }

    // MARK: - Checks

    func refresh() async {
        engine = NotesEngineKind(rawValue: prefs.notesEngine) ?? .ollama
        localModel = LocalRuntime.model(id: prefs.localModelID)
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

    func checkNotes() async {
        notes = .checking
        ollamaDetected = await OllamaService.isRunning(host: prefs.ollamaHost)

        // Auto-detection is a first-run convenience, not a standing policy: once
        // the engine has been chosen, re-running these checks must not quietly
        // switch it back because Ollama happens to be running.
        if engineWasChosen || prefs.hasCompletedSetup {
            engine = NotesEngineKind(rawValue: prefs.notesEngine) ?? .ollama
        } else {
            engine = ollamaDetected ? .ollama : .local
            prefs.notesEngine = engine.rawValue
        }

        switch engine {
        case .ollama:
            guard ollamaDetected else {
                notes = .needsAction("Ollama is not running — start it, or use the built-in engine")
                return
            }
            let models = await OllamaService.installedModels(host: prefs.ollamaHost)
            if models.contains(prefs.ollamaModel) {
                notes = .done("\(prefs.ollamaModel) via Ollama")
            } else if let first = models.first {
                notes = .needsAction("`\(prefs.ollamaModel)` is not pulled — you have \(first)")
            } else {
                notes = .needsAction("Ollama is running but has no models")
            }

        case .local:
            if LocalRuntime.isRuntimeInstalled && localModel.isDownloaded {
                notes = .done("\(localModel.name), built in")
            } else {
                let total = (LocalRuntime.isRuntimeInstalled ? 0 : LocalRuntime.runtimeDownloadBytes)
                    + (localModel.isDownloaded ? 0 : localModel.downloadBytes)
                notes = .needsAction("\(localModel.name) · \(Downloader.humanBytes(total)) download")
            }
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
        switch engine {
        case .ollama:
            await pullOllamaModel()
        case .local:
            await installLocalEngine()
        }
    }

    private func pullOllamaModel() async {
        notes = .working("Pulling \(prefs.ollamaModel)…", 0)
        do {
            try await OllamaService.pull(model: prefs.ollamaModel, host: prefs.ollamaHost) { [weak self] status, fraction in
                Task { @MainActor in self?.notes = .working(status, fraction) }
            }
            await checkNotes()
        } catch {
            notes = .failed(error.localizedDescription)
        }
    }

    private func installLocalEngine() async {
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
            prefs.localModelID = localModel.id
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

    func chooseEngine(_ kind: NotesEngineKind) {
        engineWasChosen = true
        engine = kind
        prefs.notesEngine = kind.rawValue
        Task { await checkNotes() }
    }

    func chooseLocalModel(_ model: LocalModel) {
        localModel = model
        prefs.localModelID = model.id
        Task { await checkNotes() }
    }
}
