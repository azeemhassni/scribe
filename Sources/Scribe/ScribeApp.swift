import SwiftUI

@main
struct ScribeApp: App {
    @StateObject private var controller = ScribeController()
    @StateObject private var prefs = Prefs.shared
    @ObservedObject private var library = MeetingLibrary.shared

    init() {
        if CommandLine.arguments.contains("--doctor") { Doctor.run() }
        if CommandLine.arguments.contains("--test-notes") { NotesTest.run() }
        if CommandLine.arguments.contains("--relink") { RelinkTest.run() }
        if CommandLine.arguments.contains("--setup-local") { LocalSetupTest.run() }
        if CommandLine.arguments.contains("--retry-notes") { RetryNotesTest.run() }
        if CommandLine.arguments.contains("--setup-check") { SetupCheck.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-detection") {
            let args = CommandLine.arguments
            DetectionProbe.run(seconds: i + 1 < args.count ? Int(args[i + 1]) ?? 10 : 10)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe-file"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            let segment = args.firstIndex(of: "--segment").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            FileTest.run(path: args[i + 1], segmentSeconds: segment)
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--record"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            var segment: Int?
            if let j = args.firstIndex(of: "--segment"), j + 1 < args.count { segment = Int(args[j + 1]) }
            RecordTest.run(seconds: seconds, segmentSeconds: segment)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
                .environmentObject(prefs)
                .environmentObject(library)
        } label: {
            MenuBarLabel(icon: iconName) { controller.bootstrap() }
        }
        .menuBarExtraStyle(.window)

        Window("Set up Scribe", id: SetupWindow.id) {
            SetupView()
                .environmentObject(prefs)
        }
        .defaultSize(width: 640, height: 720)
        .windowResizability(.contentMinSize)

        Window("Meetings", id: LibraryWindow.id) {
            LibraryView()
                .environmentObject(library)
                .environmentObject(prefs)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        SwiftUI.Settings {
            PreferencesView()
                .environmentObject(controller)
                .environmentObject(prefs)
        }
    }

    private var iconName: String {
        switch controller.state {
        case .idle:       return "waveform"
        case .armed:      return "waveform.badge.magnifyingglass"
        case .detected:   return "waveform.badge.plus"
        case .recording:  return "record.circle.fill"
        case .processing: return "waveform.badge.exclamationmark"
        case .failed:     return "exclamationmark.triangle.fill"
        }
    }
}

/// The menu bar item's icon. A view rather than a bare `Image` so it can reach
/// the environment and honour `--library` at launch.
private struct MenuBarLabel: View {
    let icon: String
    let onFirstAppear: () -> Void
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Image(systemName: icon)
            .onAppear {
                onFirstAppear()
                // A fresh install has no models and no permissions, so the menu
                // bar icon alone would look like an app that does nothing.
                if !prefs.hasCompletedSetup || CommandLine.arguments.contains("--setup") {
                    SetupWindow.open(openWindow)
                } else if CommandLine.arguments.contains("--library") {
                    LibraryWindow.open(openWindow)
                }
            }
    }
}

// MARK: - Menu bar popover

