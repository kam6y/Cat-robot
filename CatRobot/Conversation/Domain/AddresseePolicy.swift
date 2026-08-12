import Foundation

enum AddresseeRoute: Equatable, Sendable {
    case accept(String)
    case classify(String)
    case confirmPending(original: String)
    case ignore
}

struct PendingClarification: Equatable, Sendable {
    private static let duration: TimeInterval = 15

    let utterance: String
    let expiresAt: TimeInterval

    init(utterance: String, expiresAt: TimeInterval) {
        self.utterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expiresAt = expiresAt
    }

    init(utterance: String, at timestamp: TimeInterval) {
        self.init(utterance: utterance, expiresAt: timestamp + Self.duration)
    }
}

struct AddresseePolicy: Sendable {
    private static let wakeNames = ["ねこ", "猫ちゃん", "Cat Robot", "キャットロボット"]
    private static let fillerTokens: Set<String> = ["あ", "あの", "え", "えー", "えっと", "うーん", "ん", "んー"]
    private static let affirmativeTokens: Set<String> = ["うん", "はい", "ええ", "そう", "そうだよ", "そうです"]
    private static let negativeTokens: Set<String> = ["ううん", "いいえ", "いや", "違う", "ちがう", "違います", "そうじゃない"]
    private static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    func route(
        _ utterance: String,
        at timestamp: TimeInterval,
        engagement: EngagementWindow,
        pending: PendingClarification?
    ) -> AddresseeRoute {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.trimmingCharacters(in: Self.separators)
        guard !token.isEmpty, !Self.fillerTokens.contains(token) else { return .ignore }

        if let content = contentAfterWakeName(in: trimmed) {
            return content.isEmpty ? .ignore : .accept(content)
        }

        if let pending, timestamp < pending.expiresAt {
            if Self.affirmativeTokens.contains(token) {
                return .accept(pending.utterance)
            }
            if Self.negativeTokens.contains(token) {
                return .ignore
            }
            return .confirmPending(original: pending.utterance)
        }

        if engagement.isActive(at: timestamp) {
            return .accept(trimmed)
        }

        return .classify(trimmed)
    }

    private func contentAfterWakeName(in utterance: String) -> String? {
        for wakeName in Self.wakeNames {
            guard let range = utterance.range(
                of: wakeName,
                options: [.anchored, .caseInsensitive]
            ) else {
                continue
            }

            if range.upperBound < utterance.endIndex,
               !utterance[range.upperBound].unicodeScalars.allSatisfy(Self.separators.contains) {
                continue
            }

            let remainder = utterance[range.upperBound...]
            let content = remainder.drop { character in
                character.unicodeScalars.allSatisfy(Self.separators.contains)
            }
            return String(content)
        }

        return nil
    }
}
