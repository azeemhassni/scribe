import AppKit
import CoreAudio
import Darwin
import Foundation

/// Something that looks like a meeting in progress.
struct MeetingCandidate: Equatable {
    /// What to call it: "Zoom", "Google Meet", "Chrome".
    let name: String
    let bundleID: String
    let reason: Reason

    enum Reason: String {
        case meetingApp = "call app using the microphone"
        case meetingTab = "meeting open in the browser"
        case twoWayAudio = "app using the microphone and speakers"
    }
}

/// Decides when the user is in a meeting.
///
/// "Something has the microphone open" is not enough on its own. macOS keeps it
/// open for its own services much of the time — Siri's listener and
/// `historicalaudiod` hold it on a quiet Mac — so trusting that signal starts
/// recordings during a YouTube video. A meeting is recognised instead by:
///
/// - the process being a real app, not a system service or command-line tool;
/// - a known call app using the microphone; or
/// - a browser using the microphone with a meeting tab open; or
/// - any other app both capturing the microphone and playing audio, which is
///   what a call does and a video does not.
final class MeetingDetector {

    enum Event {
        case started(MeetingCandidate)
        case stopped
    }

    /// Seconds a meeting must look real before it is reported.
    var startDelay: TimeInterval = 8
    /// Seconds of no meeting before it is reported over.
    var stopDelay: TimeInterval = 45
    var ignoredBundleIDs: Set<String> = []

    private let pollInterval: TimeInterval = 2
    private var timer: Timer?
    private var seenSince: Date?
    private var goneSince: Date?
    private(set) var isMeetingActive = false
    private var onEvent: ((Event) -> Void)?
    private let browserMeetings = BrowserMeetings()
    private var appCache: [String: (bundleID: String, name: String)?] = [:]

    /// Native apps whose use of the microphone means a call.
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.skype.skype",
        "com.logmein.GoToMeeting", "com.ringcentral.RingCentral", "app.tuple.app",
    ]

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Evaluation

    struct AppAudio {
        let bundleID: String
        let name: String
        var capturing = false
        var playing = false
    }

    /// Audio activity per app, with helper processes folded into the app that
    /// owns them and system services left out.
    func appAudio() -> [AppAudio] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes = CA.list(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var apps: [String: AppAudio] = [:]

        for object in processes {
            let capturing = CA.value(object, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0
            let playing = CA.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            guard capturing || playing else { continue }

            let pid = CA.value(object, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != selfPID else { continue }
            let processBundleID = CA.string(object, kAudioProcessPropertyBundleID) ?? ""
            guard let owner = owningApp(pid: pid, processBundleID: processBundleID) else { continue }
            guard owner.bundleID != Bundle.main.bundleIdentifier,
                  !ignoredBundleIDs.contains(owner.bundleID),
                  !AppNames.isSystemService(owner.bundleID) else { continue }

            var entry = apps[owner.bundleID] ?? AppAudio(bundleID: owner.bundleID, name: owner.name)
            entry.capturing = entry.capturing || capturing
            entry.playing = entry.playing || playing
            apps[owner.bundleID] = entry
        }
        return Array(apps.values)
    }

    /// The best meeting candidate right now, if there is one.
    func currentCandidate() -> MeetingCandidate? {
        let candidates = appAudio().compactMap(evaluate)
        let rank: [MeetingCandidate.Reason] = [.meetingApp, .meetingTab, .twoWayAudio]
        return candidates.min { rank.firstIndex(of: $0.reason)! < rank.firstIndex(of: $1.reason)! }
    }

    func evaluate(_ app: AppAudio) -> MeetingCandidate? {
        guard app.capturing else { return nil }

        if Self.meetingApps.contains(app.bundleID) {
            return MeetingCandidate(name: app.name, bundleID: app.bundleID, reason: .meetingApp)
        }

        if BrowserMeetings.browsers.contains(app.bundleID) {
            switch browserMeetings.result(for: app.bundleID) {
            case .meeting(let service):
                return MeetingCandidate(name: service, bundleID: app.bundleID, reason: .meetingTab)
            case .noMeeting, nil:
                // No meeting tab: voice search, dictation on a site, a
                // recorder. Not a meeting, however much audio is going on.
                return nil
            case .unavailable:
                break   // cannot see the tabs, so fall back to the audio
            }
        }

        guard app.playing else { return nil }
        return MeetingCandidate(name: app.name, bundleID: app.bundleID, reason: .twoWayAudio)
    }

    /// Maps a process to the app it belongs to. Browsers and chat apps do their
    /// audio in helper processes buried inside their bundle, and Safari does
    /// it in WebKit's system XPC services.
    private func owningApp(pid: pid_t, processBundleID: String) -> (bundleID: String, name: String)? {
        if processBundleID.hasPrefix("com.apple.WebKit") {
            return ("com.apple.Safari", "Safari")
        }

        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if let cached = appCache[path] { return cached }

        // Daemons and command-line tools are never the meeting.
        var owner: (bundleID: String, name: String)?
        if !path.hasPrefix("/System/Library/"), !path.hasPrefix("/usr/"),
           let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            if let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier {
                let name = AppNames.friendlyName(for: id)
                    ?? (FileManager.default.displayName(atPath: appPath) as NSString).deletingPathExtension
                owner = (id, name)
            }
        }
        appCache[path] = owner
        return owner
    }

    // MARK: - Timing

    private func poll() {
        let candidate = currentCandidate()
        let now = Date()

        guard let candidate else {
            seenSince = nil
            guard isMeetingActive else { return }
            let since = goneSince ?? now
            goneSince = since
            if now.timeIntervalSince(since) >= stopDelay {
                isMeetingActive = false
                goneSince = nil
                onEvent?(.stopped)
            }
            return
        }

        goneSince = nil
        guard !isMeetingActive else { return }
        let since = seenSince ?? now
        seenSince = since
        if now.timeIntervalSince(since) >= startDelay {
            isMeetingActive = true
            seenSince = nil
            onEvent?(.started(candidate))
        }
    }

    /// For the menu, while a meeting is waiting out the start delay.
    var secondsUntilStart: TimeInterval? {
        guard !isMeetingActive, let since = seenSince else { return nil }
        return max(0, startDelay - Date().timeIntervalSince(since))
    }
}
