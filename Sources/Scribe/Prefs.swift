import Foundation

/// UserDefaults-backed configuration. Everything here is local to this Mac.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    /// Recommended when Ollama is installed but has nothing suitable yet.
    static let defaultOllamaModel = "gpt-oss:20b"
    private let defaults = UserDefaults.standard

    private func string(_ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }
    private func int(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    // MARK: Output

    @Published var vaultPath: String {
        didSet { defaults.set(vaultPath, forKey: "vaultPath") }
    }
    @Published var notesFolder: String {
        didSet { defaults.set(notesFolder, forKey: "notesFolder") }
    }
    /// Keeps the mixed recording in the library so transcript lines can be
    /// played back. The per-stream WAVs are always discarded.
    @Published var keepAudio: Bool {
        didSet { defaults.set(keepAudio, forKey: "keepAudio") }
    }
    /// Mirrors each meeting into the Obsidian vault as markdown.
    @Published var exportToVault: Bool {
        didSet { defaults.set(exportToVault, forKey: "exportToVault") }
    }

    // MARK: Detection

    @Published var autoDetect: Bool {
        didSet { defaults.set(autoDetect, forKey: "autoDetect") }
    }
    /// "ask" shows a prompt when a meeting is detected; "record" starts
    /// recording straight away.
    @Published var detectionMode: String {
        didSet { defaults.set(detectionMode, forKey: "detectionMode") }
    }
    var asksBeforeRecording: Bool { detectionMode != "record" }
    @Published var startDelaySeconds: Int {
        didSet { defaults.set(startDelaySeconds, forKey: "startDelaySeconds") }
    }
    @Published var stopDelaySeconds: Int {
        didSet { defaults.set(stopDelaySeconds, forKey: "stopDelaySeconds") }
    }
    /// Sessions shorter than this are discarded — a 30-second "can you hear me"
    /// is not a meeting.
    @Published var minimumMeetingSeconds: Int {
        didSet { defaults.set(minimumMeetingSeconds, forKey: "minimumMeetingSeconds") }
    }
    @Published var useCalendarTitles: Bool {
        didSet { defaults.set(useCalendarTitles, forKey: "useCalendarTitles") }
    }
    @Published var ignoredBundleIDs: String {
        didSet { defaults.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") }
    }

    // MARK: Transcription

    @Published var whisperBinary: String {
        didSet { defaults.set(whisperBinary, forKey: "whisperBinary") }
    }
    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: "whisperModel") }
    }
    @Published var whisperThreads: Int {
        didSet { defaults.set(whisperThreads, forKey: "whisperThreads") }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    /// Script for Hindi/Urdu speech, which Whisper cannot tell apart by ear.
    @Published var hindustaniScript: String {
        didSet { defaults.set(hindustaniScript, forKey: "hindustaniScript") }
    }
    /// Length of each rotating WAV chunk. Shorter means the transcript keeps up
    /// more closely; longer gives whisper more context per run.
    @Published var segmentSeconds: Int {
        didSet { defaults.set(segmentSeconds, forKey: "segmentSeconds") }
    }

    // MARK: Summarisation

    @Published var ollamaHost: String {
        didSet { defaults.set(ollamaHost, forKey: "ollamaHost") }
    }
    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published var contextTokens: Int {
        didSet { defaults.set(contextTokens, forKey: "contextTokens") }
    }
    /// Which engine writes the notes: Ollama, or the built-in llama.cpp server.
    @Published var notesEngine: String {
        didSet { defaults.set(notesEngine, forKey: "notesEngine") }
    }
    @Published var localModelID: String {
        didSet { defaults.set(localModelID, forKey: "localModelID") }
    }
    /// Set once the first-run setup has been completed or skipped.
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    var ignoredBundleIDSet: Set<String> {
        Set(ignoredBundleIDs
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    var notesDirectory: URL? {
        guard !vaultPath.isEmpty else { return nil }
        return URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
            .appendingPathComponent(notesFolder, isDirectory: true)
    }

    private init() {
        // No default: an export destination is something the user chooses in
        // setup, not somewhere Scribe guesses.
        vaultPath = defaults.string(forKey: "vaultPath") ?? ""
        notesFolder = defaults.string(forKey: "notesFolder") ?? "Meetings"
        keepAudio = defaults.object(forKey: "keepAudio") as? Bool ?? true
        exportToVault = defaults.object(forKey: "exportToVault") as? Bool ?? true

        autoDetect = defaults.object(forKey: "autoDetect") as? Bool ?? true
        detectionMode = defaults.string(forKey: "detectionMode") ?? "ask"
        // Detection only fires on a real call now, so it can speak up quickly.
        startDelaySeconds = defaults.object(forKey: "startDelaySeconds") as? Int ?? 8
        stopDelaySeconds = defaults.object(forKey: "stopDelaySeconds") as? Int ?? 45
        minimumMeetingSeconds = defaults.object(forKey: "minimumMeetingSeconds") as? Int ?? 120
        useCalendarTitles = defaults.object(forKey: "useCalendarTitles") as? Bool ?? true
        ignoredBundleIDs = defaults.string(forKey: "ignoredBundleIDs") ?? ""

        whisperBinary = defaults.string(forKey: "whisperBinary") ?? "/opt/homebrew/bin/whisper-cli"
        whisperModel = defaults.string(forKey: "whisperModel")
            ?? Paths.models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path
        whisperThreads = defaults.object(forKey: "whisperThreads") as? Int ?? 6
        language = defaults.string(forKey: "language") ?? "auto"
        segmentSeconds = defaults.object(forKey: "segmentSeconds") as? Int ?? 120
        hindustaniScript = defaults.string(forKey: "hindustaniScript") ?? HindustaniScript.systemDefault.rawValue

        ollamaHost = defaults.string(forKey: "ollamaHost") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? Self.defaultOllamaModel
        contextTokens = defaults.object(forKey: "contextTokens") as? Int ?? 32768
        notesEngine = defaults.string(forKey: "notesEngine") ?? NotesEngineKind.ollama.rawValue
        localModelID = defaults.string(forKey: "localModelID") ?? LocalRuntime.recommendedModel().id
        hasCompletedSetup = defaults.object(forKey: "hasCompletedSetup") as? Bool ?? false
    }
}
