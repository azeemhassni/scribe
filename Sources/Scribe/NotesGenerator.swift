import Foundation

/// What a notes run produces, before it is merged into a meeting.
struct GeneratedNotes {
    let title: String?
    let summary: String
    let sections: [NoteSection]
    let actions: [ActionItem]
    let model: String
    let language: String?
}

/// Writes notes for a meeting that is already filed. Used both when a meeting
/// ends and when the user retries, so there is one way notes get made.
enum NotesGenerator {

    @MainActor
    static func generate(for meeting: Meeting,
                         prefs: Prefs,
                         onStatus: @escaping (String) -> Void) async throws -> GeneratedNotes {
        onStatus("Starting the notes model…")
        let client = try await NotesEngineFactory.makeClient(prefs: prefs)

        let language = Language.dominant(in: meeting.utterances)
        let summarizer = Summarizer(client: client, language: language)
        let transcript = MeetingSession.format(meeting.utterances)

        onStatus("Writing notes with \(client.label)…")
        let title = meeting.titleIsPlaceholder == true
            ? await summarizer.title(forOpening: transcript)
            : nil

        let participants = meeting.platforms.isEmpty
            ? ""
            : "Platform: \(meeting.platforms.joined(separator: ", "))"
        let body = try await summarizer.notes(for: transcript,
                                              title: title ?? meeting.title,
                                              participantsHint: participants)

        let parsed = NotesParser.parse(body)
        guard !parsed.summary.isEmpty || !parsed.sections.isEmpty || !parsed.actions.isEmpty else {
            throw ChatError.emptyNotes
        }

        return GeneratedNotes(title: title,
                              summary: parsed.summary,
                              sections: parsed.sections,
                              actions: ActionLinker.link(parsed.actions, to: meeting.utterances),
                              model: client.modelName,
                              language: language)
    }

    static func placeholderTitle(platforms: [String]) -> String {
        "\(platforms.first ?? "Meeting") call"
    }
}
