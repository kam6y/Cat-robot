import Foundation

struct FaceExpressionRequest: Equatable, Sendable {
    let expression: FaceExpression
    let holdSeconds: Int

    init(expression: FaceExpression, holdSeconds: Int = 3) {
        self.expression = expression
        self.holdSeconds = min(10, max(1, holdSeconds))
    }
}

enum FaceExpressionReservationResult: Equatable, Sendable {
    case reserved, invalidated, unavailable
}

@MainActor
protocol FaceExpressionControlling: ReplyTurnObserving {
    var heldExpression: FaceExpression? { get }
    func reserve(_ request: FaceExpressionRequest, for id: MotionTurnID) -> FaceExpressionReservationResult
    func setConversationPhase(_ phase: ConversationPhase)
    func setVisible(_ visible: Bool)
    func reset()
}

@MainActor
final class NoopFaceExpressionController: FaceExpressionControlling {
    nonisolated init() {}
    var heldExpression: FaceExpression? { nil }
    func reserve(_ request: FaceExpressionRequest, for id: MotionTurnID) -> FaceExpressionReservationResult { .unavailable }
    func beginTurn(_ id: MotionTurnID) {}
    func speechStarted(_ id: MotionTurnID) {}
    func speechFinished(_ id: MotionTurnID) {}
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {}
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {}
    func setConversationPhase(_ phase: ConversationPhase) {}
    func setVisible(_ visible: Bool) {}
    func reset() {}
}
