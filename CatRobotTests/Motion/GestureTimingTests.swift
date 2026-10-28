import XCTest
@testable import CatRobot

final class GestureTimingTests: XCTestCase {
    func testFirmwareGoldenCycleTimesAtStandardNeutral() {
        for (gesture, seconds) in [(RobotGesture.nod, 1.52), (.shake, 2.08), (.tilt, 2.48), (.lookUp, 4.06), (.lookDown, 4.06)] {
            let request = RobotMotionRequest(gesture: gesture, intensity: .large, repeats: 3)
            XCTAssertEqual(GestureTiming.estimate(request: request, limits: standardRobotLimits, current: robotStatus()), seconds, accuracy: 0.020_001)
        }
    }

    func testAnchoredGestureOmitsUnneededTripToNeutralButCenterStillMoves() {
        let current = robotStatus(yaw: -340, pitch: 60)
        let anchor = FacePose(yaw: -34, pitch: 6)
        let nod = RobotMotionRequest(gesture: .nod, intensity: .large, repeats: 1)
        XCTAssertEqual(GestureTiming.estimate(request: nod, limits: standardRobotLimits, current: current, anchor: anchor), 1.52, accuracy: 0.020_001)
        let center = RobotMotionRequest(gesture: .center, intensity: .large, repeats: 1)
        XCTAssertEqual(GestureTiming.estimate(request: center, limits: standardRobotLimits, current: current, anchor: anchor),
                       GestureTiming.estimate(request: center, limits: standardRobotLimits, current: current))
    }

    func testVelocityStretchAndCenteringAreIncludedWithoutMultiplyingRepeats() {
        let request = RobotMotionRequest(gesture: .nod, intensity: .large, repeats: 1)
        let slow = RobotLimits(yawVelocityDeci: 600, pitchVelocityDeci: 500, yawAngleDeci: 600, pitchAngleDeci: 300)
        let neutral = GestureTiming.estimate(request: request, limits: standardRobotLimits, current: robotStatus())
        XCTAssertGreaterThan(GestureTiming.estimate(request: request, limits: slow, current: robotStatus()), neutral)
        XCTAssertGreaterThan(GestureTiming.estimate(request: request, limits: standardRobotLimits, current: robotStatus(yaw: 450, pitch: -200)), neutral)
        let repeats = RobotMotionRequest(gesture: .nod, intensity: .large, repeats: 3)
        XCTAssertEqual(GestureTiming.estimate(request: repeats, limits: standardRobotLimits, current: robotStatus()), neutral)
    }
}
