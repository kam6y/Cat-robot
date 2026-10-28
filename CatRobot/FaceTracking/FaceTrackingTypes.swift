import Foundation

/// An upright, unmirrored rectangle with the front camera fixed to the screen's left.
/// Lower-left origin, normalized to 0...1; the adapter normalizes sensor mounting.
struct FaceRectangle: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Face events contain no image. Times use RobotClock's monotonic domain.
struct FaceObservation: Sendable {
    let generation: UUID
    let capturedAt: TimeInterval
    let completedAt: TimeInterval
    let horizontalFieldOfView: Double
    let aspectRatio: Double
    let faces: [FaceRectangle]
}

struct FacePose: Equatable, Sendable {
    let yaw: Double
    let pitch: Double
}

enum FaceCameraAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

enum FaceCaptureEvent: Sendable {
    case observation(FaceObservation)
    case unavailable(generation: UUID)
    case interrupted(generation: UUID)
}

@MainActor
protocol FaceCaptureSource: AnyObject {
    var authorization: FaceCameraAuthorization { get }
    func requestAuthorization() async -> FaceCameraAuthorization
    func events() -> AsyncStream<FaceCaptureEvent>
    func start(generation: UUID)
    func stop()
    func requestSnapshot(id: UUID, generation: UUID,
                         completion: @escaping @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void)
    func cancelSnapshot(id: UUID)
}

extension FaceCaptureSource {
    func requestSnapshot(id: UUID, generation: UUID,
                         completion: @escaping @Sendable (Result<CameraSnapshot, CameraSnapshotError>) -> Void) {
        completion(.failure(.unavailable))
    }
    func cancelSnapshot(id: UUID) {}
}

extension ConversationPhase {
    /// Classification and clarification are ongoing conversation, not camera ownership changes.
    var permitsFaceTracking: Bool {
        switch self {
        case .idle, .listening, .classifying, .clarifying, .thinking, .speaking: true
        case .preparing, .paused, .failed: false
        }
    }
}

/// The app-level inputs that decide whether conversation capture may run. Face tracking
/// and explicit image requests evaluate the same rule from the same values.
struct FaceCaptureEnvironment: Equatable {
    var conversationVisible = false
    var sceneActive = false
    var mode: RobotControlMode = .conversation
    var phase: ConversationPhase = .paused

    var permitsCapture: Bool {
        conversationVisible && sceneActive && mode == .conversation && phase.permitsFaceTracking
    }
}

extension ProcessInfo.ThermalState {
    /// Serious and critical heat suspend camera work; nominal and fair do not.
    var suspendsFaceCapture: Bool { self == .serious || self == .critical }
}
