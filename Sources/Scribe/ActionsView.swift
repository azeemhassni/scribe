import SwiftUI

/// Every action item from every meeting in one place.
///
/// This is the thing a per-meeting note cannot give you: answering "what did I
/// commit to this week?" should not mean opening eight meetings and reading
/// them.
struct ActionsView: View {

    @EnvironmentObject var library: MeetingLibrary
    /// Raised when you ask to hear where an action was agreed.
    let onJump: (PendingSeek) -> Void

    @State private var scope: Scope = .open
    @State private var grouping: Grouping = .owner
    @State private var query = ""

    enum Scope: String, CaseIterable, Identifiable {
        case open = "Open", done = "Done", all = "All"
        var id: String { rawValue }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case owner = "Owner", meeting = "Meeting"
        var id: String { rawValue }
    }

    struct Entry: Identifiable {
        let id: UUID
        let action: ActionItem
        let meeting: Meeting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if groups.isEmpty {
                    ContentUnavailableView(emptyTitle,
                                           systemImage: scope == .done ? "checkmark.circle" : "checklist",
                                           description: Text(emptyMessage))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.title)
                                    .font(.headline)
                                Text("\(group.entries.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.entries) { entry in
                                ActionEntryRow(entry: entry,
                                               showMeeting: grouping == .owner,
                                               onToggle: { toggle(entry) },
                                               onJump: { jump(to: entry) })
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Actions")
        .toolbar {
            ToolbarItemGroup {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text("By \($0.rawValue.lowercased())").tag($0) }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions").font(.largeTitle.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            TextField("Filter actions", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private var subtitle: String {
        let open = library.meetings.reduce(0) { $0 + $1.openActionCount }
        let meetings = library.meetings.filter { $0.openActionCount > 0 }.count
        guard open > 0 else { return "Nothing outstanding." }
        return "\(open) open across \(meetings) meeting\(meetings == 1 ? "" : "s")."
    }

    private var emptyTitle: String {
        switch scope {
        case .open: return query.isEmpty ? "Nothing outstanding" : "No open actions match"
        case .done: return "Nothing completed yet"
        case .all: return "No actions"
        }
    }

    private var emptyMessage: String {
        scope == .open && query.isEmpty
            ? "Everything assigned in your meetings has been ticked off."
            : "Try a different filter."
    }

    // MARK: - Data

    private var entries: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.meetings.flatMap { meeting in
            meeting.actionItems.compactMap { action -> Entry? in
                switch scope {
                case .open where action.done: return nil
                case .done where !action.done: return nil
                default: break
                }
                if !needle.isEmpty,
                   !action.text.lowercased().contains(needle),
                   !action.owner.lowercased().contains(needle),
                   !meeting.title.lowercased().contains(needle) { return nil }
                return Entry(id: action.id, action: action, meeting: meeting)
            }
        }
    }

    private var groups: [(title: String, entries: [Entry])] {
        switch grouping {
        case .owner:
            let buckets = Dictionary(grouping: entries) { entry in
                entry.action.owner.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Unassigned" : entry.action.owner.trimmingCharacters(in: .whitespaces)
            }
            return buckets.keys.sorted { lhs, rhs in
                // Your own commitments are the ones you came here for.
                if (lhs == "Me") != (rhs == "Me") { return lhs == "Me" }
                if (lhs == "Unassigned") != (rhs == "Unassigned") { return rhs == "Unassigned" }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }.map { ($0, buckets[$0] ?? []) }

        case .meeting:
            let buckets = Dictionary(grouping: entries) { $0.meeting.id }
            return buckets.values
                .sorted { ($0.first?.meeting.started ?? .distantPast) > ($1.first?.meeting.started ?? .distantPast) }
                .map { ($0.first?.meeting.title ?? "Meeting", $0) }
        }
    }

    // MARK: - Mutating

    private func toggle(_ entry: Entry) {
        guard var meeting = library.meetings.first(where: { $0.id == entry.meeting.id }),
              let index = meeting.actionItems.firstIndex(where: { $0.id == entry.id }) else { return }
        meeting.actionItems[index].done.toggle()
        meeting.actionItems[index].completedAt = meeting.actionItems[index].done ? Date() : nil
        library.save(meeting)
    }

    private func jump(to entry: Entry) {
        guard let time = entry.action.sourceStart else { return }
        onJump(PendingSeek(meeting: entry.meeting.id, time: time))
    }
}

private struct ActionEntryRow: View {
    let entry: ActionsView.Entry
    let showMeeting: Bool
    let onToggle: () -> Void
    let onJump: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.action.done }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action.text)
                    .strikethrough(entry.action.done, color: .secondary)
                    .foregroundStyle(entry.action.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .naturalDirection(for: entry.action.text)

                HStack(spacing: 6) {
                    if !showMeeting {
                        Text(entry.action.owner)
                    }
                    if showMeeting {
                        Text(entry.meeting.title).lineLimit(1)
                        Text("·")
                        Text(entry.meeting.started, format: .dateTime.day().month())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if entry.action.sourceStart != nil {
                Button(action: onJump) {
                    Label("Hear it", systemImage: "waveform")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Play the moment this was agreed")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }
}
