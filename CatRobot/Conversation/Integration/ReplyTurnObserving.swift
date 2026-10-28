import Foundation

/// The existing reply lifecycle shared by independently controlled robot features.
@MainActor
protocol ReplyTurnObserving: AnyObject, Sendable {
    func beginTurn(_ id: MotionTurnID)
    func speechStarted(_ id: MotionTurnID)
    func speechFinished(_ id: MotionTurnID)
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome)
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason)
}

@MainActor
final class ReplyTurnMulticaster: ReplyTurnObserving {
    private let observers: [any ReplyTurnObserving]
    init(_ observers: [any ReplyTurnObserving]) { self.observers = observers }

    func beginTurn(_ id: MotionTurnID) { observers.forEach { $0.beginTurn(id) } }
    func speechStarted(_ id: MotionTurnID) { observers.forEach { $0.speechStarted(id) } }
    func speechFinished(_ id: MotionTurnID) { observers.forEach { $0.speechFinished(id) } }
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
        observers.forEach { $0.generationFinished(id, outcome: outcome) }
    }
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {
        observers.forEach { $0.cancelTurn(id, reason: reason) }
    }
}
