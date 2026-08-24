import Foundation
import XCTest
@testable import CatRobot

private final class SequencedCurrentDateTimeProvider: CurrentDateTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CurrentDateTimeSnapshot]
    private var storedReadCount = 0

    init(_ snapshots: [CurrentDateTimeSnapshot]) {
        self.snapshots = snapshots
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot {
        lock.withLock {
            storedReadCount += 1
            return snapshots.removeFirst()
        }
    }
}

private final class SequencedLiveCurrentDateTimeInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var timeZones: [TimeZone]
    private var storedNowReadCount = 0
    private var storedTimeZoneReadCount = 0

    init(dates: [Date], timeZones: [TimeZone]) {
        self.dates = dates
        self.timeZones = timeZones
    }

    var nowReadCount: Int {
        lock.withLock { storedNowReadCount }
    }

    var timeZoneReadCount: Int {
        lock.withLock { storedTimeZoneReadCount }
    }

    func nextDate() -> Date {
        lock.withLock {
            storedNowReadCount += 1
            return dates.removeFirst()
        }
    }

    func nextTimeZone() -> TimeZone {
        lock.withLock {
            storedTimeZoneReadCount += 1
            return timeZones.removeFirst()
        }
    }
}

final class CurrentDateTimeToolTests: XCTestCase {
    func testToolReturnsExactSortedJSONWithTheSpecifiedIdentity() async throws {
        let snapshot = tokyoSnapshot(second: 56)
        let provider = SequencedCurrentDateTimeProvider([snapshot])
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 1)
        let tool = CurrentDateTimeTool(provider: provider, budget: budget)

        let output = try await tool.call(arguments: .init(includeSeconds: true))

