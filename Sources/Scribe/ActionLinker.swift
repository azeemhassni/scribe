import Foundation

/// Ties each action item back to the moment in the recording where it was
/// agreed.
///
/// The model does not emit timestamps, and asking it to quote itself is
/// unreliable — it paraphrases. Instead the action's distinctive words are
/// matched against the transcript. Commitments are usually stated in a couple of
/// consecutive lines ("Priya, you own the customer email" / "it needs to go out
/// on the ninth"), so windows of up to three utterances are scored rather than
/// single lines.
enum ActionLinker {

    /// Words too common to identify anything.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "will", "you", "your",
        "our", "are", "was", "were", "have", "has", "had", "not", "but", "all",
        "can", "should", "would", "could", "need", "needs", "needed", "from",
        "into", "out", "get", "got", "make", "made", "take", "taken", "next",
        "before", "after", "then", "than", "them", "they", "she", "her", "him",
        "his", "its", "who", "whom", "what", "when", "where", "which", "about",
        "there", "here", "been", "being", "does", "did", "done", "also", "any",
        "one", "two", "per", "via", "let", "lets", "okay", "yes", "yeah", "sure",
    ]

    private static let maxWindow = 3
    /// Below this, a match is more likely coincidence than a real reference.
    private static let minimumScore = 0.34

    static func link(_ actions: [ActionItem], to utterances: [Utterance]) -> [ActionItem] {
        guard !utterances.isEmpty else { return actions }
        let utteranceTokens = utterances.map { tokens($0.text) }

        return actions.map { action in
            var linked = action
            linked.sourceStart = bestMatch(for: action,
                                           utterances: utterances,
                                           utteranceTokens: utteranceTokens)
            return linked
        }
    }

    private static func bestMatch(for action: ActionItem,
                                  utterances: [Utterance],
                                  utteranceTokens: [Set<String>]) -> TimeInterval? {
        // The owner's name is a strong signal ("Priya, you own…"), so include it.
        let needle = tokens(action.text).union(tokens(action.owner))
        guard needle.count >= 2 else { return nil }

        var bestScore = 0.0
        var bestLength = Int.max
        var bestStart: TimeInterval?

        for start in utterances.indices {
            var window: Set<String> = []
            for length in 0..<maxWindow {
                let index = start + length
                guard index < utterances.count else { break }
                window.formUnion(utteranceTokens[index])

                let score = Double(needle.intersection(window).count) / Double(needle.count)
                guard score > 0 else { continue }

                // Prefer a better match; on a tie prefer the tighter window. A
                // commitment stated in one line is a better answer than the same
                // words scattered across three, and without this the match drifts
                // to whatever filler happens to precede the real moment.
                let better = score > bestScore + 1e-9
                let tighterTie = abs(score - bestScore) < 1e-9 && (length + 1) < bestLength
                guard better || tighterTie else { continue }

                bestScore = score
                bestLength = length + 1
                // Point at the densest line in the window rather than the first
                // one carrying any match. A single incidental word — a date
                // mentioned earlier for an unrelated reason — otherwise drags
                // the listener to the wrong moment. Ties go to the earlier line,
                // where the subject is usually raised.
                bestStart = densestLine(in: start...index,
                                        needle: needle,
                                        utterances: utterances,
                                        utteranceTokens: utteranceTokens)
            }
        }

        return bestScore >= minimumScore ? bestStart : nil
    }

    /// The line inside a window that shares the most words with the action.
    private static func densestLine(in range: ClosedRange<Int>,
                                    needle: Set<String>,
                                    utterances: [Utterance],
                                    utteranceTokens: [Set<String>]) -> TimeInterval {
        var bestIndex = range.lowerBound
        var bestCount = 0
        for index in range {
            let count = needle.intersection(utteranceTokens[index]).count
            if count > bestCount {
                bestCount = count
                bestIndex = index
            }
        }
        return utterances[bestIndex].start
    }

    /// Urdu and Hindi function words. Short, and so common that they would
    /// otherwise connect any action to any line.
    private static let urduHindiStopwords: Set<String> = Set("""
        کے کی کا کو سے نے میں ہے ہیں تھا تھی تھے ہو ہوں گا گی گے اور یا بھی تو جو یہ وہ اس ان
        ایک پر تک کہ کر کرنا کریں کرے کرنی کرتے ہم آپ تم نہیں ہاں جی اب پھر لیے لئے ساتھ بات
        والا والی والے دیں دینا دے رہا رہی رہے ہوگا ہوگی سکتے سکتا چاہیے
        के की का को से ने में है हैं था थी थे हो और या भी तो जो यह वह इस उस एक पर तक कि कर करना
        हम आप तुम नहीं हां जी अब फिर लिए साथ बात वाला वाली वाले दें देना दे रहा रही रहे होगा सकते चाहिए
        """.split(whereSeparator: \.isWhitespace).map { normalise(String($0)) })

    private static func tokens(_ text: String) -> Set<String> {
        Set(normalise(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { token in
                // Two-letter words are noise in English ("to", "of") but carry
                // meaning in Urdu, where "bill" is بل.
                let longEnough = token.count >= 3 || (token.count == 2 && !token.allSatisfy(\.isASCII))
                return longEnough && !stopwords.contains(token) && !urduHindiStopwords.contains(token)
            })
    }

    /// Folds away differences that do not change a word: vowel marks, joiners,
    /// and the Arabic forms of letters Urdu writes differently. Whisper and a
    /// language model do not always pick the same codepoints for the same word.
    private static func normalise(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x06D6...0x06ED, 0x200C, 0x200D:
                continue                                    // harakat and joiners
            case 0x064A, 0x0649:
                scalars.append(Unicode.Scalar(0x06CC)!)     // Arabic yeh → Urdu yeh
            case 0x0643:
                scalars.append(Unicode.Scalar(0x06A9)!)     // Arabic kaf → Urdu kaf
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
