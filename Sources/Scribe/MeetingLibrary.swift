import Foundation

/// The on-disk store of meetings. One folder per meeting holding `meeting.json`
/// and the mixed audio, so a meeting can be moved, backed up or deleted as a
/// single unit.
@MainActor
final class MeetingLibrary: ObservableObject {

    static let shared = MeetingLibrary()

    @Published private(set) var meetings: [Meeting] = []
    /// Meetings whose notes are being written right now, with a status line.
    @Published private(set) var notesProgress: [UUID: String] = [:]
    private var folders: [UUID: URL] = [:]

    private init() { reload() }

    // MARK: - Loading

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Paths.library, includingPropertiesForKeys: nil)) ?? []

        var loaded: [(Meeting, URL)] = []
        for folder in contents where folder.hasDirectoryPath {
            let record = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: record) else { continue }
            do {
                let meeting = try Self.decoder.decode(Meeting.self, from: data)
                loaded.append((meeting, folder))
            } catch {
                Log.error("skipping unreadable meeting at \(folder.lastPathComponent): \(error)")
            }
        }

        folders = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0.id, $0.1) })
        meetings = loaded.map(\.0).sorted { $0.started > $1.started }
        backfillActionLinks()
        repairLegacyRecords()
    }

    /// Meetings filed before action linking existed have no source timestamps.
    /// Compute them once, on load, rather than making every reader handle both
    /// shapes.
    private func backfillActionLinks() {
        for meeting in meetings {
            guard !meeting.utterances.isEmpty,
                  !meeting.actionItems.isEmpty,
                  meeting.actionItems.allSatisfy({ $0.sourceStart == nil }) else { continue }
            var updated = meeting
            updated.actionItems = ActionLinker.link(meeting.actionItems, to: meeting.utterances)
            guard updated.actionItems.contains(where: { $0.sourceStart != nil }) else { continue }
            save(updated)
        }
    }

    /// Meetings saved by earlier builds stored a failure as prose in the summary
    /// and raw process identifiers as platforms. Convert both once, so a failed
    /// meeting can be retried and reads properly.
    private func repairLegacyRecords() {
        let legacyFailure = "Notes could not be generated: "
        for meeting in meetings {
            var repaired = meeting

            let tidy = AppNames.tidy(meeting.platforms)
            if tidy != meeting.platforms { repaired.platforms = tidy }

            if meeting.notesError == nil, meeting.summary.hasPrefix(legacyFailure) {
                let reason = meeting.summary
                    .dropFirst(legacyFailure.count)
                    .components(separatedBy: .newlines).first ?? ""
                repaired.notesError = reason.trimmingCharacters(in: .whitespaces)
                repaired.summary = ""
                // The old fallback title was built from the raw first platform.
                if meeting.title == NotesGenerator.placeholderTitle(platforms: meeting.platforms) {
                    repaired.titleIsPlaceholder = true
                    repaired.title = NotesGenerator.placeholderTitle(platforms: tidy)
                }
            }

            if repaired != meeting { save(repaired) }
        }
    }

    // MARK: - Notes

    /// Writes, or rewrites, a meeting's notes from its transcript.
    ///
    /// A failure is recorded on the meeting rather than thrown, because the
    /// caller is either a meeting that just ended or a Retry button, and both
    /// want the same outcome: the transcript kept, the reason visible, and the
    /// option to try again. Notes that already exist are left alone on failure.
    @discardableResult
    func generateNotes(for id: UUID) async -> Meeting? {
        guard notesProgress[id] == nil,
              let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        notesProgress[id] = "Starting the notes model…"
        defer { notesProgress[id] = nil }

        do {
            let notes = try await NotesGenerator.generate(for: meeting, prefs: .shared) { [weak self] status in
                self?.notesProgress[id] = status
            }
            // The meeting may have been edited or deleted while the model ran.
            guard var current = meetings.first(where: { $0.id == id }) else { return nil }
            if let title = notes.title, current.titleIsPlaceholder == true {
                current.title = title
                current.titleIsPlaceholder = false
            }
            current.summary = notes.summary
            current.sections = notes.sections
            current.actionItems = notes.actions
            current.model = notes.model
            current.language = notes.language
            current.notesError = nil
            save(current)
            Log.info("wrote notes for \(current.title) with \(notes.actions.count) actions")
            return current
        } catch {
            guard var current = meetings.first(where: { $0.id == id }) else { return nil }
            current.notesError = error.localizedDescription
            save(current)
            Log.error("notes failed for \(current.title): \(error.localizedDescription)")
            return current
        }
    }

    func dismissNotesError(for id: UUID) {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        meeting.notesError = nil
        save(meeting)
    }

    // MARK: - Access

    func folder(for meeting: Meeting) -> URL? { folders[meeting.id] }

    func audioURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName,
              let folder = folders[meeting.id] else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Mutating

    /// Files a newly finished meeting, moving its audio into the library.
    @discardableResult
    func add(_ meeting: Meeting, audioSource: URL?) -> Meeting {
        var stored = meeting
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "\(stamp.string(from: meeting.started))-\(meeting.id.uuidString.prefix(8))"
        let folder = Paths.library.appendingPathComponent(name, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let audioSource, FileManager.default.fileExists(atPath: audioSource.path) {
                let destination = folder.appendingPathComponent(audioSource.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: audioSource, to: destination)
                stored.audioFileName = destination.lastPathComponent
            }
        } catch {
            Log.error("could not create library folder: \(error.localizedDescription)")
        }

        folders[stored.id] = folder
        meetings.insert(stored, at: 0)
        meetings.sort { $0.started > $1.started }
        save(stored)
        // save() fills in the vault path, so return the stored copy rather than
        // the one we built.
        return meetings.first { $0.id == stored.id } ?? stored
    }

    func save(_ meeting: Meeting) {
        guard let folder = folders[meeting.id] else { return }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        }
        do {
            let data = try Self.encoder.encode(meeting)
            try data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            Log.error("could not save meeting: \(error.localizedDescription)")
        }
        exportToVaultIfEnabled(meeting)
    }

    func delete(_ meeting: Meeting) {
        if let folder = folders[meeting.id] {
            try? FileManager.default.removeItem(at: folder)
        }
        if let path = meeting.vaultNotePath, Prefs.shared.exportToVault {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        folders[meeting.id] = nil
        meetings.removeAll { $0.id == meeting.id }
    }

    private func exportToVaultIfEnabled(_ meeting: Meeting) {
        guard Prefs.shared.exportToVault, let directory = Prefs.shared.notesDirectory else { return }
        do {
            let url = try VaultWriter.write(meeting, into: directory)
            if meeting.vaultNotePath != url.path {
                var updated = meeting
                updated.vaultNotePath = url.path
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                    meetings[index] = updated
                }
                if let folder = folders[meeting.id],
                   let data = try? Self.encoder.encode(updated) {
                    try? data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
                }
            }
        } catch {
            Log.error("vault export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
