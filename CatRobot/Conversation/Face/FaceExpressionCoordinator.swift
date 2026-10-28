import Foundation
import Observation

@MainActor
@Observable
final class FaceExpressionCoordinator: FaceExpressionControlling {
    private struct Turn {
        let id: MotionTurnID
        var pending: FaceExpressionRequest?
        var generationFinished = false
        var speechStarted = false
        var speechFinished = false
    }

    private(set) var heldExpression: FaceExpression?
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var phase: ConversationPhase = .paused
    @ObservationIgnored private var turn: Turn?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var expiryToken: UUID?

    init(clock: any RobotClock) { self.clock = clock }
    deinit { expiryTask?.cancel() }

    func beginTurn(_ id: MotionTurnID) {
        reset()
        guard visible, phaseAllowsTurn else { return }
        turn = Turn(id: id)
    }

    func reserve(_ request: FaceExpressionRequest, for id: MotionTurnID) -> FaceExpressionReservationResult {
        guard visible else { return .unavailable }
        guard let current = turn, current.id == id,
              !current.generationFinished, !current.speechFinished else { return .invalidated }
        if current.speechStarted {
            show(request)
        } else {
            turn?.pending = request
        }
        return .reserved
    }

    func speechStarted(_ id: MotionTurnID) {
        guard let current = turn, current.id == id,
              !current.speechStarted, !current.speechFinished else { return }
        turn?.speechStarted = true
        turn?.pending = nil
        if let request = current.pending { show(request) }
    }

    func speechFinished(_ id: MotionTurnID) {
        guard turn?.id == id else { return }
        turn?.speechFinished = true
        turn?.pending = nil
        // An already visible expression keeps its original deadline.
    }

    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
        guard turn?.id == id else { return }
        switch outcome {
        case .success: turn?.generationFinished = true
        case .failed: reset()
        }
    }

    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {
        guard turn?.id == id else { return }
        reset()
    }

    func setConversationPhase(_ phase: ConversationPhase) {
        self.phase = phase
        if !phaseAllowsTurn { reset() }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible { reset() }
    }

    func reset() {
        turn = nil
        clearHeld()
    }

    private var phaseAllowsTurn: Bool {
        switch phase {
        case .listening, .classifying, .clarifying, .thinking, .speaking: true
        case .idle, .preparing, .paused, .failed: false
        }
    }

    private func show(_ request: FaceExpressionRequest) {
        clearHeld()
        heldExpression = request.expression
        let token = UUID()
        expiryToken = token
        let deadline = clock.now + TimeInterval(request.holdSeconds)
        expiryTask = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(until: deadline) }
            catch { return }
            guard !Task.isCancelled, let self, self.expiryToken == token else { return }
            self.clearHeld()
        }
    }

    private func clearHeld() {
        expiryTask?.cancel()
        expiryTask = nil
        expiryToken = nil
        heldExpression = nil
    }
}
