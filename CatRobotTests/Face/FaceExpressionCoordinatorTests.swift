import XCTest
@testable import CatRobot

@MainActor
final class FaceExpressionHarness {
    let clock = ManualRobotClock()
    let sut: FaceExpressionCoordinator

    init() {
        sut = FaceExpressionCoordinator(clock: clock)
        sut.setVisible(true)
        sut.setConversationPhase(.thinking)
    }

    func begin() -> MotionTurnID {
        let turn = MotionTurnID()
        sut.beginTurn(turn)
        return turn
    }
}

@MainActor
final class FaceExpressionCoordinatorTests: XCTestCase {
    func testPendingHoldStartsAtActualSpeechInsteadOfGeneration() async {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        XCTAssertEqual(h.sut.reserve(.init(expression: .happy), for: turn), .reserved)
        await h.clock.advance(by: 20)
        XCTAssertNil(h.sut.heldExpression)
        h.sut.generationFinished(turn, outcome: .success)
        h.sut.speechStarted(turn)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        await h.clock.advance(by: 2.99)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        await h.clock.advance(by: 0.01)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testLatestReservationWinsAndReplacementRestartsHold() async {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        _ = h.sut.reserve(.init(expression: .happy, holdSeconds: 1), for: turn)
        _ = h.sut.reserve(.init(expression: .sorry, holdSeconds: 4), for: turn)
        h.sut.speechStarted(turn)
        XCTAssertEqual(h.sut.heldExpression, .sorry)
        await h.clock.advance(by: 2)
        XCTAssertEqual(h.sut.reserve(.init(expression: .curious, holdSeconds: 3), for: turn), .reserved)
        await h.clock.advance(by: 2.99)
        XCTAssertEqual(h.sut.heldExpression, .curious)
        await h.clock.advance(by: 0.01)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testSpeechFinishedPreservesHoldButClosesAdmission() async {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        _ = h.sut.reserve(.init(expression: .happy), for: turn)
        h.sut.speechStarted(turn)
        await h.clock.advance(by: 1)
        h.sut.speechFinished(turn)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        XCTAssertEqual(h.sut.reserve(.init(expression: .sorry), for: turn), .invalidated)
        await h.clock.advance(by: 2)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testOldTurnAndOldExpiryCannotChangeNewHold() async {
        let h = FaceExpressionHarness()
        let old = h.begin()
        _ = h.sut.reserve(.init(expression: .happy, holdSeconds: 1), for: old)
        h.sut.speechStarted(old)
        await h.clock.advance(by: 0.5)
        let next = h.begin()
        XCTAssertNil(h.sut.heldExpression)
        _ = h.sut.reserve(.init(expression: .curious, holdSeconds: 3), for: next)
        h.sut.speechStarted(next)
        XCTAssertEqual(h.sut.reserve(.init(expression: .sorry), for: old), .invalidated)
        h.sut.speechFinished(old)
        h.sut.speechStarted(old)
        h.sut.generationFinished(old, outcome: .failed)
        h.sut.cancelTurn(old, reason: .fallback)
        await h.clock.advance(by: 0.5)
        XCTAssertEqual(h.sut.heldExpression, .curious)
        await h.clock.advance(by: 2.49)
        XCTAssertEqual(h.sut.heldExpression, .curious)
        await h.clock.advance(by: 0.01)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testSuccessfulGenerationKeepsPendingButRejectsLateToolsAndDuplicateStart() async {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        _ = h.sut.reserve(.init(expression: .happy), for: turn)
        h.sut.generationFinished(turn, outcome: .success)
        XCTAssertEqual(h.sut.reserve(.init(expression: .sorry), for: turn), .invalidated)
        h.sut.speechStarted(turn)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        await h.clock.advance(by: 2.5)
        h.sut.speechStarted(turn)
        await h.clock.advance(by: 0.5)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testSpeechFinishedBeforeStartCannotReleaseAPendingExpression() {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        _ = h.sut.reserve(.init(expression: .happy), for: turn)
        h.sut.speechFinished(turn)
        h.sut.speechStarted(turn)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testFallbackFailurePauseAndHiddenInvalidateWithoutReplay() async {
        let invalidations: [(String, (FaceExpressionCoordinator, MotionTurnID) -> Void)] = [
            ("fallback", { $0.cancelTurn($1, reason: .fallback) }),
            ("failure", { $0.generationFinished($1, outcome: .failed) }),
            ("idle", { controller, _ in controller.setConversationPhase(.idle) }),
            ("preparing", { controller, _ in controller.setConversationPhase(.preparing) }),
            ("paused", { controller, _ in controller.setConversationPhase(.paused) }),
            ("failed phase", { controller, _ in controller.setConversationPhase(.failed(.modelBusy)) }),
            ("hidden", { controller, _ in controller.setVisible(false) }),
            ("reset", { controller, _ in controller.reset() })
        ]
        for (name, invalidate) in invalidations {
            for alreadyPlaying in [false, true] {
                let h = FaceExpressionHarness(), turn = MotionTurnID()
                h.sut.beginTurn(turn)
                _ = h.sut.reserve(.init(expression: .happy), for: turn)
                if alreadyPlaying { h.sut.speechStarted(turn) }
                invalidate(h.sut, turn)
                XCTAssertNil(h.sut.heldExpression, name)
                h.sut.setVisible(true)
                h.sut.setConversationPhase(.thinking)
                h.sut.speechStarted(turn)
                XCTAssertEqual(h.sut.reserve(.init(expression: .sorry), for: turn), .invalidated, name)
                await h.clock.advance(by: 20)
                XCTAssertNil(h.sut.heldExpression, name)
            }
        }
    }

    func testActivePhaseChangesPreserveHoldUntilOriginalDeadline() async {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        _ = h.sut.reserve(.init(expression: .happy), for: turn)
        h.sut.speechStarted(turn)
        for phase in [ConversationPhase.listening, .classifying, .clarifying, .thinking, .speaking] {
            h.sut.setConversationPhase(phase)
            await h.clock.advance(by: 0.5)
            XCTAssertEqual(h.sut.heldExpression, .happy)
        }
        await h.clock.advance(by: 0.5)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testHiddenOrPausedControllerCannotAdmitNewTurn() {
        let sut = FaceExpressionCoordinator(clock: ManualRobotClock())
        let turn = MotionTurnID()
        sut.beginTurn(turn)
        XCTAssertEqual(sut.reserve(.init(expression: .happy), for: turn), .unavailable)
        sut.setVisible(true)
        sut.beginTurn(turn)
        XCTAssertEqual(sut.reserve(.init(expression: .happy), for: turn), .invalidated)
        sut.setConversationPhase(.thinking)
        sut.beginTurn(turn)
        XCTAssertEqual(sut.reserve(.init(expression: .happy), for: turn), .reserved)
        sut.setVisible(false)
        XCTAssertEqual(sut.reserve(.init(expression: .happy), for: turn), .unavailable)
    }
}
