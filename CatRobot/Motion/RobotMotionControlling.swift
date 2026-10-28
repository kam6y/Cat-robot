import Foundation

enum RobotGesture: String, CaseIterable, Sendable {
    case nod, shake, tilt
    case lookUp = "look_up", lookDown = "look_down", lookAtUser = "look_at_user", center
}
enum RobotIntensity: String, CaseIterable, Sendable { case small, medium, large }

struct RobotMotionRequest: Equatable, Sendable {
    let gesture: RobotGesture
    let intensity: RobotIntensity
    let repeats: Int

    var amplitudeDeci: UInt8 {
        let amplitudes: [UInt8]
        switch gesture {
        case .nod: amplitudes = [50, 100, 150]
        case .shake: amplitudes = [80, 150, 250]
        case .tilt: amplitudes = [80, 120, 150]
        case .lookUp, .lookDown: amplitudes = [80, 140, 200]
        case .lookAtUser, .center: return 0
        }
        switch intensity { case .small: return amplitudes[0]; case .medium: return amplitudes[1]; case .large: return amplitudes[2] }
    }
}

enum MotionReservationResult: Equatable, Sendable {
    case reserved(cycles: Int), unavailable, invalidArguments, budgetExceeded, invalidated
}
enum MotionGenerationOutcome: Sendable { case success, failed }
enum MotionCancellationReason: Sendable { case fallback, playbackCancelled, playbackFailed, newConversation, userStop, linkLost, background }

struct RobotTrackingTarget: Equatable, Sendable {
    let yaw: Double
    let pitch: Double
    let validUntil: TimeInterval
}

enum RobotTrackingState: Equatable, Sendable {
    case disabled, searching, following(RobotTrackingTarget), holding, returnToCenter
}

@MainActor
protocol RobotMotionControlling: ReplyTurnObserving {
    func reserve(_ request: RobotMotionRequest, for id: MotionTurnID) -> MotionReservationResult
    func setControlMode(_ mode: RobotControlMode)
    func setConversationPhase(_ phase: ConversationPhase)
    func utteranceConfirmed()
    func stopAll(reason: MotionCancellationReason)
    func setTrackingState(_ state: RobotTrackingState)
    func setAutomaticMotionSuspended(_ suspended: Bool)
}

@MainActor
final class NoopRobotMotionController: RobotMotionControlling {
    nonisolated init() {}
    func beginTurn(_ id: MotionTurnID) {}
    func reserve(_ request: RobotMotionRequest, for id: MotionTurnID) -> MotionReservationResult { .unavailable }
    func speechStarted(_ id: MotionTurnID) {}
    func speechFinished(_ id: MotionTurnID) {}
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {}
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {}
    func setControlMode(_ mode: RobotControlMode) {}
    func setConversationPhase(_ phase: ConversationPhase) {}
    func utteranceConfirmed() {}
    func stopAll(reason: MotionCancellationReason) {}
    func setTrackingState(_ state: RobotTrackingState) {}
    func setAutomaticMotionSuspended(_ suspended: Bool) {}
}

@MainActor
protocol RobotRandomSource: AnyObject { func next(in range: ClosedRange<Double>) -> Double }

@MainActor
final class SystemRobotRandomSource: RobotRandomSource {
    func next(in range: ClosedRange<Double>) -> Double { Double.random(in: range) }
}

extension RobotMotionStrength {
    var velocityLimits: RobotLimits {
        let yaw: UInt16, pitch: UInt16
        switch self {
        case .calm: (yaw, pitch) = (600, 500)
        case .standard: (yaw, pitch) = (1_200, 1_000)
        case .active: (yaw, pitch) = (1_800, 1_200)
        }
        return .init(yawVelocityDeci: yaw, pitchVelocityDeci: pitch, yawAngleDeci: 0, pitchAngleDeci: 0)
    }

    func matches(_ limits: RobotLimits) -> Bool {
        limits.yawVelocityDeci == velocityLimits.yawVelocityDeci && limits.pitchVelocityDeci == velocityLimits.pitchVelocityDeci
    }
}
