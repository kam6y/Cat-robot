import Foundation
import Observation

enum FaceTrackingStatus: Equatable, Sendable {
    case off, permissionRequired, waitingForRobot, paused, searching, tracking, pausedForHeat, unavailable

    var text: String {
        switch self {
        case .off: "オフ"
        case .permissionRequired: "カメラの許可が必要です"
        case .waitingForRobot: "ハードの接続待ち"
        case .paused: "会話画面で追尾します"
        case .searching: "顔を探しています"
        case .tracking: "顔を追っています"
        case .pausedForHeat: "熱のため一時停止"
        case .unavailable: "カメラを使用できません"
        }
    }
}

@MainActor
@Observable
final class FaceTrackingCoordinator {
    private(set) var status: FaceTrackingStatus = .off
    var isEnabled: Bool { preferences.trackingEnabled }
    var isAwaitingPermission: Bool { permissionTask != nil }
    var needsSystemSettings: Bool { source.authorization == .denied || source.authorization == .restricted }
    private let source: any FaceCaptureSource
    private let link: any RobotLinkControlling
    private let clock: any RobotClock
    private let preferences: RobotPreferences
    private let motion: any RobotMotionControlling
    @ObservationIgnored private var environment = FaceCaptureEnvironment()
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<FaceCameraAuthorization, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeDeadline: TimeInterval?
    @ObservationIgnored private var poseHistory = FacePoseHistory()
    @ObservationIgnored private var pending: FaceObservation?
    @ObservationIgnored private var lastObservationAt: TimeInterval?
    @ObservationIgnored private var lastFaceAt: TimeInterval?
    private var returnRequested: Bool { motionState == .returnToCenter }
    @ObservationIgnored private var motionState: RobotTrackingState?
    @ObservationIgnored private var captureFailed = false
    @ObservationIgnored private var wasEligible = false
    @ObservationIgnored private var thermallySuspended = false
    @ObservationIgnored private var coolUntil: TimeInterval?

