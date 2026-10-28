import Foundation

enum RobotCharacteristic: UInt8, CaseIterable, Sendable {
    case command = 1
    case status = 2
    case calibration = 3
    case limits = 4
    case info = 5

    var uuid: UUID {
        UUID(uuidString: "c47b000\(rawValue)-6d1f-4b9e-9c9a-2a3b4c5d6e7f")!
    }
}

struct RobotCalibrationValues: Equatable, Sendable {
    let yawOffsetDeci: Int16
    let pitchOffsetDeci: Int16
    let invert: UInt8
}

struct RobotCalibration: Equatable, Sendable {
    let values: RobotCalibrationValues
    let saved: Bool
}

struct RobotLimits: Equatable, Sendable {
    let yawVelocityDeci: UInt16
    let pitchVelocityDeci: UInt16
    let yawAngleDeci: Int16
    let pitchAngleDeci: Int16
}

struct RobotInfo: Equatable, Sendable {
    let protocolVersion: UInt8
    let major: UInt8
    let minor: UInt8
    let patch: UInt8
    let hardwareID: UInt8
    let capabilities: UInt8

    var supportsAnchoredGestures: Bool { capabilities & 2 != 0 }
}

enum RobotFirmwareState: UInt8, Sendable {
    case boot = 0
    case bootCenter = 1
    case idle = 2
    case active = 3
    case returning = 4
    case relaxWait = 5
}

struct RobotStatusFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let link = Self(rawValue: 1 << 0)
    static let torque = Self(rawValue: 1 << 1)
    static let moving = Self(rawValue: 1 << 2)
    static let brownout = Self(rawValue: 1 << 3)
    static let saturated = Self(rawValue: 1 << 4)
    static let calibrationDirty = Self(rawValue: 1 << 5)
    static let gesture = Self(rawValue: 1 << 6)
    static let rejected = Self(rawValue: 1 << 7)
    static let returning = Self(rawValue: 1 << 8)
    static let pairOpen = Self(rawValue: 1 << 9)
    static let saveError = Self(rawValue: 1 << 10)
}

extension RobotStatusFlags {
    /// The head is moving, playing a gesture, or returning to rest.
    static let motionInProgress: Self = [.moving, .gesture, .returning]
    /// Firmware-owned motion that no app write may replace, even a tracking MOVE.
    static let ownershipBlocking: Self = [.gesture, .returning]
}

struct RobotStatus: Equatable, Sendable {
    let yawDeci: Int16
    let pitchDeci: Int16
    let flags: RobotStatusFlags
    let pingSeq: UInt8
    let state: RobotFirmwareState
    let voltageCenti: UInt16
    let rejectedCount: UInt8
    let saveSeq: UInt8

    /// Firmware accepts motion only while idle or active.
    var isOperational: Bool { state == .idle || state == .active }
    /// Flags only: no move, gesture, or return in progress. Readiness is checked separately.
    var isAtRest: Bool { flags.intersection(.motionInProgress).isEmpty }
    /// No gesture or return holds the head, so an automatic MOVE may be replaced.
    var isFreeOfOwnedMotion: Bool { flags.intersection(.ownershipBlocking).isEmpty }
    /// Powered and at rest: the robot-side condition for releasing PWM.
    var isActiveAtRest: Bool { state == .active && isAtRest }

    /// The same status at another pose; every other field is copied unchanged.
    func with(yawDeci: Int16, pitchDeci: Int16) -> RobotStatus {
        .init(yawDeci: yawDeci, pitchDeci: pitchDeci, flags: flags, pingSeq: pingSeq, state: state,
              voltageCenti: voltageCenti, rejectedCount: rejectedCount, saveSeq: saveSeq)
    }
}

enum RobotCommand: Equatable, Sendable {
    case move(yawDeci: Int16, pitchDeci: Int16, speed: UInt8)
    case gesture(id: UInt8, ampDeci: UInt8, repeats: UInt8, speed: UInt8)
    case gestureAt(id: UInt8, ampDeci: UInt8, repeats: UInt8, speed: UInt8, yawDeci: Int16, pitchDeci: Int16)
    case stop
    case center(speed: UInt8)
    case torque(Bool)
    case setCalibration(RobotCalibrationValues)
    case saveCalibration(req: UInt8)
    case setLimits(RobotLimits)
    case ping(seq: UInt8)
}

enum RobotProtocolError: Error, Equatable {
    case badLength
    case invalidValue
    case unsupportedProtocol
}

