import Foundation

/// A rectangle in the raw, unmirrored image; lower-left origin, normalized to 0...1.
struct FaceRectangle: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum FaceLandscapeOrientation: Equatable, Sendable {
    case landscapeLeft, landscapeRight
}

/// Images never cross the capture boundary. Times use RobotClock's monotonic domain.
struct FaceObservation: Sendable {
    let generation: UUID
    let capturedAt: TimeInterval
    let completedAt: TimeInterval
    let orientation: FaceLandscapeOrientation
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
    func start(generation: UUID, orientation: FaceLandscapeOrientation)
    func stop()
}
