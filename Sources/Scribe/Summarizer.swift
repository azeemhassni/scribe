import Foundation

/// Turns a transcript into meeting notes using a local Ollama model.
/// Nothing here reaches the network beyond 127.0.0.1.
final class Summarizer {

    private let client: ChatClient

    /// Whisper code of the language the meeting was held in, if known.
    private let language: String?

    init(client: ChatClient, language: String? = nil) {
        self.client = client
        self.language = language
        self.contextTokens = client.contextWindow
    }

    /// Notes are written in the meeting's own language. Beyond reading more
    /// naturally, it keeps action items in the same words as the transcript,
    /// which is what lets an action be matched back to the moment it was said.
    private var outputLanguage: String? {
        guard let language, language != "en", language != "auto" else { return nil }
        return Language.englishName(language)
    }

    private let contextTokens: Int

    // MARK: - Public

    func notes(for transcript: String, title: String, participantsHint: String) async throws -> String {
        // Leave room for the system prompt and the generated notes themselves.
        let budgetChars = max(4000, (contextTokens - 2500) * 4)

        if transcript.count <= budgetChars {
            return try await chat(system: Self.systemPrompt,
                                  user: Self.finalPrompt(title: title,
                                                         participants: participantsHint,
                                                         language: outputLanguage,
                                                         body: transcript,
                                                         isPartialDigest: false))
        }

        // Long meeting: digest in order, then write the notes from the digests.
        let chunks = Self.split(transcript, maxChars: budgetChars)
        Log.info("transcript is \(transcript.count) chars — digesting in \(chunks.count) passes")
        var digests: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let digest = try await chat(
                system: Self.digestSystemPrompt,
                user: """
                This is part \(i + 1) of \(chunks.count) of a meeting transcript titled "\(title)".

                \(chunk)
                """)
            digests.append("### Part \(i + 1)\n\(digest)")
        }
        return try await chat(system: Self.systemPrompt,
                              user: Self.finalPrompt(title: title,
                                                     participants: participantsHint,
                                                     language: outputLanguage,
                                                     body: digests.joined(separator: "\n\n"),
                                                     isPartialDigest: true))
    }

    /// Short title for the note filename, derived from the first few minutes.
    func title(forOpening transcript: String) async -> String? {
        let opening = String(transcript.prefix(6000))
        guard opening.count > 200 else { return nil }
        let raw = try? await chat(
            system: "You name meetings. Reply with a title of at most 8 words. No quotes, no punctuation at the end, no preamble.",
            user: "Give a short descriptive title for this meeting based on its opening:\n\n\(opening)")
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .components(separatedBy: .newlines).first ?? ""
        let safe = cleaned.components(separatedBy: CharacterSet(charactersIn: "/\\:*?<>|")).joined(separator: "-")
        return safe.isEmpty ? nil : String(safe.prefix(70))
    }

    private func chat(system: String, user: String) async throws -> String {
        let instruction = outputLanguage.map { "\n\nWrite your reply in \($0)." } ?? ""
        let content = try await client.chat(system: system + instruction, user: user)
        return Self.stripReasoning(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Some local models emit a visible reasoning block; it does not belong in notes.
    private static func stripReasoning(_ text: String) -> String {
        guard let start = text.range(of: "<think>"), let end = text.range(of: "</think>") else { return text }
        guard start.lowerBound < end.lowerBound else { return text }
        var copy = text
        copy.removeSubrange(start.lowerBound..<end.upperBound)
        return copy
    }

    private static func split(_ text: String, maxChars: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You write meeting notes from raw transcripts. The transcript comes from \
    automatic speech recognition, so expect misheard words, false starts and \
    missing punctuation — read through them rather than quoting them literally.

    Rules:
    - Only state things that are actually supported by the transcript. If \
    something is unclear, say so instead of inventing a plausible detail.
    - Never invent attendee names, dates, numbers or decisions.
    - Be concise. Bullets, not paragraphs.
    - Output GitHub-flavoured Markdown only, starting at the "## Summary" \
    heading. No preamble, no closing remarks, no code fences around the whole \
    answer.
    """

    private static let digestSystemPrompt = """
    You compress one slice of a meeting transcript into dense factual notes for \
    later summarisation. Capture topics discussed, decisions, numbers, names, \
    commitments and who made them. Keep speaker attribution. Do not add anything \
    the transcript does not support. Bullets only.
    """

    private static func finalPrompt(title: String,
                                    participants: String,
                                    language: String?,
                                    body: String,
                                    isPartialDigest: Bool) -> String {
        let source = isPartialDigest
            ? "Below are ordered notes taken from consecutive parts of the meeting."
            : "Below is the transcript."
        // The headings and owner labels are parsed, so they stay in English
        // whatever language the prose is in.
        let languageRule = language.map {
            "\n\nWrite the notes in \($0). Keep the `##` headings and the owner labels **Me** and **Others** exactly as written here, in English: software reads them."
        } ?? ""
        return """
        Meeting: \(title)
        \(participants)

        \(source) Lines marked **Me** are the person these notes are for; lines \
        marked **Others** are everyone else on the call (the recording captures \
        remote participants on one shared channel, so treat "Others" as possibly \
        several people).

        Write the notes using exactly these sections, and omit any section that \
        would be empty:

        ## Summary
        Three to five sentences on what the meeting was about and where it landed.

        ## Key points
        The substantive content, as bullets.

        ## Decisions
        What was actually decided. Omit this section if nothing was decided.

        ## Action items
        One `- [ ]` checkbox per item, formatted `- [ ] **Owner** — what they \
        agreed to do (by when, if stated)`. Use **Me** as the owner when it is \
        the note-taker's task. Omit the section if there are none.

        ## Open questions
        Things left unresolved or explicitly deferred.\(languageRule)

        ---

        \(body)
        """
    }
}
