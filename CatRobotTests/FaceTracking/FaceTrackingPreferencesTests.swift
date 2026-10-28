import XCTest
@testable import CatRobot

@MainActor
final class FaceTrackingPreferencesTests: XCTestCase {
    func testNewPreferenceIsEnabledUntilExplicitlyDisabled() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RobotPreferences(defaults: defaults)
        XCTAssertTrue(preferences.trackingEnabled)
        preferences.trackingEnabled = false
        XCTAssertFalse(RobotPreferences(defaults: defaults).trackingEnabled)
        preferences.trackingEnabled = true
        XCTAssertTrue(RobotPreferences(defaults: defaults).trackingEnabled)
    }

    func testAimDefaultsToEightPointFiveAndPreservesSavedValuesIncludingZero() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RobotPreferences(defaults: defaults)
        XCTAssertEqual(preferences.trackingYawCorrection, 8.5)
        for value in [9.0, 8.5, 9.5, 0, 20] {
            preferences.trackingYawCorrection = value
            XCTAssertEqual(RobotPreferences(defaults: defaults).trackingYawCorrection, value)
        }
    }

    func testStoredAimNormalizesInvalidValuesAndHalfDegreeSteps() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cases: [(Any, Double)] = [(-2.0, 0), (25.0, 20), (10.24, 10), (10.26, 10.5),
                                     (Double.nan, 8.5), (Double.infinity, 8.5), ("invalid", 8.5)]
        for (stored, expected) in cases {
            defaults.set(stored, forKey: "robot.trackingYawCorrection")
            XCTAssertEqual(RobotPreferences(defaults: defaults).trackingYawCorrection, expected)
        }
    }

    func testAssignedAimIsNormalizedBeforePersistence() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = RobotPreferences(defaults: defaults)
        for (assigned, expected) in [(-99.0, 0.0), (99.0, 20.0), (10.24, 10.0), (10.26, 10.5),
                                     (Double.nan, 8.5), (Double.infinity, 8.5)] {
            preferences.trackingYawCorrection = assigned
            XCTAssertEqual(preferences.trackingYawCorrection, expected)
            XCTAssertEqual(defaults.double(forKey: "robot.trackingYawCorrection"), expected)
            XCTAssertEqual(RobotPreferences(defaults: defaults).trackingYawCorrection, expected)
        }
    }

    func testPreviouslySavedOffIsPreserved() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "robot.trackingEnabled")
        XCTAssertFalse(RobotPreferences(defaults: defaults).trackingEnabled)
    }
}
