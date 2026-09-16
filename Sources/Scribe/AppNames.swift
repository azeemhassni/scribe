import Foundation

/// Turns the processes CoreAudio reports into names worth showing.
enum AppNames {

    private static let friendly: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.beta": "Chrome",
        "com.brave.Browser": "Brave",
        "com.apple.Safari": "Safari",
        "com.apple.WebKit": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.apple.FaceTime": "FaceTime",
    ]

    /// System services that open the microphone for their own reasons — Siri
    /// listening, dictation — and are never the meeting.
    private static let systemServices = [
        "com.apple.CoreSpeech",
        "com.apple.corespeechd",
        "com.apple.SpeechRecognitionCore",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.dictation",
        "com.apple.accessibility",
    ]

    static func isSystemService(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return systemServices.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// Browsers and chat apps capture audio from helper processes such as
    /// `com.google.Chrome.helper`, so match on the owning app's identifier.
    static func friendlyName(for bundleID: String) -> String? {
        if let exact = friendly[bundleID] { return exact }
        return friendly
            .filter { bundleID.hasPrefix($0.key + ".") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Cleans a stored platform list: names bundle identifiers, drops system
    /// services and blanks, and removes duplicates while keeping order.
    static func tidy(_ platforms: [String]) -> [String] {
        var seen = Set<String>()
        return platforms.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isSystemService(trimmed) else { return nil }
            let name = friendlyName(for: trimmed) ?? trimmed
            return seen.insert(name).inserted ? name : nil
        }
    }
}
