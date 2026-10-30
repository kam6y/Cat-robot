import XCTest
@testable import CatRobot

@MainActor
final class RobotAppHarness {
    let ble = RobotLinkHarness()
    let base = ControlledReply()
    let motion: MotionCoordinator
    let playback: PlaybackIntegrationHarness
    let settings: RobotSettingsModel
    let coordinator: ConversationAppCoordinator
    let faceSource: FakeFaceCaptureSource?
    let faceTracking: FaceTrackingCoordinator?

    init(faceEnabled: Bool = false, idleClock: (any RobotClock)? = nil) {
        ble.preferences.idleEnabled = false
        motion = MotionCoordinator(link: ble.link, clock: ble.clock, preferences: ble.preferences,
                                   random: ScriptedRobotRandom())
        let source = ReservingMotionReply(base: base, motion: motion)
        playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: source, motion: motion), motion: motion)
        let motion = motion
        let capture = faceEnabled ? FakeFaceCaptureSource() : nil
        faceSource = capture
        let face: FaceTrackingCoordinator?
        if let capture {
            face = FaceTrackingCoordinator(source: capture, link: ble.link, clock: ble.clock,
                preferences: ble.preferences, motion: motion)
        } else { face = nil }
        faceTracking = face
        settings = RobotSettingsModel(link: ble.link, preferences: ble.preferences, clock: ble.clock,
                                      onControlModeChanged: { motion.setControlMode($0); face?.setControlMode($0) })
        coordinator = ConversationAppCoordinator(viewModel: playback.viewModel,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }),
            link: ble.link, motion: motion, settingsModel: settings, faceTracking: face,
            idleSettings: ConversationIdleSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            idleClock: idleClock ?? ConversationIdleClock())
    }
    func startConnectedConversation() async {
        await ble.connectReady()
        coordinator.beginConversation()
        await coordinator.waitForOperations()
    }
    func startTypedWave() async -> Task<Void, Never> {
        await startConnectedConversation()
        let run = Task { await playback.viewModel.submitTypedText("質問") }
        await base.waitUntilRequested()
        await base.yield("最初。続き")
        await playback.speaker.waitUntilCallCount(1)
        await playback.speaker.emit(.started)
        await ble.drain()
        ble.receiveStatus(robotStatus(state: .active, flags: [.link, .torque, .moving, .gesture]))
        await ble.drain()
        return run
    }
    func finishAudio(_ run: Task<Void, Never>) async {
        await base.finish()
        await playback.speaker.complete()
        await playback.speaker.waitUntilCallCount(2)
        await playback.speaker.complete()
        await run.value
    }
    func freshAdvance(_ seconds: TimeInterval) async {
        var remaining = seconds
        while remaining > 0.000_001 {
            let step = min(0.2, remaining)
            await ble.clock.advance(by: step)
            ble.receiveStatus(ble.link.snapshot.status!)
            await ble.drain()
            remaining -= step
        }
    }
    var commands: [RobotCommand] { ble.transport.commands }
}

