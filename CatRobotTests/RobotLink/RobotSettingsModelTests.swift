import SwiftUI
import XCTest
@testable import CatRobot

@MainActor
final class RobotSettingsModelTests: XCTestCase {
    func testCompositionDoesNotStartBluetooth() async {
        let h = RobotLinkHarness()
        let composition = ConversationComposition.live(auth: .missing, robotTransport: h.transport,
                                                      robotClock: h.clock, robotPreferences: h.preferences)
        _ = AppRootView(dependencies: composition.dependencies, robotSettings: composition.robotSettings)
        _ = RobotConnectionView(model: composition.robotSettings)
        composition.robotSettings.settingsDidOpen()
        await h.drain()
        XCTAssertEqual(h.transport.starts, 0)
        XCTAssertTrue(h.transport.attempts.isEmpty)
    }

    func testConnectionControlCancelsPendingStatesUntilExplicitReconnect() async {
        for state in [RobotLinkState.connecting, .preparing, .reconnecting(.disconnected), .connected] {
            let h = RobotLinkHarness()
            let model = makeModel(h)
            switch state {
            case .connecting:
                model.select(h.device)
                h.transport.emit(.bluetooth(state: .poweredOn))
                await h.drain()
            case .preparing: await h.beginGatt()
            default:
                await h.connectReady()
                if case .reconnecting = state {
                    h.transport.emit(.disconnected(attempt: h.attempt, reason: .disconnected))
                    await h.drain()
                }
            }
            XCTAssertEqual(model.snapshot.state, state)
            XCTAssertEqual(model.connectionActionTitle, state == .connected ? "接続を切る" : "接続をキャンセル")
            let old = h.attempt
            model.performConnectionAction()
            h.transport.emit(.disconnected(attempt: old, reason: .cancelled))
            await h.drain()
            XCTAssertEqual(h.link.snapshot.state, .suspended)
            XCTAssertEqual(model.connectionActionTitle, "このロボットに接続")
            let attempts = h.transport.attempts.count, commands = h.transport.commands.count
            await h.clock.advance(by: 20)
            h.link.resume()
            await h.drain()
            XCTAssertEqual(h.transport.attempts.count, attempts)
            XCTAssertEqual(h.transport.commands.count, commands)
            model.performConnectionAction()
            await h.drain()
            XCTAssertEqual(h.transport.attempts.count, attempts + 1)
        }
    }

    func testOpeningCalibrationWaitsForRest() async throws {
        let h = RobotLinkHarness()
        await h.connectReady(status: robotStatus(state: .active, flags: [.link, .gesture, .moving]))
        let modes = RecordedRobotModes()
        let model = makeModel(h, modes: modes)
        model.settingsDidOpen()
        XCTAssertEqual(modes.values, [.settings])
        await model.openCalibration()
        let session = try XCTUnwrap(model.calibration)
        guard case .calibration = modes.values.last else { return XCTFail("Manual ownership must precede preview") }
        await h.drain()
        XCTAssertEqual(session.phase, .waitingForRest)
        XCTAssertFalse(session.canEdit)
        XCTAssertFalse(h.transport.commands.contains { if case .setCalibration = $0 { true } else { false } })
        h.receiveStatus(robotStatus())
        await finishOpening(h)
        XCTAssertTrue(session.canEdit)
        await model.closeCalibration(.restore)
        // With unchanged values, closing never sends another calibration write.
        XCTAssertFalse(h.transport.commands.contains { if case .setCalibration = $0 { true } else { false } })
        XCTAssertNil(model.calibration)
        XCTAssertEqual(modes.values.last, .settings)
    }

