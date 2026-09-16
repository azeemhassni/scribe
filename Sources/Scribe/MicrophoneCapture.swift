import AVFoundation
import Foundation

/// Captures the local microphone — i.e. you — as a separate stream.
///
/// Keeping the mic and the system output apart gives us two-speaker attribution
/// ("Me" vs "Others") for free, without running a diarisation model.
final class MicrophoneCapture {

    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
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

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let converted = resampler.convert(buffer) else { return }
            onAudio(converted)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Log.info("microphone capture running at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        resampler = nil
        isRunning = false
    }
}
