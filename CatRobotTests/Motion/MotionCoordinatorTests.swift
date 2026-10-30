import XCTest
@testable import CatRobot

@MainActor
final class MotionCoordinatorTests: XCTestCase {
    private let nod = RobotMotionRequest(gesture: .nod, intensity: .large, repeats: 3)

    func testFaceDrivenIdleWaitsForCueAndKeepsExistingCapsAndSpeed() async {
        let h = MotionHarness()
        h.motion.setIdleFaceDriven(true)
        h.motion.setConversationPhase(.listening)
        await h.advanceFresh(by: 12)
        XCTAssertTrue(h.sentCommands.isEmpty, "Face life owns the quiet intervals")
        h.motion.requestIdleFaceMotion(yaw: 20, pitch: -20)
        await h.drain()
        await h.advanceFresh(by: 3.1, step: 0.05)
        let moves = h.link.sent.filter { if case .move = $0.command { true } else { false } }
        XCTAssertFalse(moves.isEmpty)
        for move in moves {
            guard case let .move(yaw, pitch, speed) = move.command else { continue }
            XCTAssertLessThanOrEqual(abs(yaw), 30)
            XCTAssertLessThanOrEqual(abs(pitch), 20)
            XCTAssertEqual(speed, 10)
            XCTAssertEqual(move.priority, .idleMotion)
        }
        XCTAssertEqual(moves.last?.command, .move(yawDeci: 30, pitchDeci: -20, speed: 10))
    }

    func testFaceCueIsDroppedRatherThanReplayedAfterHigherPriorityWork() async {
        for gate in 0..<7 {
            let h = MotionHarness()
            h.motion.setIdleFaceDriven(true)
            h.motion.setConversationPhase(.listening)
            switch gate {
            case 0: h.motion.setControlMode(.settings)
            case 1: h.motion.setControlMode(.background)
            case 2: h.preferences.idleEnabled = false
            case 3:
                h.preferences.trackingEnabled = true
                h.motion.setTrackingState(.holding)
            case 4: h.motion.setAutomaticMotionSuspended(true)
            case 5: _ = h.reserve()
            default: await h.clock.advance(by: 2)
            }
            h.motion.requestIdleFaceMotion(yaw: 2, pitch: 1)
            if gate != 3 { h.motion.requestYawnMotion(pitch: -10) } // Yawn may now pause tracking.
            await h.drain()
            XCTAssertTrue(h.sentCommands.isEmpty, "gate \(gate)")
            h.motion.setControlMode(.conversation)
            h.preferences.idleEnabled = true
            h.preferences.trackingEnabled = false
            h.motion.setTrackingState(.disabled)
            h.motion.setAutomaticMotionSuspended(false)
            h.link.emitStatus(robotStatus())
            await h.advanceFresh(by: 10)
            XCTAssertTrue(h.sentCommands.isEmpty, "Rejected cues must not be queued: gate \(gate)")
        }
    }

