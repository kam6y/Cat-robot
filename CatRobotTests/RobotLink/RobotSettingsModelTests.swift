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
        await model.closeCalibration(.cancelNavigation)
        XCTAssertTrue(model.calibration === session)
        let closing = Task { await model.closeCalibration(.restore) }
        await h.drain()
        XCTAssertEqual(h.transport.commands.last, .setCalibration(.init(yawOffsetDeci: 0, pitchOffsetDeci: 0, invert: 2)))
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration, data: Data([0, 0, 0, 0, 2, 0])))
        await closing.value
        XCTAssertNil(model.calibration)
        XCTAssertEqual(session.entry?.saved, false)
        XCTAssertFalse(h.transport.commands.contains { if case .saveCalibration = $0 { true } else { false } })
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