        XCTAssertEqual(tool.name, "getCurrentDateTime")
        XCTAssertEqual(
            tool.description,
            "Read the device's current local date, time, ISO weekday, time zone, and UTC offset. Use only when current time context is needed."
        )
        XCTAssertEqual(
            output,
            #"{"iso8601":"2026-08-24T12:34:56+09:00","isoWeekday":1,"localDate":"2026-08-24","localTime":"12:34:56","timeZoneIdentifier":"Asia\/Tokyo","utcOffsetSeconds":32400}"#
        )
        XCTAssertEqual(
            try JSONDecoder().decode(CurrentDateTimeSnapshot.self, from: Data(output.utf8)),
            snapshot
        )
    }

    func testRepeatedToolCallsReadFreshSnapshots() async throws {
        let firstSnapshot = tokyoSnapshot(second: 56)
        let secondSnapshot = tokyoSnapshot(second: 57)
        let provider = SequencedCurrentDateTimeProvider([firstSnapshot, secondSnapshot])
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 2)
        let tool = CurrentDateTimeTool(provider: provider, budget: budget)

        let first = try await tool.call(arguments: .init(includeSeconds: true))
        let second = try await tool.call(arguments: .init(includeSeconds: true))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(provider.readCount, 2)
    }

    func testLiveProviderReadsEachInjectedInputAgainForEverySnapshot() {
        let inputs = SequencedLiveCurrentDateTimeInputs(
            dates: [
                Date(timeIntervalSince1970: 1_787_542_496),
                Date(timeIntervalSince1970: 1_772_955_000),
            ],
            timeZones: [
                TimeZone(identifier: "Asia/Tokyo")!,
                TimeZone(identifier: "America/New_York")!,
            ]
        )
        let provider = LiveCurrentDateTimeProvider(
            now: { inputs.nextDate() },
            timeZone: { inputs.nextTimeZone() }
        )

        let first = provider.snapshot(includeSeconds: true)

        XCTAssertEqual(first, tokyoSnapshot(second: 56))
        XCTAssertEqual(inputs.nowReadCount, 1)
        XCTAssertEqual(inputs.timeZoneReadCount, 1)

        let second = provider.snapshot(includeSeconds: true)

        XCTAssertEqual(
            second,
            CurrentDateTimeSnapshot(
                iso8601: "2026-03-08T03:30:00-04:00",
                localDate: "2026-03-08",
                localTime: "03:30:00",
                isoWeekday: 7,
                timeZoneIdentifier: "America/New_York",
                utcOffsetSeconds: -14_400
            )
        )
        XCTAssertEqual(inputs.nowReadCount, 2)
        XCTAssertEqual(inputs.timeZoneReadCount, 2)
    }

    func testToolConsumesCallsAlreadyReservedByAnotherConsumer() async throws {
        let provider = SequencedCurrentDateTimeProvider([tokyoSnapshot(second: 56)])
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 8)
        for _ in 0..<11 {
            try await budget.consumeCall()
        }
        let tool = CurrentDateTimeTool(provider: provider, budget: budget)

        _ = try await tool.call(arguments: .init(includeSeconds: true))
        do {
            _ = try await tool.call(arguments: .init(includeSeconds: true))
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }

        XCTAssertEqual(provider.readCount, 1)
    }

    func testThirteenthToolCallDoesNotReadTheProvider() async throws {
        let provider = SequencedCurrentDateTimeProvider(
            Array(repeating: tokyoSnapshot(second: 56), count: 12)
        )
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 3)
        let tool = CurrentDateTimeTool(provider: provider, budget: budget)

        for _ in 0..<12 {
            _ = try await tool.call(arguments: .init(includeSeconds: true))
        }

        do {
            _ = try await tool.call(arguments: .init(includeSeconds: true))
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }
        XCTAssertEqual(provider.readCount, 12)
    }

    func testLiveProviderFormatsBothSecondsBranchesAndMapsMonday() {
        let provider = LiveCurrentDateTimeProvider(
            now: { Date(timeIntervalSince1970: 1_787_542_496) },
            timeZone: { TimeZone(identifier: "Asia/Tokyo")! }
        )

        XCTAssertEqual(
            provider.snapshot(includeSeconds: true),
            tokyoSnapshot(second: 56)
        )
        XCTAssertEqual(
            provider.snapshot(includeSeconds: false),
            CurrentDateTimeSnapshot(
                iso8601: "2026-08-24T12:34+09:00",
                localDate: "2026-08-24",
                localTime: "12:34",
                isoWeekday: 1,
                timeZoneIdentifier: "Asia/Tokyo",
                utcOffsetSeconds: 32_400
            )
        )
    }

    func testLiveProviderUsesCalendarYearSundayAndDateSpecificDSTOffset() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let weekYearBoundaryProvider = LiveCurrentDateTimeProvider(
            now: { Date(timeIntervalSince1970: 1_546_214_400) },
            timeZone: { utc }
        )
        let sundayProvider = LiveCurrentDateTimeProvider(
            now: { Date(timeIntervalSince1970: 1_787_456_096) },
            timeZone: { TimeZone(identifier: "Asia/Tokyo")! }
        )
        let daylightSavingProvider = LiveCurrentDateTimeProvider(
            now: { Date(timeIntervalSince1970: 1_772_955_000) },
            timeZone: { TimeZone(identifier: "America/New_York")! }
        )

        XCTAssertEqual(weekYearBoundaryProvider.snapshot(includeSeconds: false).localDate, "2018-12-31")
        XCTAssertEqual(sundayProvider.snapshot(includeSeconds: true).isoWeekday, 7)
        XCTAssertEqual(
            daylightSavingProvider.snapshot(includeSeconds: true),
            CurrentDateTimeSnapshot(
                iso8601: "2026-03-08T03:30:00-04:00",
                localDate: "2026-03-08",
                localTime: "03:30:00",
                isoWeekday: 7,
                timeZoneIdentifier: "America/New_York",
                utcOffsetSeconds: -14_400
            )
        )
    }

    private func tokyoSnapshot(second: Int) -> CurrentDateTimeSnapshot {
        CurrentDateTimeSnapshot(
            iso8601: "2026-08-24T12:34:\(String(format: "%02d", second))+09:00",
            localDate: "2026-08-24",
            localTime: "12:34:\(String(format: "%02d", second))",
            isoWeekday: 1,
            timeZoneIdentifier: "Asia/Tokyo",
            utcOffsetSeconds: 32_400
        )
    }
}
