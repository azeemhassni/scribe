import SwiftUI

/// Ask the local model about this meeting.
struct MeetingChatView: View {
    let meeting: Meeting

    @EnvironmentObject var library: MeetingLibrary
    @EnvironmentObject var prefs: Prefs
    @StateObject private var store = MeetingChatStore()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            conversation
            Divider()
            composer
        }
        .onAppear {
            store.load(meeting, folder: library.folder(for: meeting))
            inputFocused = true
        }
        .onChange(of: meeting.id) { _, _ in
            store.load(meeting, folder: library.folder(for: meeting))
        }
        .toolbar {
            if !store.turns.isEmpty {
                ToolbarItem {
                    Button { store.clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .help("Clear this conversation")
                }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.turns.isEmpty { empty }

                    ForEach(store.turns) { turn in
                        ChatBubble(turn: turn).id(turn.id)
                    }

                    if store.isAnswering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the meeting…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .id(Self.thinkingID)
                    }

                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.turns.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.isAnswering) { _, _ in scrollToEnd(proxy) }
        }
    }

    private static let thinkingID = "chat.thinking"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation {
            if store.isAnswering {
                proxy.scrollTo(Self.thinkingID, anchor: .bottom)
            } else if let last = store.turns.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this meeting")
                .font(.headline)
            Text("Answers come from this meeting's notes and transcript, using the same local model that wrote the notes. Nothing is sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        store.ask(suggestion, prefs: prefs)
                    } label: {
                        Text(suggestion)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(MenuRowStyle(verticalPadding: 5))
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 6)
    }

    private static let suggestions = [
        "What did I agree to do?",
        "What was decided, and what is still open?",
        "Summarise what the others wanted.",
    ]

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.isAnswering)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    private func send() {
        let question = draft
        draft = ""
        store.ask(question, prefs: prefs)
    }
}

private struct ChatBubble: View {
    let turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(turn.role == .you ? "You" : "Scribe")
                .font(.caption.weight(.semibold))
                .foregroundStyle(turn.role == .you ? Color.accentColor : .secondary)

            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .naturalDirection(for: turn.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(turn.role == .you ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: turn.text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(turn.text)
    }
}
