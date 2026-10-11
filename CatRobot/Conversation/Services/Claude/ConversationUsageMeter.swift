import Foundation

struct ConversationUsageSummary: Equatable, Sendable {
    var turnsToday: Int
    var turnsThisMonth: Int
    var estimatedCostUSDThisMonth: Double
    /// 概算トークン数（要件 §6.9）。1 文字 1 トークン換算に、指示文のキャッシュ読み取り分を足す。
    var estimatedTokensToday: Int = 0
    var estimatedTokensThisMonth: Int = 0
}

protocol ConversationUsageMetering: Sendable {
    func recordTurn(model: ConversationModelChoice, promptCharacters: Int, responseCharacters: Int) async
    func isDailyLimitReached(limit: Int) async -> Bool
    func summary() async -> ConversationUsageSummary
}

actor UserDefaultsUsageMeter: ConversationUsageMetering {
    private struct Record: Codable, Equatable {
        var day: String
        var month: String
        var turnsToday: Int
        var turnsThisMonth: Int
        var tokensToday: Int
        var tokensThisMonth: Int
        var costThisMonth: Double
    }

    private static let key = "conversation.claude.usage"
    /// 100 万トークンあたりの USD（入力、出力、キャッシュ読み取り）。要件定義書 §8.6（2026-10-06 時点）。
    private static let prices: [ConversationModelChoice: (input: Double, output: Double, cached: Double)] = [
        .opus5_5: (4, 20, 0.20),
        .sonnet5_5: (2, 10, 0.20),
        .haiku5_5: (0.10, 0.50, 0.01)
    ]
    /// 毎ターンのキャッシュ読み取り分の想定。固定部（人格・ツール・覚えていること）約 2,000 と短期記憶上限（12,000 文字）の平均の和。
    private static let cachedPrefixTokens = 8_000.0
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    static func estimatedCostUSD(model: ConversationModelChoice, promptCharacters: Int, responseCharacters: Int) -> Double {
        let price = prices[model]!
        // 日本語はおおむね 1 文字 1 トークンとして安全側に見積もる。
        let perMillion = 1_000_000.0
        return cachedPrefixTokens / perMillion * price.cached
            + Double(promptCharacters) / perMillion * price.input
            + Double(responseCharacters) / perMillion * price.output
    }

    func recordTurn(model: ConversationModelChoice, promptCharacters: Int, responseCharacters: Int) {
        var record = current()
        record.turnsToday += 1
        record.turnsThisMonth += 1
        let tokens = Int(Self.cachedPrefixTokens) + promptCharacters + responseCharacters
        record.tokensToday += tokens
        record.tokensThisMonth += tokens
        record.costThisMonth += Self.estimatedCostUSD(model: model, promptCharacters: promptCharacters, responseCharacters: responseCharacters)
        store(record)
    }

    func isDailyLimitReached(limit: Int) -> Bool { current().turnsToday >= limit }

    func summary() -> ConversationUsageSummary {
        let record = current()
        return ConversationUsageSummary(
            turnsToday: record.turnsToday,
            turnsThisMonth: record.turnsThisMonth,
            estimatedCostUSDThisMonth: record.costThisMonth,
            estimatedTokensToday: record.tokensToday,
            estimatedTokensThisMonth: record.tokensThisMonth
        )
    }

    private func current() -> Record {
        let date = now()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = "\(parts.year!)-\(parts.month!)-\(parts.day!)"
        let month = "\(parts.year!)-\(parts.month!)"
        var record = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
            ?? Record(day: day, month: month, turnsToday: 0, turnsThisMonth: 0, tokensToday: 0, tokensThisMonth: 0, costThisMonth: 0)
        if record.month != month {
            record = Record(day: day, month: month, turnsToday: 0, turnsThisMonth: 0, tokensToday: 0, tokensThisMonth: 0, costThisMonth: 0)
        }
        if record.day != day {
            record.day = day
            record.turnsToday = 0
            record.tokensToday = 0
        }
        return record
    }

    private func store(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
