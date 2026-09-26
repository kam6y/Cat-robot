import Foundation
import XCTest
@testable import CatRobot

final class FoundationModelAvailabilityServiceTests: XCTestCase {
    func testMapsEveryFrameworkAvailabilityReason() async {
        let cases: [(FoundationModelAvailabilitySnapshot, ModelAvailability)] = [
            (.init(availability: .available, supportsLocale: true), .available),
            (.init(availability: .available, supportsLocale: false), .unsupportedLocale),
            (.init(availability: .deviceNotEligible, supportsLocale: true), .deviceNotEligible),
            (.init(availability: .appleIntelligenceNotEnabled, supportsLocale: true), .appleIntelligenceNotEnabled),
            (.init(availability: .modelNotReady, supportsLocale: true), .modelNotReady),
        ]

        for (snapshot, expected) in cases {
            let service = FoundationModelAvailabilityService { snapshot }

            let actual = await service.availability()

            XCTAssertEqual(actual, expected)
        }
    }
}
