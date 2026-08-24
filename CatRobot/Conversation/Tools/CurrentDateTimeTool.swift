import Foundation
import FoundationModels

struct CurrentDateTimeSnapshot: Codable, Equatable, Sendable {
    let iso8601: String
    let localDate: String
    let localTime: String
    let isoWeekday: Int
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
}

protocol CurrentDateTimeProviding: Sendable {
    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot
}

struct LiveCurrentDateTimeProvider: CurrentDateTimeProviding {
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    init(
        now: @escaping @Sendable () -> Date = { .now },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.now = now
        self.timeZone = timeZone
    }

    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot {
        let currentDate = now()
        let currentTimeZone = timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = currentTimeZone

        let iso8601Formatter = makeFormatter(
            dateFormat: includeSeconds ? "yyyy-MM-dd'T'HH:mm:ssxxxxx" : "yyyy-MM-dd'T'HH:mmxxxxx",
            calendar: calendar,
            timeZone: currentTimeZone
        )
        let localDateFormatter = makeFormatter(
            dateFormat: "yyyy-MM-dd",
            calendar: calendar,
            timeZone: currentTimeZone
        )
        let localTimeFormatter = makeFormatter(
            dateFormat: includeSeconds ? "HH:mm:ss" : "HH:mm",
            calendar: calendar,
            timeZone: currentTimeZone
        )
        let weekday = calendar.component(.weekday, from: currentDate)

        return CurrentDateTimeSnapshot(
            iso8601: iso8601Formatter.string(from: currentDate),
            localDate: localDateFormatter.string(from: currentDate),
            localTime: localTimeFormatter.string(from: currentDate),
            isoWeekday: weekday == 1 ? 7 : weekday - 1,
            timeZoneIdentifier: currentTimeZone.identifier,
            utcOffsetSeconds: currentTimeZone.secondsFromGMT(for: currentDate)
        )
    }

    private func makeFormatter(
        dateFormat: String,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }
}

@Generable
struct CurrentDateTimeArguments {
    var includeSeconds: Bool
}

struct CurrentDateTimeTool: Tool {
    let name = "getCurrentDateTime"
    let description = "Read the device's current local date, time, ISO weekday, time zone, and UTC offset. Use only when current time context is needed."

    private let provider: any CurrentDateTimeProviding
    private let budget: ReplyToolCallBudget

    init(provider: any CurrentDateTimeProviding = LiveCurrentDateTimeProvider(), budget: ReplyToolCallBudget) {
        self.provider = provider
        self.budget = budget
    }

    func call(arguments: CurrentDateTimeArguments) async throws -> String {
        try await budget.consumeCall()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(provider.snapshot(includeSeconds: arguments.includeSeconds))
        return String(decoding: data, as: UTF8.self)
    }
}