struct MenuContent: View {
    @EnvironmentObject var controller: ScribeController
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var library: MeetingLibrary
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !controller.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            controls
            Divider()
            recents
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var header: some View {
        switch controller.state {
        case .idle:
            Label("Watching for meetings", systemImage: "waveform")
                .font(.headline)
        case .armed(let message):
            Label(message, systemImage: "ear")
                .font(.headline)
                .foregroundStyle(.secondary)
        case .detected(let name):
            VStack(alignment: .leading, spacing: 2) {
                Label("Meeting in \(name)", systemImage: "waveform.badge.plus")
                    .font(.headline)
                Text("Not recording yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .recording:
            VStack(alignment: .leading, spacing: 2) {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                // Text(style: .timer) is updated by the system, so the clock keeps
                // running however often the menu redraws.
                HStack(spacing: 4) {
                    if let started = controller.recordingStarted {
                        Text(started, style: .timer).monospacedDigit()
                    }
                    Text(recordingDetail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .processing(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.headline)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Dismiss") { controller.clearError() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var recordingDetail: String {
        var parts = [""]
        if !controller.activePlatforms.isEmpty {
            parts.append(controller.activePlatforms.joined(separator: ", "))
        }
        parts.append("\(controller.transcribedLines) lines transcribed")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var controls: some View {
        if case .recording = controller.state {
            HStack {
                Button("Stop & write notes") { controller.stopManually() }
                    .buttonStyle(.borderedProminent)
                Button("Discard") { controller.discardCurrent() }
            }
        } else if case .processing = controller.state {
            EmptyView()
        } else if case .detected = controller.state {
            HStack {
                Button("Record") { controller.recordDetectedMeeting() }
                    .buttonStyle(.borderedProminent)
                Button("Not now") { controller.dismissDetectedMeeting() }
            }
        } else {
            HStack {
                Button("Record now") { controller.startManually() }
                Toggle("Auto-detect", isOn: $prefs.autoDetect)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: prefs.autoDetect) { _, _ in controller.applyDetectorSettings() }
            }
        }
    }

    @ViewBuilder private var recents: some View {
        if library.meetings.isEmpty {
            Text("No meetings yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent meetings").font(.caption).foregroundStyle(.secondary)
                ForEach(library.meetings.prefix(5)) { meeting in
                    Button {
                        LibraryWindow.open(openWindow)
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(MeetingTime.summary(meeting))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if meeting.openActionCount > 0 {
                                Text("\(meeting.openActionCount)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open library") { LibraryWindow.open(openWindow) }
            Button("Log") { controller.openLog() }
            Spacer()
            Button("Setup…") { SetupWindow.open(openWindow) }
            Button("Settings…") { SettingsWindow.open(openSettings) }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    @EnvironmentObject var controller: ScribeController
    @EnvironmentObject var prefs: Prefs
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        TabView {
            outputTab.tabItem { Label("Output", systemImage: "folder") }
            detectionTab.tabItem { Label("Detection", systemImage: "ear") }
            modelsTab.tabItem { Label("Models", systemImage: "brain") }
        }
        .frame(width: 500)
        .padding(20)
    }

    private var outputTab: some View {
        Form {
            HStack {
                TextField("Vault", text: $prefs.vaultPath)
                Button("Choose…") { chooseVault() }
            }
            TextField("Subfolder", text: $prefs.notesFolder)
            Toggle("Keep the recording for playback", isOn: $prefs.keepAudio)
            Toggle("Also export each meeting to the vault", isOn: $prefs.exportToVault)
            Text("Notes, transcripts and audio live in Scribe's own library. The vault copy is an export, rewritten whenever you edit here — so edit in Scribe, not in Obsidian.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Start Scribe at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    loginItemError = LoginItem.set(enabled)
                    launchAtLogin = LoginItem.isEnabled
                }
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.orange)
            } else if LoginItem.requiresApproval {
                Text("Approve Scribe under System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Scribe can only detect a meeting while it is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectionTab: some View {
        Form {
            Toggle("Detect meetings automatically", isOn: $prefs.autoDetect)
            Picker("When a meeting starts", selection: $prefs.detectionMode) {
                Text("Ask before recording").tag("ask")
                Text("Record automatically").tag("record")
            }
            LabeledContent("Detect after") {
                Stepper("\(prefs.startDelaySeconds)s in a call", value: $prefs.startDelaySeconds, in: 2...120, step: 2)
            }
            LabeledContent("Stop after") {
                Stepper("\(prefs.stopDelaySeconds)s after the call ends", value: $prefs.stopDelaySeconds, in: 10...300, step: 5)
            }
            LabeledContent("Discard under") {
                Stepper("\(prefs.minimumMeetingSeconds)s", value: $prefs.minimumMeetingSeconds, in: 0...900, step: 30)
            }
            Toggle("Use calendar event titles", isOn: $prefs.useCalendarTitles)
            TextField("Ignore bundle IDs", text: $prefs.ignoredBundleIDs, prompt: Text("com.apple.VoiceMemos, …"))
        }
        .onChange(of: prefs.startDelaySeconds) { _, _ in controller.applyDetectorSettings() }
        .onChange(of: prefs.stopDelaySeconds) { _, _ in controller.applyDetectorSettings() }
        .onChange(of: prefs.ignoredBundleIDs) { _, _ in controller.applyDetectorSettings() }
    }

    private var modelsTab: some View {
        Form {
            Section("Transcription") {
                TextField("whisper-cli", text: $prefs.whisperBinary)
                TextField("Model", text: $prefs.whisperModel)
                LabeledContent("Threads") {
                    Stepper("\(prefs.whisperThreads)", value: $prefs.whisperThreads, in: 1...16)
                }
                TextField("Language", text: $prefs.language, prompt: Text("auto"))
                Picker("Hindi and Urdu speech", selection: $prefs.hindustaniScript) {
                    ForEach(HindustaniScript.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Spoken Hindi and Urdu sound the same to the speech model, so pick the script to write them in. Other languages are detected on their own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Notes") {
                Picker("Engine", selection: $prefs.notesEngine) {
                    ForEach(NotesEngineKind.allCases) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                if prefs.notesEngine == NotesEngineKind.local.rawValue {
                    Picker("Built-in model", selection: $prefs.localModelID) {
                        ForEach(LocalRuntime.models) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
                TextField("Ollama host", text: $prefs.ollamaHost)
                TextField("Model", text: $prefs.ollamaModel)
                LabeledContent("Context") {
                    Stepper("\(prefs.contextTokens) tokens", value: $prefs.contextTokens, in: 4096...131072, step: 4096)
                }
            }
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            prefs.vaultPath = url.path
        }
    }
}


/// The library window is opened from several places; keeping the id and the
/// activation in one place stops them drifting apart.
enum SettingsWindow {
    /// Scribe is a menu bar app and is not active while you use another app, so
    /// Settings opened on its own lands behind that app and looks like nothing
    /// happened. Coming forward first puts it in front.
    static func open(_ openSettings: OpenSettingsAction) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }
}

enum SetupWindow {
    static let id = "setup"

    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

enum LibraryWindow {
    static let id = "library"

    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        // Scribe is an accessory app, so its windows do not come forward on
        // their own.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
