import CoreGraphics
import Foundation

/// A requested, upright image with no source file or metadata attached.
struct CameraSnapshot: Sendable {
    let id = UUID()
    let generation: UUID
    let capturedAt: TimeInterval
    let image: CGImage

    static func isFresh(capturedAt: TimeInterval, now: TimeInterval) -> Bool {
        capturedAt.isFinite && now.isFinite && capturedAt >= 0 && capturedAt <= now
            && now - capturedAt < FaceCapturePolicy.imageFreshness - 0.000_001
    }
}

enum CameraSnapshotError: Error, Equatable, Sendable {
    case permissionRequired, unavailable, busy, timedOut, cancelled
}

@MainActor
protocol CameraSnapshotProviding: AnyObject {
    func captureSnapshot() async throws -> CameraSnapshot
    /// Recheck the image lease after actor hops, including after normal capture has stopped.
    func isSnapshotValid(_ snapshot: CameraSnapshot) -> Bool
}
