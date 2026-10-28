import Foundation
import Observation

enum RobotMotionStrength: String, CaseIterable, Sendable {
    case calm, standard, active
}

@MainActor
@Observable
final class RobotPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    /// The screen-aim correction for the left-mounted front camera. The geometry (nonisolated)
    /// validates against the same range the settings UI offers.
    nonisolated static let defaultTrackingYawCorrection = 8.5
    nonisolated static let trackingYawCorrectionRange = 0.0...20.0
    nonisolated static let trackingYawCorrectionStep = 0.5
    private static let trackingYawCorrectionKey = "robot.trackingYawCorrection"
    private var storedTrackingYawCorrection: Double

    var trackingYawCorrection: Double {
        get { storedTrackingYawCorrection }
        set {
            storedTrackingYawCorrection = Self.normalizedTrackingYawCorrection(newValue)
            defaults.set(storedTrackingYawCorrection, forKey: Self.trackingYawCorrectionKey)
        }
    }

    private static func normalizedTrackingYawCorrection(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTrackingYawCorrection }
        let bounded = min(trackingYawCorrectionRange.upperBound, max(trackingYawCorrectionRange.lowerBound, value))
        return (bounded / trackingYawCorrectionStep).rounded() * trackingYawCorrectionStep
    }

    var selectedDevice: RobotDevice? {
        didSet {
            defaults.set(selectedDevice?.id.uuidString, forKey: "robot.device.id")
            defaults.set(selectedDevice?.name, forKey: "robot.device.name")
        }
    }
    var strength: RobotMotionStrength {
        didSet { defaults.set(strength.rawValue, forKey: "robot.strength") }
    }
    var trackingEnabled: Bool {
        didSet { defaults.set(trackingEnabled, forKey: "robot.trackingEnabled") }
    }

    var idleEnabled: Bool {
        didSet { defaults.set(idleEnabled, forKey: "robot.idleEnabled") }
    }

    /// PWM may be released while resting only when neither idle motion nor tracking can
    /// reattach it with a visible jump. Checked at scheduling, task start, and BLE admission.
    var allowsIdlePowerOff: Bool { !idleEnabled && !trackingEnabled }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedTrackingYawCorrection = Self.normalizedTrackingYawCorrection(
            defaults.object(forKey: Self.trackingYawCorrectionKey) as? Double ?? Self.defaultTrackingYawCorrection)
        if let rawID = defaults.string(forKey: "robot.device.id"), let id = UUID(uuidString: rawID) {
            selectedDevice = RobotDevice(id: id,
                                         name: defaults.string(forKey: "robot.device.name") ?? "CatRobot",
                                         rssi: nil)
        } else {
            selectedDevice = nil
        }
        strength = defaults.string(forKey: "robot.strength").flatMap(RobotMotionStrength.init) ?? .standard
        trackingEnabled = defaults.object(forKey: "robot.trackingEnabled") == nil
            ? true : defaults.bool(forKey: "robot.trackingEnabled")
        idleEnabled = defaults.object(forKey: "robot.idleEnabled") == nil
            ? true : defaults.bool(forKey: "robot.idleEnabled")
    }
}