/// Firmware protocol v1. Angles use 0.1 degrees; velocity limits use 0.1 degrees/s.
enum RobotProtocol {
    static let serviceUUID = UUID(uuidString: "c47b0000-6d1f-4b9e-9c9a-2a3b4c5d6e7f")!

    static func encode(_ command: RobotCommand) throws -> Data {
        var bytes: [UInt8]
        switch command {
        case let .move(yaw, pitch, speed):
            bytes = [1] + littleEndian(yaw) + littleEndian(pitch) + [speed]
        case let .gesture(id, amp, repeats, speed):
            guard (1...6).contains(id) else { throw RobotProtocolError.invalidValue }
            bytes = [2, id, amp, repeats, speed]
        case let .gestureAt(id, amp, repeats, speed, yaw, pitch):
            guard (1...6).contains(id) else { throw RobotProtocolError.invalidValue }
            bytes = [10, id, amp, repeats, speed] + littleEndian(yaw) + littleEndian(pitch)
        case .stop:
            bytes = [3]
        case let .center(speed):
            bytes = [4, speed]
        case let .torque(on):
            bytes = [5, on ? 1 : 0]
        case let .setCalibration(values):
            bytes = [6] + littleEndian(values.yawOffsetDeci)
                + littleEndian(values.pitchOffsetDeci) + [values.invert]
        case let .saveCalibration(req):
            guard req != 0 else { throw RobotProtocolError.invalidValue }
            bytes = [7, req]
        case let .setLimits(limits):
            try validate(limits)
            bytes = [8] + littleEndian(limits.yawVelocityDeci)
                + littleEndian(limits.pitchVelocityDeci)
                + littleEndian(limits.yawAngleDeci) + littleEndian(limits.pitchAngleDeci)
        case let .ping(seq):
            bytes = [9, seq]
        }
        return Data(bytes)
    }

    static func decodeStatus(_ data: Data) throws -> RobotStatus {
        let bytes = try payload(data, length: 12)
        guard let state = RobotFirmwareState(rawValue: bytes[7]) else {
            throw RobotProtocolError.invalidValue
        }
        return RobotStatus(
            yawDeci: signed(bytes, at: 0), pitchDeci: signed(bytes, at: 2),
            flags: RobotStatusFlags(rawValue: unsigned(bytes, at: 4)), pingSeq: bytes[6],
            state: state, voltageCenti: unsigned(bytes, at: 8),
            rejectedCount: bytes[10], saveSeq: bytes[11]
        )
    }

    static func decodeCalibration(_ data: Data) throws -> RobotCalibration {
        let bytes = try payload(data, length: 6)
        return RobotCalibration(
            values: .init(yawOffsetDeci: signed(bytes, at: 0),
                          pitchOffsetDeci: signed(bytes, at: 2), invert: bytes[4]),
            saved: bytes[5] != 0
        )
    }

    static func decodeLimits(_ data: Data) throws -> RobotLimits {
        let bytes = try payload(data, length: 8)
        let limits = RobotLimits(
            yawVelocityDeci: unsigned(bytes, at: 0), pitchVelocityDeci: unsigned(bytes, at: 2),
            yawAngleDeci: signed(bytes, at: 4), pitchAngleDeci: signed(bytes, at: 6)
        )
        try validate(limits)
        return limits
    }

    static func decodeInfo(_ data: Data) throws -> RobotInfo {
        let bytes = try payload(data, length: 8)
        guard bytes[0] == 1 else { throw RobotProtocolError.unsupportedProtocol }
        return RobotInfo(protocolVersion: bytes[0], major: bytes[1], minor: bytes[2],
                         patch: bytes[3], hardwareID: bytes[4], capabilities: bytes[5])
    }

    private static func payload(_ data: Data, length: Int) throws -> [UInt8] {
        guard data.count == length else { throw RobotProtocolError.badLength }
        return Array(data)
    }

    private static func unsigned(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func signed(_ bytes: [UInt8], at index: Int) -> Int16 {
        Int16(bitPattern: unsigned(bytes, at: index))
    }

    private static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }

    private static func littleEndian(_ value: Int16) -> [UInt8] {
        littleEndian(UInt16(bitPattern: value))
    }

    private static func validate(_ limits: RobotLimits) throws {
        guard limits.yawAngleDeci >= 0, limits.pitchAngleDeci >= 0 else {
            throw RobotProtocolError.invalidValue
        }
    }
}
