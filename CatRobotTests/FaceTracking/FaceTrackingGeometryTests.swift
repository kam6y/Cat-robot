import XCTest
@testable import CatRobot

final class FaceTrackingGeometryTests: XCTestCase {
    func testFixedLeftCameraAimIsCorrectedBeforeDeadbandInBothImageOrientations() throws {
        // A 14-degree camera ray (tan(14deg)/2 from image center with 90deg FOV)
        // corresponds to a person straight in front of the screen at the chosen fixed correction.
        for (orientation, x) in [(FaceLandscapeOrientation.landscapeRight, 0.3753359986),
                                  (.landscapeLeft, 0.6246640014)] {
            let pose = FacePose(yaw: -20, pitch: 3)
            XCTAssertEqual(FaceTrackingGeometry.project(observation(x: x, orientation: orientation), pose: pose), pose)
            let centered = try XCTUnwrap(FaceTrackingGeometry.project(observation(orientation: orientation), pose: pose))
            XCTAssertEqual(centered, FacePose(yaw: -34, pitch: 3))
        }
    }

    func testCameraCenterIncludesFixedScreenAimCorrection() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(observation(), pose: .init(yaw: 30, pitch: -3)))
        XCTAssertEqual(result, FacePose(yaw: 16, pitch: -3))
    }

    func testBothLandscapeOrientationsMapToObserverLeftAndUp() throws {
        // Same physical face: raw points are rotated by 180 degrees between orientations.
        for (orientation, x, y) in [(FaceLandscapeOrientation.landscapeRight, 0.75, 0.55),
                                     (.landscapeLeft, 0.25, 0.45)] {
            let result = try XCTUnwrap(FaceTrackingGeometry.project(
                observation(x: x, y: y, orientation: orientation), pose: .init(yaw: 0, pitch: 0)))
            XCTAssertEqual(result.yaw, -40.565051, accuracy: 0.000_001)
            XCTAssertEqual(result.pitch, 4.289153, accuracy: 0.000_001)
        }
    }

    func testProjectionAddsPoseInsteadOfRecenteringNeck() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(observation(x: 0.25), pose: .init(yaw: -30, pitch: 0)))
        XCTAssertEqual(result.yaw, -17.434949, accuracy: 0.000_001)
    }

    func testDeadbandIsAppliedIndependentlyPerAxis() throws {
        let result = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.3753359986, y: 0.55), pose: .init(yaw: 30, pitch: -2)))
        XCTAssertEqual(result.yaw, 30)
        XCTAssertEqual(result.pitch, 2.289153, accuracy: 0.000_001)
    }

    func testProjectionClampsBothAxesToTrackingLimits() throws {
        let positive = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.1, y: 0.75), pose: .init(yaw: 30, pitch: 0)))
        XCTAssertEqual(positive.yaw, 45)
        XCTAssertEqual(positive.pitch, 10)
        let negative = try XCTUnwrap(FaceTrackingGeometry.project(
            observation(x: 0.9, y: 0.25), pose: .init(yaw: -30, pitch: 0)))
        XCTAssertEqual(negative.yaw, -45)
        XCTAssertEqual(negative.pitch, -10)
    }

    func testSelectsNearestFaceEvenWhenFartherFaceIsLarger() {
        let center = box(0.5, 0.5, size: 0.1)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([box(0.75, 0.5, size: 0.4), center]), center)
    }

    func testEqualDistanceSelectsLargerThenStableCoordinateOrder() {
        let larger = box(0.75, 0.5, size: 0.2)
        let smaller = box(0.25, 0.5, size: 0.1)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([smaller, larger]), larger)
        let left = box(0.25, 0.5, size: 0.2)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([larger, left]), left)
        XCTAssertEqual(FaceTrackingGeometry.selectFace([left, larger]), left)
    }

    func testRejectsMalformedRectanglesWithoutDiscardingOtherValidFace() {
        let valid = box(0.75, 0.5)
        let invalid: [FaceRectangle] = [
            .init(x: .nan, y: 0, width: 0.1, height: 0.1),
            .init(x: 0, y: 0, width: 0, height: 0.1),
            .init(x: 0.95, y: 0, width: 0.1, height: 0.1),
            .init(x: 0.1, y: -0.1, width: 0.1, height: 0.1),
            .init(x: 0, y: 0, width: 0.1, height: .infinity)
        ]
        XCTAssertNil(FaceTrackingGeometry.selectFace(invalid))
        XCTAssertEqual(FaceTrackingGeometry.selectFace(invalid + [valid]), valid)
    }

    func testRejectsEmptyFacesInvalidOpticsAndNonfinitePose() {
        XCTAssertNil(FaceTrackingGeometry.project(observation(faces: []), pose: .init(yaw: 0, pitch: 0)))
        for fov in [0.0, -30, 180, .nan, .infinity] {
            XCTAssertNil(FaceTrackingGeometry.project(observation(fov: fov), pose: .init(yaw: 0, pitch: 0)))
        }
        for aspect in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(FaceTrackingGeometry.project(observation(aspect: aspect), pose: .init(yaw: 0, pitch: 0)))
        }
        XCTAssertNil(FaceTrackingGeometry.project(observation(), pose: .init(yaw: .nan, pitch: 0)))
        XCTAssertNil(FaceTrackingGeometry.project(observation(), pose: .init(yaw: 0, pitch: .infinity)))
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

    private func box(_ x: Double, _ y: Double, size: Double = 0.1) -> FaceRectangle {
        .init(x: x - size / 2, y: y - size / 2, width: size, height: size)
    }

    private func observation(x: Double = 0.5, y: Double = 0.5,
                             orientation: FaceLandscapeOrientation = .landscapeRight,
                             fov: Double = 90, aspect: Double = 4.0 / 3,
                             faces: [FaceRectangle]? = nil) -> FaceObservation {
        .init(generation: UUID(), capturedAt: 10, completedAt: 10.1, orientation: orientation,
              horizontalFieldOfView: fov, aspectRatio: aspect, faces: faces ?? [box(x, y)])
    }
}
