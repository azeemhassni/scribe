import AppKit
import SwiftUI

/// First-run setup, and the place to come back to when something breaks.
struct SetupView: View {
    @StateObject private var model = SetupModel()
    @EnvironmentObject var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(spacing: 10) {
                    speechStep
                    modelStep
                    notesStep
                    microphoneStep
                    vaultStep
                }
                footer
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Scribe").font(.largeTitle.bold())
            Text("Everything runs on this Mac. Nothing you say in a meeting is sent anywhere.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var speechStep: some View {
        StepRow(title: "Speech engine",
                subtitle: "whisper.cpp, which does the transcription",
                state: model.speechBinary,
                actionTitle: "Install") {
            Task { await model.installSpeechBinary() }
        }
    }

    private var modelStep: some View {
        StepRow(title: "Speech model",
                subtitle: "Whisper large-v3-turbo, quantised",
                state: model.speechModel,
                actionTitle: "Download") {
            Task { await model.downloadSpeechModel() }
        }
    }

    private var notesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepRow(title: "Notes model",
                    subtitle: model.ollamaDetected
                        ? "Ollama is installed, so Scribe will use it"
                        : "No Ollama here, so Scribe brings its own",
                    state: model.notes,
                    actionTitle: model.engine == .ollama ? "Pull" : "Download") {
                Task { await model.setUpNotes() }
            }

            if model.engine == .local, !model.notes.isBusy {
                Picker("Size", selection: Binding(
                    get: { model.localModel.id },
                    set: { id in model.chooseLocalModel(LocalRuntime.model(id: id)) })
                ) {
                    ForEach(LocalRuntime.models) { candidate in
                        Text("\(candidate.name) · \(Downloader.humanBytes(candidate.downloadBytes))")
                            .tag(candidate.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 34)

                Text(model.localModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }

            if model.ollamaDetected, !model.notes.isBusy {
                HStack {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    TextField("Model", text: $prefs.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("Use built-in instead") { model.chooseEngine(.local) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.leading, 34)
            }
        }
    }

    private var microphoneStep: some View {
        StepRow(title: "Microphone",
                subtitle: "Records your side of the call",
                state: model.microphone,
                actionTitle: "Allow") {
            Task { await model.requestMicrophone() }
        }
    }

    private var vaultStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            StepRow(title: "Markdown export",
                    subtitle: "Optional. Mirror each meeting into an Obsidian vault",
                    state: model.vault,
                    actionTitle: prefs.vaultPath.isEmpty ? "Choose folder" : "Change") {
                chooseVault()
            }
            if !prefs.vaultPath.isEmpty {
                Button("Don't export, keep meetings in Scribe only") {
                    prefs.vaultPath = ""
                    prefs.exportToVault = false
                    model.checkVault()
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, 34)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("System audio is captured without any extra permission on this Mac. If the other side of a call ever records as silence, open Scribe from Finder rather than a terminal — macOS grants audio capture to whichever app launched it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !model.isReady {
                    Text("Scribe can't record a meeting until the first four are done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Finish") {
                    prefs.hasCompletedSetup = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isReady)
            }
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Pick your Obsidian vault, or any folder for the markdown copies."
        if panel.runModal() == .OK, let url = panel.url {
            prefs.vaultPath = url.path
            prefs.exportToVault = true
            model.checkVault()
        }
    }
}

/// One line of setup: what it is, where it stands, and the one button that
/// moves it forward.
private struct StepRow: View {
    let title: String
    let subtitle: String
    let state: StepState
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .working(_, let fraction) = state {
                    ProgressView(value: fraction ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        .opacity(fraction == nil ? 0.4 : 1)
                        .frame(maxWidth: 320)
                }
            }

            Spacer(minLength: 8)

            if needsButton {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detail: String {
        switch state {
        case .checking: return "Checking…"
        case .needsAction(let text): return text
        case .working(let text, _): return text
        case .done(let text): return text
        case .failed(let text): return text
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private var needsButton: Bool {
        switch state {
        case .needsAction, .failed, .done: return true
        case .checking, .working: return false
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .working, .checking:
            ProgressView().controlSize(.small)
        case .needsAction:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}
