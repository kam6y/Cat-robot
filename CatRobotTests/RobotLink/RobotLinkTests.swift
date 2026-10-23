import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class RobotLinkTests: XCTestCase {
    func testConstructionDoesNotStartBluetooth() {
        let h = RobotLinkHarness()
        XCTAssertEqual(h.transport.starts, 0)
        XCTAssertTrue(h.transport.attempts.isEmpty)
        XCTAssertEqual(h.link.snapshot.state, .unselected)
    }

    func testPreparationRequiresInfoEncryptedStatusNotifyCalibrationAndLimits() async {
        let h = RobotLinkHarness()
        await h.beginGatt()
        XCTAssertEqual(h.transport.reads.map(\.characteristic), [.info])
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        h.transport.emit(.value(attempt: h.attempt, characteristic: .info, data: Data([1, 0, 1, 0, 1, 0, 0, 0])))
        await h.drain()
        XCTAssertEqual(h.transport.reads.map(\.characteristic), [.info, .status])
        h.receiveStatus(robotStatus())
        await h.drain()
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        XCTAssertEqual(h.transport.notifications, [h.attempt])
        h.transport.emit(.notifyReady(attempt: h.attempt))
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 1])))
        await h.drain()
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        h.transport.emit(.value(attempt: h.attempt, characteristic: .limits,
                                data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
        await h.drain()
        XCTAssertEqual(h.transport.reads.map(\.characteristic), [.info, .status, .calibration, .limits])
        XCTAssertEqual(h.link.snapshot.state, .connected)
        XCTAssertTrue(h.link.snapshot.motionAvailable)
    }

    func testUnsupportedProtocolNeverAllowsCommands() async {
        let h = RobotLinkHarness()
        await h.beginGatt()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .info, data: Data([2, 0, 1, 0, 1, 0, 0, 0])))
        await h.drain()
        XCTAssertEqual(h.link.snapshot.state, .unsupported)
        await assertFailure(.notReady) { try await self.send(.stop, h: h) }
        XCTAssertTrue(h.transport.commands.isEmpty)
    }

    func testUnsafeFirmwareStatesBlockMotionButPermitExplicitStopAfterEncryption() async throws {
        for state in [RobotFirmwareState.boot, .bootCenter, .returning, .relaxWait] {
            let h = RobotLinkHarness()
            await h.connectReady(status: robotStatus(state: state))
            XCTAssertFalse(h.link.snapshot.motionAvailable, "\(state)")
            await assertFailure(.notReady) { try await self.send(.center(speed: 10), h: h) }
            try await send(.stop, h: h, priority: .manualStop)
            XCTAssertEqual(h.transport.commands, [.stop])
            h.receiveStatus(robotStatus())
            await h.drain()
            XCTAssertTrue(h.link.snapshot.motionAvailable)
        }
    }

    func testReconnectWaitsForExistingMovementAndOngoingMoveCanUpdateItsTarget() async throws {
        let h = RobotLinkHarness()
        await h.connectReady(status: robotStatus(state: .active, flags: [.link, .moving]))
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        h.receiveStatus(robotStatus())
        await h.drain()
        try await send(.move(yawDeci: 10, pitchDeci: 0, speed: 100), h: h)
        h.receiveStatus(robotStatus(state: .active, flags: [.link, .moving]))
        await h.drain()
        try await send(.move(yawDeci: 20, pitchDeci: 0, speed: 100), h: h)
        XCTAssertEqual(h.transport.commands.count, 2)
    }

    func testHeartbeatAndFreshnessRequireNewPingEcho() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        for _ in 0..<5 {
            h.receiveStatus(robotStatus())
            await h.drain()
            await h.clock.advance(by: 0.2)
        }
        XCTAssertEqual(pings(h).count, 1)
        await h.clock.advance(by: 1)
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        XCTAssertEqual(h.transport.reads.last?.characteristic, .status)
        let challenge = pings(h).last!
        h.receiveStatus(robotStatus(pingSeq: 0))
        await h.drain()
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        h.receiveStatus(robotStatus(pingSeq: challenge))
        await h.drain()
        XCTAssertTrue(h.link.snapshot.motionAvailable)
        XCTAssertEqual(h.link.snapshot.statusReceivedAt, h.clock.now)
    }

    func testMissingStatusDisconnectsAfterRecoveryDeadline() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        await h.clock.advance(by: 1.01)
        await h.clock.advance(by: 2.01)
        XCTAssertEqual(h.transport.disconnects, [h.attempt])
        XCTAssertFalse(h.link.snapshot.motionAvailable)
    }

    func testOldAttemptCannotReviveAfterReconnect() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        let old = h.attempt
        h.transport.emit(.disconnected(attempt: old, reason: .disconnected))
        await h.drain()
        await h.clock.advance(by: 2)
        XCTAssertEqual(h.transport.retrievals, [h.device.id])
        XCTAssertEqual(h.transport.attempts.count, 2)
        h.transport.emit(.gattReady(attempt: h.attempt))
        await h.drain()
        let newStatus = robotStatus(yaw: 11)
        await h.finishPreparation(status: newStatus)
        h.transport.emit(.value(attempt: old, characteristic: .status, data: robotStatusBytes(robotStatus(yaw: 222))))
        await h.drain()
        XCTAssertEqual(h.link.snapshot.status, newStatus)
    }

    func testTimeoutWaitsForTerminalCallbackAndNeverOverlapsAttempts() async {
        let h = RobotLinkHarness()
        await h.beginGatt()
        let old = h.attempt
        await h.clock.advance(by: 5.01)
        XCTAssertEqual(h.transport.disconnects, [old])
        await h.clock.advance(by: 2)
        XCTAssertEqual(h.transport.attempts.count, 1)
        h.transport.emit(.disconnected(attempt: old, reason: .cancelled))
        await h.drain()
        XCTAssertEqual(h.transport.attempts.count, 2)
    }

    func testMissingCancellationCallbackInvalidatesManagerBeforeRetry() async {
        let h = RobotLinkHarness()
        await h.beginGatt()
        await h.clock.advance(by: 5.01)
        await h.clock.advance(by: 4.9)
        XCTAssertEqual(h.transport.invalidations, 0)
        await h.clock.advance(by: 0.11)
        XCTAssertEqual(h.transport.invalidations, 1)
        XCTAssertEqual(h.transport.attempts.count, 2)
    }

    func testUserDisconnectAndBackgroundStopHeartbeatAndAutomaticResume() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        h.link.disconnectByUser()
        h.transport.emit(.disconnected(attempt: h.attempt, reason: .cancelled))
        await h.drain()
        h.link.resume()
        await h.clock.advance(by: 20)
        XCTAssertEqual(h.transport.attempts.count, 1)
        XCTAssertTrue(h.transport.commands.isEmpty)
        XCTAssertEqual(h.link.snapshot.state, .suspended)
        h.link.select(h.device)
        await h.drain()
        XCTAssertEqual(h.transport.attempts.count, 2)
        h.link.suspend()
        await h.clock.advance(by: 5)
        XCTAssertTrue(h.transport.commands.isEmpty)
    }

    func testBluetoothDeniedAndOffDoNotRetry() async {
        for state in [RobotBluetoothState.unauthorized, .poweredOff, .unsupported] {
            let h = RobotLinkHarness()
            h.link.start()
            h.transport.emit(.bluetooth(state: state))
            await h.drain()
            await h.clock.advance(by: 60)
            XCTAssertEqual(h.link.snapshot.state, .unavailable(state))
            XCTAssertTrue(h.transport.attempts.isEmpty)
        }
    }

    func testInitialEncryptedReadHasThirtyActiveSecondsForPairing() async {
        let h = RobotLinkHarness()
        await h.beginGatt()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .info, data: Data([1, 0, 1, 0, 1, 0, 0, 0])))
        await h.drain()
        await h.clock.advance(by: 20)
        XCTAssertTrue(h.transport.disconnects.isEmpty)
        h.link.setApplicationActive(false)
        await h.clock.advance(by: 60)
        XCTAssertTrue(h.transport.disconnects.isEmpty)
        h.link.setApplicationActive(true)
        await h.clock.advance(by: 9)
        XCTAssertTrue(h.transport.disconnects.isEmpty)
        await h.clock.advance(by: 1.1)
        XCTAssertEqual(h.transport.disconnects, [h.attempt])
    }

    func testInitialPermissionWaitExpiresAfterThirtyActiveSecondsAndIgnoresLatePowerOn() async {
        let h = RobotLinkHarness()
        h.link.start()
        await h.drain()
        await h.clock.advance(by: 20)
        h.link.setApplicationActive(false)
        await h.clock.advance(by: 60)
        h.link.setApplicationActive(true)
        await h.clock.advance(by: 9)
        XCTAssertTrue(h.transport.attempts.isEmpty)
        await h.clock.advance(by: 1.1)
        h.transport.emit(.bluetooth(state: .poweredOn))
        await h.drain()
        XCTAssertEqual(h.transport.scans, 0)
        XCTAssertTrue(h.transport.attempts.isEmpty)
        // A new explicit connection action can retry after the initial wait expired.
        h.link.start()
        await h.drain()
        XCTAssertEqual(h.transport.scans, 1)
    }

    func testReadsOfSameCharacteristicAreSerialized() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let a = Task { try await h.link.read(.calibration) }
        await h.drain()
        let b = Task { try await h.link.read(.calibration) }
        await h.drain()
        XCTAssertEqual(h.transport.reads.filter { $0.characteristic == .calibration }.count, 2)
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([1, 0, 0, 0, 2, 0])))
        await h.drain()
        XCTAssertEqual(h.transport.reads.filter { $0.characteristic == .calibration }.count, 3)
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([2, 0, 0, 0, 2, 0])))
        let first = try await a.value, second = try await b.value
        XCTAssertEqual(first.first, 1)
        XCTAssertEqual(second.first, 2)
    }

    func testReadTimeoutEndsConnectionEpochAndLateReadCannotCompleteAnother() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        let a = Task { try await h.link.read(.calibration) }
        let b = Task { try await h.link.read(.calibration) }
        await h.drain()
        // Keep telemetry fresh while the independent Calibration read is missing.
        for _ in 0..<4 {
            h.receiveStatus(robotStatus())
            await h.drain()
            await h.clock.advance(by: 0.8)
        }
        await assertTaskFailure(a, .timedOut)
        await assertTaskFailure(b, .timedOut)
        XCTAssertEqual(h.transport.disconnects, [h.attempt])
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([22, 0, 0, 0, 2, 1])))
        await h.drain()
        XCTAssertNotEqual(h.link.snapshot.calibration?.values.yawOffsetDeci, 22)
    }

    func testLatestMoveStopPriorityInvalidationAndExpiry() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        h.transport.canSendWriteWithoutResponse = false
        let old = Task { try await self.send(.move(yawDeci: 10, pitchDeci: 0, speed: 100), h: h) }
        await h.drain()
        await h.clock.advance(by: 0.21)
        let latestMove = RobotCommand.move(yawDeci: 20, pitchDeci: -5, speed: 100)
        let latest = Task { try await self.send(latestMove, h: h) }
        let token = UUID()
        let invalidated = Task { try await self.send(.gesture(id: 1, ampDeci: 10, repeats: 1, speed: 100),
                                                    h: h, token: token) }
        let expired = Task { try await self.send(.center(speed: 100), h: h, lifetime: 0.05) }
        let stop = Task { try await self.send(.stop, h: h, priority: .manualStop, lifetime: 1) }
        await h.drain()
        h.link.invalidate(token)
        await h.clock.advance(by: 0.1)
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        await h.drain()
        try await latest.value
        try await stop.value
        await assertTaskFailure(old, .cancelled)
        await assertTaskFailure(invalidated, .cancelled)
        await assertTaskFailure(expired, .expired)
        XCTAssertEqual(h.transport.commands, [.stop, latestMove])
    }

    func testHeartbeatPrecedesMotionWhenFlowControlResumes() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        await h.clock.advance(by: 0.9)
        h.receiveStatus(robotStatus())
        await h.drain()
        h.transport.canSendWriteWithoutResponse = false
        let move = Task { try await self.send(.move(yawDeci: 10, pitchDeci: 0, speed: 100), h: h) }
        await h.drain()
        await h.clock.advance(by: 0.1)
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        try await move.value
        XCTAssertEqual(h.transport.commands, [.ping(seq: 1), .move(yawDeci: 10, pitchDeci: 0, speed: 100)])
    }

    func testCalibrationPreviewsReplaceQueuedValuesAndTokenCannotBeReused() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        h.transport.canSendWriteWithoutResponse = false
        let first = Task { try await self.send(.setCalibration(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2)),
                                              h: h, priority: .calibration) }
        await h.drain()
        let command = RobotCommand.setCalibration(.init(yawOffsetDeci: 10, pitchOffsetDeci: 0, invert: 2))
        let second = Task { try await self.send(command, h: h, priority: .calibration) }
        await h.drain()
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        try await second.value
        await assertTaskFailure(first, .cancelled)
        XCTAssertEqual(h.transport.commands, [command])
        let token = UUID()
        h.link.invalidate(token)
        await assertFailure(.cancelled) { try await self.send(.stop, h: h, token: token) }
    }

    func testPreferencesPersistSelectionAndControlsWithoutTelemetry() {
        let h = RobotLinkHarness()
        h.preferences.selectedDevice = h.device
        h.preferences.strength = .calm
        h.preferences.idleEnabled = false
        let reloaded = RobotPreferences(defaults: h.defaults)
        XCTAssertEqual(reloaded.selectedDevice?.id, h.device.id)
        XCTAssertEqual(reloaded.selectedDevice?.name, h.device.name)
        XCTAssertNil(reloaded.selectedDevice?.rssi)
        XCTAssertEqual(reloaded.strength, .calm)
        XCTAssertFalse(reloaded.idleEnabled)
    }

    func testQueuedGestureAndIdlePowerOffRecheckRestBeforeWrite() async {
        for (command, priority) in [(RobotCommand.gesture(id: 1, ampDeci: 150, repeats: 1, speed: 100), RobotCommandPriority.motion),
                                    (.torque(false), .idlePowerOff)] {
            let h = RobotLinkHarness()
            await h.connectReady(status: robotStatus(state: .active, flags: [.link, .torque]))
            h.transport.canSendWriteWithoutResponse = false
            let sending = Task { try await self.send(command, h: h, priority: priority) }
            await h.drain()
            h.receiveStatus(robotStatus(state: .active, flags: [.link, .torque, .moving, .gesture]))
            await h.drain()
            h.transport.canSendWriteWithoutResponse = true
            h.transport.emit(.readyToWrite(attempt: h.attempt))
            await h.drain()
            await assertTaskFailure(sending, .notReady)
            XCTAssertFalse(h.transport.commands.contains(command))
        }
    }

    private func send(_ command: RobotCommand, h: RobotLinkHarness,
                      priority: RobotCommandPriority = .motion, token: UUID = UUID(),
                      lifetime: TimeInterval = 0.3) async throws {
        try await h.link.send(command, priority: priority, token: token, expiresAt: h.clock.now + lifetime)
    }
    private func pings(_ h: RobotLinkHarness) -> [UInt8] {
        h.transport.commands.compactMap { if case let .ping(seq) = $0 { seq } else { nil } }
    }
    private func assertFailure(_ expected: RobotLinkFailure, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RobotLinkFailure, expected) }
    }
    private func assertTaskFailure<T>(_ task: Task<T, Error>, _ expected: RobotLinkFailure) async {
        do { _ = try await task.value; XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RobotLinkFailure, expected) }
    }
}
