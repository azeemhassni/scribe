import Foundation

/// One task someone committed to. Kept structured rather than as a line of
/// markdown so it can be ticked off, re-owned and counted.
struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var owner: String
    var text: String
    var done = false
    var completedAt: Date?
    /// Where in the recording this was agreed, if it could be located.
    var sourceStart: TimeInterval?
}

/// A section of the generated notes other than the summary and actions —
/// "Key points", "Decisions", "Open questions". Kept generic so a change of
/// prompt does not need a schema change.
struct NoteSection: Codable, Identifiable, Hashable {
    var id = UUID()
    var heading: String
    var body: String
}

/// The canonical record of a meeting. This, not the vault file, is the source
/// of truth; the Obsidian note is rendered from it.
struct Meeting: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var started: Date
    var ended: Date
    var platforms: [String]
    var model: String

    var summary: String
    var sections: [NoteSection]
    var actionItems: [ActionItem]
    var utterances: [Utterance]

    /// Relative to the meeting's own folder, so the library stays movable.
    var audioFileName: String?
    var vaultNotePath: String?
    var warnings: [String] = []
    var edited = false

    // Added after the first release; optional so older records still decode.

    /// Language most of the meeting was spoken in, as a Whisper code.
    var language: String?
    /// Why the notes could not be written, if they could not. The transcript is
    /// always kept; this is what the library offers to retry.
    var notesError: String?
    /// True while the title is a stand-in ("Zoom call") rather than one taken
    /// from the calendar or written from the transcript, so a later notes run
    /// knows it may replace it.
    var titleIsPlaceholder: Bool?

    var duration: TimeInterval { ended.timeIntervalSince(started) }
    var openActionCount: Int { actionItems.filter { !$0.done }.count }

    var transcriptText: String {
        MeetingSession.format(utterances)
    }
}

extension Utterance: Identifiable {
    var id: String { "\(speaker.rawValue)-\(start)-\(end)" }
}
