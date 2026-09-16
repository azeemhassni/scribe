import AVFoundation
import Foundation

/// Combines the microphone and system streams into a single compressed file for
/// playback in the library.
///
/// Both inputs are wall-clock aligned by `AudioSegmentWriter`, so mixing is a
/// straight sample-wise sum — position in the mixed file equals position in the
/// transcript, which is what makes click-a-line-to-hear-it work.
enum AudioMixer {

    /// AAC at 32 kbit/s mono: about 14 MB for an eight-hour day of meetings,
    /// against ~1.8 GB for the raw 16 kHz WAVs.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    @discardableResult
    static func mix(_ inputs: [URL], to destination: URL) throws -> URL? {
        let files = inputs.compactMap { url -> AVAudioFile? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? AVAudioFile(forReading: url)
        }
        guard !files.isEmpty else { return nil }

        let output = try AVAudioFile(forWriting: destination, settings: outputSettings)
        let format = output.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)   // one second at a time
        let longest = files.map(\.length).max() ?? 0
        var position: AVAudioFramePosition = 0

        while position < longest {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk), longest - position))
            guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let target = mixed.floatChannelData else { break }
            mixed.frameLength = frames
            memset(target[0], 0, Int(frames) * MemoryLayout<Float>.size)

            for file in files where file.framePosition < file.length {
                guard let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: frames) else { continue }
                try file.read(into: scratch, frameCount: frames)
                guard let source = scratch.floatChannelData else { continue }
                for i in 0..<Int(scratch.frameLength) {
                    target[0][i] += source[0][i]
                }
            }

            // Two people rarely peak together, but clamp so a clash cannot wrap.
            for i in 0..<Int(frames) {
                target[0][i] = max(-1, min(1, target[0][i]))
            }

            try output.write(from: mixed)
            position += AVAudioFramePosition(frames)
        }
        return destination
    }
}
