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

    func testMuzzleUsesOneClosedContourWithoutASeparateCenterSeam() {
        let commands = CatFaceGeometry.muzzle.commands
        let moveCount = commands.reduce(into: 0) { count, command in
            if case .move = command { count += 1 }
        }
        let closeCount = commands.reduce(into: 0) { count, command in
            if case .close = command { count += 1 }
        }

        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(commands.contains { command in
            guard case let .line(point) = command else { return false }
            return abs(point.x - 0.5) < 0.0001 && point.y > CatFaceGeometry.mouthHinge.y
        })
    }

    func testMouthOpeningsAreVisibleAndStayInsideApprovedWideLimit() {
        XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .small), 0.025, accuracy: 0.0001)
        XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .medium), 0.055, accuracy: 0.0001)
        XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .wide), 0.090, accuracy: 0.0001)
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .wide), 0.095)
    }
}
