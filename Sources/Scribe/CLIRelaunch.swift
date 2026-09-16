import Foundation

/// macOS attributes privacy permissions to the *responsible* process, not the
/// one making the call. A binary exec'd from a terminal inherits the terminal as
/// its responsible process, so the system-audio tap opens and then quietly
/// delivers nothing but silence — no error, no prompt.
///
/// Rather than making that a documentation footnote everyone trips over, the
/// command-line modes relaunch themselves through LaunchServices, where Scribe
/// is its own responsible process, and relay the output back to the terminal.
enum CLIRelaunch {

    private static let marker = "--relaunched"

    /// Returns normally if we are already running under LaunchServices;
    /// otherwise relaunches and exits with the child's result.
    static func ensureOwnResponsibleProcess() {
        let arguments = CommandLine.arguments
        guard !arguments.contains(marker) else { return }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // Running the raw SwiftPM binary; nothing to relaunch into.
            FileHandle.standardError.write(Data(
                "Note: running outside an .app bundle — system audio will record silence.\n".utf8))
            return
        }

        let scratch = FileManager.default.temporaryDirectory
        let stdoutURL = scratch.appendingPathComponent("scribe-\(UUID().uuidString).out")
        let stderrURL = scratch.appendingPathComponent("scribe-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` is essential: without it, `open` just activates the menu bar
        // app that is already running, silently discards these arguments, and
        // `--wait-apps` then blocks until the user quits Scribe.
        open.arguments = ["-n", "-a", bundleURL.path,
                          "--wait-apps",
                          "--stdout", stdoutURL.path,
                          "--stderr", stderrURL.path,
                          "--args"] + arguments.dropFirst() + [marker]
        do {
            try open.run()
        } catch {
            FileHandle.standardError.write(Data("Could not relaunch: \(error.localizedDescription)\n".utf8))
            return
        }
        // Relay as it arrives rather than at exit: `--setup-local` downloads
        // gigabytes, and a progress bar nobody sees until the end is no
        // progress bar at all.
        var offset: UInt64 = 0
        var output = ""
        while open.isRunning {
            output += relay(from: stdoutURL, offset: &offset, to: .standardOutput)
            usleep(200_000)
        }
        open.waitUntilExit()
        output += relay(from: stdoutURL, offset: &offset, to: .standardOutput)

        var errorOffset: UInt64 = 0
        _ = relay(from: stderrURL, offset: &errorOffset, to: .standardError)
        // `open --wait-apps` does not forward the app's exit status, so the
        // child reports success in its output instead.
        exit(output.contains(CLIStatus.successMarker) ? 0 : 1)
    }
}

private extension CLIRelaunch {

    /// Copies whatever has been appended to `url` since `offset` to `handle`.
    static func relay(from url: URL, offset: inout UInt64, to handle: FileHandle) -> String {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? reader.close() }
        try? reader.seek(toOffset: offset)
        guard let data = try? reader.readToEnd(), !data.isEmpty else { return "" }
        offset += UInt64(data.count)
        handle.write(data)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum CLIStatus {
    /// Printed by the CLI modes on success so the relaunch wrapper can tell
    /// whether the run passed.
    static let successMarker = "[scribe:ok]"
}
