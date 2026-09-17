import AppKit
import Foundation
import UserNotifications

@MainActor
final class ScribeController: ObservableObject {

    enum State: Equatable {
        case idle
        case armed(String)          // something is on the mic, waiting out the delay
        case detected(String)       // a meeting is on, waiting for the user to say record
        case recording
        case processing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recordingStarted: Date?
    @Published private(set) var activePlatforms: [String] = []
    @Published private(set) var transcribedLines = 0
    @Published private(set) var warnings: [String] = []
    /// A meeting that was detected but not yet recorded, in ask mode.
    @Published private(set) var detectedMeeting: MeetingCandidate?

    let prefs = Prefs.shared
    let library = MeetingLibrary.shared
    private let detector = MeetingDetector()
    private var session: MeetingSession?
    private var uiTimer: Timer?
    private let notifications = NotificationRouter()

    // MARK: - Startup

    func bootstrap() {
        _ = AppUpdater.shared
        applyDetectorSettings()

        Task {
            _ = await MicrophoneCapture.requestPermission()
            if prefs.useCalendarTitles { _ = await CalendarLookup.requestAccess() }
            requestNotificationPermission()
        }

        notifications.onRecord = { [weak self] in self?.recordDetectedMeeting() }
        notifications.onDismiss = { [weak self] in self?.dismissDetectedMeeting() }
        notifications.install()

        detector.start { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                guard self.prefs.autoDetect else { return }
                switch event {
                case .started(let meeting):
                    guard self.session == nil else { return }
                    if self.prefs.asksBeforeRecording {
                        self.offerToRecord(meeting)
                    } else {
                        self.beginRecording(platforms: [meeting.name])
                    }
                case .stopped:
                    self.clearDetectedMeeting()
                    guard self.session != nil else { return }
                    await self.endRecording(discard: false)
                }
            }
        }

        uiTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
    }

    func applyDetectorSettings() {
        detector.startDelay = TimeInterval(prefs.startDelaySeconds)
        detector.stopDelay = TimeInterval(prefs.stopDelaySeconds)
        detector.ignoredBundleIDs = prefs.ignoredBundleIDSet
    }

    private var silenceWarned = false
    /// The meeting whose notes are being written, so the menu can show progress.
    private var notesMeetingID: UUID?

    private func tick() {
        if let session {
            let count = session.utteranceCount
            if count != transcribedLines { transcribedLines = count }
            checkForSilentStreams(session)
        } else if case .failed = state {
            // leave the error on screen until something else happens
        } else if let meeting = detectedMeeting {
            state = .detected(meeting.name)
        } else if let seconds = detector.secondsUntilStart, !prefs.asksBeforeRecording {
            let who = detector.currentCandidate()?.name ?? "A meeting"
            state = .armed("\(who) — recording in \(Int(seconds))s")
        } else if case .processing = state {
            if let id = notesMeetingID, let status = library.notesProgress[id] {
                state = .processing(status)
            }
        } else {
            state = .idle
        }
    }

    /// A stream that has stayed at digital silence well into the meeting is not
    /// going to recover on its own. Say so now, while the meeting can still be
    /// saved, rather than in the notes afterwards.
    private func checkForSilentStreams(_ session: MeetingSession) {
        guard !silenceWarned, session.duration > 90 else { return }
        if session.systemAudioAvailable, session.systemPeak < 0.001 {
            silenceWarned = true
            warnings.append("The other participants are recording as silence. Quit Scribe, then reopen it from Finder or Spotlight rather than from a terminal — macOS grants audio capture to whichever app launched it.")
        } else if session.microphoneAvailable, session.micPeak < 0.001 {
            silenceWarned = true
            warnings.append("Your microphone is recording silence — check that the right input device is selected.")
        }
    }

    // MARK: - Asking

    /// Ask mode: say a meeting is on and let the user decide. A wrong guess
    /// costs one dismissed notification instead of a recording.
    private func offerToRecord(_ meeting: MeetingCandidate) {
        detectedMeeting = meeting
        state = .detected(meeting.name)
        notifications.postMeetingDetected(name: meeting.name)
        Log.info("meeting detected: \(meeting.name) (\(meeting.reason.rawValue))")
    }

    func recordDetectedMeeting() {
        guard let meeting = detectedMeeting, session == nil else { return }
        clearDetectedMeeting()
        beginRecording(platforms: [meeting.name])
    }

