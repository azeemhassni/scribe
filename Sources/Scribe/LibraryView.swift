import AppKit
import SwiftUI

// MARK: - Window

/// What the sidebar is pointing at: the cross-meeting action list, or one
/// meeting.
enum LibrarySelection: Hashable {
    case actions
    case meeting(Meeting.ID)
}

/// A request to open a meeting at a particular moment, raised when you jump
/// from an action item to where it was agreed.
struct PendingSeek: Equatable {
    let meeting: Meeting.ID
    let time: TimeInterval
}

struct LibraryView: View {
    @EnvironmentObject var library: MeetingLibrary
    @State private var selection: LibrarySelection? = .actions
    @State private var query = ""
    @State private var pendingSeek: PendingSeek?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("All actions", systemImage: "checklist")
                        .badge(library.meetings.reduce(0) { $0 + $1.openActionCount })
                        .tag(LibrarySelection.actions)
                }

                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(LibrarySelection.meeting(meeting.id))
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search meetings and transcripts")
            .navigationSplitViewColumnWidth(min: 250, ideal: 290)
            .overlay {
                if library.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet",
                                           systemImage: "waveform",
                                           description: Text("Scribe files a meeting here once it has recorded and summarised one."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        } detail: {
            switch selection {
            case .actions:
                ActionsView { seek in
                    pendingSeek = seek
                    selection = .meeting(seek.meeting)
                }
            case .meeting(let id):
                if let meeting = library.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(meeting: meeting, pendingSeek: $pendingSeek)
                        .id(meeting.id)
                } else {
                    ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
                }
            case nil:
                ContentUnavailableView("Select a meeting",
                                       systemImage: "sidebar.left",
                                       description: Text("Pick a meeting to read its notes, actions and transcript."))
            }
        }
        .navigationTitle("Meetings")
        .onAppear { library.reload() }
    }

    /// Searches titles, notes *and* transcript text — finding the meeting where
    /// something was said is the main reason to keep transcripts at all.
    private var filtered: [Meeting] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return library.meetings }
        return library.meetings.filter { meeting in
            meeting.title.lowercased().contains(needle)
                || meeting.summary.lowercased().contains(needle)
                || meeting.actionItems.contains { $0.text.lowercased().contains(needle) }
                || meeting.utterances.contains { $0.text.lowercased().contains(needle) }
        }
    }

    private var groups: [MeetingGroup] { MeetingGroup.build(from: filtered) }
}

/// Meetings bucketed by recency, so the sidebar reads like a calendar rather
/// than an undifferentiated list.
struct MeetingGroup: Identifiable {
    let id: String
    let title: String
    let meetings: [Meeting]

