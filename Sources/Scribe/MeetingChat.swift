import Foundation

/// One turn of a conversation about a meeting.
struct ChatTurn: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case you, scribe }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

/// Questions and answers about one meeting.
///
/// Kept in its own file beside the meeting rather than inside `meeting.json`:
/// the library decodes every meeting record at launch, and a long conversation
/// in each one would be read for nothing every time Scribe starts.
@MainActor
final class MeetingChatStore: ObservableObject {

    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isAnswering = false
    @Published var error: String?

    private var meeting: Meeting?
    private var folder: URL?

    // MARK: - Loading

    func load(_ meeting: Meeting, folder: URL?) {
        guard self.meeting?.id != meeting.id else {
            self.meeting = meeting
            return
        }
        self.meeting = meeting
        self.folder = folder
        error = nil
        turns = folder
            .map { $0.appendingPathComponent("chat.json") }
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Self.decoder.decode([ChatTurn].self, from: $0) } ?? []
    }

    func clear() {
        turns = []
        persist()
    }

    private func persist() {
        guard let folder else { return }
        let url = folder.appendingPathComponent("chat.json")
        guard !turns.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Self.encoder.encode(turns) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Asking

    func ask(_ question: String, prefs: Prefs) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering, let meeting else { return }

        turns.append(ChatTurn(role: .you, text: trimmed))
        persist()
        isAnswering = true
        error = nil

        Task {
            defer { isAnswering = false }
            do {
                let client = try await NotesEngineFactory.makeClient(prefs: prefs)
                let context = Self.context(for: meeting,
                                           question: trimmed,
                                           budgetChars: max(4000, (client.contextWindow - 1500) * 4))
                let answer = try await client.chat(system: Self.systemPrompt,
                                                   user: Self.userPrompt(context: context,
                                                                         history: history,
                                                                         question: trimmed))
                turns.append(ChatTurn(role: .scribe, text: Self.tidy(answer)))
                persist()
            } catch {
                self.error = error.localizedDescription
                // Leave the question in place so it can be retried as it is.
            }
        }
    }

    /// Recent turns only: a long conversation would crowd out the transcript,
    /// which is the part that actually answers the question.
    private var history: [ChatTurn] {
        Array(turns.dropLast().suffix(6))
    }

    // MARK: - Context

    /// Notes always, then as much of the transcript as fits — the parts that
    /// share words with the question first.
    ///
    /// Not embeddings: word overlap is crude, but it runs instantly, needs no
    /// second model, and the lines it misses are usually ones the notes above
    /// already cover.
    static func context(for meeting: Meeting, question: String, budgetChars: Int) -> String {
        var parts: [String] = []

        if !meeting.summary.isEmpty { parts.append("## Summary\n\(meeting.summary)") }
        for section in meeting.sections where !section.body.isEmpty {
            parts.append("## \(section.heading)\n\(section.body)")
        }
        if !meeting.actionItems.isEmpty {
            let lines = meeting.actionItems.map { "- \($0.owner): \($0.text)" }
            parts.append("## Action items\n" + lines.joined(separator: "\n"))
        }

        let notes = parts.joined(separator: "\n\n")
        let transcriptBudget = max(1000, budgetChars - notes.count)
        let transcript = selectedTranscript(for: meeting,
                                            question: question,
                                            budgetChars: transcriptBudget)
        return notes.isEmpty ? transcript : notes + "\n\n## Transcript\n" + transcript
    }

    private static func selectedTranscript(for meeting: Meeting,
                                           question: String,
                                           budgetChars: Int) -> String {
        func line(_ u: Utterance) -> String {
            "[\(MeetingSession.timecode(u.start))] \(u.speaker.rawValue): \(u.text)"
        }

        let whole = meeting.utterances.map(line).joined(separator: "\n")
        if whole.count <= budgetChars { return whole }

        // Too long: keep the lines that look relevant, and a neighbour either
        // side so an answer is not quoted out of context.
        let needle = tokens(question)
        var scored: [(index: Int, score: Int)] = []
        for (index, utterance) in meeting.utterances.enumerated() {
            let score = needle.intersection(tokens(utterance.text)).count
            if score > 0 { scored.append((index, score)) }
        }
        scored.sort { $0.score > $1.score }

        var keep = Set<Int>()
        var used = 0
        for candidate in scored {
            for index in (candidate.index - 1)...(candidate.index + 1)
            where meeting.utterances.indices.contains(index) && !keep.contains(index) {
                let cost = line(meeting.utterances[index]).count + 1
                guard used + cost <= budgetChars else { continue }
                keep.insert(index)
                used += cost
            }
        }

        guard !keep.isEmpty else { return String(whole.prefix(budgetChars)) }

        // Back in order, with gaps marked so the model does not read across one.
        var out: [String] = []
        var previous = -2
        for index in keep.sorted() {
            if index != previous + 1 && previous >= 0 { out.append("…") }
            out.append(line(meeting.utterances[index]))
            previous = index
        }
        return out.joined(separator: "\n")
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "what", "when", "where",
        "who", "did", "was", "were", "are", "you", "your", "they", "them",
        "about", "from", "have", "has", "had", "any", "all", "can", "could",
        "would", "should", "there", "their", "how", "why", "does", "do",
    ]

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You answer questions about one meeting, using only the material you are \
    given. It is a transcript from automatic speech recognition, so expect \
    misheard words and read through them.

    Rules:
    - Answer only from the material. If it does not cover the question, say so \
    plainly rather than guessing.
    - Cite the moment with its timecode in square brackets, like [12:34], when \
    you are drawing on a line of the transcript.
    - Be brief and direct. No preamble, no restating the question.
    - A "…" in the transcript means lines were left out; do not read across it.
    """

    private static func userPrompt(context: String, history: [ChatTurn], question: String) -> String {
        var out = "Meeting material:\n\n\(context)\n\n"
        if !history.isEmpty {
            let earlier = history
                .map { "\($0.role == .you ? "Question" : "Answer"): \($0.text)" }
                .joined(separator: "\n")
            out += "Earlier in this conversation:\n\(earlier)\n\n"
        }
        return out + "Question: \(question)"
    }

    private static func tidy(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some local models still open with a reasoning block.
        if let start = text.range(of: "<think>"), let end = text.range(of: "</think>"),
           start.lowerBound < end.lowerBound {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