    func testUnsavedExitRestoresEntryWithoutPersisting() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let model = makeModel(h)
        await model.openCalibration()
        await finishOpening(h, saved: false)
        let session = try XCTUnwrap(model.calibration)
        session.preview(.init(yawOffsetDeci: 15, pitchOffsetDeci: 0, invert: 2))
        await h.drain()
        let closing = Task { await model.closeCalibration(.restore) }
        await h.drain()
        XCTAssertEqual(h.transport.commands.last, .setCalibration(.init(yawOffsetDeci: 0, pitchOffsetDeci: 0, invert: 2)))
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 0])))
        await closing.value
        XCTAssertNil(model.calibration)
        XCTAssertEqual(session.entry?.saved, false)
        XCTAssertFalse(h.transport.commands.contains { if case .saveCalibration = $0 { true } else { false } })
    }

    func testExitRestoresAppliedPreviewEvenWhenDraftAlreadyMatchesEntry() async throws {
        for expiresFinalPreview in [false, true] {
            let h = RobotLinkHarness()
            await h.connectReady()
            let model = makeModel(h)
            await model.openCalibration()
            await finishOpening(h)
            let session = try XCTUnwrap(model.calibration)
            let entry = RobotCalibrationValues(yawOffsetDeci: 0, pitchOffsetDeci: 0, invert: 2)
            let preview = RobotCalibrationValues(yawOffsetDeci: 15, pitchOffsetDeci: 0, invert: 2)
            session.preview(preview)
            await h.drain()
            XCTAssertEqual(h.transport.commands.last, .setCalibration(preview))
            session.preview(entry)
            if expiresFinalPreview {
                h.transport.canSendWriteWithoutResponse = false
                await h.clock.advance(by: 0.1)
                await h.clock.advance(by: 0.31)
                h.transport.canSendWriteWithoutResponse = true
                h.transport.emit(.readyToWrite(attempt: h.attempt))
            }
            await h.drain()
            XCTAssertFalse(session.hasNewChanges)
            XCTAssertEqual(h.transport.commands.last, .setCalibration(preview))

            let closing = Task { await model.closeCalibration(.restore) }
            await h.drain()
            XCTAssertTrue(model.calibration === session, "Keep the screen until the entry value is confirmed")
            XCTAssertEqual(h.transport.commands.last, .setCalibration(entry))
            h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration,
                                    data: Data([0, 0, 0, 0, 2, 1])))
            await closing.value
            XCTAssertNil(model.calibration)
            XCTAssertFalse(h.transport.commands.contains { if case .saveCalibration = $0 { true } else { false } })
        }
    }

    func testSaveExitWaitsForMatchingReadback() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let model = makeModel(h)
        await model.openCalibration()
        await finishOpening(h)
        let session = try XCTUnwrap(model.calibration)
        session.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
        let closing = Task { await model.closeCalibration(.save) }
        await h.drain()
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        XCTAssertTrue(model.calibration === session)
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([5, 0, 0, 0, 2, 1])))
        await closing.value
        XCTAssertNil(model.calibration)
        XCTAssertEqual(session.entry?.saved, true)
    }

    func testDisconnectedCalibrationDoesNotReplayDraftOnReconnect() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let model = makeModel(h)
        await model.openCalibration()
        await finishOpening(h)
        let session = try XCTUnwrap(model.calibration)
        h.transport.canSendWriteWithoutResponse = false
        session.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
        await h.drain()
        h.transport.emit(.disconnected(attempt: h.attempt, reason: .disconnected))
        await h.drain()
        await model.closeCalibration(.restore)
        XCTAssertNil(model.calibration)
        XCTAssertNotNil(model.calibrationExitWarning)
        await h.clock.advance(by: 2)
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.gattReady(attempt: h.attempt))
        await h.drain()
        await h.finishPreparation()
        XCTAssertFalse(h.transport.commands.contains { if case .setCalibration = $0 { true } else { false } })
        XCTAssertFalse(session.canEdit)
    }

    func testSearchCanChangeDevicesWhileConnectedAndAfterUserDisconnect() async {
        let h = RobotLinkHarness()
        await h.connectReady()
        let model = makeModel(h)
        let before = h.transport.scans
        model.startSearch()
        await h.drain()
        XCTAssertEqual(h.transport.scans, before + 1)
        XCTAssertEqual(h.link.snapshot.state, .connected)
        XCTAssertEqual(h.transport.attempts.count, 1)
        model.disconnect()
        h.transport.emit(.disconnected(attempt: h.attempt, reason: .cancelled))
        await h.drain()
        model.startSearch()
        await h.drain()
        XCTAssertEqual(h.transport.scans, before + 2)
        XCTAssertEqual(h.link.snapshot.state, .searching)
        let other = RobotDevice(id: UUID(), name: "Another CatRobot", rssi: -50)
        h.transport.emit(.discovered(other))
        await h.drain()
        XCTAssertTrue(model.snapshot.discoveredDevices.contains(other))
        XCTAssertEqual(h.transport.attempts.count, 1)
        model.select(other)
        await h.drain()
        XCTAssertEqual(h.transport.attempts.last?.device, other.id)
    }

    func testManualSearchWithSavedDeviceWaitsForExplicitSelection() async {
        let h = RobotLinkHarness()
        h.preferences.selectedDevice = h.device
        let model = makeModel(h)
        model.startSearch()
        h.transport.emit(.bluetooth(state: .poweredOn))
        await h.drain()
        XCTAssertEqual(h.transport.scans, 1)
        XCTAssertTrue(h.transport.attempts.isEmpty)
    }

    func testLateOldSaveFailureCannotHideDisconnectOrTrapCalibrationAfterReconnect() async throws {
        let h = RobotLinkHarness()
        await h.connectReady()
        let delayed = DelayedCalibrationSendLink(base: h.link)
        let model = RobotSettingsModel(link: delayed, preferences: h.preferences, clock: h.clock)
        await model.openCalibration()
        await finishOpening(h)
        let session = try XCTUnwrap(model.calibration)
        session.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
        await h.drain()
        delayed.delaysSends = true
        let saving = Task { await model.closeCalibration(.save) }
        await h.drain()
        XCTAssertTrue(delayed.hasHeldSend)
        h.transport.emit(.disconnected(attempt: h.attempt, reason: .disconnected))
        await h.drain()
        await h.clock.advance(by: 2)
        h.transport.emit(.gattReady(attempt: h.attempt))
        await h.drain()
        await h.finishPreparation()
        delayed.failHeldSend()
        await saving.value
        XCTAssertEqual(session.phase, .failed(.disconnected))
        delayed.delaysSends = false
        await model.closeCalibration(.restore)
        XCTAssertNil(model.calibration)
        XCTAssertNotNil(model.calibrationExitWarning)
    }

    private func makeModel(_ h: RobotLinkHarness, modes: RecordedRobotModes = RecordedRobotModes()) -> RobotSettingsModel {
        RobotSettingsModel(link: h.link, preferences: h.preferences, clock: h.clock,
                           onControlModeChanged: { modes.values.append($0) })
    }

    private func finishOpening(_ h: RobotLinkHarness, saved: Bool = true) async {
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, saved ? 1 : 0])))
        await h.drain()
        h.transport.emit(.value(attempt: h.attempt, characteristic: .limits, data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
        await h.drain()
    }
}