    /// Not now. The detector stays quiet until this meeting ends, so the same
    /// call does not ask twice.
    func dismissDetectedMeeting() {
        clearDetectedMeeting()
        if case .detected = state { state = .idle }
    }

    private func clearDetectedMeeting() {
        detectedMeeting = nil
        notifications.removeMeetingDetected()
    }

    // MARK: - Recording

    func startManually() {
        guard session == nil else { return }
        let name = detectedMeeting?.name ?? detector.currentCandidate()?.name
        clearDetectedMeeting()
        beginRecording(platforms: name.map { [$0] } ?? [])
    }

    private func beginRecording(platforms: [String]) {
        let title = prefs.useCalendarTitles ? CalendarLookup.currentEventTitle() : nil
        let session = MeetingSession(platforms: platforms, calendarTitle: title, settings: prefs)
        do {
            try session.start()
        } catch {
            state = .failed(error.localizedDescription)
            session.discardAudio()
            return
        }

        self.session = session
        recordingStarted = session.startedAt
        activePlatforms = platforms
        transcribedLines = 0
        warnings = []
        silenceWarned = false
        state = .recording

        if !session.systemAudioAvailable {
            warnings.append("Recording your mic only — system audio capture was refused. Grant Scribe access under System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        if !session.microphoneAvailable {
            warnings.append("Recording the call audio only — no microphone access.")
        }
        Log.info("recording started (\(platforms.joined(separator: ", ")))\(title.map { " · calendar: \($0)" } ?? "")")
    }

    func stopManually() {
        Task { await endRecording(discard: false) }
    }

    func discardCurrent() {
        Task { await endRecording(discard: true) }
    }

    private func endRecording(discard: Bool) async {
        guard let session else { return }
        self.session = nil
        recordingStarted = nil

        if discard {
            state = .processing("Discarding…")
            _ = session.finish()
            session.discardAudio()
            state = .idle
            Log.info("recording discarded by request")
            return
        }

        state = .processing("Finishing transcription…")
        let result = await Task.detached(priority: .userInitiated) { session.finish() }.value
        warnings = result.warnings

        guard result.duration >= Double(prefs.minimumMeetingSeconds) else {
            session.discardAudio()
            state = .idle
            Log.info("session was \(Int(result.duration))s — below the \(prefs.minimumMeetingSeconds)s threshold, discarded")
            return
        }
        guard !result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.discardAudio()
            state = .failed("Nothing was transcribed — check the microphone and system audio permissions.")
            return
        }

        await fileAndSummarise(session: session, result: result)
    }

    /// Files the transcript before asking for notes, so nothing that happens
    /// to the model — not running, crashing, timing out — can cost the meeting.
    private func fileAndSummarise(session: MeetingSession, result: MeetingSession.Result) async {
        state = .processing("Saving the transcript…")
        let draft = Meeting(title: session.calendarTitle ?? NotesGenerator.placeholderTitle(platforms: session.platforms),
                            started: session.startedAt,
                            ended: session.startedAt.addingTimeInterval(result.duration),
                            platforms: session.platforms,
                            model: "",
                            summary: "",
                            sections: [],
                            actionItems: [],
                            utterances: result.utterances,
                            audioFileName: nil,
                            vaultNotePath: nil,
                            warnings: result.warnings,
                            language: Language.dominant(in: result.utterances),
                            titleIsPlaceholder: session.calendarTitle == nil)

        // add() moves the mixed audio into the library first; only then is the
        // working folder (with the raw per-stream WAVs) thrown away.
        let filed = library.add(draft, audioSource: prefs.keepAudio ? result.audioURL : nil)
        session.discardAudio()

        notesMeetingID = filed.id
        defer { notesMeetingID = nil }
        let finished = await library.generateNotes(for: filed.id) ?? filed

        if let error = finished.notesError {
            state = .failed("Notes couldn't be written: \(error) The transcript is saved — retry from the library.")
            notify(title: "Notes couldn't be written",
                   body: "\(finished.title) — the transcript is saved. Open the library to retry.",
                   identifier: finished.id.uuidString)
        } else {
            state = .idle
            notify(title: "Meeting notes ready",
                   body: "\(finished.title) · \(finished.actionItems.count) action item\(finished.actionItems.count == 1 ? "" : "s")",
                   identifier: finished.id.uuidString)
        }
    }

    // MARK: - Notes

    func openNotesFolder() {
        guard let directory = prefs.notesDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    func clearError() { if case .failed = state { state = .idle } }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, identifier: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