    static func build(from meetings: [Meeting], now: Date = Date()) -> [MeetingGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Meeting]] = [:]

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"

        for meeting in meetings {
            let title: String
            if calendar.isDateInToday(meeting.started) {
                title = "Today"
            } else if calendar.isDateInYesterday(meeting.started) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: meeting.started, to: now).day,
                      days < 7 {
                title = "Earlier this week"
            } else if calendar.isDate(meeting.started, equalTo: now, toGranularity: .month) {
                title = "Earlier this month"
            } else {
                title = monthFormatter.string(from: meeting.started)
            }

            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(meeting)
        }

        return order.map { MeetingGroup(id: $0, title: $0, meetings: buckets[$0] ?? []) }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if meeting.notesError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Notes couldn't be written")
                }
                Text(meeting.title).lineLimit(1).font(.body.weight(.medium))
            }
            HStack(spacing: 6) {
                Text(meeting.started, format: .dateTime.weekday().day().month().hour().minute())
                Text("·")
                Text("\(Int((meeting.duration / 60).rounded())) min")
                if meeting.openActionCount > 0 {
                    Spacer()
                    Text("\(meeting.openActionCount)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct MeetingDetailView: View {
    let meeting: Meeting
    @Binding var pendingSeek: PendingSeek?
    @EnvironmentObject var library: MeetingLibrary
    @StateObject private var player = AudioPlayer()
    @State private var draft: Meeting
    @State private var isEditing = false
    @State private var transcriptQuery = ""
    @State private var speakerFilter: Speaker?
    @State private var confirmingDelete = false
    @State private var jumpRequest: TimeInterval?
    @State private var confirmingRegenerate = false

    init(meeting: Meeting, pendingSeek: Binding<PendingSeek?>) {
        self.meeting = meeting
        _pendingSeek = pendingSeek
        _draft = State(initialValue: meeting)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if player.isLoaded { PlayerBar(player: player) }
                    summarySection
                    actionSection
                    ForEach($draft.sections) { $section in
                        NoteSectionView(section: $section, isEditing: isEditing)
                    }
                    transcriptSection
                }
                .padding(24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onAppear { consumePendingSeek(proxy) }
            .onChange(of: pendingSeek) { _, _ in consumePendingSeek(proxy) }
            .onChange(of: jumpRequest) { _, request in
                guard let request else { return }
                jumpRequest = nil
                play(from: request, using: proxy)
            }
        }
        .toolbar { toolbarContent }
        .onAppear { player.load(library.audioURL(for: meeting)) }
        .onDisappear { player.stop() }
        // Notes can change underneath this view — a retry finishing, an action
        // ticked in the Actions view — so follow the library unless mid-edit.
        .onChange(of: meeting) { _, updated in
            if !isEditing { draft = updated }
        }
        .confirmationDialog("Rewrite the notes?", isPresented: $confirmingRegenerate) {
            Button("Rewrite") { regenerateNotes() }
        } message: {
            Text("The summary and action items are written again from the transcript. Edits and ticked actions are replaced.")
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { library.delete(meeting) }
        } message: {
            Text("The notes, transcript and recording are removed from Scribe\(Prefs.shared.exportToVault ? " and the vault note is deleted" : "").")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
            } else {
                Text(draft.title).font(.largeTitle.bold())
                    .naturalDirection(for: draft.title)
            }

            HStack(spacing: 8) {
                Label(draft.started.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                Label("\(Int((draft.duration / 60).rounded())) min", systemImage: "clock")
                if !draft.platforms.isEmpty {
                    Label(draft.platforms.joined(separator: ", "), systemImage: "video")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !draft.warnings.isEmpty {
                ForEach(draft.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Summary

    private var isWritingNotes: Bool { library.notesProgress[meeting.id] != nil }

    /// No notes yet, either because they are being written or because writing
    /// them failed — in both cases "Nothing was assigned" would be a lie.
    private var notesPending: Bool {
        isWritingNotes || (draft.notesError != nil && draft.summary.isEmpty)
    }

    @ViewBuilder private var notesStatus: some View {
        if let status = library.notesProgress[meeting.id] {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        } else if let error = draft.notesError {
            let hasNotes = !draft.summary.isEmpty
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasNotes ? "Notes couldn't be rewritten" : "Notes couldn't be written")
                        .font(.body.weight(.medium))
                    Text(hasNotes ? "\(error) The previous notes are unchanged." : "\(error) The transcript is saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Retry") { regenerateNotes() }
                if hasNotes {
                    Button {
                        library.dismissNotesError(for: meeting.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func regenerateNotes() {
        if isEditing {
            save()
            isEditing = false
        }
        let id = meeting.id
        Task { await library.generateNotes(for: id) }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Summary")
            notesStatus
            if isEditing {
                TextEditor(text: $draft.summary)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else if draft.summary.isEmpty {
                if !notesPending {
                    Text("No summary.").foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(draft.summary)
            }
        }
    }

    // MARK: Actions

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading("Action items")
                Spacer()
                if !draft.actionItems.isEmpty {
                    Text("\(draft.actionItems.filter { !$0.done }.count) open")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isEditing {
                    Button {
                        draft.actionItems.append(ActionItem(owner: "Me", text: ""))
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                }
            }

            if draft.actionItems.isEmpty {
                if !notesPending {
                    Text("Nothing was assigned.").foregroundStyle(.secondary)
                }
            } else {
                ForEach($draft.actionItems) { $item in
                    ActionItemRow(item: $item,
                                  isEditing: isEditing,
                                  canPlay: player.isLoaded) {
                        draft.actionItems.removeAll { $0.id == item.id }
                        save()
                    } onToggle: {
                        save()
                    } onJump: { time in
                        jumpRequest = time
                    }
                }
            }
        }
    }

    // MARK: Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeading("Transcript")
                Spacer()
                Picker("", selection: $speakerFilter) {
                    Text("Everyone").tag(Speaker?.none)
                    Text("Me").tag(Speaker?.some(.me))
                    Text("Others").tag(Speaker?.some(.others))
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            TextField("Find in transcript", text: $transcriptQuery)
                .textFieldStyle(.roundedBorder)

            if visibleUtterances.isEmpty {
                Text(draft.utterances.isEmpty ? "No transcript was captured." : "No lines match.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleUtterances) { utterance in
                        TranscriptLine(utterance: utterance,
                                       isCurrent: isCurrent(utterance),
                                       canPlay: player.isLoaded,
                                       highlight: transcriptQuery) {
                            player.play(from: utterance.start)
                        }
                        .id(utterance.id)
                    }
                }
            }
        }
    }

    private var visibleUtterances: [Utterance] {
        let needle = transcriptQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return draft.utterances.filter { utterance in
            (speakerFilter == nil || utterance.speaker == speakerFilter)
                && (needle.isEmpty || utterance.text.lowercased().contains(needle))
        }
    }

    /// Opening a meeting from an action item should land on the moment it was
    /// agreed, not the top of the page.
    private func consumePendingSeek(_ proxy: ScrollViewProxy) {
        guard let seek = pendingSeek, seek.meeting == meeting.id else { return }
        pendingSeek = nil
        play(from: seek.time, using: proxy)
    }

    private func play(from time: TimeInterval, using proxy: ScrollViewProxy) {
        // Clear the filters, or the line we are scrolling to may not be on
        // screen at all.
        speakerFilter = nil
        transcriptQuery = ""

        guard let target = draft.utterances.min(by: {
            abs($0.start - time) < abs($1.start - time)
        }) else { return }

        if player.isLoaded { player.play(from: time) }
        // Give the list a beat to lay out before scrolling to a row in it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        }
    }

    private func isCurrent(_ utterance: Utterance) -> Bool {
        player.isPlaying && player.currentTime >= utterance.start && player.currentTime < utterance.end
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if isEditing { save() }
                isEditing.toggle()
            } label: {
                Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
            }

            Menu {
                if let path = draft.vaultNotePath, FileManager.default.fileExists(atPath: path) {
                    Button("Open note in Obsidian") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
                if let folder = library.folder(for: meeting) {
                    Button("Reveal recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Button(draft.notesError != nil && draft.summary.isEmpty ? "Write notes again" : "Rewrite notes…") {
                    // Only ask when there is something of the user's to lose.
                    let userTouched = draft.edited || draft.actionItems.contains { $0.done }
                    if draft.summary.isEmpty || !userTouched {
                        regenerateNotes()
                    } else {
                        confirmingRegenerate = true
                    }
                }
                .disabled(isWritingNotes || draft.utterances.isEmpty)
                Button("Copy transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.transcriptText, forType: .string)
                }
                Divider()
                Button("Delete meeting", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func save() {
        var updated = draft
        updated.edited = true
        for index in updated.actionItems.indices {
            let done = updated.actionItems[index].done
            if done, updated.actionItems[index].completedAt == nil {
                updated.actionItems[index].completedAt = Date()
            } else if !done {
                updated.actionItems[index].completedAt = nil
            }
        }
        draft = updated
        library.save(updated)
    }
}

// MARK: - Pieces

private struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private struct ActionItemRow: View {
    @Binding var item: ActionItem
    let isEditing: Bool
    let canPlay: Bool
    let onDelete: () -> Void
    let onToggle: () -> Void
    let onJump: (TimeInterval) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Toggle("", isOn: $item.done)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .onChange(of: item.done) { _, _ in onToggle() }

            if isEditing {
                TextField("Owner", text: $item.owner).frame(width: 90)
                TextField("Task", text: $item.text)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text)
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .naturalDirection(for: item.text)
                    if !item.owner.isEmpty {
                        Text(item.owner).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)

            if let start = item.sourceStart, !isEditing {
                Button { onJump(start) } label: {
                    Label(MeetingSession.timecode(start), systemImage: "waveform")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .help("Jump to where this was agreed")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct NoteSectionView: View {
    @Binding var section: NoteSection
    let isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(section.heading)
            if isEditing {
                TextEditor(text: $section.body)
                    .font(.body)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                MarkdownText(section.body)
            }
        }
    }
}

private struct TranscriptLine: View {
    let utterance: Utterance
    let isCurrent: Bool
    let canPlay: Bool
    let highlight: String
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onPlay) {
                Text(MeetingSession.timecode(utterance.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(canPlay ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help(canPlay ? "Play from here" : "No recording kept for this meeting")

            Text(utterance.speaker.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(utterance.speaker == .me ? Color.accentColor : Color.orange)
                .frame(width: 48, alignment: .leading)

            Text(attributed)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .naturalDirection(for: utterance.text)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private var attributed: AttributedString {
        var text = AttributedString(utterance.text)
        let needle = highlight.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return text }
        var search = text.startIndex..<text.endIndex
        while let found = text[search].range(of: needle, options: .caseInsensitive) {
            text[found].backgroundColor = .yellow.opacity(0.45)
            guard found.upperBound < text.endIndex else { break }
            search = found.upperBound..<text.endIndex
        }
        return text
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }

            Text(MeetingSession.timecode(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(value: Binding(get: { player.currentTime },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))

            Text(MeetingSession.timecode(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Renders the model's markdown bullets as actual bullets, with inline emphasis.
private struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(line.text)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .naturalDirection(for: line.text)
                } else {
                    Text(inline(line.text)).fixedSize(horizontal: false, vertical: true)
                        .naturalDirection(for: line.text)
                }
            }
        }
        .textSelection(.enabled)
    }

    private struct Line { let text: String; let isBullet: Bool }

    private var lines: [Line] {
        source.components(separatedBy: .newlines).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return Line(text: String(trimmed.dropFirst(2)), isBullet: true)
            }
            return Line(text: trimmed, isBullet: false)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
