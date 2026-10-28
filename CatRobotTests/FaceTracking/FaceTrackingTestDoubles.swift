import Foundation
@testable import CatRobot

@MainActor
final class FakeFaceCaptureSource: FaceCaptureSource {
    struct Start { let generation: UUID }
    var authorization: FaceCameraAuthorization
    private(set) var requests = 0
    private(set) var starts: [Start] = []
    private(set) var stops = 0
    struct SnapshotRequest {
        let id: UUID
        let generation: UUID
        let completion: @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void
    }
    private(set) var snapshotRequests: [SnapshotRequest] = []
    private(set) var snapshotCancellations: [UUID] = []
    private var permission: CheckedContinuation<FaceCameraAuthorization, Never>?
    private let stream: AsyncStream<FaceCaptureEvent>
    private let continuation: AsyncStream<FaceCaptureEvent>.Continuation

    init(authorization: FaceCameraAuthorization = .authorized) {
        self.authorization = authorization
        let pair = AsyncStream<FaceCaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }
    func requestAuthorization() async -> FaceCameraAuthorization {
        requests += 1
        if authorization != .notDetermined { return authorization }
        return await withCheckedContinuation { permission = $0 }
    }
    func resolveAuthorization(_ result: FaceCameraAuthorization) {
        authorization = result
        permission?.resume(returning: result)
        permission = nil
    }
    func events() -> AsyncStream<FaceCaptureEvent> { stream }
    func start(generation: UUID) {
        starts.append(.init(generation: generation))
    }
    func stop() { stops += 1 }
    func emit(_ event: FaceCaptureEvent) { continuation.yield(event) }
    func requestSnapshot(id: UUID, generation: UUID,
                         completion: @escaping @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void) {
        snapshotRequests.append(.init(id: id, generation: generation, completion: completion))
    }
    func cancelSnapshot(id: UUID) { snapshotCancellations.append(id) }

}

@MainActor
final class FaceTrackingHarness {
    let clock = ManualRobotClock()
    let source: FakeFaceCaptureSource
    let link: RecordingRobotLink
    let preferences: RobotPreferences
    let motion = MotionControllerSpy()
    let coordinator: FaceTrackingCoordinator
    let defaults: UserDefaults
    var following: [RobotTrackingTarget] {
        motion.trackingStates.compactMap { if case let .following(target) = $0 { target } else { nil } }
    }
    init(authorization: FaceCameraAuthorization = .authorized, enabled: Bool = true,
         storedYawCorrection: Double? = nil) {
        defaults = UserDefaults(suiteName: "FaceTrackingTests.\(UUID().uuidString)")!
        if let storedYawCorrection { defaults.set(storedYawCorrection, forKey: "robot.trackingYawCorrection") }
        preferences = RobotPreferences(defaults: defaults)
        preferences.trackingEnabled = enabled
        source = FakeFaceCaptureSource(authorization: authorization)
        link = RecordingRobotLink(clock: clock)
        coordinator = FaceTrackingCoordinator(source: source, link: link, clock: clock,
                                              preferences: preferences, motion: motion)
    }
    func environment(visible: Bool = true, active: Bool = true, mode: RobotControlMode = .conversation,
                     phase: ConversationPhase = .listening) {
        coordinator.setEnvironment(conversationVisible: visible, sceneActive: active, mode: mode, phase: phase)
    }
    func frame(capturedAt: TimeInterval? = nil, generation: UUID? = nil,
               faces: [FaceRectangle] = [.init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)]) {
        guard let start = source.starts.last else { return }
        source.emit(.observation(.init(generation: generation ?? start.generation,
                                      capturedAt: capturedAt ?? clock.now, completedAt: clock.now,
                                      horizontalFieldOfView: 90, aspectRatio: 4.0 / 3, faces: faces)))
    }
    func advanceFresh(by duration: TimeInterval) async {
        var remaining = duration
        while remaining > 0.000_001 {
            let step = min(0.1, remaining)
            await clock.advance(by: step)
            link.emitStatus(link.snapshot.status!)
            await robotDrain()
            remaining -= step
        }
    }
}
