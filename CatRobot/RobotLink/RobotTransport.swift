import Foundation

struct RobotDevice: Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int?
}

enum RobotBluetoothState: Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

enum RobotLinkFailure: Error, Equatable, Sendable {
    case bluetoothUnavailable(RobotBluetoothState)
    case disconnected, timedOut, cancelled, notReady, expired
    case protocolMismatch, invalidData, saveFailed, valueMismatch, authenticationFailed
}

enum RobotTransportEvent: Sendable {
    case bluetooth(state: RobotBluetoothState)
    case discovered(RobotDevice)
    case gattReady(attempt: UUID)
    case disconnected(attempt: UUID, reason: RobotLinkFailure)
    case value(attempt: UUID, characteristic: RobotCharacteristic, data: Data)
    case notifyReady(attempt: UUID)
    case readyToWrite(attempt: UUID)
    case failed(attempt: UUID, reason: RobotLinkFailure)
}

@MainActor
protocol RobotTransport: AnyObject {
    var events: AsyncStream<RobotTransportEvent> { get }
    var canSendWriteWithoutResponse: Bool { get }
    func start()
    /// Retrieves the selected UUID, falling back to service-filtered discovery if absent.
    func retrieve(_ id: UUID)
    func scan()
    func stopScan()
    func connect(_ id: UUID, attempt: UUID)
    func disconnect(attempt: UUID)
    func read(_ characteristic: RobotCharacteristic, attempt: UUID)
    func setStatusNotify(_ enabled: Bool, attempt: UUID)
    func writeCommand(_ data: Data, attempt: UUID)
    /// Discards the old manager. A new power-state event precedes further connections.
    func invalidate()
}

enum RobotLinkState: Equatable, Sendable {
    case unselected
    case unavailable(RobotBluetoothState)
    case searching, connecting, preparing, connected
    case reconnecting(RobotLinkFailure)
    case suspended, unsupported
}

/// Recorded synchronously at the BLE write boundary, before send's continuation resumes.
struct RobotAutomaticWrite: Equatable, Sendable {
    let token: UUID
    let command: RobotCommand
    let at: TimeInterval
    let priority: RobotCommandPriority
}

struct RobotLinkSnapshot: Equatable, Sendable {
    var state: RobotLinkState = .unselected
    var device: RobotDevice?
    var discoveredDevices: [RobotDevice] = []
    var info: RobotInfo?
    var status: RobotStatus?
    var calibration: RobotCalibration?
    var limits: RobotLimits?
    var statusReceivedAt: TimeInterval?
    var motionAvailable = false
    var failure: RobotLinkFailure?
    var connectionID: UUID?
    var automaticWrite: RobotAutomaticWrite?
}

enum RobotCommandPriority: Int, Comparable, Sendable {
    case manualStop, heartbeat, calibration, toolMotion, automaticSettlement, motion, tracking, idleMotion, idlePowerOff
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
protocol RobotLinkControlling: AnyObject {
    var snapshot: RobotLinkSnapshot { get }
    func updates() -> AsyncStream<RobotLinkSnapshot>
    func start()
    func select(_ device: RobotDevice)
    func resume()
    func suspend()
    func setApplicationActive(_ active: Bool)
    func disconnectByUser()
    func send(_ command: RobotCommand, priority: RobotCommandPriority,
              token: UUID, expiresAt: TimeInterval) async throws
    /// A single current-pose MOVE tied to the last written automatic owner, also allowed while inactive.
    func settleAutomaticMotion(replacing owner: UUID, token: UUID, expiresAt: TimeInterval) async throws
    func invalidate(_ token: UUID)
    func read(_ characteristic: RobotCharacteristic) async throws -> Data
}
