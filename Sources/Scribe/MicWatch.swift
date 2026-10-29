import AVFoundation
import CoreAudio
import Foundation

/// `Scribe --mic-watch [seconds]` — captures the microphone and reports the
/// level each second, switching the default input device part-way through to
/// prove the stream survives a reconfiguration.
///
/// The original input device is put back before it exits.
enum MicWatch {

    static func run(seconds: Int) -> Never {
        let capture = MicrophoneCapture()
        let meter = Meter()

        do {
            try capture.start { buffer in meter.add(buffer) }
        } catch {
            print("could not start: \(error.localizedDescription)")
            exit(1)
        }

        let original = defaultInputDevice()
        let alternate = otherInputDevice(besides: original)
        print("input device: \(name(of: original) ?? "unknown")")
        if let alternate {
            print("will switch to: \(name(of: alternate) ?? "unknown") at 5s, back at 10s\n")
        } else {
            print("no second input device to switch to; watching only\n")
        }

        for second in 1...seconds {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let peak = meter.takePeak()
            let bar = String(repeating: "█", count: min(28, Int(peak * 80)))
            print(String(format: "  %2ds  peak %.3f  %@%@", second, peak, bar,
                         peak < 0.0005 ? "  (silent)" : ""))

            if second == 5, let alternate {
                print("  -- switching input device --")
                setDefaultInput(alternate)
            }
            if second == 10, alternate != nil {
                print("  -- switching back --")
                setDefaultInput(original)
            }
        }

        setDefaultInput(original)
        capture.stop()
        print("\nrebuilds: \(capture.restarts)")
        print(CLIStatus.successMarker)
        exit(0)
    }

    // MARK: - Level

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Float = 0

        func add(_ buffer: AVAudioPCMBuffer) {
            var local: Float = 0
            if let samples = buffer.int16ChannelData {
                for i in 0..<Int(buffer.frameLength) {
                    local = max(local, abs(Float(samples[0][i]) / 32768))
                }
            }
            lock.lock(); peak = max(peak, local); lock.unlock()
        }

        func takePeak() -> Float {
            lock.lock(); defer { peak = 0; lock.unlock() }
            return peak
        }
    }

    // MARK: - Devices

    private static func defaultInputDevice() -> AudioDeviceID {
        CA.value(AudioObjectID(kAudioObjectSystemObject),
                 kAudioHardwarePropertyDefaultInputDevice,
                 default: AudioDeviceID(kAudioObjectUnknown))
    }

    private static func name(of device: AudioDeviceID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        return CA.string(device, kAudioObjectPropertyName)
    }

    private static func otherInputDevice(besides current: AudioDeviceID) -> AudioDeviceID? {
        let all = CA.list(AudioObjectID(kAudioObjectSystemObject),
                          kAudioHardwarePropertyDevices,
                          of: AudioDeviceID.self)
        return all.first { device in
            guard device != current else { return false }
            // Input devices only: anything with input channels to offer.
            let streams = CA.list(device, kAudioDevicePropertyStreams,
                                  scope: kAudioObjectPropertyScopeInput,
                                  of: AudioStreamID.self)
            return !streams.isEmpty
        }
    }

    private static func setDefaultInput(_ device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else { return }
        var address = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        var value = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }
}