@MainActor
private final class RecordedRobotModes { var values: [RobotControlMode] = [] }

/// Delivers an old send error after reconnect, independently of the snapshot stream.
@MainActor
private final class DelayedCalibrationSendLink: RobotLinkControlling {
    let base: any RobotLinkControlling
    var delaysSends = false
    private var held: CheckedContinuation<Void, Error>?
    var hasHeldSend: Bool { held != nil }
    init(base: any RobotLinkControlling) { self.base = base }
    var snapshot: RobotLinkSnapshot { base.snapshot }
    func updates() -> AsyncStream<RobotLinkSnapshot> { base.updates() }
    func start() { base.start() }
    func select(_ device: RobotDevice) { base.select(device) }
    func resume() { base.resume() }
    func suspend() { base.suspend() }
    func setApplicationActive(_ active: Bool) { base.setApplicationActive(active) }
    func disconnectByUser() { base.disconnectByUser() }
    func invalidate(_ token: UUID) { base.invalidate(token) }
    func read(_ characteristic: RobotCharacteristic) async throws -> Data { try await base.read(characteristic) }
    func send(_ command: RobotCommand, priority: RobotCommandPriority, token: UUID, expiresAt: TimeInterval) async throws {
        if delaysSends { try await withCheckedThrowingContinuation { held = $0 } }
        else { try await base.send(command, priority: priority, token: token, expiresAt: expiresAt) }
    }
    func settleAutomaticMotion(replacing owner: UUID, token: UUID, expiresAt: TimeInterval) async throws {
        try await base.settleAutomaticMotion(replacing: owner, token: token, expiresAt: expiresAt)
    }
    func failHeldSend() {
        let old = held
        held = nil
        old?.resume(throwing: RobotLinkFailure.notReady)
    }
}
