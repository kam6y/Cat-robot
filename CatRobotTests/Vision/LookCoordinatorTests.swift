import XCTest
@testable import CatRobot

@MainActor
final class LookCoordinatorTests: XCTestCase {
    func testEarlierSpeechCannotHideIndicationBeforeImageHandoff() async throws {
        for timing in ["before", "delay", "capture"] {
            let h = LookHarness(), turn = h.begin()
            if timing == "before" { h.look.speechStarted(turn) }
            let task = Task { try await h.look.capture(for: turn) }
            await robotDrain()
            if timing == "delay" { h.look.speechStarted(turn) }
            XCTAssertTrue(h.look.isLooking, timing)
            await h.clock.advance(by: 0.1)
            if timing == "capture" { h.look.speechStarted(turn) }
            XCTAssertTrue(h.look.isLooking, timing)
            try h.camera.complete()
            let snapshot = try await task.value
            XCTAssertTrue(h.look.finishCapture(snapshot, for: turn))
            XCTAssertTrue(h.look.isLooking, "Keep the indication through handoff: \(timing)")
            h.look.generationFinished(turn, outcome: .success)
            XCTAssertFalse(h.look.isLooking)
        }
    }

    func testIndicatorPrecedesCaptureAndSurvivesSuccessUntilSpeech() async throws {
        let h = LookHarness(), turn = hID()
        h.look.beginTurn(turn)
        let task = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        XCTAssertTrue(h.look.isLooking)
        XCTAssertEqual(h.camera.requests, 0)
        await h.clock.advance(by: 0.099)
        XCTAssertEqual(h.camera.requests, 0)
        await h.clock.advance(by: 0.001)
        XCTAssertEqual(h.camera.requests, 1)
        try h.camera.complete()
        let snapshot = try await task.value
        XCTAssertTrue(h.look.finishCapture(snapshot, for: turn))
        XCTAssertTrue(h.look.isLooking)
        h.look.speechStarted(turn)
        XCTAssertFalse(h.look.isLooking)
        h.look.reset()
    }

    func testOnlyVisibleCurrentGeneratingTurnCanCapture() async {
        let h = LookHarness(), turn = hID()
        h.look.beginTurn(turn)
        await assertLookFailure(Task { try await h.look.capture(for: hID()) }, .cancelled)
        h.look.generationFinished(turn, outcome: .success)
        await assertLookFailure(Task { try await h.look.capture(for: turn) }, .cancelled)
        h.look.beginTurn(turn)
        h.look.setVisible(false)
        await assertLookFailure(Task { try await h.look.capture(for: turn) }, .unavailable)
        XCTAssertEqual(h.camera.requests, 0)
    }

    func testConcurrentCallIsBusyButSequentialCallsEachCaptureOneImage() async throws {
        let h = LookHarness(), turn = h.begin()
        let first = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        await assertLookFailure(Task { try await h.look.capture(for: turn) }, .busy)
        XCTAssertTrue(h.look.isLooking)
        await h.clock.advance(by: 0.1)
        try h.camera.complete()
        let firstSnapshot = try await first.value
        XCTAssertTrue(h.look.finishCapture(firstSnapshot, for: turn))
        let second = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        XCTAssertEqual(h.camera.requests, 2)
        try h.camera.complete(index: 1)
        let secondSnapshot = try await second.value
        XCTAssertTrue(h.look.finishCapture(secondSnapshot, for: turn))
        h.look.generationFinished(turn, outcome: .success)
        XCTAssertFalse(h.look.isLooking)
    }

    func testFailureClearsIndicatorWithoutInvalidatingConversationTurn() async throws {
        let h = LookHarness(), turn = h.begin()
        let task = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        h.camera.fail(.permissionRequired)
        await assertLookFailure(task, .permissionRequired)
        XCTAssertFalse(h.look.isLooking)
        XCTAssertTrue(h.look.isCurrent(turn))
        h.look.reset()
    }

    func testResetDuringVisibleDelayNeverRequestsImage() async {
        let h = LookHarness(), turn = h.begin()
        let task = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        h.look.reset()
        XCTAssertFalse(h.look.isLooking)
        await h.clock.advance(by: 1)
        await assertLookFailure(task, .cancelled)
        XCTAssertEqual(h.camera.requests, 0)
    }

