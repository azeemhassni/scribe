import SwiftUI

/// Search across every meeting: notes, action items and transcripts.
///
/// Separate from the sidebar's filter, which narrows the list of meetings. This
/// answers the other question — where was that said — and takes you to the line.
struct SearchResultsView: View {

    /// Bumped by ⌘⇧F so the field takes focus even when this view is already up.
    let focusRequests: Int
    let onOpen: (PendingSeek) -> Void

    @EnvironmentObject var library: MeetingLibrary
    @State private var query = ""
    @State private var results: [MeetingHits] = []
    @FocusState private var focused: Bool

    private var totalHits: Int { results.reduce(0) { $0 + $1.hits.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    hint
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(results) { result in
                        MeetingHitGroup(result: result, query: query, onOpen: onOpen)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Search")
        .onAppear { focused = true }
        .onChange(of: focusRequests) { _, _ in focused = true }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: library.meetings) { _, _ in refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search").font(.largeTitle.bold())
            TextField("Find across all meetings", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .frame(maxWidth: 460)
            if totalHits > 0 {
                Text("\(totalHits) result\(totalHits == 1 ? "" : "s") in \(results.count) meeting\(results.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search everything Scribe has recorded.")
                .foregroundStyle(.secondary)
            Text("Summaries, decisions, action items and every spoken line. Click a result to open the meeting at that moment.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func refresh() {
        results = MeetingSearch.search(library.meetings, query: query)
    }
}

/// One meeting's worth of results.
private struct MeetingHitGroup: View {
    let result: MeetingHits
    let query: String
    let onOpen: (PendingSeek) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(result.meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(MeetingTime.summary(result.meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CountBadge(count: result.hits.count)
            }
            .padding(.bottom, 2)

            ForEach(result.hits) { hit in
                Button {
                    onOpen(PendingSeek(meeting: result.meeting.id,
                                       time: hit.time,
                                       scrollID: hit.scrollID))
                } label: {
                    HitRow(hit: hit, query: query)
                }
                .buttonStyle(MenuRowStyle(verticalPadding: 6))
            }
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            Text(AttributedString.highlighting(hit.snippet, query))
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .naturalDirection(for: hit.snippet)

            Spacer(minLength: 0)
        }
    }

    /// A timecode where there is one, otherwise where in the notes it came from.
    private var label: String {
        if let time = hit.time { return MeetingSession.timecode(time) }
        return hit.field.label
    }
}
