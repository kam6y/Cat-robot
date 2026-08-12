import XCTest
@testable import CatRobot

final class CatFaceGeometryTests: XCTestCase {
    func testLandmarksStayInsideNormalizedCanvas() {
        for point in CatFaceGeometry.landmarksAndControlPoints {
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
    }

    func testCanonicalCanvasMatchesTheFullReferenceRaster() {
        XCTAssertEqual(CatFaceGeometry.aspectRatio, 1672.0 / 941.0, accuracy: 0.0001)
    }

    func testMirroredFeaturePairsAreSymmetric() {
        for pair in CatFaceGeometry.mirroredFeaturePairs {
            XCTAssertEqual(pair.left.x + pair.right.x, 1, accuracy: 0.001)
            XCTAssertEqual(pair.left.y, pair.right.y, accuracy: 0.001)
        }
    }

    func testMouthOpeningIncreasesAcrossSpeakingPoses() {
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .closed),
                          CatFaceGeometry.mouthOpening(for: .small))
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .small),
                          CatFaceGeometry.mouthOpening(for: .medium))
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .medium),
                          CatFaceGeometry.mouthOpening(for: .wide))
    }
}
