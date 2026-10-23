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

    func testPreviouslySavedOffIsPreserved() {
        let name = "FaceTrackingPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "robot.trackingEnabled")
        XCTAssertFalse(RobotPreferences(defaults: defaults).trackingEnabled)
    }
}