    func testFaceCueCancellationInvalidatesBackpressuredWrite() async {
        let h = MotionHarness()
        h.motion.setIdleFaceDriven(true)
        h.motion.setConversationPhase(.listening)
        h.link.writable = false
        h.motion.requestIdleFaceMotion(yaw: 2, pitch: 0)
        await h.drain()
        XCTAssertFalse(h.link.queuedCommands.isEmpty)
        h.motion.cancelIdleFaceMotion()
        await h.drain()
        XCTAssertTrue(h.link.queuedCommands.isEmpty)
        h.link.writable = true
        await h.advanceFresh(by: 4)
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testCancellingFaceLifeCannotCancelTrackingTakingOverAnIdleWrite() async {
        let h = MotionHarness()
        h.motion.setIdleFaceDriven(true)
        h.motion.setConversationPhase(.listening)
        h.motion.requestIdleFaceMotion(yaw: 2, pitch: 0)
        await h.drain()
        XCTAssertFalse(h.sentCommands.isEmpty)
        h.preferences.trackingEnabled = true
        h.link.writable = false
        h.motion.setTrackingState(.following(.init(yaw: 12, pitch: 3, validUntil: h.clock.now + 1)))
        await h.drain()
        let tracking = RobotCommand.move(yawDeci: 120, pitchDeci: 30, speed: 20)
        XCTAssertTrue(h.link.queuedCommands.contains(tracking))
        h.motion.cancelIdleFaceMotion()
        await h.drain()
        XCTAssertTrue(h.link.queuedCommands.contains(tracking), "Face cancellation must not invalidate a higher-priority takeover")
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertTrue(h.sentCommands.contains(tracking))
    }

    func testNonFiniteFaceCuesAreIgnored() async {
        let h = MotionHarness()
        h.motion.setIdleFaceDriven(true)
        h.motion.setConversationPhase(.listening)
        h.motion.requestIdleFaceMotion(yaw: .nan, pitch: 0)
        h.motion.requestIdleFaceMotion(yaw: 0, pitch: .infinity)
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testSpeechReleasesOnceAndKeepsRunningAfterSpeechEnds() async {
        let h = MotionHarness()
        let turn = MotionTurnID()
        h.motion.beginTurn(turn)
        XCTAssertEqual(h.motion.reserve(.init(gesture: .nod, intensity: .large, repeats: 1), for: turn), .reserved(cycles: 1))
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
        h.motion.speechStarted(turn)
        h.motion.speechStarted(turn)
        h.motion.speechFinished(turn)
        h.motion.generationFinished(turn, outcome: .success)
        await h.drain()
        XCTAssertEqual(h.gestureCommands, [.gesture(id: 1, ampDeci: 150, repeats: 1, speed: 100)])
        await h.completeCycle(after: 1.52)
        XCTAssertFalse(h.sentCommands.contains(.stop))
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
    }

    func testBudgetCountsIndividualCycles() async {
        for (gesture, count, duration) in [(RobotGesture.nod, 2, 1.52), (.shake, 1, 2.08), (.lookUp, 1, 4.06)] {
            let h = MotionHarness()
            let turn = MotionTurnID()
            h.motion.beginTurn(turn)
            XCTAssertEqual(h.motion.reserve(.init(gesture: gesture, intensity: .large, repeats: 3), for: turn), .reserved(cycles: count))
            h.motion.speechStarted(turn)
            await h.drain()
            for _ in 0..<count { await h.completeCycle(after: duration) }
            XCTAssertEqual(h.gestureCommands.count, count)
            XCTAssertTrue(h.gestureCommands.allSatisfy { if case .gesture(_, _, 1, 100) = $0 { true } else { false } })
            XCTAssertFalse(h.sentCommands.contains(.stop))
        }
    }

    func testNewTurnDropsUnstartedOldCyclesButFinishesCurrent() async {
        let h = MotionHarness()
        let old = h.reserve(repeats: 3)
        h.motion.speechStarted(old)
        await h.drain()
        await h.startCycle()
        let next = h.reserve(.shake)
        h.motion.speechStarted(next)
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertEqual(h.motion.reserve(nod, for: old), .invalidated)
        await h.completeCycle(after: 1.52)
        XCTAssertEqual(h.gestureCommands, [.gesture(id: 1, ampDeci: 150, repeats: 1, speed: 100),
                                         .gesture(id: 2, ampDeci: 250, repeats: 1, speed: 100)])
        XCTAssertFalse(h.sentCommands.contains(.stop))
    }

    func testSettingsFinishesCycleAndCalibrationRejectsReservations() async {
        let h = MotionHarness()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        h.motion.setControlMode(.settings)
        h.motion.cancelTurn(turn, reason: .playbackCancelled)
        await h.completeCycle(after: 1.52)
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertFalse(h.sentCommands.contains(.stop))
        let next = MotionTurnID()
        h.motion.beginTurn(next)
        h.motion.setControlMode(.calibration(UUID()))
        XCTAssertEqual(h.motion.reserve(nod, for: next), .unavailable)
    }

    func testNoObservedStartWithinOneSecondDropsRemainingCycles() async {
        let h = MotionHarness()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.advanceFresh(by: 1.1)
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
    }

    func testStartedCycleTimesOutAndWaitsForStatusResynchronization() async {
        let h = MotionHarness()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        await h.advanceFresh(by: 3.45)
        XCTAssertEqual(h.link.statusReadCount, 0)
        await h.advanceFresh(by: 0.1)
        XCTAssertEqual(h.link.statusReadCount, 1)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        XCTAssertFalse(h.sentCommands.contains(.stop))

        // A notification alone cannot release an uncertain cycle or its old queue.
        h.link.emitStatus(robotStatus())
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 1)
        let next = MotionTurnID()
        h.motion.beginTurn(next)
        XCTAssertEqual(h.motion.reserve(nod, for: next), .unavailable)
        h.link.completeStatusRead(robotStatus())
        await h.drain()
        XCTAssertEqual(h.motion.reserve(.init(gesture: .shake, intensity: .large, repeats: 1), for: next), .reserved(cycles: 1))
        h.motion.speechStarted(next)
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 2)
    }

