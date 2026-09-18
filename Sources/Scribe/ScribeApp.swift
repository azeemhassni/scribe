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
        if let i = CommandLine.arguments.firstIndex(of: "--render-menu"),
           i + 1 < CommandLine.arguments.count {
            MenuPreview.run(directory: CommandLine.arguments[i + 1])
        }
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
    @ObservedObject private var updater = AppUpdater.shared

    private var recents: [Meeting] { Array(library.meetings.prefix(5)) }
    private var openActions: Int { library.meetings.reduce(0) { $0 + $1.openActionCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)

            if !controller.warnings.isEmpty {
                warnings.padding(.bottom, 8)
            }

            actions.padding(.bottom, 4)

            if !recents.isEmpty {
                separator
                MenuSectionHeader(title: "Recent meetings") {
                    if openActions > 0 {
                        Button {
                            LibraryWindow.open(openWindow, showing: .actions)
                        } label: {
                            Text("\(openActions) open")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show every unfinished action")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)

                ForEach(recents) { meeting in
                    MeetingMenuRow(meeting: meeting) {
                        LibraryWindow.open(openWindow, showing: .meeting(meeting.id))
                    }
                }
                .padding(.horizontal, 2)
            }

            separator
            footer.padding(.horizontal, 2).padding(.bottom, 6)
        }
        .frame(width: 360)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch controller.state {
        case .idle:
            StatusLine(symbol: "waveform", tint: .secondary,
                       title: "Watching for meetings",
                       subtitle: prefs.autoDetect
                           ? "Scribe starts on its own when a call begins"
                           : "Auto-detect is off — start recording yourself")

        case .armed(let message):
            StatusLine(symbol: "ear", tint: .orange, title: "Listening", subtitle: message)

        case .detected(let name):
            StatusLine(symbol: "waveform.badge.plus", tint: .accentColor,
                       title: "Meeting in \(name)", subtitle: "Not recording yet")

        case .recording:
            HStack(spacing: 10) {
                StatusChip(symbol: "record.circle.fill", tint: .red, pulsing: true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Recording").font(.system(size: 13, weight: .semibold))
                        // Driven by the system clock, so it keeps counting
                        // however often this view happens to redraw.
                        if let started = controller.recordingStarted {
                            Text(started, style: .timer)
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(recordingDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        case .processing(let message):
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 26, height: 26)
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Working").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                StatusLine(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "Something went wrong", subtitle: message)
                Button("Dismiss") { controller.clearError() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)
            }
        }
    }

    private var recordingDetail: String {
        var parts: [String] = []
        if !controller.activePlatforms.isEmpty {
            parts.append(controller.activePlatforms.joined(separator: ", "))
        }
        parts.append("\(controller.transcribedLines) lines")
        return parts.joined(separator: " · ")
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(warning)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.22)), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 10)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch controller.state {
        case .recording:
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { controller.stopManually() } label: {
                        Label("Stop & write notes", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Discard") { controller.discardCurrent() }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 10)

        case .detected:
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { controller.recordDetectedMeeting() } label: {
                        Label("Record this", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Not now") { controller.dismissDetectedMeeting() }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 10)

        case .processing:
            EmptyView()

        default:
            VStack(spacing: 2) {
                Button { controller.startManually() } label: {
                    Label("Record now", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                Toggle(isOn: $prefs.autoDetect) {
                    Label("Auto-detect meetings", systemImage: "sparkles")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, 10)
                .onChange(of: prefs.autoDetect) { _, _ in controller.applyDetectorSettings() }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Button {
                LibraryWindow.open(openWindow)
            } label: {
                Label("Open Library", systemImage: "rectangle.stack")
                    .font(.system(size: 12))
            }
            .buttonStyle(MenuRowStyle(stretch: false, verticalPadding: 4))

            Spacer(minLength: 0)

            Menu {
                Button("Set Up Scribe…") { SetupWindow.open(openWindow) }
                Button("Settings…") { SettingsWindow.open(openSettings) }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Show Log") { controller.openLog() }
                Divider()
                Button("Quit Scribe") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 8)
            .help("More")
        }
    }
}

/// Status glyph plus one line of explanation, used for every menu state that is
/// not a live recording.
private struct StatusLine: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            StatusChip(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One meeting in the menu. Opens that meeting rather than just the window,
/// which is the whole point of listing them here.
private struct MeetingMenuRow: View {
    let meeting: Meeting
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(MeetingTime.summary(meeting))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if meeting.openActionCount > 0 {
                    CountBadge(count: meeting.openActionCount)
                        .help("\(meeting.openActionCount) unfinished action\(meeting.openActionCount == 1 ? "" : "s")")
                }
            }
        }
        .buttonStyle(MenuRowStyle())
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

            Toggle("Check for updates automatically", isOn: Binding(
                get: { AppUpdater.shared.automaticallyChecks },
                set: { AppUpdater.shared.automaticallyChecks = $0 }))
            HStack {
                Text("Version \(AppUpdater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check now") { AppUpdater.shared.checkForUpdates() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

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
                Picker("Notes language", selection: $prefs.notesLanguage) {
                    Text("Match the meeting").tag(NotesLanguage.matchMeeting)
                    Divider()
                    ForEach(NotesLanguage.options) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                Text("Notes, titles and action items are written in this language whatever was spoken. The transcript stays in the language of the meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// - Parameter selection: what the window should show. Without it the
    ///   library keeps whatever was selected last, so opening from a specific
    ///   meeting in the menu would land somewhere else entirely.
    @MainActor
    static func open(_ openWindow: OpenWindowAction, showing selection: LibrarySelection? = nil) {
        if let selection { LibraryNavigator.shared.request = selection }
        openWindow(id: id)
        // Scribe is an accessory app, so its windows do not come forward on
        // their own.
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
