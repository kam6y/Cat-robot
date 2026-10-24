import XCTest
@testable import CatRobot

@MainActor
final class FaceTrackingMotionTests: XCTestCase {
    func testFaceAcquisitionPreemptsIdleIncludingItsQueuedNextSample() async {
        for backpressure in [false, true] {
            let h = makeHarness()
            h.motion.setConversationPhase(.listening)
            h.motion.setTrackingState(.searching)
            await h.advanceFresh(by: 4.25, step: 0.05)
            XCTAssertFalse(h.sentCommands.isEmpty)
            h.link.emitStatus(robotStatus(flags: [.link, .moving, .torque], yaw: -10))
            await h.drain()
            if backpressure {
                h.link.writable = false
                await h.advanceFresh(by: 0.05)
                XCTAssertFalse(h.link.queuedCommands.isEmpty)
            }
            let before = h.sentCommands.count
            follow(h, yaw: 20)
            await h.drain()
            h.link.writable = true
            h.link.flush()
            await h.drain()
            await h.advanceFresh(by: 0.3, step: 0.05)
            XCTAssertEqual(Array(h.sentCommands.dropFirst(before)), [.move(yawDeci: 200, pitchDeci: 0, speed: 20)])
        }
    }

    func testFaceLossSettlesOwnedMoveAtCurrentPoseOnce() async {
        let h = makeHarness()
        follow(h, yaw: 45)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 100, pitch: 20))
        await h.drain()
        h.motion.setTrackingState(.holding)
        await h.drain()
        h.motion.setTrackingState(.holding)
        await h.advanceFresh(by: 0.3)
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 450, pitchDeci: 0, speed: 20),
                                        .move(yawDeci: 100, pitchDeci: 20, speed: 10)])
    }

    func testAcknowledgementStartedDuringFaceHoldPreservesCurrentPose() async {
        let h = makeHarness()
        h.link.emitStatus(robotStatus(yaw: -340, pitch: 60))
        h.motion.setTrackingState(.holding)
        h.motion.utteranceConfirmed()
        await h.advanceFresh(by: 0.6, step: 0.05)
        XCTAssertFalse(h.sentCommands.isEmpty)
        XCTAssertTrue(h.sentCommands.allSatisfy {
            if case let .move(yaw, _, _) = $0 { yaw == -340 } else { false }
        })
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: -340, pitchDeci: 60, speed: 20))
    }

    func testFaceLossDoesNotInterruptAcknowledgement() async {
        let h = makeHarness()
        h.link.emitStatus(robotStatus(yaw: 300, pitch: 20))
        follow(h, yaw: 30, pitch: 2)
        await h.drain()
        h.motion.utteranceConfirmed()
        await h.advanceFresh(by: 0.2, step: 0.05)
        h.motion.setTrackingState(.holding)
        await h.advanceFresh(by: 0.4, step: 0.05)
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: 300, pitchDeci: 20, speed: 20))
        XCTAssertFalse(h.sentCommands.contains { if case .move(_, _, 10) = $0 { true } else { false } })
    }

    func testTrackingUsesSlowBoundedMovesDuringThinkingAndSpeaking() async {
        for phase in [ConversationPhase.thinking, .speaking, .classifying, .clarifying] {
            let h = makeHarness()
            h.motion.setConversationPhase(phase)
            follow(h, yaw: 90, pitch: -30)
            await h.drain()
            XCTAssertEqual(h.sentCommands, [.move(yawDeci: 450, pitchDeci: -100, speed: 20)])
        }
    }

    func testTrackingUpdatesItsOwnMovingTargetAtMostFiveTimesPerSecond() async {
        let h = makeHarness()
        follow(h, yaw: 10)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 30))
        await h.advanceFresh(by: 0.1)
        follow(h, yaw: 20)
        await h.advanceFresh(by: 0.1)
        follow(h, yaw: 30)
        await h.advanceFresh(by: 0.2)
        XCTAssertEqual(h.sentCommands, [10, 20, 30].map { .move(yawDeci: $0 * 10, pitchDeci: 0, speed: 20) })
        for pair in zip(h.link.sent, h.link.sent.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.at - pair.0.at, 0.199_999)
        }
    }

    func testExpiryRefreshOfSameAnglesDoesNotResend() async {
        let h = makeHarness()
        follow(h, yaw: 20)
        await h.drain()
        await h.advanceFresh(by: 0.2)
        follow(h, yaw: 20, lifetime: 5)
        await h.advanceFresh(by: 0.4)
        XCTAssertEqual(h.sentCommands.count, 1)
    }

    func testStationaryFaceNoiseDoesNotRestartTrackingButSlowDriftAccumulates() async {
        let h = makeHarness()
        follow(h, yaw: 20)
        await h.drain()
        for yaw in [20.1, 19.8, 20.7, 21.4, 21.9] {
            await h.advanceFresh(by: 0.35)
            follow(h, yaw: yaw)
            await h.drain()
        }
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 200, pitchDeci: 0, speed: 20)])
        await h.advanceFresh(by: 0.35)
        follow(h, yaw: 22)
        await h.drain()
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 200, pitchDeci: 0, speed: 20),
                                        .move(yawDeci: 220, pitchDeci: 0, speed: 20)])
    }

    func testTrackingStabilizesEachAxisIndependentlyWithoutDelayingLargeChanges() async {
        let h = makeHarness()
        follow(h, yaw: 20, pitch: 3)
        await h.drain()
        await h.advanceFresh(by: 0.35)
        follow(h, yaw: 20.9, pitch: 5)
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: 200, pitchDeci: 50, speed: 20))
        await h.advanceFresh(by: 0.35)
        follow(h, yaw: -20, pitch: 4.5)
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: -200, pitchDeci: 50, speed: 20))
        await h.advanceFresh(by: 0.35)
        follow(h, yaw: -20.5, pitch: -5)
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: -200, pitchDeci: -50, speed: 20))
    }

    func testTrackingReacquiresSameTargetAfterAnotherOwnerMovesTheNeck() async throws {
        let h = makeHarness()
        follow(h, yaw: 20)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .moving], yaw: 200))
        try await h.link.send(.center(speed: 20), priority: .motion, token: UUID(), expiresAt: h.clock.now + 1)
        await h.advanceFresh(by: 0.35)
        XCTAssertEqual(h.sentCommands.count, 2)
        h.link.emitStatus(robotStatus())
        follow(h, yaw: 20)
        // The new observation may replace the auto attempt started by the fresh rest STATUS.
        // Reacquisition must succeed at the next ordinary 5Hz command boundary.
        await h.advanceFresh(by: 0.2)
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 200, pitchDeci: 0, speed: 20),
                                        .center(speed: 20),
                                        .move(yawDeci: 200, pitchDeci: 0, speed: 20)])
    }

    func testOnlyLatestPendingTargetSurvivesBackpressure() async {
        let h = makeHarness()
        h.link.writable = false
        follow(h, yaw: 10)
        await h.drain()
        follow(h, yaw: 30)
        await h.advanceFresh(by: 0.2)
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 300, pitchDeci: 0, speed: 20)])
    }

    func testExpiredTargetDoesNotWriteAfterBackpressure() async {
        let h = makeHarness()
        h.link.writable = false
        follow(h, yaw: 10, lifetime: 0.1)
        await h.advanceFresh(by: 0.2)
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testToolReservationInvalidatesPendingTrackingBeforeSpeech() async {
        let h = makeHarness()
        h.link.writable = false
        follow(h, yaw: 10)
        await h.drain()
        let turn = h.reserve()
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
        h.motion.speechStarted(turn)
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 1)
    }

    func testEveryExpressiveToolUsesExecutionTimePoseOnAnchoredFirmware() async throws {
        for (gesture, id, amp) in [(RobotGesture.nod, 1, 150), (.shake, 2, 250), (.tilt, 3, 150),
                                    (.lookUp, 5, 200), (.lookDown, 6, 200)] {
            let h = makeHarness()
            h.link.emitInfo(.init(protocolVersion: 1, major: 0, minor: 2, patch: 0, hardwareID: 1, capabilities: 2))
            h.link.emitStatus(robotStatus(yaw: -200, pitch: 20))
            follow(h, yaw: -30, pitch: 6)
            await h.drain()
            let turn = h.reserve(gesture)
            h.link.emitStatus(robotStatus(yaw: -340, pitch: 60))
            h.motion.speechStarted(turn)
            await h.drain()
            let command = try XCTUnwrap(h.sentCommands.last)
            XCTAssertEqual(try RobotProtocol.encode(command), Data([10, UInt8(id), UInt8(amp), 1, 100, 0xAC, 0xFE, 60, 0]))
            XCTAssertFalse(h.sentCommands.contains(.stop))
            XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        }
    }

    func testTrackingDisabledKeepsLegacyGestureEvenOnCapableFirmware() async {
        let h = makeHarness()
        h.preferences.trackingEnabled = false
        h.link.emitInfo(.init(protocolVersion: 1, major: 0, minor: 2, patch: 0, hardwareID: 1, capabilities: 2))
        h.link.emitStatus(robotStatus(yaw: -340, pitch: 60))
        h.motion.speechStarted(h.reserve(.nod))
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .gesture(id: 1, ampDeci: 150, repeats: 1, speed: 100))
    }

    func testAnchoredGestureSurvivesFaceLossThenResumesOnlyFreshTracking() async {
        let h = makeHarness()
        h.link.emitInfo(.init(protocolVersion: 1, major: 0, minor: 2, patch: 0, hardwareID: 1, capabilities: 2))
        h.link.emitStatus(robotStatus(yaw: -340, pitch: 60))
        follow(h, yaw: -34, pitch: 6)
        await h.drain()
        h.motion.speechStarted(h.reserve(.nod))
        await h.drain()
        let gesture = h.sentCommands.last
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque, .moving, .gesture], yaw: -340, pitch: -80))
        await h.drain()
        h.motion.setTrackingState(.holding)
        await h.advanceFresh(by: 0.5)
        XCTAssertEqual(h.sentCommands.last, gesture)
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque], yaw: -340, pitch: 60))
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, gesture)
        follow(h, yaw: -30, pitch: 6)
        await h.advanceFresh(by: 0.2)
        XCTAssertEqual(h.sentCommands.last, .move(yawDeci: -300, pitchDeci: 60, speed: 20))
        XCTAssertFalse(h.sentCommands.contains(.center(speed: 100)))
    }

    func testToolKeepsCurrentPoseDuringFaceHoldAndExplicitCenterStillCenters() async throws {
        let h = makeHarness()
        h.link.emitInfo(.init(protocolVersion: 1, major: 0, minor: 2, patch: 0, hardwareID: 1, capabilities: 2))
        h.link.emitStatus(robotStatus(yaw: -340, pitch: 60))
        h.motion.setTrackingState(.holding)
        h.motion.speechStarted(h.reserve(.nod))
        await h.drain()
        XCTAssertEqual(try RobotProtocol.encode(try XCTUnwrap(h.sentCommands.last)),
                       Data([10, 1, 150, 1, 100, 0xAC, 0xFE, 60, 0]))
        await h.completeCycle(after: 2)
        h.motion.speechStarted(h.reserve(.center))
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .center(speed: 100))
    }

    func testToolSupersedesOwnedTrackingWithoutPowerInterruption() async {
        let h = makeHarness()
        follow(h, yaw: 20)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .torque, .moving], yaw: 80))
        await h.drain()
        h.motion.speechStarted(h.reserve())
        await h.drain()
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 200, pitchDeci: 0, speed: 20),
                                        .gesture(id: 1, ampDeci: 150, repeats: 1, speed: 100)])
    }

    func testTrackingAndToolsCannotStealUnownedMovingNeck() async {
        for flags: RobotStatusFlags in [[.link, .moving], [.link, .moving, .gesture]] {
            let h = makeHarness()
            h.link.emitStatus(robotStatus(flags: flags))
            await h.drain()
            follow(h, yaw: 20)
            h.motion.speechStarted(h.reserve())
            await h.advanceFresh(by: 0.3)
            XCTAssertTrue(h.sentCommands.isEmpty)
        }
    }

    func testInactiveAndDisableInvalidateUnsentTracking() async {
        for disabled in [true, false] {
            let h = makeHarness()
            h.link.writable = false
            follow(h, yaw: 20)
            await h.drain()
            if disabled { h.motion.setTrackingState(.disabled) }
            else { h.motion.setControlMode(.inactive) }
            h.link.writable = true
            h.link.flush()
            await h.drain()
            XCTAssertTrue(h.sentCommands.isEmpty)
        }
    }

    func testDisablingWrittenTrackingSettlesOnlyItsOwnMoveWithoutStop() async {
        let h = makeHarness()
        follow(h, yaw: 30)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .moving], yaw: 120, pitch: 20))
        await h.drain()
        h.motion.setTrackingState(.disabled)
        await h.drain()
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 300, pitchDeci: 0, speed: 20),
                                        .move(yawDeci: 120, pitchDeci: 20, speed: 10)])
    }

    func testDisableSeesWriteBeforeSendingTaskResumes() async {
        let h = makeHarness()
        h.link.writable = false
        follow(h, yaw: 30)
        await h.drain()
        h.link.writable = true
        h.link.flush()
        // The transport has written, but send's awaiting task has not resumed yet.
        h.motion.setTrackingState(.disabled)
        await h.drain()
        XCTAssertEqual(h.sentCommands, [.move(yawDeci: 300, pitchDeci: 0, speed: 20),
                                        .move(yawDeci: 0, pitchDeci: 0, speed: 10)])
    }

    func testFaceAcknowledgementDoesNotJumpFromPoseOutsideTrackingRange() async {
        let h = makeHarness()
        follow(h, yaw: 30)
        await h.drain()
        h.link.emitStatus(robotStatus(yaw: 500, pitch: 150))
        h.motion.utteranceConfirmed()
        await h.advanceFresh(by: 0.6, step: 0.05)
        XCTAssertEqual(h.sentCommands.count, 1)
    }

    func testDisconnectDiscardsTrackingOwnershipAndTarget() async {
        let h = makeHarness()
        follow(h, yaw: 20)
        await h.drain()
        h.link.disconnect()
        await h.drain()
        h.link.reconnect()
        h.link.emitStatus(robotStatus(flags: [.link, .moving]))
        await h.advanceFresh(by: 0.3)
        XCTAssertEqual(h.sentCommands.count, 1)
    }

    func testHoldingSuppressesIdleAndSearchingAllowsIt() async {
        let h = makeHarness()
        h.motion.setConversationPhase(.listening)
        h.motion.setTrackingState(.holding)
        await h.advanceFresh(by: 8)
        XCTAssertTrue(h.sentCommands.isEmpty)
        h.motion.setTrackingState(.searching)
        await h.advanceFresh(by: 4.1)
        XCTAssertFalse(h.sentCommands.isEmpty)
    }

    func testReturnWaitsForToolAndSendsOnlyOnce() async {
        let h = makeHarness()
        h.motion.speechStarted(h.reserve())
        await h.drain()
        await h.startCycle()
        h.motion.setTrackingState(.returnToCenter)
        await h.advanceFresh(by: 0.2)
        XCTAssertEqual(h.sentCommands.count, 1)
        await h.completeCycle(after: 1.5)
        await h.advanceFresh(by: 0.5)
        XCTAssertEqual(h.sentCommands.filter { $0 == .move(yawDeci: 0, pitchDeci: 0, speed: 10) }.count, 1)
    }

    func testTrackingHoldsPWMWhenIdleDisabledButExplicitStopWins() async {
        let h = makeHarness()
        h.preferences.idleEnabled = false
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        h.motion.setTrackingState(.searching)
        await h.advanceFresh(by: 3)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        h.motion.stopAll(reason: .userStop)
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .stop)
    }

    func testThermalSuspensionPreventsTrackingAndIdleUntilReleased() async {
        let h = makeHarness()
        h.motion.setConversationPhase(.listening)
        h.motion.setAutomaticMotionSuspended(true)
        follow(h, yaw: 20)
        await h.advanceFresh(by: 8)
        XCTAssertTrue(h.sentCommands.isEmpty)
        h.motion.setTrackingState(.searching)
        h.motion.setAutomaticMotionSuspended(false)
        await h.advanceFresh(by: 4.1)
        XCTAssertFalse(h.sentCommands.isEmpty)
    }

    func testFaceAcknowledgementKeepsYawAndReturnsToCurrentPitch() async {
        let h = makeHarness()
        h.link.emitStatus(robotStatus(yaw: 300, pitch: 20))
        follow(h, yaw: 30, pitch: 2)
        await h.drain()
        h.link.emitStatus(robotStatus(flags: [.link, .moving], yaw: 300, pitch: 20))
        h.motion.utteranceConfirmed()
        await h.drain()
        await h.advanceFresh(by: 0.6, step: 0.05)
        let moves = h.sentCommands.compactMap { command -> (Int16, Int16)? in
            if case let .move(yaw, pitch, _) = command { (yaw, pitch) } else { nil }
        }
        XCTAssertTrue(moves.allSatisfy { $0.0 == 300 })
        XCTAssertTrue(moves.contains { $0.1 == -30 })
        XCTAssertEqual(moves.last?.1, 20)
    }

    func testFaceAcknowledgementShrinksOrSkipsAtLowerPitchLimit() async {
        for (pitch, expectedCount, expectedMinimum): (Int16, Int, Int16) in [(-80, 14, -100), (-95, 1, -95)] {
            let h = makeHarness()
            h.link.emitStatus(robotStatus(yaw: 300, pitch: pitch))
            follow(h, yaw: 30, pitch: Double(pitch) / 10)
            await h.drain()
            h.motion.utteranceConfirmed()
            await h.drain()
            await h.advanceFresh(by: 0.6, step: 0.05)
            let pitches = h.sentCommands.compactMap { command -> Int16? in
                if case let .move(_, p, _) = command { p } else { nil }
            }
            XCTAssertEqual(pitches.count, expectedCount)
            XCTAssertEqual(pitches.min(), expectedMinimum)
            XCTAssertEqual(pitches.last, pitch)
        }
    }

    private func makeHarness() -> MotionHarness {
        let h = MotionHarness()
        h.preferences.trackingEnabled = true
        return h
    }
    private func follow(_ h: MotionHarness, yaw: Double, pitch: Double = 0, lifetime: TimeInterval = 2) {
        h.motion.setTrackingState(.following(.init(yaw: yaw, pitch: pitch, validUntil: h.clock.now + lifetime)))
    }
}
