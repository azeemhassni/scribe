import CoreAudio
import Foundation

/// Thin, crash-free wrappers around the AudioObject property API.
enum CA {

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size value (Int, UInt32, ASBD, ...).
    static func value<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         default fallback: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var out = fallback
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? out : fallback
    }

    /// Reads a variable-length array property (e.g. the process or device list).
    static func list<T>(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        of type: T.Type) -> [T] {
        var addr = address(selector, scope)
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &byteSize) == noErr,
              byteSize > 0 else { return [] }
        let count = Int(byteSize) / MemoryLayout<T>.size
        var buffer = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        let status = buffer.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &byteSize, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(buffer.prefix(Int(byteSize) / MemoryLayout<T>.size))
    }

    /// Reads a CFString-valued property (UIDs, bundle identifiers, ...).
    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: CFString? = nil
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return out as String?
    }

    /// The AudioObjectID that CoreAudio uses to represent a running process.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inputPID = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &inputPID,
                                                &size, &out)
        guard status == noErr, out != kAudioObjectUnknown else { return nil }
        return out
    }

    static var defaultOutputDeviceUID: String? {
        let device = value(AudioObjectID(kAudioObjectSystemObject),
                           kAudioHardwarePropertyDefaultOutputDevice,
                           default: AudioDeviceID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}
