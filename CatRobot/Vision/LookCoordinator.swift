import Foundation
import Observation

@MainActor
@Observable
final class LookCoordinator: LookControlling {
    private(set) var isLooking = false
    @ObservationIgnored private let camera: any CameraSnapshotProviding
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var turn: MotionTurnID?
    @ObservationIgnored private var generating = false
    @ObservationIgnored private var deliveredSnapshotID: UUID?
    @ObservationIgnored private var request: Request?

    private struct Request {
        let id: UUID
        let task: Task<CameraSnapshot, Error>
    }

    init(camera: any CameraSnapshotProviding, clock: any RobotClock) {
        self.camera = camera
        self.clock = clock
    }
    deinit { request?.task.cancel() }

    func beginTurn(_ id: MotionTurnID) {
        reset()
        guard visible else { return }
        turn = id
        generating = true
    }

    func isCurrent(_ id: MotionTurnID) -> Bool { visible && turn == id && generating }

    func capture(for id: MotionTurnID) async throws -> CameraSnapshot {
        guard !Task.isCancelled else { throw CameraSnapshotError.cancelled }
        guard visible else { throw CameraSnapshotError.unavailable }
        guard isCurrent(id) else { throw CameraSnapshotError.cancelled }
        guard request == nil else { throw CameraSnapshotError.busy }
        let token = UUID()
        isLooking = true
        deliveredSnapshotID = nil
        let deadline = clock.now + 0.1
        let task = Task { [weak self, camera, clock] in
            try await clock.sleep(until: deadline)
            try Task.checkCancellation()
            guard self?.isCurrent(id) == true, self?.request?.id == token else { throw CameraSnapshotError.cancelled }
            let snapshot = try await camera.captureSnapshot()
            try Task.checkCancellation()
            guard self?.isCurrent(id) == true, self?.request?.id == token, camera.isSnapshotValid(snapshot) else { throw CameraSnapshotError.cancelled }
            return snapshot
        }
        request = .init(id: token, task: task)
        return try await withTaskCancellationHandler {
            do {
                let snapshot = try await task.value
                guard !Task.isCancelled, isCurrent(id), request?.id == token,
                      camera.isSnapshotValid(snapshot) else { throw CameraSnapshotError.cancelled }
                // Keep ownership and the indication until the Tool has resumed and validated the handoff.
                deliveredSnapshotID = snapshot.id
                return snapshot
            } catch {
                cancelRequest(token)
                if Task.isCancelled || error is CancellationError { throw CameraSnapshotError.cancelled }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(token) }
        }
    }

    func finishCapture(_ snapshot: CameraSnapshot, for id: MotionTurnID) -> Bool {
        let ownsResult = request != nil && deliveredSnapshotID == snapshot.id
        guard ownsResult, !Task.isCancelled, isCurrent(id), camera.isSnapshotValid(snapshot) else {
            if ownsResult { clearRequest() }
            return false
        }
        request = nil
        deliveredSnapshotID = nil
        return true
    }

    func speechStarted(_ id: MotionTurnID) {
        guard turn == id else { return }
        // Earlier streamed speech must not erase a look still awaiting camera/Tool handoff.
        if request == nil { isLooking = false }
    }
    func speechFinished(_ id: MotionTurnID) {}

    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
        guard turn == id else { return }
        generating = false
        clearRequest()
    }

    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {
        guard turn == id else { return }
        reset()
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if !visible { reset() }
    }

    func reset() {
        turn = nil
        generating = false
        clearRequest()
    }

    private func cancelRequest(_ token: UUID) {
        guard request?.id == token else { return }
        clearRequest()
    }

    private func clearRequest() {
        let task = request?.task
        request = nil
        deliveredSnapshotID = nil
        isLooking = false
        task?.cancel()
    }
}
