import AVFoundation
import Foundation

/// `Scribe --doctor` — verifies every moving part without needing a meeting.
enum Doctor {

    static func run() -> Never {
        CLIRelaunch.ensureOwnResponsibleProcess()
        let prefs = Prefs.shared
        var failures = 0

        func check(_ name: String, _ body: () -> (Bool, String)) {
            let (ok, detail) = body()
            if !ok { failures += 1 }
            print("\(ok ? "✅" : "❌")  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(detail)")
        }

        print("Scribe self-check\n")

        check("whisper-cli") {
            let path = prefs.whisperBinary
            return (FileManager.default.isExecutableFile(atPath: path), path)
        }

        check("speech model") {
            let path = prefs.whisperModel
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            guard let size = attrs?[.size] as? Int else { return (false, "missing — open Setup, or run `Scribe --setup-local`") }
            return (size > 1_000_000, "\(size / 1_048_576) MB · \((path as NSString).lastPathComponent)")
        }

        check("microphone") {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                // Ask here so the whole setup can be completed from one command.
                let semaphore = DispatchSemaphore(value: 0)
                AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
                _ = semaphore.wait(timeout: .now() + 60)
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return (true, "granted")
            default: return (false, "denied — System Settings › Privacy & Security › Microphone")
            }
        }

        check("system audio") {
            let tap = SystemAudioTap()
            let counter = FrameCounter()
            do {
                try tap.start { buffer in counter.add(buffer) }
            } catch {
                return (false, error.localizedDescription)
            }
            // Make noise ourselves so the probe does not depend on the user
            // having something playing.
            let player = ProbeTone()
            player.play()
            Thread.sleep(forTimeInterval: 2.0)
            player.stop()
            tap.stop()

            if counter.total == 0 {
                return (false, "tap opened but delivered no audio at all")
            }
            if counter.peak < 0.001 {
                return (false, "capturing silence — macOS attributes audio capture to the launching app, so run this via Scribe.app rather than the bare binary")
            }
            return (true, "\(counter.total) frames, peak \(String(format: "%.3f", counter.peak))\(counter.layout)")
        }

        check("notes model") {
            let engine = NotesEngineKind(rawValue: prefs.notesEngine) ?? .ollama
            switch engine {
            case .local:
                guard LocalRuntime.isRuntimeInstalled else {
                    return (false, "built-in runtime not installed — run `Scribe --setup-local`")
                }
                let model = LocalRuntime.model(id: prefs.localModelID)
                guard model.isDownloaded else {
                    return (false, "\(model.name) not downloaded — run `Scribe --setup-local`")
                }
                return (true, "\(model.name), built in")

            case .ollama:
                let semaphore = DispatchSemaphore(value: 0)
                var result = (false, "Ollama is not running — start it, or switch to the built-in engine in Setup")
                Task {
                    defer { semaphore.signal() }
                    guard await OllamaService.isRunning(host: prefs.ollamaHost) else { return }
                    let models = await OllamaService.installedModels(host: prefs.ollamaHost)
                    if models.contains(prefs.ollamaModel) {
                        result = (true, "\(prefs.ollamaModel) via Ollama")
                    } else {
                        result = (false, "`\(prefs.ollamaModel)` not pulled — have: \(models.joined(separator: ", "))")
                    }
                }
                _ = semaphore.wait(timeout: .now() + 15)
                return result
            }
        }

        check("vault export") {
            guard prefs.exportToVault else { return (true, "off — meetings stay in Scribe") }
            guard let directory = prefs.notesDirectory else {
                return (false, "no folder chosen — pick one in Setup, or turn the export off")
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let probe = directory.appendingPathComponent(".scribe-write-test")
                try Data().write(to: probe)
                try FileManager.default.removeItem(at: probe)
                return (true, directory.path)
            } catch {
                return (false, "\(directory.path) — \(error.localizedDescription)")
            }
        }

        check("library") {
            (FileManager.default.isWritableFile(atPath: Paths.library.path), Paths.library.path)
        }

        print("\n\(failures == 0 ? "All good. \(CLIStatus.successMarker)" : "\(failures) problem(s) above.")")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Thread-safe frame/level accumulator for the tap probe.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var maxAmplitude: Float = 0
    private var described = ""

    func add(_ buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let channel = buffer.int16ChannelData {
            for i in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(Float(channel[0][i]) / 32768))
            }
        }
        lock.lock()
        count += Int(buffer.frameLength)
        maxAmplitude = max(maxAmplitude, peak)
        lock.unlock()
    }

    func describe(_ text: String) { lock.lock(); described = text; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    var peak: Float { lock.lock(); defer { lock.unlock() }; return maxAmplitude }
    var layout: String { lock.lock(); defer { lock.unlock() }; return described }
}

/// Plays a system sound from a *separate* process so the probe is not filtered
/// out by the tap's own-process exclusion.
private final class ProbeTone {
    private var process: Process?

    func play() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["/System/Library/Sounds/Submarine.aiff"]
        try? task.run()
        process = task
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
