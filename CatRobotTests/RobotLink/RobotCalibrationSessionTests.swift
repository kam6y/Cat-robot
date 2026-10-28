import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class RobotCalibrationSessionTests: XCTestCase {
    private let original = RobotCalibrationValues(yawOffsetDeci: 0, pitchOffsetDeci: 0, invert: 2)
    private let intended = RobotCalibrationValues(yawOffsetDeci: 25, pitchOffsetDeci: -10, invert: 3)

    func testBeginWaitsForRestAndFreshCalibrationAndLimits() async throws {
        let h = RobotLinkHarness()
        await h.connectReady(status: robotStatus(state: .active, flags: [.link, .gesture, .moving]))
        let session = RobotCalibrationSession(link: h.link, clock: h.clock)
        let opening = Task { try await session.begin() }
        await h.drain()
        XCTAssertEqual(session.phase, .waitingForRest)
        XCTAssertFalse(session.canEdit)
        XCTAssertEqual(h.transport.reads.filter { $0.characteristic == .calibration }.count, 1)
        session.preview(intended)
        XCTAssertTrue(calibrationWrites(h).isEmpty)
        h.receiveStatus(robotStatus())
        await h.drain()
        emitCalibration(original, saved: true, h: h)
        await h.drain()
        XCTAssertFalse(session.canEdit)
        emitLimits(h)
        try await opening.value
        XCTAssertTrue(session.canEdit)
        XCTAssertEqual(session.entry, .init(values: original, saved: true))
    }

    func testSaveConfirmsIntendedReadback() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        XCTAssertEqual(requests(h), [1])
        XCTAssertEqual(calibrationWrites(h).last, intended)
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        XCTAssertEqual(session.phase, .saving)
        XCTAssertNotEqual(session.entry?.values, intended)
        emitCalibration(intended, saved: true, h: h)
        let result = try await saving.value
        XCTAssertEqual(result, .init(values: intended, saved: true))
        XCTAssertEqual(session.entry, result)
        XCTAssertFalse(session.hasNewChanges)
    }

    func testPartialSetCalLossRestartsWithNewReq() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        emitCalibration(original, saved: true, h: h)
        await h.drain()
        XCTAssertEqual(requests(h), [1, 2])
        XCTAssertEqual(calibrationWrites(h).suffix(2), [intended, intended])
        h.receiveStatus(robotStatus(saveSeq: 2))
        await h.drain()
        emitCalibration(intended, saved: true, h: h)
        let result = try await saving.value
        XCTAssertEqual(result.values, intended)
    }

    func testSameReqRetryThreeAttemptsWhilePingContinues() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        for _ in 0..<3 { await advanceFresh(1, saveSeq: 255, h: h) }
        await expectFailure(saving, .timedOut)
        XCTAssertEqual(requests(h), [1, 1, 1])
        XCTAssertGreaterThanOrEqual(h.transport.commands.filter { if case .ping = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(session.draft, intended)
    }

    func testNvsErrorNeverReadsSuccessOrMarksSaved() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let before = h.transport.reads.filter { $0.characteristic == .calibration }.count
        let saving = Task { try await session.save() }
        await h.drain()
        h.receiveStatus(robotStatus(flags: [.link, .saveError], saveSeq: 1))
        await expectFailure(saving, .saveFailed)
        XCTAssertEqual(h.transport.reads.filter { $0.characteristic == .calibration }.count, before)
        XCTAssertEqual(session.draft, intended)
        XCTAssertNotEqual(session.entry?.values, intended)
    }

    func testSavedZeroCannotCompleteAndWholeRetryIsBounded() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        for seq: UInt8 in [1, 2] {
            h.receiveStatus(robotStatus(saveSeq: seq))
            await h.drain()
            emitCalibration(intended, saved: false, h: h)
            await h.drain()
        }
        await expectFailure(saving, .valueMismatch)
        XCTAssertEqual(requests(h), [1, 2])
        XCTAssertTrue(session.hasNewChanges)
    }

    func testOldSuccessCannotCompleteNewSaveAfterCancellation() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let oldSave = Task { try await session.save() }
        await h.drain()
        session.cancel()
        await expectFailure(oldSave, .cancelled)
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        XCTAssertEqual(session.phase, .closed)
        XCTAssertNotEqual(session.entry?.values, intended)

        let fresh = RobotCalibrationSession(link: h.link, clock: h.clock)
        try await open(fresh, entry: original, saved: true, h: h)
        fresh.preview(intended)
        let newSave = Task { try await fresh.save() }
        await h.drain()
        XCTAssertEqual(requests(h).last, 2)
        // Duplicate success from request 1 cannot satisfy the new request 2.
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        XCTAssertEqual(fresh.phase, .saving)
        h.receiveStatus(robotStatus(saveSeq: 2))
        await h.drain()
        emitCalibration(intended, saved: true, h: h)
        _ = try await newSave.value
    }

    func testOriginalDirtyEntryRemainsDirtyAfterRestore() async throws {
        let (h, session) = try await editing(saved: false)
        session.preview(intended)
        await h.drain()
        let restoring = Task { try await session.restoreEntry() }
        await h.drain()
        emitCalibration(original, saved: false, h: h)
        try await restoring.value
        XCTAssertEqual(session.draft, original)
        XCTAssertFalse(session.entry!.saved)
        XCTAssertFalse(session.hasNewChanges)
        XCTAssertTrue(requests(h).isEmpty)
    }

    func testPreviewRateLimitLatestValueAndSaveFreezeRejectLatePreview() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        let a = RobotCalibrationValues(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2)
        let b = RobotCalibrationValues(yawOffsetDeci: 10, pitchOffsetDeci: 0, invert: 2)
        let c = RobotCalibrationValues(yawOffsetDeci: 15, pitchOffsetDeci: 0, invert: 2)
        session.preview(a)
        await h.drain()
        session.preview(b)
        session.preview(c)
        await h.drain()
        XCTAssertEqual(calibrationWrites(h), [a])
        await h.clock.advance(by: 0.1)
        XCTAssertEqual(calibrationWrites(h), [a, c])
        h.transport.canSendWriteWithoutResponse = false
        session.preview(b)
        await h.clock.advance(by: 0.1)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        session.preview(a)
        XCTAssertEqual(session.draft, intended)
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        await h.drain()
        XCTAssertEqual(calibrationWrites(h), [a, c, intended])
        h.receiveStatus(robotStatus(saveSeq: 1))
        await h.drain()
        emitCalibration(intended, saved: true, h: h)
        _ = try await saving.value
    }

    func testDisconnectKeepsDraftAndNeverReplaysItAfterReconnect() async throws {
        let (h, session) = try await editing(saveSeq: 255)
        session.preview(intended)
        let saving = Task { try await session.save() }
        await h.drain()
        let count = h.transport.commands.count
        h.transport.emit(.disconnected(attempt: h.attempt, reason: .disconnected))
        await h.drain()
        await expectFailure(saving, .disconnected)
        XCTAssertEqual(session.draft, intended)
        XCTAssertFalse(session.canEdit)
        await h.clock.advance(by: 2)
        h.transport.emit(.gattReady(attempt: h.attempt))
        await h.drain()
        await h.finishPreparation()
        XCTAssertEqual(h.transport.commands.count, count)
        XCTAssertFalse(session.canEdit)
    }

    func testEdgesUseFacingUserDirectionsFreshLimitsAndLowSpeed() async throws {
        let (h, session) = try await editing()
        let edges: [RobotCalibrationEdge] = [.left, .right, .up, .down]
        for edge in edges {
            let move = Task { try await session.moveToEdge(edge) }
            await h.drain()
            h.transport.emit(.value(attempt: h.attempt, characteristic: .limits,
                                    data: Data([0xB0, 4, 0xE8, 3, 0xF4, 1, 0xFA, 0])))
            try await move.value
        }
        try await session.center()
        await session.stop()
        // Facing the robot, the user's left is the robot's negative yaw.
        XCTAssertEqual(h.transport.commands.suffix(6), [
            .move(yawDeci: -500, pitchDeci: 0, speed: 10),
            .move(yawDeci: 500, pitchDeci: 0, speed: 10),
            .move(yawDeci: 0, pitchDeci: 250, speed: 10),
            .move(yawDeci: 0, pitchDeci: -250, speed: 10),
            .center(speed: 10), .stop
        ])
    }

    func testClosingInvalidatesPreviewWaitingForFlowControl() async throws {
        let (h, session) = try await editing()
        h.transport.canSendWriteWithoutResponse = false
        session.preview(intended)
        await h.drain()
        session.cancel()
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        await h.drain()
        XCTAssertTrue(calibrationWrites(h).isEmpty)
    }

    func testGestureStartingAfterEntryInvalidatesQueuedCalibrationPreview() async throws {
        let (h, session) = try await editing()
        h.transport.canSendWriteWithoutResponse = false
        session.preview(intended)
        await h.drain()
        h.receiveStatus(robotStatus(state: .active, flags: [.link, .gesture, .moving]))
        await h.drain()
        XCTAssertFalse(session.canEdit)
        h.transport.canSendWriteWithoutResponse = true
        h.transport.emit(.readyToWrite(attempt: h.attempt))
        await h.drain()
        XCTAssertTrue(calibrationWrites(h).isEmpty)
        session.cancel()
    }

    private func editing(saveSeq: UInt8 = 0, saved: Bool = true) async throws -> (RobotLinkHarness, RobotCalibrationSession) {
        let h = RobotLinkHarness()
        await h.connectReady(status: robotStatus(saveSeq: saveSeq))
        let session = RobotCalibrationSession(link: h.link, clock: h.clock)
        try await open(session, entry: original, saved: saved, h: h)
        return (h, session)
    }
    private func open(_ session: RobotCalibrationSession, entry: RobotCalibrationValues,
                      saved: Bool, h: RobotLinkHarness) async throws {
        let opening = Task { try await session.begin() }
        await h.drain()
        emitCalibration(entry, saved: saved, h: h)
        await h.drain()
        emitLimits(h)
        try await opening.value
    }
    private func emitCalibration(_ values: RobotCalibrationValues, saved: Bool, h: RobotLinkHarness) {
        func le(_ v: Int16) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        h.transport.emit(.value(attempt: h.attempt, characteristic: .calibration,
                                data: Data(le(values.yawOffsetDeci) + le(values.pitchOffsetDeci) + [values.invert, saved ? 1 : 0])))
    }
    private func emitLimits(_ h: RobotLinkHarness) {
        h.transport.emit(.value(attempt: h.attempt, characteristic: .limits,
                                data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
    }
    private func calibrationWrites(_ h: RobotLinkHarness) -> [RobotCalibrationValues] {
        h.transport.commands.compactMap { if case let .setCalibration(values) = $0 { values } else { nil } }
    }
    private func requests(_ h: RobotLinkHarness) -> [UInt8] {
        h.transport.commands.compactMap { if case let .saveCalibration(req) = $0 { req } else { nil } }
    }
    private func advanceFresh(_ duration: TimeInterval, saveSeq: UInt8, h: RobotLinkHarness) async {
        for _ in 0..<Int((duration / 0.25).rounded()) {
            h.receiveStatus(robotStatus(saveSeq: saveSeq))
            await h.drain()
            await h.clock.advance(by: 0.25)
        }
    }
    private func expectFailure<T>(_ task: Task<T, Error>, _ expected: RobotLinkFailure) async {
        do { _ = try await task.value; XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RobotLinkFailure, expected) }
    }
}
