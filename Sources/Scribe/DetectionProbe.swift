import Foundation

/// `Scribe --probe-detection [seconds]` — shows what the detector sees and
/// why it does or does not call it a meeting. For tracking down false
/// detections.
enum DetectionProbe {

    static func run(seconds: Int) -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let detector = MeetingDetector()
        var lines: [String: Int] = [:]
        var verdicts: [String: Int] = [:]
        let samples = max(1, seconds)

        for sample in 0..<samples {
            for app in detector.appAudio() {
                var browser = ""
                if BrowserMeetings.browsers.contains(app.bundleID) {
                    // Synchronous here so the answer is in this sample.
                    browser = " tabs=\(BrowserMeetings.lookUp(app.bundleID))"
                }
                let line = "\(app.name) [\(app.bundleID)] mic=\(app.capturing) speakers=\(app.playing)\(browser)"
                lines[line, default: 0] += 1
            }
            let verdict = detector.currentCandidate().map { "MEETING: \($0.name) — \($0.reason.rawValue)" }
                ?? "no meeting"
            verdicts[verdict, default: 0] += 1
            if sample < samples - 1 { Thread.sleep(forTimeInterval: 1) }
        }

        print("Audio activity over \(samples)s (seconds seen):")
        for (line, count) in lines.sorted(by: { $0.key < $1.key }) { print("  \(count)s  \(line)") }
        print("\nVerdicts:")
        for (verdict, count) in verdicts.sorted(by: { $0.value > $1.value }) { print("  \(count)s  \(verdict)") }
        print(CLIStatus.successMarker)
        exit(0)
    }
}
