import XCTest
@testable import CatRobot

final class FaceCapturePolicyTests: XCTestCase {
    func testChoosesThreeFPSAndLargestBoundedOutputWithNativeAspect() throws {
        let selected = try XCTUnwrap(FaceCapturePolicy.select([
            format(0, width: 1920, height: 1080), format(1, width: 1280, height: 960),
            format(2, width: 640, height: 480)
        ]))
        XCTAssertEqual(selected.formatID, 2)
        XCTAssertEqual(selected.width, 640)
        XCTAssertEqual(selected.height, 480)
        XCTAssertEqual(selected.frameDuration, 1.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(selected.horizontalFieldOfView, 72)
        let wide = try XCTUnwrap(FaceCapturePolicy.select([format(3, width: 1920, height: 1080)]))
        XCTAssertEqual(wide.width, 640)
        XCTAssertEqual(wide.height, 360)
    }

    func testRejectsFormatsWithoutThreeFPSOrValidOptics() {
        XCTAssertNil(FaceCapturePolicy.select([format(0, minimumFPS: 15), format(1, minimumFPS: 30)]))
        for value in [0.0, -1, Double.nan, .infinity] {
            XCTAssertNil(FaceCapturePolicy.select([format(0, minimumFPS: value)]))
            XCTAssertNil(FaceCapturePolicy.select([format(0, maximumFPS: value)]))
        }
        for value in [0.0, 180, Double.nan, .infinity] {
            XCTAssertNil(FaceCapturePolicy.select([format(0, fov: value)]))
        }
        XCTAssertNil(FaceCapturePolicy.select([format(0, maximumFPS: 2)]))
        XCTAssertNil(FaceCapturePolicy.select([format(0, minimumFPS: 4)]))
        XCTAssertNotNil(FaceCapturePolicy.select([format(0, minimumFPS: 3, maximumFPS: 3)]))
        XCTAssertNil(FaceCapturePolicy.select([format(0, width: 0)]))
        // No exact, even-pixel representation at the output size limit.
        XCTAssertNil(FaceCapturePolicy.select([format(0, width: 641, height: 479)]))
    }

    func testUsesAnySupportedFrameRateRangeAndNeverUpscales() throws {
        let descriptor = FaceCaptureFormat(id: 1, width: 320, height: 240,
            horizontalFieldOfView: 60, frameRateRanges: [
                .init(minimum: 15, maximum: 30), .init(minimum: 1, maximum: 5)
            ])
        let selected = try XCTUnwrap(FaceCapturePolicy.select([descriptor]))
        XCTAssertEqual(selected.width, 320)
        XCTAssertEqual(selected.height, 240)
    }

    func testCadenceHeadroomAcceptsObservedClockRoundingButStillRejectsOverFiveFPS() throws {
        // iPhone 16 Pro reported 0.199995s for nominal 5fps, stopping on its second frame.
        // The lower capture cadence also keeps the observed rounding within the actual 5fps ceiling.
        let selected = try XCTUnwrap(FaceCapturePolicy.select([format(0)]))
        XCTAssertGreaterThan(selected.frameDuration, 0.2)
        let configured = FaceCaptureConfiguration(formatID: 0, width: 640, height: 480,
            frameDuration: 0.25, horizontalFieldOfView: 72)
        XCTAssertTrue(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10.249995,
            previous: 10, configuration: configured))
        XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10.199995,
            previous: 10, configuration: configured))
        XCTAssertNil(FaceCapturePolicy.select([format(0, minimumFPS: 5, maximumFPS: 30)]))
    }

    func testCapturedTimeUsesHostAnchorInsteadOfCompletionTime() throws {
        let mapping = try XCTUnwrap(FaceCaptureTimeMapping(hostAnchor: 1000, robotAnchor: 40))
        XCTAssertEqual(try XCTUnwrap(mapping.robotTime(hostTime: 1000.1)), 40.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(mapping.robotTime(hostTime: 1000.3)), 40.3, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(mapping.robotTime(hostTime: 999.9)), 39.9, accuracy: 0.000_001)
    }

    func testInvalidClockValuesNeverProduceCaptureTimes() throws {
        for value in [-1.0, Double.nan, .infinity] {
            XCTAssertNil(FaceCaptureTimeMapping(hostAnchor: value, robotAnchor: 10))
            XCTAssertNil(FaceCaptureTimeMapping(hostAnchor: 10, robotAnchor: value))
        }
        let mapping = try XCTUnwrap(FaceCaptureTimeMapping(hostAnchor: 100, robotAnchor: 1))
        for value in [0.0, -1, Double.nan, .infinity] {
            XCTAssertNil(mapping.robotTime(hostTime: value))
        }
    }

    func testActualFrameDimensionsAndCadenceMustMeetSelectedContract() throws {
        let selected = try XCTUnwrap(FaceCapturePolicy.select([format(0)]))
        XCTAssertTrue(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10,
            previous: nil, configuration: selected))
        XCTAssertTrue(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10.2,
            previous: 10, configuration: selected))
        XCTAssertTrue(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10.6,
            previous: 10, configuration: selected))
        XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 1280, height: 960, at: 10.2,
            previous: 10, configuration: selected))
        XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 640, height: 360, at: 10.2,
            previous: 10, configuration: selected))
        for time in [10.1, 10, 9.9, -1, Double.nan, .infinity] {
            XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: time,
                previous: 10, configuration: selected))
        }
        XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10.2,
            previous: .nan, configuration: selected))
    }

    func testOnlyNewestEventIsBufferedAcrossSlowMainActorDelivery() async {
        let channel = FaceCapturePolicy.makeEventStream()
        let old = UUID(), newest = UUID()
        channel.continuation.yield(.unavailable(generation: old))
        channel.continuation.yield(.interrupted(generation: newest))
        channel.continuation.finish()
        var received: [UUID] = []
        for await event in channel.stream {
            switch event {
            case .unavailable(let id), .interrupted(let id): received.append(id)
            case .observation: XCTFail("Unexpected observation")
            }
        }
        XCTAssertEqual(received, [newest])
    }

    func testQuarterTurnUsesNativeVerticalFieldOfViewAndReciprocalAspect() throws {
        let optics = try XCTUnwrap(FaceCapturePolicy.uprightOptics(
            nativeFieldOfView: 90, nativeAspect: 4.0 / 3, rotationDegrees: 90))
        XCTAssertEqual(optics.fieldOfView, 73.739795, accuracy: 0.000_001)
        XCTAssertEqual(optics.aspectRatio, 0.75)
        XCTAssertNil(FaceCapturePolicy.uprightOptics(
            nativeFieldOfView: 90, nativeAspect: 4.0 / 3, rotationDegrees: 45))
    }

    func testInvalidFrameDurationsAreRejected() {
        for duration in [0.0, -1, 1.0 / 30, Double.nan, .infinity] {
            let invalid = FaceCaptureConfiguration(formatID: 0, width: 640, height: 480,
                frameDuration: duration, horizontalFieldOfView: 72)
            XCTAssertFalse(FaceCapturePolicy.acceptsFrame(width: 640, height: 480, at: 10,
                previous: nil, configuration: invalid))
        }
    }

    private func format(_ id: Int, width: Int = 640, height: Int = 480,
                        minimumFPS: Double = 1, maximumFPS: Double = 30,
                        fov: Double = 72) -> FaceCaptureFormat {
        .init(id: id, width: width, height: height, horizontalFieldOfView: fov,
              frameRateRanges: [.init(minimum: minimumFPS, maximum: maximumFPS)])
    }
}
