import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (i.e. the other participants) using a
/// CoreAudio process tap — no virtual audio driver, no BlackHole install.
///
/// Requires macOS 14.4+ and the "System Audio Recording" privacy permission.
final class SystemAudioTap {

    enum TapError: LocalizedError {
        case unsupportedOS
        case noOutputDevice
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case badFormat
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS: return "System audio capture needs macOS 14.4 or later."
            case .noOutputDevice: return "No default output device."
            case .tapCreationFailed(let s):
                return "Could not create the audio tap (\(s)). Grant Scribe permission under System Settings › Privacy & Security › Screen & System Audio Recording."
            case .aggregateCreationFailed(let s): return "Could not create the aggregate device (\(s))."
            case .badFormat: return "The tap reported an unusable audio format."
            case .ioProcFailed(let s): return "Could not start the audio I/O proc (\(s))."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var tapFormat: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "scribe.systemtap.io", qos: .userInitiated)

    private(set) var isRunning = false

    /// - Parameter onAudio: receives 16 kHz mono PCM, already downmixed.
    func start(onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard #available(macOS 14.4, *) else { throw TapError.unsupportedOS }
        guard let outputUID = CA.defaultOutputDeviceUID else { throw TapError.noOutputDevice }

        // Exclude ourselves so we never record our own notification sounds.
        var excluded: [AudioObjectID] = []
        if let selfObject = CA.processObject(for: ProcessInfo.processInfo.processIdentifier) {
            excluded.append(selfObject)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Scribe System Audio"
        description.isPrivate = true
        // muteBehavior is left at its CATapUnmuted default so the user still
        // hears the call while we record it.

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        guard let tapUID = CA.string(tap, kAudioTapPropertyUID) else {
            cleanUp()
            throw TapError.badFormat
        }

        let aggregateUID = "com.scribe.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggregate = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            cleanUp()
            throw TapError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        var asbd = CA.value(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard asbd.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanUp()
            throw TapError.badFormat
        }
        tapFormat = format
        resampler = Resampler(from: format)
        guard resampler != nil else {
            cleanUp()
            throw TapError.badFormat
        }

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.tapFormat, let resampler = self.resampler else { return }
            guard let raw = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                  raw.frameLength > 0,
                  let converted = resampler.convert(raw) else { return }
            onAudio(converted)
        }
        guard procStatus == noErr, let procID else {
            cleanUp()
            throw TapError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            cleanUp()
            throw TapError.ioProcFailed(startStatus)
        }
        isRunning = true
        Log.info("system audio tap running at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cleanUp()
    }

    private func cleanUp() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        resampler = nil
        tapFormat = nil
    }

    deinit { cleanUp() }
}
