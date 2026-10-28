import Foundation
import Observation

/// Shares one physical capture between tracking and explicitly requested images.
@MainActor
@Observable
final class ConversationCamera: FaceCaptureSource, CameraSnapshotProviding {
    private(set) var authorization: FaceCameraAuthorization
    private(set) var permissionInProgress = false
    @ObservationIgnored private let source: any FaceCaptureSource
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private let stream: AsyncStream<FaceCaptureEvent>
    @ObservationIgnored private let continuation: AsyncStream<FaceCaptureEvent>.Continuation
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<FaceCameraAuthorization, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var trackingGeneration: UUID?
    @ObservationIgnored private var physicalGeneration: UUID?
    @ObservationIgnored private var validSnapshotID: UUID?
    @ObservationIgnored private var environmentPermitsCapture = false
    @ObservationIgnored private var tooHot = false
    @ObservationIgnored private var captureFailed = false
    @ObservationIgnored private var isShutdown = false
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<CameraSnapshot, Error>
    }

    init(source: any FaceCaptureSource, clock: any RobotClock) {
        self.source = source
        self.clock = clock
        authorization = source.authorization
        let channel = FaceCapturePolicy.makeEventStream()
        stream = channel.stream
        continuation = channel.continuation
        let events = source.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    deinit { eventTask?.cancel(); timeoutTask?.cancel(); permissionTask?.cancel() }

    func events() -> AsyncStream<FaceCaptureEvent> { stream }

    func requestAuthorization() async -> FaceCameraAuthorization {
        guard !isShutdown else { return authorization }
        let task: Task<FaceCameraAuthorization, Never>
        if let existing = permissionTask { task = existing }
        else {
            permissionInProgress = true
            task = Task { [source] in await source.requestAuthorization() }
            permissionTask = task
        }
        let result = await task.value
        authorization = result
        permissionInProgress = false
        permissionTask = nil
        reconcile()
        return result
    }

    func refreshAuthorization() {
        authorization = source.authorization
        if authorization != .authorized { revokeSnapshots(.permissionRequired) }
        reconcile()
    }

    func setEnvironment(conversationVisible: Bool, sceneActive: Bool, mode: RobotControlMode,
                        phase: ConversationPhase) {
        environmentPermitsCapture = FaceCaptureEnvironment(conversationVisible: conversationVisible,
                                                           sceneActive: sceneActive, mode: mode,
                                                           phase: phase).permitsCapture
        refreshAuthorization()
        if !eligible { revokeSnapshots(.cancelled) }
        reconcile()
    }

    func setThermalState(_ state: ProcessInfo.ThermalState) {
        tooHot = state.suspendsFaceCapture
        if tooHot { revokeSnapshots(.cancelled) }
        reconcile()
    }

    func start(generation: UUID) {
        trackingGeneration = generation
        captureFailed = false
        reconcile()
    }

    /// Ends tracking demand only; a pending look still owns capture.
    func stop() {
        trackingGeneration = nil
        reconcile()
    }

    func captureSnapshot() async throws -> CameraSnapshot {
        guard !Task.isCancelled else { throw CameraSnapshotError.cancelled }
        refreshAuthorization()
        guard authorization == .authorized else { throw CameraSnapshotError.permissionRequired }
        guard eligible else { throw CameraSnapshotError.unavailable }
        guard pending == nil else { throw CameraSnapshotError.busy }
        let id = UUID()
        validSnapshotID = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CameraSnapshotError.cancelled)
                    return
                }
                pending = .init(id: id, continuation: continuation)
                captureFailed = false
                reconcile()
                guard let generation = physicalGeneration else {
                    finishPending(.failure(.unavailable), id: id)
                    return
                }
                let deadline = clock.now + 3
                timeoutTask = Task { [weak self, clock] in
                    do { try await clock.sleep(until: deadline) } catch { return }
                    self?.finishPending(.failure(.timedOut), id: id)
                }
                source.requestSnapshot(id: id, generation: generation) { [weak self] result in
                    Task { @MainActor [weak self] in self?.receivedSnapshot(result, id: id, generation: generation) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPending(.failure(.cancelled), id: id) }
        }
    }

    func isSnapshotValid(_ snapshot: CameraSnapshot) -> Bool {
        validSnapshotID == snapshot.id && eligible && source.authorization == .authorized
            && CameraSnapshot.isFresh(capturedAt: snapshot.capturedAt, now: clock.now)
    }

    func shutdown() {
        isShutdown = true
        trackingGeneration = nil
        revokeSnapshots(.cancelled)
        stopPhysical()
        eventTask?.cancel()
        eventTask = nil
        continuation.finish()
    }

    private var eligible: Bool {
        !isShutdown && environmentPermitsCapture && !tooHot && authorization == .authorized
    }

    private func reconcile() {
        guard eligible, !captureFailed, trackingGeneration != nil || pending != nil else {
            stopPhysical()
            return
        }
        guard physicalGeneration == nil else { return }
        let generation = UUID()
        physicalGeneration = generation
        source.start(generation: generation)
    }

    private func stopPhysical() {
        guard physicalGeneration != nil else { return }
        physicalGeneration = nil
        source.stop()
    }

    /// Global invalidation: every handed-out image stops being valid and any pending
    /// request fails. Request-specific completion and cancellation keep using
    /// finishPending(_:id:) directly so a late cancel cannot revoke a delivered image.
    private func revokeSnapshots(_ error: CameraSnapshotError) {
        validSnapshotID = nil
        finishPending(.failure(error))
    }

    private func finishPending(_ result: Result<CameraSnapshot, CameraSnapshotError>, id: UUID? = nil) {
        guard let request = pending, id == nil || id == request.id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        source.cancelSnapshot(id: request.id)
        reconcile()
        request.continuation.resume(with: result.mapError { $0 as Error })
    }

    private func receivedSnapshot(_ result: Result<CameraSnapshot, CameraSnapshotError>, id: UUID, generation: UUID) {
        guard pending?.id == id, physicalGeneration == generation else { return }
        if case let .success(snapshot) = result {
            guard eligible, snapshot.generation == generation,
                  CameraSnapshot.isFresh(capturedAt: snapshot.capturedAt, now: clock.now),
                  snapshot.image.width > 0, snapshot.image.height > 0,
                  max(snapshot.image.width, snapshot.image.height) <= 1024 else {
                finishPending(.failure(.unavailable), id: id)
                return
            }
        }
        if case let .success(snapshot) = result { validSnapshotID = snapshot.id }
        finishPending(result, id: id)
    }

    private func receive(_ event: FaceCaptureEvent) {
        switch event {
        case let .observation(observation):
            guard observation.generation == physicalGeneration, let generation = trackingGeneration else { return }
            continuation.yield(.observation(.init(generation: generation, capturedAt: observation.capturedAt,
                completedAt: observation.completedAt,
                horizontalFieldOfView: observation.horizontalFieldOfView, aspectRatio: observation.aspectRatio,
                faces: observation.faces)))
        case let .unavailable(generation), let .interrupted(generation):
            guard generation == physicalGeneration else { return }
            if let trackingGeneration {
                if case .interrupted = event { continuation.yield(.interrupted(generation: trackingGeneration)) }
                else { continuation.yield(.unavailable(generation: trackingGeneration)) }
            }
            captureFailed = true
            revokeSnapshots(.unavailable)
            stopPhysical()
        }
    }
}
