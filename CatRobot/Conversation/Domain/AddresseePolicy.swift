import CoreFoundation
import Foundation

enum AddresseeRoute: Equatable, Sendable {
    case wakeOnly
    case accept(String)
    case ignore
}

struct AddresseePolicy: Sendable {
    static let defaultWakePhrase = "猫ちゃん"
    private static let fillerTokens: Set<String> = ["あ", "あの", "え", "えー", "えっと", "うーん", "ん", "んー"]
    private static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    func route(_ utterance: String, at timestamp: TimeInterval, engagement: EngagementWindow,
               wakePhrase: String, isFacingScreen: Bool = false) -> AddresseeRoute {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.trimmingCharacters(in: Self.separators)
        guard !token.isEmpty else { return .ignore }

        let phrase = Self.words(in: wakePhrase).joined()
        let words = Self.words(in: trimmed)
        for start in words.indices where phrase.hasPrefix(words[start]) {
            var candidate = ""
            for index in start..<words.endIndex {
                candidate += words[index]
                guard phrase.hasPrefix(candidate) else { break }
                if candidate == phrase {
                    return start == 0 && index == words.count - 1 ? .wakeOnly : .accept(trimmed)
                }
            }
        }

        guard !Self.fillerTokens.contains(token) else { return .ignore }
        return isFacingScreen || engagement.isActive(at: timestamp) ? .accept(trimmed) : .ignore
    }

    // Compare spoken readings at word boundaries. ASR can write the same name as 猫ちゃん or ねこちゃん.
    static func words(in text: String) -> [String] {
        let locale = Locale(identifier: "ja_JP")
        let normalized = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: locale)
        let tokenizer = CFStringTokenizerCreate(nil, normalized as CFString, CFRange(location: 0, length: normalized.utf16.count),
                                                kCFStringTokenizerUnitWord, locale as CFLocale)
        var words: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (normalized as NSString).substring(with: NSRange(location: range.location, length: range.length))
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
            words.append(reading as? String ?? token)
        }
        return words
    }
}
