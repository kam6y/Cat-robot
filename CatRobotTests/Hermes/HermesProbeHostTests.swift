import XCTest
@testable import CatRobot

@MainActor
final class HermesProbeHostTests: XCTestCase {
    func testHermesProbeCreatesNoLiveCompositionWithoutASpeechFlag() {
        let app = CatRobotApp(environment: ["HERMES_PROBE": "1"])
        XCTAssertTrue(app.composition == nil, "probe must not create the live composition")
        XCTAssertTrue(app.isHermesProbe)
    }

    func testHermesProbeStillSelectsItsHostWhenBothDiagnosticFlagsAreSet() {
        let app = CatRobotApp(environment: ["HERMES_PROBE": "1", "SUPER_INTEGRATION_TESTS": "1"])
        XCTAssertTrue(app.composition == nil)
        XCTAssertTrue(app.isHermesProbe)
    }

    func testExistingSpeechHostIsPreservedAndOnlyTheExactHermesFlagSelectsTheProbe() {
        for value in ["", "0", "true"] {
            let app = CatRobotApp(environment: ["SUPER_INTEGRATION_TESTS": "1", "HERMES_PROBE": value])
            XCTAssertTrue(app.composition == nil)
            XCTAssertFalse(app.isHermesProbe)
        }
    }
}
