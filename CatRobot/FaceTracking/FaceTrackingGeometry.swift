import Foundation

enum FaceTrackingGeometry {
    fileprivate static let facingYawHalfWidthDegrees: Double = 30
    fileprivate static let facingPitchLimitDegrees: Double = 25

    static func selectFace(_ faces: [FaceRectangle], yawCorrection: Double) -> FaceRectangle? {
        guard yawCorrection.isFinite, RobotPreferences.trackingYawCorrectionRange.contains(yawCorrection) else { return nil }
        // A face turned from the left-mounted lens toward screen center has negative Vision yaw.
        // Construct endpoints in degrees first to preserve inclusive fractional-degree bounds.
        let yawRange = ((-yawCorrection - facingYawHalfWidthDegrees) * .pi / 180)...((-yawCorrection + facingYawHalfWidthDegrees) * .pi / 180)
        // Filter before ranking so a nearer turned face cannot hide a facing face.
        return faces.lazy.filter { $0.isValid && $0.isFacingScreen(yawRange: yawRange) }.min { lhs, rhs in
            let leftDistance = pow(lhs.centerX - 0.5, 2) + pow(lhs.centerY - 0.5, 2)
            let rightDistance = pow(rhs.centerX - 0.5, 2) + pow(rhs.centerY - 0.5, 2)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
    }

    static func project(_ observation: FaceObservation, yawCorrection: Double, pose: FacePose) -> FacePose? {
        let fov = observation.horizontalFieldOfView, aspect = observation.aspectRatio
        guard pose.isFinite, fov.isFinite, fov > 0, fov < 180,
              aspect.isFinite, aspect > 0,
              let face = selectFace(observation.faces, yawCorrection: yawCorrection) else { return nil }
        // Upright front-camera frames are not mirrored. Rightward image motion is leftward
        // to the person facing the robot.
        let tangent = tan(fov * .pi / 360)
        // This robot mounts the front camera to the observer's left of screen center.
        // User-adjusted screen aim is applied BEFORE the deadband.
        let yawDelta = -atan((2 * face.centerX - 1) * tangent) * 180 / .pi - yawCorrection
        let pitchDelta = atan((2 * face.centerY - 1) * tangent / aspect) * 180 / .pi
        return .init(yaw: max(-45, min(45, pose.yaw + (abs(yawDelta) <= 4 ? 0 : yawDelta))),
                     pitch: max(-10, min(10, pose.pitch + (abs(pitchDelta) <= 4 ? 0 : pitchDelta))))
    }
}

private extension FaceRectangle {
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var area: Double { width * height }
    func isFacingScreen(yawRange: ClosedRange<Double>) -> Bool {
        guard let yawRadians, let pitchRadians,
              yawRadians.isFinite, pitchRadians.isFinite else { return false }
        // Head direction, not eye gaze.
        return yawRange.contains(yawRadians)
            && abs(pitchRadians) <= FaceTrackingGeometry.facingPitchLimitDegrees * .pi / 180
    }
    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
}

private extension FacePose {
    var isFinite: Bool { yaw.isFinite && pitch.isFinite }
}

/// STATUS angles are commanded logical angles, not external measurements of shaft angle.
struct FacePoseHistory {
    private struct Sample { let time: TimeInterval; let pose: FacePose }
    private var samples: [Sample] = []

    mutating func record(at time: TimeInterval, pose: FacePose) {
        guard time.isFinite, time >= 0, pose.isFinite,
              samples.last.map({ time >= $0.time }) ?? true else { return }
        if samples.last?.time == time { samples.removeLast() }
        samples.append(.init(time: time, pose: pose))
        // Retain one boundary sample; lookup still rejects every sample older than 1s.
        while samples.count > 2, samples[1].time < time - 1 { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    func pose(at time: TimeInterval, now: TimeInterval) -> FacePose? {
        guard time.isFinite, now.isFinite, time >= 0, time <= now,
              let upperIndex = samples.firstIndex(where: { $0.time >= time }) else { return nil }
        let upper = samples[upperIndex]
        guard upper.time <= now, now - upper.time <= 1 else { return nil }
        if upper.time == time { return upper.pose }
        guard upperIndex > 0 else { return nil }
        let lower = samples[upperIndex - 1]
        guard now - lower.time <= 1 else { return nil }
        let fraction = (time - lower.time) / (upper.time - lower.time)
        return .init(yaw: lower.pose.yaw + (upper.pose.yaw - lower.pose.yaw) * fraction,
                     pitch: lower.pose.pitch + (upper.pose.pitch - lower.pose.pitch) * fraction)
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}
