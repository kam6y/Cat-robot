import XCTest
@testable import CatRobot

@MainActor
final class ReplyTurnMulticasterTests: XCTestCase {
    private final class Recorder {
        var events: [String] = []
        var turns: [MotionTurnID] = []
    }

    private final class Observer: ReplyTurnObserving {
        let label: String
        let recorder: Recorder
        init(_ label: String, recorder: Recorder) { self.label = label; self.recorder = recorder }
        private func record(_ event: String, _ id: MotionTurnID) {
            recorder.events.append("\(label):\(event)")
            recorder.turns.append(id)
        }
        func beginTurn(_ id: MotionTurnID) { record("begin", id) }
        func speechStarted(_ id: MotionTurnID) { record("start", id) }
        func speechFinished(_ id: MotionTurnID) { record("finish", id) }
        func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
            switch outcome { case .success: record("generated", id); case .failed: record("failed", id) }
        }
        func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {
            record("cancel-\(reason)", id)
        }
    }

    func testAllTurnEventsReachBothObserversOnceInOrderWithOriginalIdentity() {
        let recorder = Recorder(), turn = MotionTurnID()
        let sut = ReplyTurnMulticaster([Observer("motion", recorder: recorder), Observer("face", recorder: recorder)])
        sut.beginTurn(turn)
        sut.speechStarted(turn)
        sut.generationFinished(turn, outcome: .success)
        sut.speechFinished(turn)
        sut.generationFinished(turn, outcome: .failed)
        sut.cancelTurn(turn, reason: .fallback)
        XCTAssertEqual(recorder.events, [
            "motion:begin", "face:begin", "motion:start", "face:start",
            "motion:generated", "face:generated", "motion:finish", "face:finish",
            "motion:failed", "face:failed", "motion:cancel-fallback", "face:cancel-fallback"
        ])
        XCTAssertEqual(recorder.turns, Array(repeating: turn, count: 12))
    }
}
