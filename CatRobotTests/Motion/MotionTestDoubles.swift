import Foundation
import XCTest
@testable import CatRobot

let standardRobotLimits = RobotLimits(yawVelocityDeci: 1_200, pitchVelocityDeci: 1_000,
                                     yawAngleDeci: 600, pitchAngleDeci: 300)

@MainActor
final class RecordingRobotLink: RobotLinkControlling {
    struct Sent {
        let command: RobotCommand
        let priority: RobotCommandPriority
        let at: TimeInterval
    }
    private struct Pending {
        let command: RobotCommand
        let priority: RobotCommandPriority
        let token: UUID
        let expiresAt: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    let clock: ManualRobotClock
    private(set) var snapshot: RobotLinkSnapshot
    private(set) var sent: [Sent] = []
    private var observers: [UUID: AsyncStream<RobotLinkSnapshot>.Continuation] = [:]
    private var pending: [UUID: Pending] = [:]
    private var invalid: Set<UUID> = []
    private var reads: [UUID: (characteristic: RobotCharacteristic, continuation: CheckedContinuation<Data, Error>)] = [:]
    var writable = true
    var publishesUpdates = true
    var queuedCommands: [RobotCommand] { pending.values.map(\.command) }
    var limitsReadCount = 0
    var statusReadCount = 0
    var startCount = 0
    var suspendCount = 0

    init(clock: ManualRobotClock) {
        self.clock = clock
        snapshot = .init(state: .connected, status: robotStatus(), limits: standardRobotLimits,
                         statusReceivedAt: clock.now, motionAvailable: true, connectionID: UUID())
    }

    func updates() -> AsyncStream<RobotLinkSnapshot> {
        let id = UUID()
        let stream = AsyncStream<RobotLinkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream.stream
    }
    func start() { startCount += 1 }
    func select(_ device: RobotDevice) { snapshot.device = device }
    func resume() {}
    func suspend() { suspendCount += 1; disconnect() }
    func setApplicationActive(_ active: Bool) {}
    func disconnectByUser() { disconnect() }

    func emitInfo(_ info: RobotInfo) { snapshot.info = info; publish() }

    func emitStatus(_ status: RobotStatus) {
        snapshot.status = status
        snapshot.statusReceivedAt = clock.now
        snapshot.motionAvailable = snapshot.state == .connected && (status.state == .idle || status.state == .active)
            && !status.flags.contains(.returning)
        publish()
    }
    func disconnect() {
        snapshot.state = .reconnecting(.disconnected)
        snapshot.connectionID = nil
        snapshot.automaticWrite = nil
        snapshot.motionAvailable = false
        publish()
    }
    func reconnect() {
        snapshot.state = .connected
        snapshot.connectionID = UUID()
        emitStatus(robotStatus())
    }
    private func publish() {
        guard publishesUpdates else { return }
        for observer in observers.values { observer.yield(snapshot) }
    }

