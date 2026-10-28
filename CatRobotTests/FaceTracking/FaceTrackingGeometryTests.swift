import XCTest
@testable import CatRobot

final class FaceTrackingGeometryTests: XCTestCase {
    func testFixedLeftCameraAimIsCorrectedBeforeDeadband() throws {
        // A 9-degree camera ray (tan(9deg)/2 from image center with 90deg FOV)
        // corresponds to a person straight in front of the screen at the chosen fixed correction.
        let pose = FacePose(yaw: -20, pitch: 3)
        XCTAssertEqual(FaceTrackingGeometry.project(observation(x: 0.4208077798), yawCorrection: 9, pose: pose), pose)
        let centered = try XCTUnwrap(FaceTrackingGeometry.project(observation(), yawCorrection: 9, pose: pose))
        XCTAssertEqual(centered, FacePose(yaw: -29, pitch: 3))
    }

    func testCameraCenterIncludesFixedScreenAimCorrection() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(observation(), yawCorrection: 9, pose: .init(yaw: 30, pitch: -3)))
        XCTAssertEqual(result, FacePose(yaw: 21, pitch: -3))
    }

    func testFixedLeftCameraMapsUprightImageToObserverLeftAndUp() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.75, y: 0.55), yawCorrection: 9, pose: .init(yaw: 0, pitch: 0)))
        XCTAssertEqual(result.yaw, -35.565051, accuracy: 0.000_001)
        XCTAssertEqual(result.pitch, 4.289153, accuracy: 0.000_001)
    }

    func testProjectionAddsPoseInsteadOfRecenteringNeck() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(observation(x: 0.25), yawCorrection: 9, pose: .init(yaw: -30, pitch: 0)))
        XCTAssertEqual(result.yaw, -12.434949, accuracy: 0.000_001)
    }

    func testDeadbandIsAppliedIndependentlyPerAxis() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.4208077798, y: 0.55), yawCorrection: 9, pose: .init(yaw: 30, pitch: -2)))
        XCTAssertEqual(result.yaw, 30)
        XCTAssertEqual(result.pitch, 2.289153, accuracy: 0.000_001)
    }

    func testProjectionClampsBothAxesToTrackingLimits() throws {
        let positive = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.1, y: 0.75), yawCorrection: 9, pose: .init(yaw: 30, pitch: 0)))
        XCTAssertEqual(positive.yaw, 45)
        XCTAssertEqual(positive.pitch, 10)
        let negative = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.9, y: 0.25), yawCorrection: 9, pose: .init(yaw: -30, pitch: 0)))
        XCTAssertEqual(negative.yaw, -45)
        XCTAssertEqual(negative.pitch, -10)
    }

    func testSelectsNearestFaceEvenWhenFartherFaceIsLarger() {
        let center = box(0.5, 0.5, size: 0.1)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([box(0.75, 0.5, size: 0.4), center], yawCorrection: 0), center)
    }

    func testEqualDistanceSelectsLargerThenStableCoordinateOrder() {
        let larger = box(0.75, 0.5, size: 0.2)
        let smaller = box(0.25, 0.5, size: 0.1)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([smaller, larger], yawCorrection: 0), larger)
        let left = box(0.25, 0.5, size: 0.2)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([larger, left], yawCorrection: 0), left)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([left, larger], yawCorrection: 0), left)
    }

    func testRejectsMalformedRectanglesWithoutDiscardingOtherValidFace() {
        let valid = box(0.75, 0.5)
        let invalid: [FaceRectangle] = [
            .init(x: .nan, y: 0, width: 0.1, height: 0.1, yawRadians: 0, pitchRadians: 0),
            .init(x: 0, y: 0, width: 0, height: 0.1, yawRadians: 0, pitchRadians: 0),
            .init(x: 0.95, y: 0, width: 0.1, height: 0.1, yawRadians: 0, pitchRadians: 0),
            .init(x: 0.1, y: -0.1, width: 0.1, height: 0.1, yawRadians: 0, pitchRadians: 0),
            .init(x: 0, y: 0, width: 0.1, height: .infinity, yawRadians: 0, pitchRadians: 0)
        ]
        XCTAssertNil(FaceTrackingGeometry.selectFace(invalid, yawCorrection: 0))
        XCTAssertEqual(FaceTrackingGeometry.selectFace(invalid + [valid], yawCorrection: 0), valid)
    }

    func testFaceWithoutHeadAnglesIsNeitherSelectedNorProjected() {
        // Without head angles a face cannot be shown to be facing the robot.
        let unknownHeading = FaceRectangle(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        XCTAssertNil(FaceTrackingGeometry.selectFace([unknownHeading], yawCorrection: 0))
        XCTAssertNil(FaceTrackingGeometry.project(
            observation(faces: [unknownHeading]), yawCorrection: 9, pose: .init(yaw: 0, pitch: 0)))
    }

    func testHeadAnglesUpToThirtyDegreesSidewaysAndTwentyFiveVerticallyAreEligibleOnBothSides() {
        let yawLimit = 30 * Double.pi / 180, pitchLimit = 25 * Double.pi / 180
        let limits: [(yaw: Double, pitch: Double)] = [(yawLimit, 0), (0, pitchLimit), (yawLimit, pitchLimit)]
        for sign in [-1.0, 1.0] {
            for (yaw, pitch) in limits {
                let face = box(0.5, 0.5, yaw: sign * yaw, pitch: sign * pitch)
                XCTAssertEqual(FaceTrackingGeometry.selectFace([face], yawCorrection: 0), face, "yaw \(sign * yaw) pitch \(sign * pitch)")
            }
        }
    }

    func testTurnedNonfiniteOrPartlyMissingHeadAnglesAreIneligible() {
        let degree = Double.pi / 180
        let angles: [(yaw: Double?, pitch: Double?)] = [
            (30.01 * degree, 0), (-30.01 * degree, 0), (0, 25.01 * degree), (0, -25.01 * degree),
            (Double.nan, 0), (0, Double.nan), (Double.infinity, 0), (0, -Double.infinity), (nil, 0), (0, nil)
        ]
        for angle in angles {
            let face = box(0.5, 0.5, yaw: angle.yaw, pitch: angle.pitch)
            XCTAssertNil(FaceTrackingGeometry.selectFace([face], yawCorrection: 0), "\(angle)")
            XCTAssertNil(FaceTrackingGeometry.project(
                observation(faces: [face]), yawCorrection: 0, pose: .init(yaw: 0, pitch: 0)), "\(angle)")
        }
    }

    func testNearerTurnedFaceDoesNotMaskFartherFacingFace() throws {
        let turned = box(0.5, 0.5, size: 0.3, yaw: Double.pi / 3)
        let facing = box(0.8, 0.5)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([turned, facing], yawCorrection: 0), facing)
        let result = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(faces: [turned, facing]), yawCorrection: 0, pose: .init(yaw: 0, pitch: 0)))
        XCTAssertEqual(result.yaw, -atan(0.6) * 180 / .pi, accuracy: 0.000_001)
    }

    func testFacingYawWindowIsCenteredOnTheNegativeScreenAimCorrection() {
        // The camera sits left of the screen, so looking at the screen center turns the head
        // about `correction` degrees to the person's right: negative Vision yaw.
        let windows: [(correction: Double, lower: Double, upper: Double)] = [(0, -30, 30), (8.5, -38.5, 21.5), (20, -50, 10)]
        for window in windows {
            for degrees in [window.lower, window.upper] {
                XCTAssertNotNil(projectedPose(yawDegrees: degrees, correction: window.correction), "\(window) \(degrees)")
            }
            for degrees in [window.lower - 0.01, window.upper + 0.01] {
                XCTAssertNil(projectedPose(yawDegrees: degrees, correction: window.correction), "\(window) \(degrees)")
            }
        }
    }

    func testCorrectionDecidesWhichSideOfFrontalIsAccepted() {
        XCTAssertNotNil(projectedPose(yawDegrees: -35, correction: 10))
        XCTAssertNil(projectedPose(yawDegrees: 25, correction: 10))
        XCTAssertNil(projectedPose(yawDegrees: -35, correction: 0))
        XCTAssertNotNil(projectedPose(yawDegrees: 25, correction: 0))
    }

    func testNearerFaceOutsideCorrectedWindowDoesNotMaskFartherFacingFace() throws {
        let degree = Double.pi / 180
        let outside = box(0.5, 0.5, size: 0.3, yaw: 25 * degree)
        let inside = box(0.8, 0.5, yaw: -35 * degree)
        let result = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(faces: [outside, inside]), yawCorrection: 10, pose: .init(yaw: 0, pitch: 0)))
        XCTAssertEqual(result.yaw, -atan(0.6) * 180 / .pi - 10, accuracy: 0.000_001)
    }

    func testRejectsEmptyFacesInvalidOpticsAndNonfinitePose() {
        XCTAssertNil(FaceTrackingGeometry.project(observation(faces: []), yawCorrection: 9, pose: .init(yaw: 0, pitch: 0)))
        for fov in [0.0, -30, 180, .nan, .infinity] {
            XCTAssertNil(FaceTrackingGeometry.project(observation(fov: fov), yawCorrection: 9, pose: .init(yaw: 0, pitch: 0)))
        }
        for aspect in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(FaceTrackingGeometry.project(observation(aspect: aspect), yawCorrection: 9, pose: .init(yaw: 0, pitch: 0)))
        }
        XCTAssertNil(FaceTrackingGeometry.project(observation(), yawCorrection: 9, pose: .init(yaw: .nan, pitch: 0)))
        XCTAssertNil(FaceTrackingGeometry.project(observation(), yawCorrection: 9, pose: .init(yaw: 0, pitch: .infinity)))
    }

    func testConfiguredCorrectionChangesYawWithoutChangingPitch() throws {
        for (correction, expectedYaw) in [(0.0, 30.0), (5.5, 24.5), (14.0, 16.0), (20.0, 10.0)] {
            let result = try XCTUnwrap(FaceTrackingGeometry.project(
                observation(), yawCorrection: correction, pose: .init(yaw: 30, pitch: 3)))
            XCTAssertEqual(result.yaw, expectedYaw, accuracy: 0.000_001)
            XCTAssertEqual(result.pitch, 3)
        }
    }

    func testInvalidCorrectionCannotProduceMotion() {
        for correction in [-1.0, 21.0, .nan, .infinity, -.infinity] {
            XCTAssertNil(FaceTrackingGeometry.selectFace([box(0.5, 0.5)], yawCorrection: correction))
            XCTAssertNil(FaceTrackingGeometry.project(observation(), yawCorrection: correction, pose: .init(yaw: 0, pitch: 0)))
        }
    }

    func testPoseHistoryInterpolatesCaptureTime() throws {
        var history = FacePoseHistory()
        history.record(at: 10, pose: .init(yaw: 10, pitch: -4))
        history.record(at: 10.2, pose: .init(yaw: 20, pitch: 0))
        let result = try XCTUnwrap(history.pose(at: 10.1, now: 10.3))
        XCTAssertEqual(result.yaw, 15, accuracy: 0.000_001)
        XCTAssertEqual(result.pitch, -2, accuracy: 0.000_001)
        XCTAssertEqual(history.pose(at: 10, now: 10.3), FacePose(yaw: 10, pitch: -4))
    }

    func testPoseHistoryNeverExtrapolatesOrAcceptsStaleStatus() {
        var history = FacePoseHistory()
        history.record(at: 10, pose: .init(yaw: 10, pitch: 0))
        history.record(at: 10.2, pose: .init(yaw: 20, pitch: 0))
        XCTAssertNil(history.pose(at: 9.9, now: 10.3))
        XCTAssertNil(history.pose(at: 10.3, now: 10.3))
        XCTAssertNil(history.pose(at: 10.1, now: 11.01))
        XCTAssertNil(history.pose(at: 10.1, now: 10.05))
        XCTAssertNil(history.pose(at: .nan, now: 10.3))
        XCTAssertNil(history.pose(at: 10.1, now: .infinity))
    }

    func testPoseHistoryRejectsOutOfOrderAndInvalidSamples() {
        var history = FacePoseHistory()
        history.record(at: 10, pose: .init(yaw: 10, pitch: 0))
        history.record(at: 9, pose: .init(yaw: 90, pitch: 0))
        history.record(at: .nan, pose: .init(yaw: 90, pitch: 0))
        history.record(at: 10.1, pose: .init(yaw: .nan, pitch: 0))
        history.record(at: 10.2, pose: .init(yaw: 20, pitch: 0))
        XCTAssertNil(history.pose(at: 9.5, now: 10.3))
        XCTAssertEqual(history.pose(at: 10.1, now: 10.3)?.yaw ?? -1, 15, accuracy: 0.000_001)
    }

    func testResetDropsPosesAcrossCaptureSessions() {
        var history = FacePoseHistory()
        history.record(at: 10, pose: .init(yaw: 10, pitch: 0))
        history.reset()
        XCTAssertNil(history.pose(at: 10, now: 10.1))
    }

    private func projectedPose(yawDegrees: Double, correction: Double) -> FacePose? {
        FaceTrackingGeometry.project(observation(faces: [box(0.5, 0.5, yaw: yawDegrees * .pi / 180)]),
                                     yawCorrection: correction, pose: .init(yaw: 0, pitch: 0))
    }

    private func box(_ x: Double, _ y: Double, size: Double = 0.1,
                     yaw: Double? = 0, pitch: Double? = 0) -> FaceRectangle {
        .init(x: x - size / 2, y: y - size / 2, width: size, height: size, yawRadians: yaw, pitchRadians: pitch)
    }

    private func observation(x: Double = 0.5, y: Double = 0.5,
                             fov: Double = 90, aspect: Double = 4.0 / 3,
                             faces: [FaceRectangle]? = nil) -> FaceObservation {
        .init(generation: UUID(), capturedAt: 10, completedAt: 10.1,
              horizontalFieldOfView: fov, aspectRatio: aspect, faces: faces ?? [box(x, y)])
    }
}
