import Foundation
import Observation

enum RobotMotionStrength: String, CaseIterable, Sendable {
    case calm, standard, active
}

@MainActor
@Observable
final class RobotPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var selectedDevice: RobotDevice? {
        didSet {
            defaults.set(selectedDevice?.id.uuidString, forKey: "robot.device.id")
            defaults.set(selectedDevice?.name, forKey: "robot.device.name")
        }
    }
    var strength: RobotMotionStrength {
        didSet { defaults.set(strength.rawValue, forKey: "robot.strength") }
    }
    var idleEnabled: Bool {
        didSet { defaults.set(idleEnabled, forKey: "robot.idleEnabled") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawID = defaults.string(forKey: "robot.device.id"), let id = UUID(uuidString: rawID) {
            selectedDevice = RobotDevice(id: id,
                                         name: defaults.string(forKey: "robot.device.name") ?? "CatRobot",
                                         rssi: nil)
        } else {
            selectedDevice = nil
        }
        strength = defaults.string(forKey: "robot.strength").flatMap(RobotMotionStrength.init) ?? .standard
        idleEnabled = defaults.object(forKey: "robot.idleEnabled") == nil
            ? true : defaults.bool(forKey: "robot.idleEnabled")
    }
}