    func testCompletionDeadlineIsCappedAtTwentySecondsWithSlowReadbackLimits() async {
        let h = MotionHarness()
        let slow = RobotLimits(yawVelocityDeci: 10, pitchVelocityDeci: 10, yawAngleDeci: 600, pitchAngleDeci: 300)
        h.link.completeLimitsRead(slow)
        await h.drain()
        XCTAssertEqual(h.link.limitsReadCount, 1)
        // The attempted strength change did not apply; admission must use the actual low caps.
        h.link.completeLimitsRead(slow)
        await h.drain()
        let turn = h.reserve()
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        await h.advanceFresh(by: 19.9)
        XCTAssertEqual(h.link.statusReadCount, 0)
        await h.advanceFresh(by: 0.2)
        XCTAssertEqual(h.link.statusReadCount, 1)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        XCTAssertEqual(h.gestureCommands.count, 1)
        h.link.completeStatusRead(robotStatus())
        await h.drain()
    }

    func testCompletionTimeoutAlsoBoundsSettingsAndInactiveButBackgroundDoesNotRecover() async {
        for mode in [RobotControlMode.settings, .inactive] {
            let h = MotionHarness()
            let turn = h.reserve()
            h.motion.speechStarted(turn)
            await h.drain()
            await h.startCycle()
            h.motion.setControlMode(mode)
            await h.advanceFresh(by: 3.6)
            XCTAssertEqual(h.link.statusReadCount, 1, "\(mode)")
            XCTAssertFalse(h.sentCommands.contains(.stop))
            h.motion.setControlMode(.background)
            h.link.completeStatusRead(robotStatus())
            await h.drain()
            await h.advanceFresh(by: 25)
            XCTAssertEqual(h.link.statusReadCount, 1)
            XCTAssertEqual(h.gestureCommands.count, 1)
            XCTAssertFalse(h.sentCommands.contains(.stop))
        }
    }

