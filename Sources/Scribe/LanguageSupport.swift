import Foundation
import SwiftUI

/// Hindi and Urdu are, spoken, largely the same language. Whisper cannot tell
/// them apart by ear and leans towards Hindi, so an Urdu speaker gets their
/// meeting back in Devanagari. This decides which script that shared speech is
/// written in.
enum HindustaniScript: String, CaseIterable, Identifiable {
    case urdu
    case hindi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .urdu: return "Urdu (اردو)"
        case .hindi: return "Hindi (हिन्दी)"
        }
    }

    var whisperCode: String {
        switch self {
        case .urdu: return "ur"
        case .hindi: return "hi"
        }
    }

    /// Taken from the Mac's own language and region settings, so a Pakistani
    /// setup gets Urdu without being asked.
    static var systemDefault: HindustaniScript {
        let languages = Locale.preferredLanguages.map { $0.lowercased() }
        if let urdu = languages.firstIndex(where: { $0.hasPrefix("ur") }) {
            let hindi = languages.firstIndex(where: { $0.hasPrefix("hi") })
            if hindi == nil || urdu < hindi! { return .urdu }
        }
        if languages.contains(where: { $0.hasPrefix("hi") }) { return .hindi }
        switch Locale.current.region?.identifier {
        case "PK": return .urdu
        default: return .hindi   // Whisper's own preference
        }
    }
}

enum Language {

    /// English name for a Whisper language code, for use in prompts.
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// The language most of the meeting was spoken in, weighted by how much
    /// was said — letters, not seconds. Whisper can stamp a long stretch of
    /// silence or noise with a two-character "line", and weighting by time let
    /// that outvote the actual discussion.
    static func dominant(in utterances: [Utterance]) -> String? {
        var weight: [String: Int] = [:]
        for utterance in utterances {
            guard let code = utterance.language else { continue }
            weight[code, default: 0] += utterance.text.unicodeScalars.filter(CharacterSet.letters.contains).count
        }
        return weight.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    /// Whether a piece of text should be laid out right to left. Decided by the
    /// text rather than the meeting's language, because Urdu meetings are full of
    /// English lines and the other way round.
    static func isRightToLeft(_ text: String) -> Bool {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                rtl += 1
            default:
                if CharacterSet.letters.contains(scalar) { ltr += 1 }
            }
        }
        return rtl > ltr
    }
}

extension View {
    /// Lays out right-to-left text from the right, so Urdu reads as it should
    /// inside an otherwise left-to-right window.
    @ViewBuilder
    func naturalDirection(for text: String) -> some View {
        if Language.isRightToLeft(text) {
            self.frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            self
        }
    }
}
