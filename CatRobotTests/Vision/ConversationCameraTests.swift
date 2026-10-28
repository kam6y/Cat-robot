import XCTest
@testable import CatRobot

@MainActor
final class ConversationCameraTests: XCTestCase {
    func testSnapshotStartsAndStopsWithoutTrackingOrRobot() async throws {
        let h = CameraHarness()
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        XCTAssertEqual(h.source.starts.count, 1)
        XCTAssertEqual(h.source.requests, 0)
        try h.complete()
        let snapshot = try await task.value
        XCTAssertEqual(snapshot.image.width, 4)
        XCTAssertEqual(h.source.stops, 1)
        h.camera.shutdown()
    }

    func testSnapshotReusesTrackingCaptureAndDoesNotStopItOnCompletion() async throws {
        let h = CameraHarness()
        h.camera.start(generation: UUID())
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        XCTAssertEqual(h.source.starts.count, 1)
        try h.complete()
        _ = try await task.value
        XCTAssertEqual(h.source.stops, 0)
        h.camera.stop()
        XCTAssertEqual(h.source.stops, 1)
        h.camera.shutdown()
    }

    func testTrackingStopDoesNotCancelPendingSnapshot() async throws {
        let h = CameraHarness()
        h.camera.start(generation: UUID())
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        h.camera.stop()
        XCTAssertEqual(h.source.stops, 0)
        try h.complete()
        _ = try await task.value
        XCTAssertEqual(h.source.stops, 1)
        h.camera.shutdown()
    }

    func testTimeoutReleasesCameraAndLateResultCannotCompleteNextRequest() async throws {
        let h = CameraHarness()
        let first = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        await h.clock.advance(by: 2.99)
        XCTAssertEqual(h.source.stops, 0)
        await h.clock.advance(by: 0.01)
        await assertCameraFailure(first, .timedOut)
        XCTAssertEqual(h.source.stops, 1)
        var secondFinished = false
        let second = Task { let image = try await h.camera.captureSnapshot(); secondFinished = true; return image }
        await robotDrain()
        try h.complete(index: 0)
        await robotDrain()
        XCTAssertFalse(secondFinished)
        try h.complete(index: 1)
        _ = try await second.value
        XCTAssertTrue(secondFinished)
        h.camera.shutdown()
    }

    func testConcurrentSnapshotIsBusyWithoutStartingAnotherCapture() async throws {
        let h = CameraHarness()
        let first = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        let second = Task { try await h.camera.captureSnapshot() }
        await assertCameraFailure(second, .busy)
        XCTAssertEqual(h.source.snapshotRequests.count, 1)
        XCTAssertEqual(h.source.starts.count, 1)
        try h.complete()
        _ = try await first.value
        h.camera.shutdown()
    }

    func testRequestCancellationStopsSnapshotButLeavesTracking() async throws {
        let h = CameraHarness()
        h.camera.start(generation: UUID())
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        task.cancel()
        await assertCameraFailure(task, .cancelled)
        XCTAssertEqual(h.source.stops, 0)
        XCTAssertEqual(h.source.snapshotCancellations.count, 1)
        h.camera.shutdown()
    }

    func testMissingPermissionNeverPromptsOrStartsCamera() async {
        for authorization in [FaceCameraAuthorization.notDetermined, .denied, .restricted] {
            let h = CameraHarness(authorization: authorization)
            let task = Task { try await h.camera.captureSnapshot() }
            await assertCameraFailure(task, .permissionRequired)
            XCTAssertTrue(h.source.starts.isEmpty)
            XCTAssertEqual(h.source.requests, 0)
            h.camera.shutdown()
        }
    }

    func testExplicitPermissionDoesNotStartCaptureOrTracking() async {
        let h = CameraHarness(authorization: .notDetermined)
        let request = Task { await h.camera.requestAuthorization() }
        await robotDrain()
        XCTAssertEqual(h.source.requests, 1)
        h.source.resolveAuthorization(.authorized)
        let result = await request.value
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(h.camera.authorization, .authorized)
        XCTAssertTrue(h.source.starts.isEmpty)
        h.camera.shutdown()
    }

    func testInactiveSettingsAndPausedEnvironmentsRefuseCapture() async {
        let cases: [(Bool, Bool, RobotControlMode, ConversationPhase)] = [
            (false, true, .conversation, .thinking), (true, false, .conversation, .thinking),
            (true, true, .settings, .thinking), (true, true, .calibration(UUID()), .thinking),
            (true, true, .conversation, .paused), (true, true, .conversation, .preparing)
        ]
        for (visible, active, mode, phase) in cases {
            let h = CameraHarness()
            h.camera.setEnvironment(conversationVisible: visible, sceneActive: active, mode: mode, phase: phase)
            let task = Task { try await h.camera.captureSnapshot() }
            await assertCameraFailure(task, .unavailable)
            XCTAssertTrue(h.source.starts.isEmpty)
            h.camera.shutdown()
        }
    }

