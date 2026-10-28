import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ManualRobotClock: RobotClock {
    private struct Waiter {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private(set) var now: TimeInterval = 0
    private var waiters: [UUID: Waiter] = [:]
    /// Tasks currently sleeping on this clock. A periodic timer that is armed shows up as one.
    var pendingSleepCount: Int { waiters.count }

    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        guard deadline > now else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(by duration: TimeInterval) async {
        now += duration
        let due = waiters.filter { $0.value.deadline <= now + 0.000_001 }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
        await robotDrain()
    }
}

@MainActor
func robotDrain() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
final class FakeRobotTransport: RobotTransport {
    let events: AsyncStream<RobotTransportEvent>
    private let continuation: AsyncStream<RobotTransportEvent>.Continuation
    var canSendWriteWithoutResponse = true
    var knownDevices: [UUID: RobotDevice] = [:]
    private(set) var starts = 0
    private(set) var scans = 0
    private(set) var retrievals: [UUID] = []
    private(set) var attempts: [(device: UUID, attempt: UUID)] = []
    private(set) var disconnects: [UUID] = []
    private(set) var reads: [(characteristic: RobotCharacteristic, attempt: UUID)] = []
    private(set) var notifications: [UUID] = []
    private(set) var invalidations = 0
    private(set) var commands: [RobotCommand] = []
    private(set) var writtenData: [Data] = []

    init() {
        let stream = AsyncStream<RobotTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func emit(_ event: RobotTransportEvent) { continuation.yield(event) }
    func start() { starts += 1 }
    func retrieve(_ id: UUID) {
        retrievals.append(id)
        if let device = knownDevices[id] { emit(.discovered(device)) } else { scan() }
    }
    func scan() { scans += 1 }
    func stopScan() {}
    func connect(_ id: UUID, attempt: UUID) { attempts.append((id, attempt)) }
    func disconnect(attempt: UUID) { disconnects.append(attempt) }
    func read(_ characteristic: RobotCharacteristic, attempt: UUID) { reads.append((characteristic, attempt)) }
    func setStatusNotify(_ enabled: Bool, attempt: UUID) { if enabled { notifications.append(attempt) } }
    func invalidate() {
        invalidations += 1
        // A recreated central reports its power state before it can connect again.
        emit(.bluetooth(state: .poweredOn))
    }
    func writeCommand(_ data: Data, attempt: UUID) {
        writtenData.append(data)
        if let command = decodeCommand(Array(data)) { commands.append(command) }
    }

    private func decodeCommand(_ b: [UInt8]) -> RobotCommand? {
        guard let type = b.first else { XCTFail("Empty command"); return nil }
        func u(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        func s(_ i: Int) -> Int16 { Int16(bitPattern: u(i)) }
        switch (type, b.count) {
        case (1, 6): return .move(yawDeci: s(1), pitchDeci: s(3), speed: b[5])
        case (2, 5): return .gesture(id: b[1], ampDeci: b[2], repeats: b[3], speed: b[4])
        case (10, 9): return .gestureAt(id: b[1], ampDeci: b[2], repeats: b[3], speed: b[4], yawDeci: s(5), pitchDeci: s(7))
        case (3, 1): return .stop
        case (4, 2): return .center(speed: b[1])
        case (5, 2): return .torque(b[1] != 0)
        case (6, 6): return .setCalibration(.init(yawOffsetDeci: s(1), pitchOffsetDeci: s(3), invert: b[5]))
        case (7, 2): return .saveCalibration(req: b[1])
        case (8, 9): return .setLimits(.init(yawVelocityDeci: u(1), pitchVelocityDeci: u(3),
                                            yawAngleDeci: s(5), pitchAngleDeci: s(7)))
        case (9, 2): return .ping(seq: b[1])
        default: XCTFail("Malformed command at the transport boundary"); return nil
        }
    }
}

func robotStatus(
    state: RobotFirmwareState = .idle, flags: RobotStatusFlags = [.link],
    pingSeq: UInt8 = 0, saveSeq: UInt8 = 0, yaw: Int16 = 0, pitch: Int16 = 0
) -> RobotStatus {
    .init(yawDeci: yaw, pitchDeci: pitch, flags: flags, pingSeq: pingSeq, state: state,
          voltageCenti: 0, rejectedCount: 0, saveSeq: saveSeq)
}

func robotStatusBytes(_ status: RobotStatus) -> Data {
    func le(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    return Data(le(UInt16(bitPattern: status.yawDeci)) + le(UInt16(bitPattern: status.pitchDeci))
        + le(status.flags.rawValue) + [status.pingSeq, status.state.rawValue]
        + le(status.voltageCenti) + [status.rejectedCount, status.saveSeq])
}

@MainActor
final class RobotLinkHarness {
    let clock = ManualRobotClock()
    let transport = FakeRobotTransport()
    let preferences: RobotPreferences
    let link: RobotLink
    let device = RobotDevice(id: UUID(), name: "CatRobot-test", rssi: -40)
    let defaults: UserDefaults
    private let suite = "RobotLinkTests.\(UUID().uuidString)"
    var attempt: UUID { transport.attempts.last!.attempt }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        preferences = RobotPreferences(defaults: defaults)
        link = RobotLink(transport: transport, clock: clock, preferences: preferences)
        transport.knownDevices[device.id] = device
    }

    func beginGatt() async {
        link.start()
        transport.emit(.bluetooth(state: .poweredOn))
        await drain()
        link.select(device)
        await drain()
        transport.emit(.gattReady(attempt: attempt))
        await drain()
    }

    func finishPreparation(status: RobotStatus = robotStatus(), capabilities: UInt8 = 0) async {
        transport.emit(.value(attempt: attempt, characteristic: .info,
                              data: Data([1, 0, 1, 0, 1, capabilities, 0, 0])))
        await drain()
        receiveStatus(status)
        await drain()
        transport.emit(.notifyReady(attempt: attempt))
        await drain()
        transport.emit(.value(attempt: attempt, characteristic: .calibration,
                              data: Data([0, 0, 0, 0, 2, 1])))
        await drain()
        transport.emit(.value(attempt: attempt, characteristic: .limits,
                              data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
        await drain()
    }

    func connectReady(status: RobotStatus = robotStatus(), capabilities: UInt8 = 0) async {
        await beginGatt()
        await finishPreparation(status: status, capabilities: capabilities)
    }
    func receiveStatus(_ status: RobotStatus) {
        transport.emit(.value(attempt: attempt, characteristic: .status, data: robotStatusBytes(status)))
    }
    func drain() async { await robotDrain() }
}
