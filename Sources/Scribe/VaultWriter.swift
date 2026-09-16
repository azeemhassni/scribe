import Foundation

/// Renders a `Meeting` as an Obsidian note.
///
/// This is an export, not the store: the library holds the truth, and this file
/// is rewritten whenever the meeting changes. Editing the note in Obsidian will
/// therefore be overwritten — edit in Scribe instead.
enum VaultWriter {

    static func write(_ meeting: Meeting, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = destination(for: meeting, in: directory)
        try render(meeting).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func render(_ meeting: Meeting) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current

        let minutes = Int((meeting.duration / 60).rounded())
        let platform = meeting.platforms.isEmpty ? "unknown" : meeting.platforms.joined(separator: ", ")

        var out = """
        ---
        title: "\(meeting.title.replacingOccurrences(of: "\"", with: "'"))"
        date: \(iso.string(from: meeting.started))
        duration_minutes: \(minutes)
        platform: \(platform)
        open_actions: \(meeting.openActionCount)
        source: scribe
        model: \(meeting.model)
        tags: [meeting]
        ---

        # \(meeting.title)

        *\(friendly(meeting.started)) · \(minutes) min\(meeting.platforms.isEmpty ? "" : " · " + platform)*


        """

        if let error = meeting.notesError, meeting.summary.isEmpty {
            out += "> [!warning] Notes could not be written\n> \(error)\n> Retry from the meeting in Scribe.\n\n"
        }
        if !meeting.summary.isEmpty {
            out += "## Summary\n\n\(meeting.summary)\n\n"
        }

        if !meeting.actionItems.isEmpty {
            out += "## Action items\n\n"
            for item in meeting.actionItems {
                let box = item.done ? "x" : " "
                let owner = item.owner.isEmpty ? "" : "**\(item.owner)** — "
                out += "- [\(box)] \(owner)\(item.text)\n"
            }
            out += "\n"
        }

        for section in meeting.sections where !section.body.isEmpty {
            out += "## \(section.heading)\n\n\(section.body)\n\n"
        }

        out += """
        ---

        ## Transcript

        > [!note]- Full transcript
        \(asCallout(meeting.transcriptText))

        """

        if meeting.edited {
            out += "\n*Edited in Scribe. This file is regenerated from the Scribe library — edit there, not here.*\n"
        }
        return out
    }

    // MARK: - Helpers

    /// Reuses the existing file so edits update one note rather than piling up
    /// near-duplicates in the vault.
    private static func destination(for meeting: Meeting, in directory: URL) -> URL {
        if let path = meeting.vaultNotePath {
            let existing = URL(fileURLWithPath: path)
            if existing.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
               FileManager.default.fileExists(atPath: path) {
                return existing
            }
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let base = "\(stamp.string(from: meeting.started)) \(sanitize(meeting.title))"

        var candidate = directory.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }
        return candidate
    }

    private static func asCallout(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    private static func friendly(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM, HH:mm"
        return f.string(from: date)
    }

    private static func sanitize(_ title: String) -> String {
        title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