    func testOldCompletionAfterNewTurnCannotReturnImageOrClearNewIndicator() async throws {
        let h = LookHarness(), old = h.begin()
        let first = Task { try await h.look.capture(for: old) }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        let next = h.begin()
        let second = Task { try await h.look.capture(for: next) }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        try h.camera.complete(index: 0)
        await assertLookFailure(first, .cancelled)
        XCTAssertTrue(h.look.isLooking)
        try h.camera.complete(index: 1)
        _ = try await second.value
        XCTAssertTrue(h.look.isLooking)
        h.look.cancelTurn(old, reason: .fallback)
        XCTAssertTrue(h.look.isLooking)
        h.look.reset()
    }

    func testCancelledCallerCannotReturnLateImage() async throws {
        let h = LookHarness(), turn = h.begin()
        let task = Task { try await h.look.capture(for: turn) }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        task.cancel()
        await robotDrain()
        XCTAssertFalse(h.look.isLooking)
        try h.camera.complete()
        await assertLookFailure(task, .cancelled)
    }

    func testFallbackHiddenAndFailedTurnsClearPendingCapture() async throws {
        for action in 0..<3 {
            let h = LookHarness(), turn = h.begin()
            let task = Task { try await h.look.capture(for: turn) }
            await robotDrain()
            await h.clock.advance(by: 0.1)
            switch action {
            case 0: h.look.cancelTurn(turn, reason: .fallback)
            case 1: h.look.setVisible(false)
            default: h.look.generationFinished(turn, outcome: .failed)
            }
            XCTAssertFalse(h.look.isLooking)
            try h.camera.complete()
            await assertLookFailure(task, .cancelled)
        }
    }

    func testLookDoesNotChangeHeldExpressionCaptionPhaseOrMouth() {
        var state = ConversationViewState.speaking(caption: "元の返答")
        state.heldExpression = .happy
        state.isLooking = true
        XCTAssertEqual(state.faceExpression, .curious)
        XCTAssertTrue(state.statusChips.contains(.looking))
        XCTAssertEqual(state.caption, "元の返答")
        XCTAssertEqual(state.heldExpression, .happy)
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(state.mouthPose, .medium)
        state.isLooking = false
        XCTAssertEqual(state.faceExpression, .happy)
        XCTAssertFalse(state.statusChips.contains(.looking))
    }

    func testLookAnnouncementDoesNotRepeatForUnrelatedStateUpdates() {
        let before = ConversationViewState.thinking
        var looking = before
        looking.isLooking = true
        XCTAssertEqual(ConversationAnnouncementPolicy.announcement(from: before, to: looking), "見ています")
        var update = looking
        update.caption = "元の返答"
        XCTAssertNil(ConversationAnnouncementPolicy.announcement(from: looking, to: update))
    }
}

private func hID() -> MotionTurnID { MotionTurnID() }

@MainActor
final class LookHarness {
    let clock = ManualRobotClock()
    let camera = ControlledSnapshotCamera()
    let look: LookCoordinator
    init() {
        look = LookCoordinator(camera: camera, clock: clock)
        look.setVisible(true)
    }
    func begin() -> MotionTurnID {
        let turn = MotionTurnID()
        look.beginTurn(turn)
        return turn
    }
}

/// Deliberately keeps cancelled callbacks to exercise uncooperative/late camera completions.
@MainActor
final class ControlledSnapshotCamera: CameraSnapshotProviding {
    private(set) var requests = 0
    private var continuations: [CheckedContinuation<CameraSnapshot, Error>?] = []
    func isSnapshotValid(_ snapshot: CameraSnapshot) -> Bool { true }
    func captureSnapshot() async throws -> CameraSnapshot {
        requests += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func complete(index: Int? = nil) throws {
        let chosen = index ?? continuations.count - 1
        let continuation = try XCTUnwrap(continuations.indices.contains(chosen) ? continuations[chosen] : nil)
        continuations[chosen] = nil
        continuation.resume(returning: .init(generation: UUID(), capturedAt: 0,
            image: try makeCameraTestImage()))
    }
    func fail(_ error: CameraSnapshotError) {
        continuations[continuations.count - 1]?.resume(throwing: error)
        continuations[continuations.count - 1] = nil
    }
}

@MainActor
func assertLookFailure(_ task: Task<CameraSnapshot, Error>, _ expected: CameraSnapshotError,
                       file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await task.value; XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? CameraSnapshotError, expected, file: file, line: line) }
}