@MainActor
final class RobotLifecycleIntegrationTests: XCTestCase {
    func testCancellingUnwrittenYawnSettlesPreviousTrackingMove() async throws {
        for openSettings in [false, true] {
            let h = RobotAppHarness()
            await h.startConnectedConversation()
            h.ble.preferences.idleEnabled = true
            h.ble.preferences.trackingEnabled = true
            h.motion.setConversationPhase(.listening)
            h.motion.setTrackingState(.following(.init(yaw: 25, pitch: 4, validUntil: h.ble.clock.now + 1)))
            await h.ble.drain()
            h.ble.receiveStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 120, pitch: 20))
            await h.ble.drain()
            h.ble.transport.canSendWriteWithoutResponse = false
            let cue = try XCTUnwrap(CatFaceLifePlanner.yawn().frames.compactMap(\.neckCue).first)
            let actions = h.coordinator.makeActions(openSettings: {})
            actions.idleFaceMotion(cue)
            await h.ble.drain()
            let before = h.commands.count
            if openSettings { h.motion.setControlMode(.settings) }
            else { actions.cancelIdleFaceMotion() }
            h.ble.transport.canSendWriteWithoutResponse = true
            h.ble.transport.emit(.readyToWrite(attempt: h.ble.attempt))
            await h.ble.drain()
            let moves = h.commands.dropFirst(before).filter { if case .move = $0 { true } else { false } }
            XCTAssertEqual(moves, [.move(yawDeci: 120, pitchDeci: 20, speed: 10)],
                           "Cancel before the first yawn write must still stop the previous tracking move")
            h.coordinator.scenePhaseDidChange(.background)
        }
    }

    func testYawnTemporarilyTakesOverMovingTrackingAndResumesItsLatestTarget() async throws {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.ble.preferences.idleEnabled = true
        h.ble.preferences.trackingEnabled = true
        h.motion.setConversationPhase(.listening)
        h.motion.setTrackingState(.following(.init(yaw: 20, pitch: 4, validUntil: h.ble.clock.now + 1)))
        await h.ble.drain()
        h.ble.receiveStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 170, pitch: 30))
        await h.ble.drain()
        let before = h.commands.count
        let cue = try XCTUnwrap(CatFaceLifePlanner.yawn().frames.compactMap(\.neckCue).first)
        h.coordinator.makeActions(openSettings: {}).idleFaceMotion(cue)
        await h.ble.drain()
        // New camera targets keep arriving; none may interrupt the yawn.
        for _ in 0..<28 {
            h.motion.setTrackingState(.following(.init(yaw: -20, pitch: 2, validUntil: h.ble.clock.now + 1)))
            await h.freshAdvance(0.1)
        }
        let during = h.commands.dropFirst(before).filter { if case .move = $0 { true } else { false } }
        XCTAssertFalse(during.isEmpty)
        XCTAssertTrue(during.allSatisfy {
            if case let .move(yaw, pitch, speed) = $0 { yaw == 170 && abs(pitch) <= 100 && speed == 10 }
            else { false }
        }, "The yawn keeps the actual yaw instead of recentering or following camera updates")
        await h.freshAdvance(0.4)
        let moves = h.commands.dropFirst(before).filter { if case .move = $0 { true } else { false } }
        XCTAssertTrue(moves.contains(.move(yawDeci: 170, pitchDeci: -100, speed: 10)))
        XCTAssertEqual(moves.last, .move(yawDeci: -200, pitchDeci: 20, speed: 20))
        h.coordinator.scenePhaseDidChange(.background)
    }

    func testYawnCueReachesTenDegreesThroughTheRealAppAction() async throws {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.ble.preferences.idleEnabled = true
        h.motion.setConversationPhase(.listening)
        let cue = try XCTUnwrap(CatFaceLifePlanner.yawn().frames.compactMap(\.neckCue).first)
        h.coordinator.makeActions(openSettings: {}).idleFaceMotion(cue)
        await h.freshAdvance(3.1)
        let moves = h.commands.compactMap { command -> (Int16, Int16, UInt8)? in
            if case let .move(yaw, pitch, speed) = command { return (yaw, pitch, speed) }
            return nil
        }
        let last = try XCTUnwrap(moves.last)
        XCTAssertEqual(last.0, 0)
        XCTAssertEqual(last.1, -100, "Yawn must reach 10°, not be clamped by the ordinary idle limit")
        XCTAssertTrue(moves.allSatisfy { abs($0.0) <= 30 && abs($0.1) <= 100 && $0.2 == 10 })
        h.coordinator.scenePhaseDidChange(.background)
    }

    func testFaceAcquisitionPreemptsIdleThroughRealLinkUnderBackpressure() async {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.ble.preferences.idleEnabled = true
        h.motion.setConversationPhase(.listening)
        h.motion.setTrackingState(.searching)
        // The visible face now owns idle timing; exercise the real app action.
        h.coordinator.makeActions(openSettings: {}).idleFaceMotion(.init(yaw: -1, pitch: 0))
        await h.freshAdvance(1.2)
        XCTAssertTrue(h.commands.contains { if case .move = $0 { true } else { false } })
        h.ble.receiveStatus(robotStatus(flags: [.link, .moving, .torque], yaw: -10))
        await h.ble.drain()
        h.ble.transport.canSendWriteWithoutResponse = false
        await h.freshAdvance(0.1)
        let before = h.commands.count
        h.motion.setTrackingState(.following(.init(yaw: 20, pitch: 0, validUntil: h.ble.clock.now + 1)))
        await h.ble.drain()
        h.ble.transport.canSendWriteWithoutResponse = true
        h.ble.transport.emit(.readyToWrite(attempt: h.ble.attempt))
        await h.ble.drain()
        await h.freshAdvance(0.2)
        let newMoves = h.commands.dropFirst(before).filter { if case .move = $0 { true } else { false } }
        XCTAssertEqual(newMoves, [.move(yawDeci: 200, pitchDeci: 0, speed: 20)])
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testInactiveSettlesWrittenTrackingThroughRealLink() async {
        for backpressure in [false, true] {
            let h = RobotAppHarness(faceEnabled: true)
            await h.startConnectedConversation()
            h.motion.setConversationPhase(.listening)
            h.motion.setTrackingState(.following(.init(yaw: 30, pitch: 0, validUntil: h.ble.clock.now + 1)))
            await h.ble.drain()
            XCTAssertTrue(h.commands.contains(.move(yawDeci: 300, pitchDeci: 0, speed: 20)))
            h.ble.receiveStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 100, pitch: 20))
            await h.ble.drain()
            h.ble.transport.canSendWriteWithoutResponse = !backpressure
            h.coordinator.scenePhaseDidChange(.inactive)
            await h.coordinator.waitForOperations()
            await h.ble.drain()
            h.ble.transport.canSendWriteWithoutResponse = true
            h.ble.transport.emit(.readyToWrite(attempt: h.ble.attempt))
            await h.ble.drain()
            XCTAssertEqual(h.commands.last, .move(yawDeci: 100, pitchDeci: 20, speed: 10))
            XCTAssertFalse(h.commands.contains(.stop))
            XCTAssertTrue(h.ble.transport.disconnects.isEmpty)
            h.coordinator.scenePhaseDidChange(.background)
            await h.coordinator.waitForOperations()
            await h.playback.viewModel.shutdown()
        }
    }

    func testRealRobotLinkCaptureStopsSynchronouslyForSettingsAndBackground() async throws {
        let h = RobotAppHarness(faceEnabled: true)
        await h.startConnectedConversation()
        let source = try XCTUnwrap(h.faceSource)
        XCTAssertEqual(source.starts.count, 1)
        h.coordinator.openVoiceSettings()
        XCTAssertEqual(source.stops, 1)
        await h.coordinator.waitForOperations()
        h.coordinator.closeVoiceSettings()
        await h.coordinator.waitForOperations()
        XCTAssertEqual(source.starts.count, 2)
        h.coordinator.scenePhaseDidChange(.background)
        XCTAssertEqual(source.stops, 2)
        XCTAssertEqual(h.ble.transport.disconnects.count, 1)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testSettingsModeIsSetBeforePlaybackCancellationAndWaveFinishes() async {
        let h = RobotAppHarness()
        let run = await h.startTypedWave()
        h.coordinator.openVoiceSettings()
        XCTAssertEqual(h.settings.effectiveControlMode, .settings)
        await h.coordinator.waitForOperations()
        await run.value
        XCTAssertTrue(h.coordinator.showsVoiceSettings)
        XCTAssertFalse(h.commands.contains(.stop))
        await h.freshAdvance(1.52)
        h.ble.receiveStatus(robotStatus(state: .active, flags: [.link, .torque]))
        await h.ble.drain()
        XCTAssertEqual(h.commands.filter { if case .gesture = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(h.commands.contains { if case .ping = $0 { true } else { false } })
        XCTAssertFalse(h.commands.contains(.stop))
        await h.playback.viewModel.shutdown()
    }

    func testBackgroundUsesDisconnectInsteadOfStopAndJoinsPlayback() async {
        let h = RobotAppHarness()
        let run = await h.startTypedWave()
        h.coordinator.scenePhaseDidChange(.background)
        XCTAssertEqual(h.ble.transport.disconnects.count, 1)
        await h.coordinator.waitForOperations()
        await run.value
        XCTAssertFalse(h.commands.contains(.stop))
        let count = h.commands.count
        await h.freshAdvance(2)
        await h.base.yield("古い返答。")
        await h.playback.speaker.complete(run: 0)
        await h.playback.viewModel.shutdown()
        await h.ble.drain()
        XCTAssertEqual(h.commands.count, count)
    }

    func testInactiveKeepsConnectionAndDoesNotStopCurrentWave() async {
        let h = RobotAppHarness()
        let run = await h.startTypedWave()
        h.coordinator.scenePhaseDidChange(.inactive)
        await h.coordinator.waitForOperations()
        await run.value
        await h.freshAdvance(1.1)
        XCTAssertTrue(h.ble.transport.disconnects.isEmpty)
        XCTAssertFalse(h.commands.contains(.stop))
        XCTAssertTrue(h.commands.contains { if case .ping = $0 { true } else { false } })
        h.coordinator.scenePhaseDidChange(.background)
        await h.playback.viewModel.shutdown()
    }

    func testPermissionInactiveKeepsEncryptedHandshakeAndPausesOnlyItsUserWait() async {
        let h = RobotAppHarness()
        await h.ble.beginGatt()
        h.ble.transport.emit(.value(attempt: h.ble.attempt, characteristic: .info, data: Data([1, 0, 1, 0, 1, 0, 0, 0])))
        await h.ble.drain()
        h.coordinator.beginConversation()
        await h.coordinator.waitForOperations()
        h.coordinator.scenePhaseDidChange(.inactive)
        await h.ble.clock.advance(by: 40)
        XCTAssertTrue(h.ble.transport.disconnects.isEmpty)
        XCTAssertEqual(h.ble.link.snapshot.state, .preparing)
        h.coordinator.scenePhaseDidChange(.active)
        await h.ble.clock.advance(by: 29)
        XCTAssertTrue(h.ble.transport.disconnects.isEmpty)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testFirstConversationAndActiveResumeOnlyTheSavedDevice() async {
        for saved in [false, true] {
            let h = RobotAppHarness()
            if saved { h.ble.preferences.selectedDevice = h.ble.device }
            h.coordinator.scenePhaseDidChange(.active)
            XCTAssertEqual(h.ble.transport.starts, 0)
            h.coordinator.beginConversation()
            h.ble.transport.emit(.bluetooth(state: .poweredOn))
            await h.coordinator.waitForOperations()
            await h.ble.drain()
            XCTAssertEqual(h.ble.transport.starts, saved ? 1 : 0)
            XCTAssertEqual(h.ble.transport.retrievals, saved ? [h.ble.device.id] : [])
            XCTAssertEqual(h.playback.viewModel.viewState.phase, .listening)
            h.coordinator.scenePhaseDidChange(.background)
            await h.coordinator.waitForOperations()
            await h.playback.viewModel.shutdown()
        }
    }

    func testRepeatedActiveDoesNotDuplicateConnectionOrHeartbeat() async {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.coordinator.scenePhaseDidChange(.active)
        h.coordinator.scenePhaseDidChange(.active)
        await h.coordinator.waitForOperations()
        await h.freshAdvance(2)
        XCTAssertEqual(h.ble.transport.starts, 1)
        XCTAssertEqual(h.ble.transport.attempts.count, 1)
        XCTAssertEqual(h.commands.filter { if case .ping = $0 { true } else { false } }.count, 2)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testExplicitStopAndNewConversationStopWaveAfterAudioHasEnded() async {
        for newConversation in [false, true] {
            let h = RobotAppHarness()
            let run = await h.startTypedWave()
            await h.finishAudio(run)
            if newConversation { h.coordinator.makeActions(openSettings: {}).startNewConversation() }
            else { h.coordinator.makeActions(openSettings: {}).toggleListening() }
            await h.coordinator.waitForOperations()
            await h.ble.drain()
            XCTAssertEqual(h.commands.filter { $0 == .stop }.count, 1)
            h.coordinator.scenePhaseDidChange(.background)
            await h.coordinator.waitForOperations()
            await h.playback.viewModel.shutdown()
        }
    }

    func testSettingsCannotCloseUntilCalibrationSaveOrRestoreReadCompletes() async throws {
        for save in [false, true] {
            let h = RobotAppHarness()
            await h.startConnectedConversation()
            h.coordinator.openVoiceSettings()
            await h.coordinator.waitForOperations()
            await h.settings.openCalibration()
            await h.ble.drain()
            emitCalibration(Data([0, 0, 0, 0, 2, 1]), h: h)
            await h.ble.drain()
            emitLimits(h)
            await h.ble.drain()
            let session = try XCTUnwrap(h.settings.calibration)
            session.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
            let closing = Task { await h.settings.closeCalibration(save ? .save : .restore) }
            await h.ble.drain()
            if save {
                h.ble.receiveStatus(robotStatus(saveSeq: 1))
                await h.ble.drain()
            }
            h.coordinator.closeVoiceSettings()
            await h.coordinator.waitForOperations()
            let starts = await h.playback.recognizer.startCount
            XCTAssertTrue(h.coordinator.showsVoiceSettings)
            XCTAssertEqual(starts, 1)
            emitCalibration(Data([save ? 5 : 0, 0, 0, 0, 2, 1]), h: h)
            await closing.value
            h.coordinator.closeVoiceSettings()
            await h.coordinator.waitForOperations()
            let resumed = await h.playback.recognizer.startCount
            XCTAssertEqual(resumed, 2)
            XCTAssertEqual(h.playback.viewModel.viewState.phase, .listening)
            h.coordinator.scenePhaseDidChange(.background)
            await h.coordinator.waitForOperations()
            await h.playback.viewModel.shutdown()
        }
    }

    func testBackgroundCalibrationExitCannotReenableMotionOrReplayDraft() async throws {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.coordinator.openVoiceSettings()
        await h.coordinator.waitForOperations()
        await h.settings.openCalibration()
        await h.ble.drain()
        emitCalibration(Data([0, 0, 0, 0, 2, 1]), h: h)
        await h.ble.drain()
        emitLimits(h)
        await h.ble.drain()
        h.ble.transport.canSendWriteWithoutResponse = false
        h.settings.calibration?.preview(.init(yawOffsetDeci: 5, pitchOffsetDeci: 0, invert: 2))
        await h.ble.drain()
        let old = h.ble.attempt
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        h.ble.transport.emit(.disconnected(attempt: old, reason: .cancelled))
        await h.ble.drain()
        await h.settings.closeCalibration(.restore)
        XCTAssertEqual(h.settings.effectiveControlMode, .background)
        XCTAssertNil(h.settings.calibration)
        XCTAssertNotNil(h.settings.calibrationExitWarning)
        h.coordinator.scenePhaseDidChange(.active)
        await h.ble.clock.advance(by: 2)
        h.ble.transport.canSendWriteWithoutResponse = true
        h.ble.transport.emit(.gattReady(attempt: h.ble.attempt))
        await h.ble.drain()
        await h.ble.finishPreparation()
        XCTAssertFalse(h.commands.contains { if case .setCalibration = $0 { true } else { false } })
        XCTAssertTrue(h.coordinator.showsVoiceSettings)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testInactiveDropsUnsentManualMoveAndDoesNotReplayItOnActive() async {
        let h = RobotAppHarness()
        await h.startConnectedConversation()
        h.ble.transport.canSendWriteWithoutResponse = false
        let move = RobotCommand.move(yawDeci: 100, pitchDeci: 0, speed: 10)
        let sending = Task { try await h.ble.link.send(move, priority: .calibration, token: UUID(), expiresAt: h.ble.clock.now + 0.3) }
        await h.ble.drain()
        h.coordinator.scenePhaseDidChange(.inactive)
        h.ble.transport.canSendWriteWithoutResponse = true
        h.ble.transport.emit(.readyToWrite(attempt: h.ble.attempt))
        await h.ble.drain()
        do { try await sending.value; XCTFail("Inactive manual movement must be discarded") }
        catch { XCTAssertEqual(error as? RobotLinkFailure, .notReady) }
        h.coordinator.scenePhaseDidChange(.active)
        await h.coordinator.waitForOperations()
        XCTAssertFalse(h.commands.contains(move))
        XCTAssertTrue(h.ble.transport.disconnects.isEmpty)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testSavedDeviceUnknownBluetoothPermissionWaitHasThirtyActiveSeconds() async {
        let h = RobotAppHarness()
        h.ble.preferences.selectedDevice = h.ble.device
        h.coordinator.beginConversation()
        await h.coordinator.waitForOperations()
        h.coordinator.scenePhaseDidChange(.inactive)
        await h.ble.clock.advance(by: 40)
        XCTAssertNil(h.ble.link.snapshot.failure)
        h.coordinator.scenePhaseDidChange(.active)
        await h.ble.clock.advance(by: 30.1)
        XCTAssertEqual(h.ble.link.snapshot.failure, .timedOut)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testViewModelForwardsPhasesAndOneConfirmedVoiceUtterance() async {
        let spy = MotionControllerSpy()
        let base = ControlledReply()
        let h = PlaybackIntegrationHarness(service: base, motion: spy)
        let run = await h.beginVoiceTurn()
        await base.waitUntilRequested()
        await h.viewModel.flushSegmentation(at: 11.2)
        XCTAssertEqual(spy.confirmations, 1)
        XCTAssertTrue(spy.phases.contains(.listening))
        XCTAssertTrue(spy.phases.contains(.thinking))
        await base.yield("返答。")
        await base.finish()
        await h.speaker.waitUntilCallCount(1)
        await h.speaker.complete()
        await run.value
        XCTAssertTrue(spy.phases.contains(.speaking))
        await h.viewModel.shutdown()
    }

    func testActualSynthesisFailureStopsCurrentWaveEvenInSettingsMode() async {
        let h = MotionHarness()
        let base = ControlledReply()
        let source = ReservingMotionReply(base: base, motion: h.motion)
        let speaker = ControlledSpeaker()
        let sut = ReplyPlaybackCoordinator(reply: MotionReplyGenerator(base: source, motion: h.motion),
                                           speaker: speaker, motion: h.motion)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await base.waitUntilRequested()
        await base.yield("最初。続き")
        await speaker.waitUntilCallCount(1)
        await speaker.emit(.started)
        await h.drain()
        await h.startCycle()
        h.motion.setControlMode(.settings)
        await speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        do { _ = try await run.value; XCTFail("Expected synthesis failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        await h.drain()
        XCTAssertEqual(h.sentCommands.filter { $0 == .stop }.count, 1)
    }

    func testStrengthCancelledForInactiveIsDeferredAndRetriedOnActive() async {
        let h = MotionHarness()
        h.link.writable = false
        h.preferences.strength = .calm
        await h.advanceFresh(by: 0.1)
        XCTAssertTrue(h.link.queuedCommands.contains { if case .setLimits = $0 { true } else { false } })
        h.motion.setControlMode(.inactive)
        await h.drain()
        h.motion.setControlMode(.conversation)
        h.link.writable = true
        h.link.flush()
        await h.drain()
        XCTAssertEqual(h.sentCommands.filter { if case .setLimits = $0 { true } else { false } }.count, 1)
        h.link.completeLimitsRead(.init(yawVelocityDeci: 600, pitchVelocityDeci: 500, yawAngleDeci: 600, pitchAngleDeci: 300))
        await h.drain()
    }

    private func emitCalibration(_ data: Data, h: RobotAppHarness) {
        h.ble.transport.emit(.value(attempt: h.ble.attempt, characteristic: .calibration, data: data))
    }
    private func emitLimits(_ h: RobotAppHarness) {
        h.ble.transport.emit(.value(attempt: h.ble.attempt, characteristic: .limits, data: Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])))
    }
}
