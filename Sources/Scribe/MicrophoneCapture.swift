import AVFoundation
import Foundation

/// Captures the local microphone — i.e. you — as a separate stream.
///
/// Keeping the mic and the system output apart gives us two-speaker attribution
/// ("Me" vs "Others") for free, without running a diarisation model.
final class MicrophoneCapture {

    private var engine = AVAudioEngine()
    private var resampler: Resampler?
    private var onAudio: ((AVAudioPCMBuffer) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?

    private let lock = NSLock()
    private var lastBufferAt = Date.distantPast

    private(set) var isRunning = false
    /// How many times the stream had to be rebuilt. Surfaced in the log so a
    /// meeting that went quiet can be explained afterwards.
    private(set) var restarts = 0

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        self.onAudio = onAudio
        try attach()
        isRunning = true

        // A meeting app switching on echo cancellation reconfigures the input
        // device — often to another sample rate. The engine does not follow: it
        // keeps running and quietly delivers silence for the rest of the call.
        // This is why a meeting on the built-in mic could come back with no
        // "Me" lines at all while an external USB mic was unaffected.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild(reason: "the audio hardware was reconfigured")
        }

        // Belt and braces: a live input delivers buffers continuously, silence
        // included, so a gap with no buffers at all means the stream is dead
        // rather than quiet — whatever the reason, and whether or not the
        // notification above ever arrived.
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.lock.lock()
            let silentFor = Date().timeIntervalSince(self.lastBufferAt)
            self.lock.unlock()
            if silentFor > 5 {
                self.rebuild(reason: "no audio arrived for \(Int(silentFor))s")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        detach()
        resampler = nil
        onAudio = nil
        if restarts > 0 { Log.info("microphone stream was rebuilt \(restarts) time(s) during this meeting") }
    }

    // MARK: - Internals

    private func attach() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Scribe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No usable microphone input. Check System Settings › Privacy & Security › Microphone."
            ])
        }
        guard let resampler = Resampler(from: format) else {
            throw NSError(domain: "Scribe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not set up microphone resampling."
            ])
        }
        self.resampler = resampler

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.lastBufferAt = Date()
            self.lock.unlock()
            guard let converted = resampler.convert(buffer) else { return }
            self.onAudio?(converted)
        }
        engine.prepare()
        try engine.start()

        lock.lock()
        lastBufferAt = Date()
        lock.unlock()

        Log.info("microphone capture running at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
                 + " on \(CA.defaultInputDeviceName ?? "an unnamed device")")
    }

    private func detach() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Rebuilds the capture chain around whatever the hardware looks like now.
    ///
    /// A fresh `AVAudioEngine` rather than restarting the old one: after a
    /// device change the existing input node keeps the stale format, and
    /// reusing it reproduces the very silence this is here to end.
    private func rebuild(reason: String) {
        guard isRunning, let onAudio else { return }
        Log.info("rebuilding the microphone stream — \(reason)")
        restarts += 1

        let previousObserver = configurationObserver
        detach()
        engine = AVAudioEngine()
        self.onAudio = onAudio

        do {
            try attach()
        } catch {
            Log.error("could not rebuild the microphone stream: \(error.localizedDescription)")
            return
        }

        // The notification is tied to a specific engine, so it has to follow.
        if let previousObserver { NotificationCenter.default.removeObserver(previousObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild(reason: "the audio hardware was reconfigured")
        }
    }
}
