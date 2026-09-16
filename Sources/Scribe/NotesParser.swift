import Foundation

/// Turns the model's markdown into structured notes.
///
/// The summariser is asked for a fixed set of `##` headings and a strict action
/// item format, so parsing is reliable — but it is a language model, so anything
/// unrecognised is preserved as a section rather than discarded.
enum NotesParser {

    static func parse(_ markdown: String) -> (summary: String, sections: [NoteSection], actions: [ActionItem]) {
        var summary = ""
        var sections: [NoteSection] = []
        var actions: [ActionItem] = []

        var heading: String?
        var body: [String] = []

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { body.removeAll() }
            guard let heading else {
                // Text before any heading is treated as the summary.
                if !text.isEmpty, summary.isEmpty { summary = text }
                return
            }
            let key = heading.lowercased()
            if key.contains("summary") {
                summary = text
            } else if key.contains("action") {
                actions = parseActions(text)
            } else if !text.isEmpty {
                sections.append(NoteSection(heading: heading, body: text))
            }
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# ") {
                continue    // the note's own title; the meeting already has one
            } else {
                body.append(line)
            }
        }
        flush()

        return (summary, sections, actions)
    }

    /// Expects `- [ ] **Owner** — task`, but tolerates a missing owner, a plain
    /// bullet, and any of the dash characters models like to use.
    private static func parseActions(_ text: String) -> [ActionItem] {
        var items: [ActionItem] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            var done = false
            if let range = line.range(of: #"^[-*]\s*\[( |x|X)\]\s*"#, options: .regularExpression) {
                done = line[range].lowercased().contains("x")
                line.removeSubrange(range)
            } else if let range = line.range(of: #"^[-*]\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
            } else {
                continue
            }

            var owner = ""
            if let match = line.range(of: #"^\*\*(.+?)\*\*"#, options: .regularExpression) {
                owner = String(line[match]).replacingOccurrences(of: "*", with: "")
                line.removeSubrange(match)
                // Drop the separator between owner and task.
                if let sep = line.range(of: #"^\s*[—–\-:]\s*"#, options: .regularExpression) {
                    line.removeSubrange(sep)
                }
            }

            let task = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            items.append(ActionItem(owner: owner.isEmpty ? "Unassigned" : owner,
                                    text: task,
                                    done: done))
        }
        return items
    }
}
