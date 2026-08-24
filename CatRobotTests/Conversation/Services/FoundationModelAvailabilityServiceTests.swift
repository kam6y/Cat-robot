import Foundation
import XCTest
@testable import CatRobot

private final class AvailabilityPurposeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: FoundationModelAvailabilityPurpose?

    var value: FoundationModelAvailabilityPurpose? {
        lock.withLock { storedValue }
    }

    func record(_ value: FoundationModelAvailabilityPurpose) {
        lock.withLock { storedValue = value }
    }
}

final class FoundationModelAvailabilityServiceTests: XCTestCase {
    func testDefaultAvailabilityPurposeIsContentTagging() async {
        let recorder = AvailabilityPurposeRecorder()
        let service = FoundationModelAvailabilityService(
            locale: Locale(identifier: "ja-JP"),
            snapshotForPurpose: { purpose in
                recorder.record(purpose)
                return .init(availability: .available, supportsLocale: true)
            }
        )

        _ = await service.availability()

        XCTAssertEqual(recorder.value, .contentTagging)
    }

    func testMapsEveryFrameworkAvailabilityReason() async {
        let locale = Locale(identifier: "ja-JP")
        let cases: [(FoundationModelAvailabilitySnapshot, ModelAvailability)] = [
            (.init(availability: .available, supportsLocale: true), .available),
            (.init(availability: .available, supportsLocale: false), .unsupportedLocale),
            (.init(availability: .deviceNotEligible, supportsLocale: true), .deviceNotEligible),
            (.init(availability: .appleIntelligenceNotEnabled, supportsLocale: true), .appleIntelligenceNotEnabled),
            (.init(availability: .modelNotReady, supportsLocale: true), .modelNotReady),
        ]

        for (snapshot, expected) in cases {
            let service = FoundationModelAvailabilityService(locale: locale) { _ in snapshot }

            let actual = await service.availability()

            XCTAssertEqual(actual, expected)
        }
    }
}
