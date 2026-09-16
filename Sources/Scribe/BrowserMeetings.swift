import Foundation

/// Tells whether a browser has a meeting open, by reading its tab URLs.
///
/// A browser holding the microphone could be a Meet call or a voice search, and
/// the audio alone cannot say which. The tab can. Lookups run off the main
/// thread and are cached, because the first one waits on the user answering the
/// Automation permission prompt.
final class BrowserMeetings: @unchecked Sendable {

    enum Result: Equatable {
        /// A meeting tab is open; the associated value names the service.
        case meeting(String)
        case noMeeting
        /// The browser cannot be asked: not scriptable, or permission denied.
        case unavailable
    }

    /// Browsers whose tabs can be listed over AppleScript.
    static let scriptable: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    static let browsers: Set<String> = scriptable.union(["org.mozilla.firefox", "app.zen-browser.zen"])

    /// Pages that are a call, not just a site that happens to use the mic.
    private static let patterns: [(String, String)] = [
        (#"https://meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}"#, "Google Meet"),
        (#"https://teams\.(microsoft|live)\.com/"#, "Teams"),
        (#"https://[\w.-]*zoom\.us/(wc|j)/"#, "Zoom"),
        (#"https://whereby\.com/[\w-]+"#, "Whereby"),
        (#"https://[\w.-]*webex\.com/"#, "Webex"),
        (#"https://app\.slack\.com/huddle/"#, "Slack"),
        (#"https://discord\.com/channels/"#, "Discord"),
        (#"https://meet\.jit\.si/[\w-]+"#, "Jitsi Meet"),
        (#"https://app\.gather\.town/"#, "Gather"),
        (#"https://[\w-]+\.daily\.co/"#, "Daily"),
    ]

    private let queue = DispatchQueue(label: "scribe.browser-meetings")
    private let lock = NSLock()
    private var cache: [String: (result: Result, checked: Date)] = [:]
    private var inFlight: Set<String> = []

    /// The latest known answer for a browser, refreshing it in the background
    /// once it is a few seconds old. Nil until the first lookup completes.
    func result(for bundleID: String) -> Result? {
        guard Self.scriptable.contains(bundleID) else { return .unavailable }
        lock.lock()
        let cached = cache[bundleID]
        let stale = cached.map { Date().timeIntervalSince($0.checked) > 8 } ?? true
        let shouldRefresh = stale && !inFlight.contains(bundleID)
        if shouldRefresh { inFlight.insert(bundleID) }
        lock.unlock()

        if shouldRefresh {
            queue.async { [weak self] in
                let result = Self.lookUp(bundleID)
                self?.lock.lock()
                self?.cache[bundleID] = (result, Date())
                self?.inFlight.remove(bundleID)
                self?.lock.unlock()
            }
        }
        return cached?.result
    }

    /// Synchronous lookup, for the command-line probe.
    static func lookUp(_ bundleID: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(bundleID)\" to get URL of every tab of every window"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return .unavailable }
        let urls = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        // -1743 is "not authorised"; anything else means it cannot be asked.
        guard process.terminationStatus == 0 else { return .unavailable }

        for (pattern, name) in patterns where urls.range(of: pattern, options: .regularExpression) != nil {
            return .meeting(name)
        }
        return .noMeeting
    }
}
