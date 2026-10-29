import AVFoundation
import Foundation

/// `Scribe --check-resampler` — pushes a known tone through `Resampler` in each
/// channel layout a Mac microphone can present, and reports what comes out.
enum ResamplerProbe {

    static func run() -> Never {
        print("Resampler check — a 440 Hz tone in, 16 kHz mono out\n")
        var failures = 0

        for candidate in formats() {
            let (label, format) = candidate
            if true {
                guard let resampler = Resampler(from: format) else {
                    print("  ❌ \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) Resampler refused this format")
                    failures += 1
                    continue
                }
                guard let input = tone(format: format, seconds: 0.5) else { continue }
                guard let output = resampler.convert(input) else {
                    print("  ❌ \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) convert() returned nil")
                    failures += 1
                    continue
                }

                var peak: Float = 0
                if let samples = output.int16ChannelData {
                    for i in 0..<Int(output.frameLength) {
                        peak = max(peak, abs(Float(samples[0][i]) / 32768))
                    }
                }
                let ok = peak > 0.05
                if !ok { failures += 1 }
                print("  \(ok ? "✅" : "❌") \(label.padding(toLength: 28, withPad: " ", startingAt: 0))"
                      + " \(output.frameLength) frames, peak \(String(format: "%.3f", peak))")
            }
        }

        print("\n\(failures == 0 ? "All layouts convert. \(CLIStatus.successMarker)" : "\(failures) layout(s) produce no audio.")")
        exit(failures == 0 ? 0 : 1)
    }

    /// Every layout a Mac microphone realistically hands us, including the
    /// multi-channel arrays the convenience initialiser cannot express.
    private static func formats() -> [(String, AVAudioFormat)] {
        var out: [(String, AVAudioFormat)] = []

        for channels in [AVAudioChannelCount(1), 2] {
            for interleaved in [false, true] {
                if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 48_000,
                                              channels: channels,
                                              interleaved: interleaved) {
                    out.append(("\(channels) ch \(interleaved ? "interleaved" : "planar")", format))
                }
            }
        }

        // What a built-in mic array actually reports.
        let tags: [(String, AudioChannelLayoutTag)] = [
            ("3 ch discrete", kAudioChannelLayoutTag_DiscreteInOrder | 3),
            ("3 ch standard 3.0", kAudioChannelLayoutTag_MPEG_3_0_A),
            ("4 ch discrete", kAudioChannelLayoutTag_DiscreteInOrder | 4),
        ]
        for (name, tag) in tags {
            guard let layout = AVAudioChannelLayout(layoutTag: tag) else { continue }
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
            out.append((name, format))
        }
        return out
    }

    private static func tone(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let channels = Int(format.channelCount)

        for frame in 0..<Int(frames) {
            let value = 0.5 * sinf(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
            if format.isInterleaved {
                guard let data = buffer.floatChannelData?[0] else { return nil }
                for channel in 0..<channels { data[frame * channels + channel] = value }
            } else {
                guard let data = buffer.floatChannelData else { return nil }
                for channel in 0..<channels { data[channel][frame] = value }
            }
        }
        return buffer
    }
}