    func testTimedOutCycleStillMovingOnReadReconnectsWithoutStop() async {
        let h = MotionHarness()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        await h.advanceFresh(by: 3.6)
        XCTAssertEqual(h.link.statusReadCount, 1)
        h.link.completeStatusRead(robotStatus(state: .active, flags: [.link, .moving, .gesture]))
        await h.drain()
        XCTAssertEqual(h.link.suspendCount, 1)
        XCTAssertEqual(h.link.snapshot.state, .reconnecting(.disconnected))
        XCTAssertFalse(h.sentCommands.contains(.stop))
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        h.link.reconnect()
        await h.drain()
        let next = h.reserve(.shake)
        h.motion.speechStarted(next)
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 2)
    }

    func testMeasuredOverrunDropsNextWithoutCuttingCurrent() async {
        let h = MotionHarness()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.completeCycle(after: 3.4)
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertFalse(h.sentCommands.contains(.stop))
    }

    func testLateOldCancellationCannotStopNewTurn() async {
        let h = MotionHarness()
        let old = h.reserve()
        h.motion.speechStarted(old)
        await h.drain()
        await h.completeCycle(after: 1.52)
        let next = h.reserve(.shake)
        h.motion.speechStarted(next)
        await h.drain()
        h.motion.cancelTurn(old, reason: .playbackCancelled)
        await h.drain()
        XCTAssertEqual(h.gestureCommands.count, 2)
        XCTAssertFalse(h.sentCommands.contains(.stop))
    }

    func testExplicitStopAndBackgroundUseDifferentCommands() async {
        for background in [false, true] {
            let h = MotionHarness()
            let turn = h.reserve()
            h.motion.speechStarted(turn)
            await h.drain()
            await h.startCycle()
            h.motion.stopAll(reason: background ? .background : .userStop)
            await h.drain()
            XCTAssertEqual(h.sentCommands.filter { $0 == .stop }.count, background ? 0 : 1)
            XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        }
    }

    func testTiltStartsLeftAndAlternatesOnlyWhenSent() async {
        let h = MotionHarness()
        for _ in 0..<3 {
            let turn = h.reserve(.tilt)
            h.motion.speechStarted(turn)
            await h.drain()
            await h.completeCycle(after: 2.48)
        }
        XCTAssertEqual(h.gestureCommands, [3, 4, 3].map { .gesture(id: $0, ampDeci: 150, repeats: 1, speed: 100) })
    }

    func testLookAtUserUsesOnlyFreshTrackingAndSaturatesAutonomousRange() async {
        for fresh in [false, true] {
            let h = MotionHarness()
            h.motion.setTrackingState(.following(.init(yaw: 90, pitch: -60, validUntil: fresh ? 10 : -1)))
            let turn = h.reserve(.lookAtUser, repeats: 3)
            h.motion.speechStarted(turn)
            await h.drain()
            XCTAssertEqual(h.sentCommands, fresh ? [.move(yawDeci: 450, pitchDeci: -200, speed: 100)] : [.center(speed: 100)])
        }
    }

    func testInvalidArgumentsAndMissingTurnDoNotReserve() {
        let h = MotionHarness()
        XCTAssertEqual(h.motion.reserve(nod, for: MotionTurnID()), .invalidated)
        let turn = MotionTurnID()
        h.motion.beginTurn(turn)
        for repeats in [0, 4] {
            XCTAssertEqual(h.motion.reserve(.init(gesture: .nod, intensity: .small, repeats: repeats), for: turn), .invalidArguments)
        }
    }

    func testIdleIntervalBoundsSmoothSamplesAndRate() async {
        let h = MotionHarness(random: ScriptedRobotRandom([4, 3, 2]))
        h.motion.setConversationPhase(.listening)
        await h.advanceFresh(by: 3.9)
        XCTAssertTrue(h.sentCommands.isEmpty)
        await h.advanceFresh(by: 0.1)
        await h.advanceFresh(by: 3.0, step: 0.05)
        let moves = h.link.sent.filter { if case .move = $0.command { true } else { false } }
        XCTAssertGreaterThan(moves.count, 20)
        for move in moves {
            guard case let .move(yaw, pitch, speed) = move.command else { return XCTFail() }
            XCTAssertLessThanOrEqual(abs(yaw), 30)
            XCTAssertLessThanOrEqual(abs(pitch), 20)
            XCTAssertEqual(speed, 10)
        }
        for pair in zip(moves, moves.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1.at - pair.0.at, 0.049_999) }
        XCTAssertEqual(moves.first?.command, .move(yawDeci: 0, pitchDeci: 0, speed: 10))
        XCTAssertEqual(moves.last?.command, .move(yawDeci: 30, pitchDeci: 20, speed: 10))
        XCTAssertEqual(moves.last!.at - moves.first!.at, 3.0, accuracy: 0.051)
    }

    func testToolSpeechInvalidatesBlockedIdleMove() async {
        let h = MotionHarness(random: ScriptedRobotRandom([4, 3, 2, 3.5]))
        h.motion.setConversationPhase(.listening)
        await h.advanceFresh(by: 4.1, step: 0.05)
        h.link.writable = false
        await h.advanceFresh(by: 0.05)
        XCTAssertTrue(h.link.queuedCommands.contains { if case .move = $0 { true } else { false } })
        let turn = h.reserve()
        h.motion.speechStarted(turn)
        await h.drain()
        let before = h.sentCommands.count
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertFalse(h.sentCommands.dropFirst(before).contains { if case .move = $0 { true } else { false } })
        XCTAssertEqual(h.gestureCommands.count, 1)
    }

    func testUtteranceAcknowledgementUsesPointSixSecondMoveColumn() async {
        let h = MotionHarness()
        h.motion.utteranceConfirmed()
        await h.drain()
        await h.advanceFresh(by: 0.6, step: 0.05)
        let moves = h.link.sent.filter { if case .move = $0.command { true } else { false } }
        XCTAssertEqual(moves.count, 13)
        XCTAssertEqual(moves.first?.command, .move(yawDeci: 0, pitchDeci: 0, speed: 100))
        XCTAssertEqual(moves.last?.command, .move(yawDeci: 0, pitchDeci: 0, speed: 100))
        XCTAssertTrue(moves.contains { $0.command == .move(yawDeci: 0, pitchDeci: -50, speed: 100) })
        XCTAssertTrue(h.gestureCommands.isEmpty)
    }

    func testAcknowledgementReturnsFromManualPoseAtCalibrationSpeed() async {
        let poses: [(Int16, Int16)] = [(-600, 0), (600, 0), (0, -300), (0, 300)]
        for (yaw, pitch) in poses {
            let h = MotionHarness()
            h.link.emitStatus(robotStatus(yaw: yaw, pitch: pitch))
            await h.drain()
            h.motion.utteranceConfirmed()
            await h.drain()
            await h.advanceFresh(by: 0.6, step: 0.05)
            let commands = h.sentCommands.filter { if case .move = $0 { true } else { false } }
            XCTAssertEqual(commands.count, 13)
            XCTAssertTrue(commands.allSatisfy {
                if case .move(_, _, 10) = $0 { true } else { false }
            }, "Automatic acknowledgement must not rapidly recenter a manual pose")
            XCTAssertEqual(commands.last, .move(yawDeci: 0, pitchDeci: 0, speed: 10))
        }
    }

    func testIdleEnabledKeepsPWMAcrossSettingsAndWaitingMovements() async {
        let h = MotionHarness()
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        h.motion.setControlMode(.calibration(UUID()))
        await h.drain()
        h.motion.setControlMode(.settings)
        await h.advanceFresh(by: 3)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        h.motion.setControlMode(.conversation)
        h.motion.setConversationPhase(.listening)
        await h.advanceFresh(by: 18, step: 0.05)
        XCTAssertTrue(h.sentCommands.contains { if case .move = $0 { true } else { false } })
        XCTAssertFalse(h.sentCommands.contains(.torque(false)), "Do not cycle PWM between idle movements")
        h.motion.stopAll(reason: .userStop)
        await h.drain()
        XCTAssertEqual(h.sentCommands.last, .stop)
    }

    func testEnablingIdleInvalidatesQueuedPWMStop() async {
        let h = MotionHarness()
        h.preferences.idleEnabled = false
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        await h.drain()
        h.link.writable = false
        await h.advanceFresh(by: 2)
        XCTAssertTrue(h.link.queuedCommands.contains(.torque(false)))
        h.preferences.idleEnabled = true
        await h.advanceFresh(by: 0.05)
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        await h.advanceFresh(by: 3)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
    }

    func testDisablingIdleStartsFreshRestPeriodBeforePWMStop() async {
        let h = MotionHarness()
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        h.motion.setControlMode(.settings)
        await h.drain()
        await h.advanceFresh(by: 3)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        h.preferences.idleEnabled = false
        await h.advanceFresh(by: 0.05)
        await h.advanceFresh(by: 1.9)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        await h.advanceFresh(by: 0.1)
        XCTAssertEqual(h.sentCommands.filter { $0 == .torque(false) }.count, 1)
    }

    func testIdleTorqueCannotStopNewMoveAfterBackpressure() async {
        let h = MotionHarness()
        h.preferences.idleEnabled = false
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        await h.drain()
        h.link.writable = false
        await h.advanceFresh(by: 2)
        XCTAssertTrue(h.link.queuedCommands.contains(.torque(false)))
        let turn = h.reserve()
        h.motion.speechStarted(turn)
        await h.drain()
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        XCTAssertEqual(h.gestureCommands.count, 1)
    }

    func testIdleTorqueIsActiveRestOnlyAndFiresOnce() async {
        let h = MotionHarness()
        h.preferences.idleEnabled = false
        await h.advanceFresh(by: 3)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        h.link.emitStatus(robotStatus(state: .active, flags: [.link, .torque]))
        await h.drain()
        await h.advanceFresh(by: 1.9)
        XCTAssertFalse(h.sentCommands.contains(.torque(false)))
        await h.advanceFresh(by: 0.1)
        await h.advanceFresh(by: 3)
        XCTAssertEqual(h.sentCommands.filter { $0 == .torque(false) }.count, 1)
        XCTAssertFalse(h.sentCommands.contains(.torque(true)))
    }

    func testStrengthWaitsForRestAndReadbackWithoutChangingAngles() async {
        let h = MotionHarness()
        let model = RobotSettingsModel(link: h.link, preferences: h.preferences, clock: h.clock)
        let turn = h.reserve()
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        h.preferences.strength = .calm
        await h.advanceFresh(by: 0.2)
        XCTAssertFalse(h.sentCommands.contains { if case .setLimits = $0 { true } else { false } })
        await h.completeCycle(after: 1.52)
        XCTAssertEqual(h.sentCommands.last, .setLimits(.init(yawVelocityDeci: 600, pitchVelocityDeci: 500, yawAngleDeci: 0, pitchAngleDeci: 0)))
        XCTAssertEqual(h.link.limitsReadCount, 1)
        XCTAssertEqual(model.displayedStrength, .standard)
        h.link.completeLimitsRead(.init(yawVelocityDeci: 600, pitchVelocityDeci: 500, yawAngleDeci: 600, pitchAngleDeci: 300))
        await h.drain()
        XCTAssertEqual(model.displayedStrength, .calm)
    }

    func testWrongStrengthReadbackKeepsActualDisplayAndDoesNotLoop() async {
        let h = MotionHarness()
        let model = RobotSettingsModel(link: h.link, preferences: h.preferences, clock: h.clock)
        h.preferences.strength = .active
        await h.advanceFresh(by: 0.1)
        XCTAssertEqual(h.sentCommands.last, .setLimits(.init(yawVelocityDeci: 1_800, pitchVelocityDeci: 1_200, yawAngleDeci: 0, pitchAngleDeci: 0)))
        h.link.completeLimitsRead(standardRobotLimits)
        await h.drain()
        await h.advanceFresh(by: 1)
        XCTAssertEqual(model.displayedStrength, .standard)
        XCTAssertEqual(h.sentCommands.filter { if case .setLimits = $0 { true } else { false } }.count, 1)
    }

    func testDisconnectDiscardsQueuedMotionAndNeverReplaysOnReconnect() async {
        let h = MotionHarness()
        h.link.writable = false
        let turn = h.reserve()
        h.motion.speechStarted(turn)
        await h.drain()
        h.link.disconnect()
        await h.drain()
        h.link.reconnect()
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
    }

    func testTimingTraceSeparatesSpeechAndPreviousCycleWait() async {
        let h = MotionHarness()
        let old = h.reserve()
        h.motion.speechStarted(old)
        await h.drain()
        await h.startCycle()
        await h.clock.advance(by: 0.2)
        let next = h.reserve(.shake)
        h.motion.speechStarted(next)
        await h.completeCycle(after: 1.32)
        let sent = h.trace.events.last { $0.turn == next && $0.point == .sent }
        XCTAssertEqual(sent?.at ?? -1, 1.52, accuracy: 0.001)
        XCTAssertEqual(sent?.speechToSend ?? -1, 1.32, accuracy: 0.001)
        XCTAssertEqual(sent?.previousCycleWait ?? -1, 1.32, accuracy: 0.001)
        XCTAssertNotNil(h.trace.events.first { $0.turn == next && $0.point == .eligible })
    }
    func testCenteringIsChargedOnlyForTheFirstPendingCycle() async {
        let h = MotionHarness()
        h.link.emitStatus(robotStatus(yaw: 450, pitch: 200))
        await h.drain()
        let turn = MotionTurnID()
        h.motion.beginTurn(turn)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .reserved(cycles: 2))
    }

    func testUnobservedReconnectCannotReleaseOldReservationOrScheduledWrite() async {
        for reconnectAfterSpeech in [false, true] {
            let h = MotionHarness()
            await h.drain()
            let turn = h.reserve()
            h.link.publishesUpdates = false
            if reconnectAfterSpeech { h.motion.speechStarted(turn) }
            h.link.disconnect()
            h.link.reconnect()
            if !reconnectAfterSpeech { h.motion.speechStarted(turn) }
            await h.drain()
            XCTAssertTrue(h.sentCommands.isEmpty)
            XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        }
    }

    func testAcknowledgementCannotCrossAnUnobservedConnectionEpoch() async {
        let h = MotionHarness()
        await h.drain()
        h.link.publishesUpdates = false
        h.motion.utteranceConfirmed()
        h.link.disconnect()
        h.link.reconnect()
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testRejectedReservationRecordsAnEnumeratedResult() {
        let h = MotionHarness()
        let turn = MotionTurnID()
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
        XCTAssertEqual(h.trace.events.last?.point, .reserved)
        XCTAssertEqual(h.trace.events.last?.result, .invalidated)
        h.motion.beginTurn(turn)
        h.motion.setControlMode(.settings)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .unavailable)
        XCTAssertEqual(h.trace.events.last?.result, .unavailable)
    }

    func testLookAtUserTargetExpiresWhileWaitingForFlowControl() async {
        let h = MotionHarness()
        h.motion.setTrackingState(.following(.init(yaw: 30, pitch: 10, validUntil: 0.1)))
        h.link.writable = false
        let turn = h.reserve(.lookAtUser)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.clock.advance(by: 0.2)
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testStrengthReadbackDoesNotDependOnSnapshotObserverOrdering() async {
        let h = MotionHarness()
        h.preferences.strength = .calm
        await h.advanceFresh(by: 0.1)
        XCTAssertEqual(h.link.limitsReadCount, 1)
        h.link.publishesUpdates = false
        h.link.completeLimitsRead(.init(yawVelocityDeci: 600, pitchVelocityDeci: 500, yawAngleDeci: 600, pitchAngleDeci: 300))
        await h.drain()
        XCTAssertEqual(h.sentCommands.filter { if case .setLimits = $0 { true } else { false } }.count, 1)
        h.motion.stopAll(reason: .linkLost)
        await h.drain()
    }

    // MARK: 50 ms timer lifetime (C27)

    func testTimerSleepsOnlyWhileConnected() async {
        let h = MotionHarness()
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "the 50 ms timer is armed while connected")
        h.link.disconnect()
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 0, "a disconnected coordinator schedules no wakeups")
        await h.clock.advance(by: 1)
        XCTAssertEqual(h.clock.pendingSleepCount, 0, "time passing while disconnected never re-arms the timer")
        h.link.reconnect()
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "reconnecting re-arms the timer")
    }

    func testTickDrivenDiscardStillRunsAfterReconnect() async {
        let h = MotionHarness()
        h.link.disconnect()
        await h.drain()
        await h.clock.advance(by: 1)
        h.link.reconnect()
        await h.drain()
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.advanceFresh(by: 1.1)
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertEqual(h.motion.reserve(nod, for: turn), .invalidated)
    }

    /// Only a lost link stops the timer. Every "connected but not ready" state is a recovery
    /// wait that the tick itself must keep observing.
    func testTimerStaysArmedWhileConnectedButNotReady() async {
        let h = MotionHarness()
        await h.drain()
        // Stale STATUS: over a second without a notification on a live link.
        await h.clock.advance(by: 1.1)
        let stale = MotionTurnID()
        h.motion.beginTurn(stale)
        XCTAssertEqual(h.motion.reserve(nod, for: stale), .unavailable)
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "a stale STATUS keeps the timer armed")
        // motionAvailable=false while connected: the firmware is returning to neutral.
        h.link.emitStatus(robotStatus(state: .returning, flags: [.link, .returning]))
        await h.drain()
        XCTAssertFalse(h.link.snapshot.motionAvailable)
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "motion unavailable on a live link keeps the timer armed")
        h.link.emitStatus(robotStatus())
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 1)
        // Completion timeout: the resynchronizing STATUS read is awaited with the timer running.
        let turn = h.reserve(repeats: 3)
        h.motion.speechStarted(turn)
        await h.drain()
        await h.startCycle()
        await h.advanceFresh(by: 3.55)
        XCTAssertEqual(h.link.statusReadCount, 1)
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "resynchronization never stops the timer")
    }

    func testCoordinatorCreatedWhileDisconnectedSchedulesNoWakeups() async {
        let h = MotionHarness(connected: false)
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 0, "no timer before the first connection")
        await h.clock.advance(by: 1)
        XCTAssertEqual(h.clock.pendingSleepCount, 0)
        h.link.reconnect()
        await h.drain()
        XCTAssertEqual(h.clock.pendingSleepCount, 1, "the first connection arms the timer")
    }
}