    func send(_ command: RobotCommand, priority: RobotCommandPriority, token: UUID, expiresAt: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = .init(command: command, priority: priority, token: token,
                                    expiresAt: expiresAt, continuation: continuation)
                flush()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?.continuation.resume(throwing: RobotLinkFailure.cancelled)
            }
        }
    }
    func settleAutomaticMotion(replacing owner: UUID, token: UUID, expiresAt: TimeInterval) async throws {
        guard snapshot.automaticWrite?.token == owner, let status = snapshot.status else { throw RobotLinkFailure.notReady }
        try await send(.move(yawDeci: status.yawDeci, pitchDeci: status.pitchDeci, speed: 10),
                       priority: .automaticSettlement, token: token, expiresAt: expiresAt)
    }
    func invalidate(_ token: UUID) {
        invalid.insert(token)
        for id in pending.keys.filter({ pending[$0]?.token == token }) {
            pending.removeValue(forKey: id)?.continuation.resume(throwing: RobotLinkFailure.cancelled)
        }
    }
    func flush() {
        guard writable else { return }
        while let id = pending.keys.min(by: { pending[$0]!.priority < pending[$1]!.priority }),
              let write = pending.removeValue(forKey: id) {
            if invalid.contains(write.token) { write.continuation.resume(throwing: RobotLinkFailure.cancelled) }
            else if write.expiresAt <= clock.now { write.continuation.resume(throwing: RobotLinkFailure.expired) }
            else if snapshot.state != .connected { write.continuation.resume(throwing: RobotLinkFailure.notReady) }
            else {
                sent.append(.init(command: write.command, priority: write.priority, at: clock.now))
                switch write.command {
                case .move, .center, .gesture, .gestureAt, .stop, .torque, .setCalibration:
                    snapshot.automaticWrite = write.priority == .tracking || write.priority == .idleMotion
                        ? .init(token: write.token, command: write.command, at: clock.now, priority: write.priority) : nil
                    publish()
                default: break
                }
                write.continuation.resume()
            }
        }
    }

    func read(_ characteristic: RobotCharacteristic) async throws -> Data {
        guard characteristic == .limits || characteristic == .status else { throw RobotLinkFailure.notReady }
        if characteristic == .limits { limitsReadCount += 1 } else { statusReadCount += 1 }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reads[id] = (characteristic, $0) }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.reads.removeValue(forKey: id)?.continuation.resume(throwing: RobotLinkFailure.cancelled)
            }
        }
    }
    func completeLimitsRead(_ limits: RobotLimits) {
        snapshot.limits = limits
        publish()
        func le(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
        let data = Data(le(limits.yawVelocityDeci) + le(limits.pitchVelocityDeci)
                        + le(UInt16(bitPattern: limits.yawAngleDeci)) + le(UInt16(bitPattern: limits.pitchAngleDeci)))
        completeReads(.limits, data: data)
    }
    func completeStatusRead(_ status: RobotStatus) {
        emitStatus(status)
        completeReads(.status, data: robotStatusBytes(status))
    }
    private func completeReads(_ characteristic: RobotCharacteristic, data: Data) {
        let ids = reads.keys.filter { reads[$0]?.characteristic == characteristic }
        for id in ids { reads.removeValue(forKey: id)?.continuation.resume(returning: data) }
    }
}

@MainActor
final class ScriptedRobotRandom: RobotRandomSource {
    var values: [Double]
    init(_ values: [Double] = []) { self.values = values }
    func next(in range: ClosedRange<Double>) -> Double {
        guard !values.isEmpty else { return range.lowerBound }
        let value = values.removeFirst()
        XCTAssertTrue(range.contains(value), "Scripted random input must be inside its requested range")
        return value
    }
}

@MainActor
final class MotionTraceRecorder { var events: [MotionTraceEvent] = [] }

@MainActor
final class MotionHarness {
    let clock = ManualRobotClock()
    let link: RecordingRobotLink
    let preferences: RobotPreferences
    let motion: MotionCoordinator
    let trace = MotionTraceRecorder()
    var sentCommands: [RobotCommand] { link.sent.map(\.command) }
    var gestureCommands: [RobotCommand] { sentCommands.filter { if case .gesture = $0 { true } else { false } } }

    /// `connected: false` builds the coordinator on a link that has already lost its connection.
    init(random: ScriptedRobotRandom = ScriptedRobotRandom(), connected: Bool = true) {
        let link = RecordingRobotLink(clock: clock)
        if !connected { link.disconnect() }
        self.link = link
        preferences = RobotPreferences(defaults: UserDefaults(suiteName: "MotionTests.\(UUID().uuidString)")!)
        preferences.trackingEnabled = false
        let trace = trace
        motion = MotionCoordinator(link: link, clock: clock, preferences: preferences, random: random,
                                   trace: { trace.events.append($0) })
        motion.setConversationPhase(.thinking)
    }
    func drain() async { await robotDrain() }
    func startCycle() async {
        link.emitStatus(robotStatus(state: .active, flags: [.link, .torque, .moving, .gesture]))
        await drain()
    }
    func completeCycle(after duration: TimeInterval) async {
        await startCycle()
        await clock.advance(by: duration)
        link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        await drain()
    }
    func advanceFresh(by duration: TimeInterval, step: TimeInterval = 0.1) async {
        var remaining = duration
        while remaining > 0.000_001 {
            let amount = min(step, remaining)
            await clock.advance(by: amount)
            link.emitStatus(link.snapshot.status!)
            await drain()
            remaining -= amount
        }
    }
    @discardableResult
    func reserve(_ gesture: RobotGesture = .nod, intensity: RobotIntensity = .large,
                 repeats: Int = 1, turn: MotionTurnID = MotionTurnID()) -> MotionTurnID {
        motion.beginTurn(turn)
        XCTAssertNotEqual(motion.reserve(.init(gesture: gesture, intensity: intensity, repeats: repeats), for: turn), .unavailable)
        return turn
    }
}
