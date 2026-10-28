import XCTest
@testable import CatRobot

final class ConversationUsageMeterTests: XCTestCase {
    private func suiteName() -> String {
        let name = "ConversationUsageMeterTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return name
    }

    func testTurnsResetAtDayBoundaryAndMonthBoundary() async {
        let name = suiteName()
        let defaults = UserDefaults(suiteName: name)!
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_767_311_999)) // 2026-01-01 23:59:59 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let meter = UserDefaultsUsageMeter(defaults: defaults, calendar: calendar, now: { clock.now })
        await meter.recordTurn(model: .opus5_5, promptCharacters: 20, responseCharacters: 40)
        await meter.recordTurn(model: .opus5_5, promptCharacters: 20, responseCharacters: 40)

        var summary = await meter.summary()
        XCTAssertEqual(summary.turnsToday, 2)
        XCTAssertEqual(summary.turnsThisMonth, 2)
        XCTAssertEqual(summary.estimatedTokensToday, 16_120)
        XCTAssertEqual(summary.estimatedTokensThisMonth, 16_120)
        XCTAssertEqual(summary.estimatedCostUSDThisMonth, 0.00496, accuracy: 0.000000001)

        clock.advance(by: 1) // 2026-01-02 00:00:00 UTC
        summary = await meter.summary()
        XCTAssertEqual(summary.turnsToday, 0)
        XCTAssertEqual(summary.turnsThisMonth, 2)
        XCTAssertEqual(summary.estimatedTokensToday, 0)
        XCTAssertEqual(summary.estimatedTokensThisMonth, 16_120)
        XCTAssertEqual(summary.estimatedCostUSDThisMonth, 0.00496, accuracy: 0.000000001)

        clock.advance(by: 86_400 * 30 - 1) // 2026-01-31 23:59:59 UTC
        await meter.recordTurn(model: .sonnet5_5, promptCharacters: 10, responseCharacters: 10)
        summary = await meter.summary()
        XCTAssertEqual(summary.turnsToday, 1)
        XCTAssertEqual(summary.turnsThisMonth, 3)
        XCTAssertEqual(summary.estimatedTokensToday, 8_020)
        XCTAssertEqual(summary.estimatedTokensThisMonth, 24_140)
        XCTAssertEqual(summary.estimatedCostUSDThisMonth, 0.00668, accuracy: 0.000000001)

        clock.advance(by: 1) // 2026-02-01 00:00:00 UTC
        summary = await meter.summary()
        XCTAssertEqual(summary, ConversationUsageSummary(turnsToday: 0, turnsThisMonth: 0, estimatedCostUSDThisMonth: 0))
        await meter.recordTurn(model: .haiku5_5, promptCharacters: 1, responseCharacters: 1)
        summary = await meter.summary()
        XCTAssertEqual(summary.turnsToday, 1)
        XCTAssertEqual(summary.turnsThisMonth, 1)
        XCTAssertEqual(summary.estimatedTokensToday, 8_002)
        XCTAssertEqual(summary.estimatedTokensThisMonth, 8_002)
        XCTAssertEqual(summary.estimatedCostUSDThisMonth, 0.0000806, accuracy: 0.000000001)
    }

    func testDailyLimitAndPersistenceAcrossInstances() async {
        let name = suiteName()
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(Data("not-json".utf8), forKey: "conversation.claude.usage")
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let meter = UserDefaultsUsageMeter(defaults: defaults, calendar: calendar, now: { now })
        let empty = await meter.summary()
        XCTAssertEqual(empty, ConversationUsageSummary(turnsToday: 0, turnsThisMonth: 0, estimatedCostUSDThisMonth: 0))

        for _ in 0..<3 {
            await meter.recordTurn(model: .opus5_5, promptCharacters: 1, responseCharacters: 1)
        }
        let reached = await meter.isDailyLimitReached(limit: 3)
        let exceeded = await meter.isDailyLimitReached(limit: 2)
        let belowLimit = await meter.isDailyLimitReached(limit: 4)
        XCTAssertTrue(reached)
        XCTAssertTrue(exceeded)
        XCTAssertFalse(belowLimit)

        let reloaded = UserDefaultsUsageMeter(defaults: UserDefaults(suiteName: name)!, calendar: calendar, now: { now })
        let summary = await reloaded.summary()
        XCTAssertEqual(summary.turnsToday, 3)
        XCTAssertEqual(summary.turnsThisMonth, 3)
        XCTAssertEqual(summary.estimatedTokensToday, 24_006)
        XCTAssertEqual(summary.estimatedTokensThisMonth, 24_006)
        XCTAssertEqual(summary.estimatedCostUSDThisMonth, 0.004872, accuracy: 0.000000001)
    }

    func testCostEstimateFollowsSpecTable() {
        // 固定部 8,000 トークンのキャッシュ読み取り + 入力 100 + 出力 80（単価は要件定義書 §8.6、固定部は短期記憶の上限 12,000 文字に合わせた想定）。
        let opus = UserDefaultsUsageMeter.estimatedCostUSD(model: .opus5_5, promptCharacters: 100, responseCharacters: 80)
        XCTAssertEqual(opus, 0.0036, accuracy: 0.0002)
        let sonnet = UserDefaultsUsageMeter.estimatedCostUSD(model: .sonnet5_5, promptCharacters: 100, responseCharacters: 80)
        XCTAssertEqual(sonnet, 0.0026, accuracy: 0.000000001)
        let haiku = UserDefaultsUsageMeter.estimatedCostUSD(model: .haiku5_5, promptCharacters: 100, responseCharacters: 80)
        XCTAssertEqual(haiku, 0.00013, accuracy: 0.000000001)
        XCTAssertLessThan(haiku, opus / 10)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
