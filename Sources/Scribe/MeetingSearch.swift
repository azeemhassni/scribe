import Foundation
import SwiftUI

/// Where inside a meeting a hit was found.
///
/// Carries the SwiftUI identity of the view that holds it, so a result found in
/// one place can be scrolled to in another without the two sides agreeing on
/// anything more than this value.
struct SearchHit: Identifiable, Hashable {
    enum Field: Hashable {
        case summary
        case section(String)
        case action
        case transcript(Speaker)

        var label: String {
            switch self {
            case .summary: return "Summary"
            case .section(let heading): return heading
            case .action: return "Action"
            case .transcript(let speaker): return speaker.rawValue
            }
        }
    }

    let id: String
    let field: Field
    /// The `.id(…)` of the view holding this hit.
    let scrollID: String
    /// Enough text either side of the hit to recognise it.
    let snippet: String
    /// Range of the hit inside `snippet`, for highlighting.
    let snippetRange: Range<String.Index>
    /// Position in the recording, for transcript hits.
    let time: TimeInterval?
}

/// Every hit in one meeting, and the meeting it came from.
struct MeetingHits: Identifiable {
    let meeting: Meeting
    let hits: [SearchHit]
    var id: Meeting.ID { meeting.id }
}

/// Plain substring search over a meeting's notes and transcript.
///
/// No index and no embeddings: a meeting is a few thousand words, and scanning
/// them is faster than maintaining anything cleverer would be to keep correct.
enum MeetingSearch {

    /// Hits in document order — summary, sections, actions, then the transcript
    /// — so stepping through them with the find bar moves down the page.
    static func hits(in meeting: Meeting, query: String) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }

        var hits: [SearchHit] = []

        hits += occurrences(of: needle,
                            in: meeting.summary,
                            field: .summary,
                            scrollID: ScrollID.summary,
                            time: nil)

        for section in meeting.sections {
            hits += occurrences(of: needle,
                                in: section.body,
                                field: .section(section.heading),
                                scrollID: ScrollID.section(section.id),
                                time: nil)
        }

        for action in meeting.actionItems {
            hits += occurrences(of: needle,
                                in: "\(action.owner) \(action.text)",
                                field: .action,
                                scrollID: ScrollID.action(action.id),
                                time: action.sourceStart)
        }

        for utterance in meeting.utterances {
            hits += occurrences(of: needle,
                                in: utterance.text,
                                field: .transcript(utterance.speaker),
                                scrollID: utterance.id,
                                time: utterance.start)
        }

        return hits
    }

    /// Meetings that contain the query, newest first, each with its own hits.
    static func search(_ meetings: [Meeting], query: String, maxPerMeeting: Int = 50) -> [MeetingHits] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }

        return meetings.compactMap { meeting in
            let found = hits(in: meeting, query: needle)
            guard !found.isEmpty else { return nil }
            return MeetingHits(meeting: meeting, hits: Array(found.prefix(maxPerMeeting)))
        }
    }

    // MARK: - Internals

    private static let contextRadius = 60

    private static func occurrences(of needle: String,
                                    in haystack: String,
                                    field: SearchHit.Field,
                                    scrollID: String,
                                    time: TimeInterval?) -> [SearchHit] {
        guard !haystack.isEmpty else { return [] }

        var hits: [SearchHit] = []
        var searchFrom = haystack.startIndex

        while searchFrom < haystack.endIndex,
              let range = haystack.range(of: needle,
                                         options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchFrom..<haystack.endIndex) {
            let (snippet, snippetRange) = context(around: range, in: haystack)
            hits.append(SearchHit(id: "\(scrollID)#\(haystack.distance(from: haystack.startIndex, to: range.lowerBound))",
                                  field: field,
                                  scrollID: scrollID,
                                  snippet: snippet,
                                  snippetRange: snippetRange,
                                  time: time))
            // Advance past this hit; an empty needle is already excluded.
            searchFrom = range.upperBound
        }
        return hits
    }

    /// A window of text around the hit, trimmed to word boundaries so a snippet
    /// does not start mid-word.
    private static func context(around range: Range<String.Index>,
                                in text: String) -> (String, Range<String.Index>) {
        var start = text.index(range.lowerBound,
                               offsetBy: -contextRadius,
                               limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound,
                             offsetBy: contextRadius,
                             limitedBy: text.endIndex) ?? text.endIndex

        if start != text.startIndex,
           let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        if end != text.endIndex,
           let space = text[range.upperBound..<end].lastIndex(of: " ") {
            end = space
        }

        var snippet = String(text[start..<end])
        if start != text.startIndex { snippet = "…" + snippet }
        if end != text.endIndex { snippet += "…" }

        // Re-find the hit inside the snippet: the ellipsis shifts every index.
        let hitRange = snippet.range(of: String(text[range]),
                                     options: [.caseInsensitive, .diacriticInsensitive])
            ?? snippet.startIndex..<snippet.startIndex
        return (snippet, hitRange)
    }
}

/// SwiftUI identities for the parts of a meeting that can be scrolled to.
enum ScrollID {
    static let summary = "notes.summary"
    static func section(_ id: NoteSection.ID) -> String { "notes.section.\(id.uuidString)" }
    static func action(_ id: ActionItem.ID) -> String { "notes.action.\(id.uuidString)" }
}


extension AttributedString {
    /// Marks every occurrence of `needle`, for find-style highlighting.
    static func highlighting(_ text: String,
                             _ needle: String,
                             markdown: Bool = false) -> AttributedString {
        var attributed = markdown
            ? ((try? AttributedString(markdown: text)) ?? AttributedString(text))
            : AttributedString(text)

        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }

        var searchFrom = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchFrom].range(of: trimmed,
                                                       options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[found].backgroundColor = .yellow.opacity(0.45)
            guard found.upperBound < attributed.endIndex else { break }
            searchFrom = found.upperBound..<attributed.endIndex
        }
        return attributed
    }
}