    func testSceneLossCancelsPendingImageBeforeLateCallback() async throws {
        let h = CameraHarness()
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        h.camera.setEnvironment(conversationVisible: true, sceneActive: false, mode: .background, phase: .thinking)
        await assertCameraFailure(task, .cancelled)
        XCTAssertEqual(h.source.stops, 1)
        try h.complete()
        await robotDrain()
        XCTAssertEqual(h.source.starts.count, 1)
        h.camera.shutdown()
    }

    func testHeatStopsSnapshotAndRefusesAnotherUntilCool() async throws {
        let h = CameraHarness()
        let task = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        h.camera.setThermalState(.serious)
        await assertCameraFailure(task, .cancelled)
        await assertCameraFailure(Task { try await h.camera.captureSnapshot() }, .unavailable)
        h.camera.setThermalState(.fair)
        let recovered = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        try h.complete(index: 1)
        _ = try await recovered.value
        h.camera.shutdown()
    }

    func testMalformedOrStaleSnapshotCannotCrossOwnerBoundary() async throws {
        for kind in 0..<3 {
            let h = CameraHarness()
            await h.clock.advance(by: 1)
            let task = Task { try await h.camera.captureSnapshot() }
            await robotDrain()
            let request = try XCTUnwrap(h.source.snapshotRequests.last)
            let result = CameraSnapshot(generation: kind == 0 ? UUID() : request.generation,
                capturedAt: kind == 1 ? 0.6 : kind == 2 ? .infinity : 1,
                image: try makeCameraTestImage())
            request.completion(.success(result))
            await assertCameraFailure(task, .unavailable)
            h.camera.shutdown()
        }
    }

    func testPhysicalGenerationIsTranslatedAndOldPhysicalEventsAreDiscarded() async throws {
        let h = CameraHarness()
        h.camera.start(generation: UUID())
        let old = try XCTUnwrap(h.source.starts.last?.generation)
        h.camera.stop()
        let client = UUID()
        h.camera.start(generation: client)
        let physical = try XCTUnwrap(h.source.starts.last?.generation)
        XCTAssertNotEqual(client, physical)
        let stream = h.camera.events()
        let event = Task { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
        h.source.emit(.observation(h.observation(generation: old, at: 0)))
        await robotDrain()
        h.source.emit(.observation(h.observation(generation: physical, at: 1)))
        guard case let .observation(observation) = await event.value else { return XCTFail("No observation") }
        XCTAssertEqual(observation.generation, client)
        XCTAssertEqual(observation.capturedAt, 1)
        h.camera.shutdown()
    }

    func testCaptureFailureDoesNotRestartContinuously() async throws {
        let h = CameraHarness()
        h.camera.start(generation: UUID())
        let generation = try XCTUnwrap(h.source.starts.last?.generation)
        h.source.emit(.unavailable(generation: generation))
        await robotDrain()
        h.camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: .thinking)
        await robotDrain()
        XCTAssertEqual(h.source.starts.count, 1)
        h.camera.shutdown()
    }
}

@MainActor
private final class CameraHarness {
    let clock = ManualRobotClock()
    let source: FakeFaceCaptureSource
    let camera: ConversationCamera
    init(authorization: FaceCameraAuthorization = .authorized) {
        source = FakeFaceCaptureSource(authorization: authorization)
        camera = ConversationCamera(source: source, clock: clock)
        camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: .thinking)
    }
    func complete(index: Int? = nil) throws {
        let chosen = index ?? source.snapshotRequests.count - 1
        let request = try XCTUnwrap(source.snapshotRequests.indices.contains(chosen) ? source.snapshotRequests[chosen] : nil)
        request.completion(.success(.init(generation: request.generation, capturedAt: clock.now,
            image: try makeCameraTestImage())))
    }
    func observation(generation: UUID, at time: TimeInterval) -> FaceObservation {
        .init(generation: generation, capturedAt: time, completedAt: time,
              horizontalFieldOfView: 90, aspectRatio: 4.0 / 3,
              faces: [.init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)])
    }
}

@MainActor
func assertCameraFailure(_ task: Task<CameraSnapshot, Error>, _ expected: CameraSnapshotError,
                         file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await task.value; XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? CameraSnapshotError, expected, file: file, line: line) }
}
