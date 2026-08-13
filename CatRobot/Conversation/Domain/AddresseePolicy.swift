import Foundation

enum AddresseeRoute: Equatable, Sendable {
    case wakeOnly
    case accept(String)
    case classify(String)
    case confirmPending(original: String)
    case dismissPending
    case ignore
}

struct PendingClarification: Equatable, Sendable {
    static let duration: TimeInterval = 15

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
    private static let conversationalStarters = [
        "今日", "今", "明日", "どう", "何", "なに", "いつ", "どこ", "誰", "だれ",
        "なぜ", "なんで", "元気", "教えて", "聞いて", "お願い", "おはよう", "こんにちは", "こんばんは"
    ]
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
            return content.isEmpty ? .wakeOnly : .accept(content)
        }

        if let pending, timestamp < pending.expiresAt {
            if Self.affirmativeTokens.contains(token) {
                return .accept(pending.utterance)
            }
            if Self.negativeTokens.contains(token) {
                return .dismissPending
            }
            return .classify(utterance)
        }

        if engagement.isActive(at: timestamp) {
            return .accept(trimmed)
        }

        return .classify(utterance)
    }

    private func contentAfterWakeName(in utterance: String) -> String? {
        for wakeName in Self.wakeNames {
            guard let range = utterance.range(
                of: wakeName,
                options: [.anchored, .caseInsensitive]
            ) else {
                continue
            }

            let remainder = utterance[range.upperBound...]
            guard let first = remainder.first else {
                return ""
            }

            if first.unicodeScalars.allSatisfy(Self.separators.contains) {
                let content = remainder.drop { character in
                    character.unicodeScalars.allSatisfy(Self.separators.contains)
                }
                return String(content)
            }

            let content = String(remainder)
            guard Self.conversationalStarters.contains(where: { content.hasPrefix($0) }) else {
                continue
            }
            return content
        }

        return nil
    }
}
