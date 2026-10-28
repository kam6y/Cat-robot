import Foundation

struct FaceCaptureFormat: Sendable {
    struct FrameRateRange: Sendable {
        let minimum: Double
        let maximum: Double
    }
    let id: Int
    let width: Int
    let height: Int
    let horizontalFieldOfView: Double
    let frameRateRanges: [FrameRateRange]
}

struct FaceCaptureConfiguration: Sendable {
    let formatID: Int
    let width: Int
    let height: Int
    let frameDuration: TimeInterval
    let horizontalFieldOfView: Double
}

struct FaceCaptureTimeMapping: Sendable {
    private let hostAnchor: TimeInterval
    private let robotAnchor: TimeInterval

    init?(hostAnchor: TimeInterval, robotAnchor: TimeInterval) {
        guard hostAnchor.isFinite, hostAnchor >= 0, robotAnchor.isFinite, robotAnchor >= 0 else { return nil }
        self.hostAnchor = hostAnchor
        self.robotAnchor = robotAnchor
    }

    func robotTime(hostTime: TimeInterval) -> TimeInterval? {
        guard hostTime.isFinite, hostTime >= 0 else { return nil }
        let result = robotAnchor + (hostTime - hostAnchor)
        return result.isFinite && result >= 0 ? result : nil
    }
}

struct FaceCaptureOptics: Sendable {
    let fieldOfView: Double
    let aspectRatio: Double
}

enum FaceCapturePolicy {
    /// An observation or image older than this no longer describes where the face is.
    /// Tracking targets expire and snapshot leases end at this age.
    static let imageFreshness: TimeInterval = 0.4
    // Reduce camera/Vision work while retaining a cadence within the 400ms image freshness limit.
    // Actual frames still obey the 5fps ceiling, with headroom for timestamp rounding.
    private static let configuredFrameRate = 3.0
    private static let minimumActualInterval = 0.2

    static func uprightOptics(nativeFieldOfView: Double, nativeAspect: Double,
                               rotationDegrees: Double) -> FaceCaptureOptics? {
        guard nativeFieldOfView.isFinite, nativeFieldOfView > 0, nativeFieldOfView < 180,
              nativeAspect.isFinite, nativeAspect > 0,
              [0.0, 90, 180, 270].contains(rotationDegrees) else { return nil }
        if rotationDegrees == 90 || rotationDegrees == 270 {
            return .init(fieldOfView: 2 * atan(tan(nativeFieldOfView * .pi / 360) / nativeAspect) * 180 / .pi,
                         aspectRatio: 1 / nativeAspect)
        }
        return .init(fieldOfView: nativeFieldOfView, aspectRatio: nativeAspect)
    }

    static func select(_ formats: [FaceCaptureFormat]) -> FaceCaptureConfiguration? {
        let candidates = formats.compactMap { format -> (FaceCaptureConfiguration, Double)? in
            guard format.width > 0, format.height > 0,
                  format.horizontalFieldOfView.isFinite,
                  format.horizontalFieldOfView > 0, format.horizontalFieldOfView < 180,
                  format.frameRateRanges.contains(where: {
                      $0.minimum.isFinite && $0.maximum.isFinite && $0.minimum > 0 &&
                      $0.minimum <= configuredFrameRate && $0.maximum >= configuredFrameRate
                  }) else { return nil }
            // AVCaptureVideoDataOutput requires the EXACT native aspect; rounded sizes can throw.
            let divisor = gcd(format.width, format.height)
            let unitWidth = format.width / divisor, unitHeight = format.height / divisor
            var scale = min(divisor, 640 / unitWidth, 480 / unitHeight)
            if unitWidth % 2 != 0 || unitHeight % 2 != 0 { scale -= scale % 2 }
            guard scale > 0 else { return nil }
            return (.init(formatID: format.id, width: unitWidth * scale, height: unitHeight * scale,
                          frameDuration: 1 / configuredFrameRate, horizontalFieldOfView: format.horizontalFieldOfView),
                    Double(format.width) * Double(format.height))
        }
        return candidates.min {
            let area0 = $0.0.width * $0.0.height, area1 = $1.0.width * $1.0.height
            if area0 != area1 { return area0 > area1 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.formatID < $1.0.formatID
        }?.0
    }

    static func acceptsFrame(width: Int, height: Int, at: TimeInterval,
                             previous: TimeInterval?, configuration: FaceCaptureConfiguration) -> Bool {
        guard width > 0, width <= 640, height > 0, height <= 480,
              width == configuration.width, height == configuration.height,
              configuration.frameDuration.isFinite, configuration.frameDuration >= minimumActualInterval,
              at.isFinite, at >= 0 else { return false }
        guard let previous else { return true }
        return previous.isFinite && previous >= 0 && at - previous >= minimumActualInterval - 0.000_001
    }

    static func makeEventStream() -> (stream: AsyncStream<FaceCaptureEvent>,
                                     continuation: AsyncStream<FaceCaptureEvent>.Continuation) {
        AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    private static func gcd(_ x: Int, _ y: Int) -> Int {
        var a = x, b = y
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