    init(source: any FaceCaptureSource, link: any RobotLinkControlling, clock: any RobotClock,
         preferences: RobotPreferences, motion: any RobotMotionControlling) {
        self.source = source
        self.link = link
        self.clock = clock
        self.preferences = preferences
        self.motion = motion
        connectionID = link.snapshot.connectionID
        let events = source.events(), updates = link.updates()
        sourceTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
        linkTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
        }
    }

    deinit { sourceTask?.cancel(); linkTask?.cancel(); wakeTask?.cancel(); permissionTask?.cancel() }

    func setEnabled(_ enabled: Bool) async {
        preferences.trackingEnabled = enabled
        captureFailed = false
        reconcile()
        if enabled { await requestPermissionForConversation() }
    }

    func requestPermissionForConversation() async {
        guard preferences.trackingEnabled else { return }
        if source.authorization == .notDetermined {
            let task: Task<FaceCameraAuthorization, Never>
            if let existing = permissionTask { task = existing }
            else {
                task = Task { [source] in await source.requestAuthorization() }
                permissionTask = task
            }
            let result = await task.value
            permissionTask = nil
            if result == .denied || result == .restricted { preferences.trackingEnabled = false }
        }
        reconcile()
    }

    func setEnvironment(conversationVisible: Bool, sceneActive: Bool, mode: RobotControlMode, phase: ConversationPhase) {
        environment = .init(conversationVisible: conversationVisible, sceneActive: sceneActive, mode: mode, phase: phase)
        reconcile()
    }

    func setControlMode(_ mode: RobotControlMode) {
        environment.mode = mode
        reconcile()
    }

    func setThermalState(_ state: ProcessInfo.ThermalState) {
        if state.suspendsFaceCapture {
            coolUntil = nil
            if !thermallySuspended {
                thermallySuspended = true
                motion.setAutomaticMotionSuspended(true)
            }
        } else if thermallySuspended, coolUntil == nil { coolUntil = clock.now + 10 }
        reconcile()
    }

    func resetConversation() {
        stopCapture()
        captureFailed = false
        reconcile()
    }

    private var linkReady: Bool { link.snapshot.isMotionReady(at: clock.now) }

    private func reconcile() {
        if connectionID != link.snapshot.connectionID {
            connectionID = link.snapshot.connectionID
            stopCapture()
            captureFailed = false
        }
        if let coolUntil, clock.now + 0.000_001 >= coolUntil {
            self.coolUntil = nil
            thermallySuspended = false
            motion.setAutomaticMotionSuspended(false)
        }
        if needsSystemSettings, preferences.trackingEnabled { preferences.trackingEnabled = false }
        let eligible = preferences.trackingEnabled && environment.permitsCapture && !thermallySuspended
            && source.authorization == .authorized && linkReady
        if eligible && !wasEligible { captureFailed = false }
        wasEligible = eligible
        if !eligible || captureFailed {
            stopCapture()
            if !preferences.trackingEnabled { status = needsSystemSettings ? .permissionRequired : .off }
            else if thermallySuspended { status = .pausedForHeat }
            else if source.authorization != .authorized { status = .permissionRequired }
            else if !environment.permitsCapture { status = .paused }
            else if !linkReady { status = .waitingForRobot }
            else { status = .unavailable }
        } else {
            if generation == nil {
                let id = UUID()
                generation = id
                setMotionState(.searching)
                source.start(generation: id)
            }
            recordCurrentPose()
            processPending()
            updateLoss()
        }
        scheduleWake()
    }

    private func stopCapture() {
        if generation != nil { generation = nil; source.stop() }
        pending = nil
        lastObservationAt = nil
        lastFaceAt = nil
        poseHistory.reset()
        setMotionState(.disabled)
    }

    private func recordCurrentPose() {
        guard let received = link.snapshot.statusReceivedAt, let pose = link.snapshot.status else { return }
        poseHistory.record(at: received, pose: .init(yaw: Double(pose.yawDeci) / 10, pitch: Double(pose.pitchDeci) / 10))
    }

    private func receive(_ event: FaceCaptureEvent) {
        switch event {
        case let .observation(observation):
            reconcile()
            guard observation.generation == generation,
                  observation.capturedAt.isFinite, observation.completedAt.isFinite,
                  observation.capturedAt >= 0, observation.capturedAt <= observation.completedAt,
                  observation.completedAt <= clock.now + 0.000_001,
                  clock.now - observation.capturedAt < FaceCapturePolicy.imageFreshness - 0.000_001,
                  lastObservationAt.map({ observation.capturedAt > $0 }) ?? true else { return }
            lastObservationAt = observation.capturedAt
            pending = observation
            if FaceTrackingGeometry.selectFace(observation.faces, yawCorrection: preferences.trackingYawCorrection) == nil {
                pending = nil
                if lastFaceAt != nil, !returnRequested { setMotionState(.holding) }
            } else { processPending() }
            updateLoss()
            scheduleWake()
        case let .unavailable(id), let .interrupted(id):
            guard id == generation else { return }
            captureFailed = true
            reconcile()
        }
    }

    private func processPending() {
        guard let observation = pending else { return }
        guard clock.now - observation.capturedAt < FaceCapturePolicy.imageFreshness - 0.000_001 else { pending = nil; return }
        guard let pose = poseHistory.pose(at: observation.capturedAt, now: clock.now) else { return }
        pending = nil
        guard let target = FaceTrackingGeometry.project(
            observation, yawCorrection: preferences.trackingYawCorrection, pose: pose) else { return }
        lastFaceAt = observation.capturedAt
        setMotionState(.following(.init(yaw: target.yaw, pitch: target.pitch,
                                        validUntil: observation.capturedAt + FaceCapturePolicy.imageFreshness)))
    }

    private func updateLoss() {
        guard generation != nil else { return }
        guard let lastFaceAt else { status = .searching; return }
        // A fresh detected face waiting for bracketing STATUS is not face loss.
        // The old target still expires normally; only a newly projected target can send a MOVE.
        if let pending, clock.now - pending.capturedAt < FaceCapturePolicy.imageFreshness - 0.000_001 {
            status = .tracking
            return
        }
        if clock.now - lastFaceAt >= 10 - 0.000_001 {
            if !returnRequested { setMotionState(.returnToCenter) }
            status = .searching
        } else if case let .following(target) = motionState, target.validUntil > clock.now + 0.000_001 {
            status = .tracking
        } else {
            setMotionState(.holding)
            status = .searching
        }
    }

    private func setMotionState(_ state: RobotTrackingState) {
        guard state != motionState else { return }
        motionState = state
        motion.setTrackingState(state)
    }

    /// One wake for the nearest freshness/loss/cooling boundary; no background polling loop.
    private func scheduleWake() {
        var deadlines: [TimeInterval] = []
        if let coolUntil { deadlines.append(coolUntil) }
        if generation != nil {
            if let received = link.snapshot.statusReceivedAt { deadlines.append(received + RobotLinkSnapshot.statusFreshness) }
            if let lastFaceAt {
                deadlines.append(lastFaceAt + FaceCapturePolicy.imageFreshness)
                if !returnRequested { deadlines.append(lastFaceAt + 10) }
            }
            if let pending { deadlines.append(pending.capturedAt + FaceCapturePolicy.imageFreshness) }
        }
        let next = deadlines.filter { $0 > clock.now + 0.000_001 }.min()
        guard next != wakeDeadline else { return }
        wakeTask?.cancel()
        wakeTask = nil
        wakeDeadline = next
        guard let next else { return }
        wakeTask = Task { [weak self, clock] in
            do { try await clock.sleep(until: next) } catch { return }
            guard let self, self.wakeDeadline == next else { return }
            self.wakeTask = nil
            self.wakeDeadline = nil
            self.reconcile()
        }
    }
}
