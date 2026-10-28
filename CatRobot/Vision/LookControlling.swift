import Foundation

@MainActor
protocol LookControlling: ReplyTurnObserving {
    var isLooking: Bool { get }
    func capture(for id: MotionTurnID) async throws -> CameraSnapshot
    /// Validate and release the pending image at the Tool return boundary.
    func finishCapture(_ snapshot: CameraSnapshot, for id: MotionTurnID) -> Bool
    func setVisible(_ visible: Bool)
    func reset()
}

@MainActor
final class NoopLookController: LookControlling {
    nonisolated init() {}
    var isLooking: Bool { false }
    func capture(for id: MotionTurnID) async throws -> CameraSnapshot { throw CameraSnapshotError.unavailable }
    func finishCapture(_ snapshot: CameraSnapshot, for id: MotionTurnID) -> Bool { false }
    func setVisible(_ visible: Bool) {}
    func reset() {}
    func beginTurn(_ id: MotionTurnID) {}
    func speechStarted(_ id: MotionTurnID) {}
    func speechFinished(_ id: MotionTurnID) {}
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {}
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {}
}
