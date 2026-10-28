import XCTest
@testable import CatRobot

@MainActor
final class ConversationIdleIntegrationTests: XCTestCase {
    private func app(_ h: ConversationHarness, clock: ManualRobotClock) -> ConversationAppCoordinator {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return ConversationAppCoordinator(viewModel: h.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(),
            idleSettings: ConversationIdleSettings(defaults: defaults),
            idleClock: clock)
    }

    func testSleepingStopsCaptureAndOnlyFaceTapRestartsIt() async {
        let h = ConversationHarness(), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 600); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        var starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 1)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        app.scenePhaseDidChange(.active); await app.waitForOperations()
        app.openVoiceSettings(); await app.waitForOperations()
        app.closeVoiceSettings(); await app.waitForOperations()
        let actions = app.makeActions(openSettings: {})
        actions.startNewConversation(); actions.performRecovery(.retry)
        actions.showTypedInput(); actions.sendTypedText()
        await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 1)
        actions.toggleListening(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 2)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testForegroundAndSettingsCloseEvaluateExpiredTimeBeforeStartingMicrophone() async {
        for settings in [false, true] {
            let h = ConversationHarness(), clock = ManualRobotClock()
            let app = app(h, clock: clock)
            app.beginConversation(); await app.waitForOperations()
            await clock.advance(by: 100)
            if settings { app.openVoiceSettings() } else { app.scenePhaseDidChange(.background) }
            await app.waitForOperations()
            await clock.advance(by: 500)
            if settings { app.closeVoiceSettings() } else { app.scenePhaseDidChange(.active) }
            await app.waitForOperations()
            XCTAssertEqual(app.inactivity.state, .sleeping)
            XCTAssertEqual(h.sut.viewState.phase, .paused)
            let starts = await h.recognizer.startCount
            XCTAssertEqual(starts, 1)
            app.scenePhaseDidChange(.background); await app.waitForOperations()
            await h.sut.shutdown()
        }
    }

    func testAddressedSpeechAndTypedTurnsResetButBackgroundSpeechDoesNot() async {
        for kind in ["wake", "addressed", "typed", "notAddressed", "ambiguous"] {
            let classification: AddressTarget = kind == "notAddressed" ? .notAddressed : kind == "ambiguous" ? .ambiguous : .addressed
            let h = ConversationHarness(classification: classification), clock = ManualRobotClock()
            let app = app(h, clock: clock)
            app.beginConversation(); await app.waitForOperations()
            await clock.advance(by: 350)
            XCTAssertEqual(app.inactivity.state, .sleepy, kind)
            if kind == "typed" { await h.sut.submitTypedText("こんにちは") }
            else { await h.emitCompletedUtterance(kind == "wake" ? "猫ちゃん" : "今日は何曜日？", at: 350) }
            let resets = ["wake", "addressed", "typed"].contains(kind)
            XCTAssertEqual(app.inactivity.state, resets ? .awake : .sleepy, kind)
            await clock.advance(by: 250); await app.waitForOperations()
            XCTAssertEqual(app.inactivity.state, resets ? .awake : .sleeping, kind)
            app.scenePhaseDidChange(.background); await app.waitForOperations()
            await h.sut.shutdown()
        }
    }

    func testTapDuringSleepShutdownWaitsAndResumesExactlyOnce() async {
        let gate = ConversationTestGate()
        let h = ConversationHarness(recognizerStopGate: gate), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 600)
        await gate.waitUntilEntered()
        app.makeActions(openSettings: {}).toggleListening()
        await robotDrain()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        await gate.open(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 2)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }
    func testSleepingStopsRealTrackingAndAutomaticMotionUntilTap() async throws {
        let clock = ManualRobotClock()
        let h = RobotAppHarness(faceEnabled: true, idleClock: clock)
        h.ble.preferences.trackingEnabled = true
        await h.startConnectedConversation()
        XCTAssertEqual(h.faceSource?.starts.count, 1)
        h.motion.setConversationPhase(.listening)
        h.motion.setTrackingState(.following(.init(yaw: 30, pitch: 0, validUntil: h.ble.clock.now + 1)))
        await h.ble.drain()
        XCTAssertTrue(h.commands.contains(.move(yawDeci: 300, pitchDeci: 0, speed: 20)))
        h.ble.receiveStatus(robotStatus(flags: [.link, .moving, .torque], yaw: 100, pitch: 20))
        await h.ble.drain()
        await clock.advance(by: 600)
        await h.coordinator.waitForOperations()
        await h.ble.drain()
        XCTAssertEqual(h.coordinator.inactivity.state, .sleeping)
        XCTAssertEqual(h.faceSource?.stops, 1)
        XCTAssertEqual(h.settings.effectiveControlMode, .inactive)
        XCTAssertEqual(h.commands.last, .move(yawDeci: 100, pitchDeci: 20, speed: 10))
        let moves = h.commands.filter { if case .move = $0 { true } else { false } }
        h.motion.setTrackingState(.following(.init(yaw: -30, pitch: 0, validUntil: h.ble.clock.now + 10)))
        await h.freshAdvance(5)
        XCTAssertEqual(h.commands.filter { if case .move = $0 { true } else { false } }, moves)
        h.coordinator.makeActions(openSettings: {}).toggleListening()
        await h.coordinator.waitForOperations()
        XCTAssertEqual(h.faceSource?.starts.count, 2)
        XCTAssertEqual(h.settings.effectiveControlMode, .conversation)
        h.coordinator.scenePhaseDidChange(.background)
        await h.coordinator.waitForOperations()
        await h.playback.viewModel.shutdown()
    }

    func testForegroundDuringPauseAtExpiredDeadlineStillWakesOnce() async {
        let gate = ConversationTestGate()
        let h = ConversationHarness(recognizerStopGate: gate), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 590)
        app.scenePhaseDidChange(.inactive)
        await gate.waitUntilEntered()
        await clock.advance(by: 20)
        app.scenePhaseDidChange(.active)
        XCTAssertEqual(app.inactivity.state, .sleeping)
        app.makeActions(openSettings: {}).toggleListening()
        await robotDrain()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        await gate.open(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 2)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testSaveRetryWhileSleepingSavesWithoutWaking() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let h = ConversationHarness(memory: memory), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 600); await app.waitForOperations()
        app.makeActions(openSettings: {}).retryMemory(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.memoryState, .ready)
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 1)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testLongReplyFinishesBeforeSleepingWithoutResettingTheDeadline() async {
        let h = ConversationHarness(speakerAutomaticallyFinishes: false), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        let turn = Task { await h.emitCompletedUtterance("猫ちゃん、話して", at: 0) }
        await h.speaker.waitUntilTextCount(1)
        await h.speaker.yield(.started)
        let speaking = await h.waitUntil { h.sut.viewState.phase == .speaking }
        XCTAssertTrue(speaking)
        await clock.advance(by: 600)
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .speaking)
        await h.speaker.yield(.finished); await h.speaker.finish()
        await turn.value; await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testSpeechBeginningBeforeDeadlineCanFinishAndResetSleep() async {
        let h = ConversationHarness(), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 599)
        await h.emit(.provisional("猫ちゃん"), at: 599)
        await clock.advance(by: 1); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleepy)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        await h.emitCompletedUtterance("猫ちゃん、こんにちは", at: 600)
        XCTAssertEqual(app.inactivity.state, .awake)
        await clock.advance(by: 299)
        XCTAssertEqual(app.inactivity.state, .awake)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testUnfinishedRecognitionDefersButDoesNotResetTheDeadline() async {
        let h = ConversationHarness(), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 590)
        await h.emit(.provisional("周囲の声"), at: 590)
        await clock.advance(by: 10); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleepy)
        await h.sut.flushSegmentation(at: 610)
        await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testTypedOnlyConversationSleepsAfterMicrophoneDenial() async {
        let h = ConversationHarness(microphoneAllowed: false), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .failed(.microphoneDenied))
        await clock.advance(by: 100)
        let actions = app.makeActions(openSettings: {})
        actions.performRecovery(.showTypedInput)
        actions.updateTypedText("こんにちは")
        actions.sendTypedText(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        actions.updateTypedText("書きかけの質問")
        await clock.advance(by: 299)
        XCTAssertEqual(app.inactivity.state, .awake)
        await clock.advance(by: 1)
        XCTAssertEqual(app.inactivity.state, .sleepy)
        await clock.advance(by: 300); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.typedText, "書きかけの質問")
        actions.toggleListening(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .failed(.microphoneDenied))
        XCTAssertEqual(h.sut.viewState.typedText, "書きかけの質問")
        actions.sendTypedText(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        let starts = await h.recognizer.startCount
        let prompts = await h.reply.prompts
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(prompts, ["こんにちは", "書きかけの質問"])
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testDeniedMicrophoneWithoutTypedInputStillSleepsAfterExplicitStart() async {
        let h = ConversationHarness(microphoneAllowed: false), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .failed(.microphoneDenied))
        await clock.advance(by: 300)
        XCTAssertEqual(app.inactivity.state, .sleepy)
        await clock.advance(by: 300); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 0)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testTerminalSpeechFailureStillReachesStandby() async {
        let h = ConversationHarness(speakerError: .speechSynthesisFailed), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await h.emitCompletedUtterance("猫ちゃん、こんにちは", at: 0)
        XCTAssertEqual(h.sut.viewState.phase, .failed(.speechSynthesisFailed))
        await clock.advance(by: 299)
        XCTAssertEqual(app.inactivity.state, .awake)
        await clock.advance(by: 1)
        XCTAssertEqual(app.inactivity.state, .sleepy)
        var presentation = h.sut.viewState
        presentation.inactivity = app.inactivity.state
        XCTAssertEqual(presentation.faceExpression, .sorry, "エラーの案内は寝るまで表示する")
        await clock.advance(by: 300); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        let beforeWake = await h.recognizer.startCount
        XCTAssertEqual(beforeWake, 1)
        app.makeActions(openSettings: {}).toggleListening(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        let afterWake = await h.recognizer.startCount
        XCTAssertEqual(afterWake, 2)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testExpiredDeadlineDuringFailureCleanupSleepsAndWakesOnce() async {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let h = ConversationHarness(speakerError: .speechSynthesisFailed, audioDeactivateGate: gate)
        let clock = ManualRobotClock(), app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        let turn = Task { await h.emitCompletedUtterance("猫ちゃん、こんにちは", at: 0) }
        await gate.waitUntilEntered()
        await clock.advance(by: 600)
        XCTAssertEqual(app.inactivity.state, .awake, "失敗の後片付けが完了するまでは処理中")
        await gate.open(); await turn.value; await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        await clock.advance(by: 600); await app.waitForOperations()
        let beforeWake = await h.recognizer.startCount
        XCTAssertEqual(beforeWake, 1)
        app.makeActions(openSettings: {}).toggleListening(); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .awake)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        let afterWake = await h.recognizer.startCount
        XCTAssertEqual(afterWake, 2)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testStandbyClearsOldCaptionButKeepsTypedDraftAfterWake() async {
        let h = ConversationHarness(replySnapshots: ["前の返事"]), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await h.emitCompletedUtterance("猫ちゃん、こんにちは", at: 0)
        XCTAssertEqual(h.sut.viewState.caption, "前の返事")
        let actions = app.makeActions(openSettings: {})
        actions.showTypedInput(); actions.updateTypedText("書きかけの質問")
        await clock.advance(by: 600); await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.caption, "")
        XCTAssertEqual(h.sut.viewState.typedText, "書きかけの質問")
        actions.toggleListening(); await app.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        XCTAssertEqual(h.sut.viewState.caption, "")
        XCTAssertEqual(h.sut.viewState.typedText, "書きかけの質問")
        XCTAssertTrue(h.sut.viewState.showsTypedInput)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

    func testIgnoredSpeechAtDeadlineReleasesPendingWithoutResettingActivity() async {
        let h = ConversationHarness(), clock = ManualRobotClock()
        let app = app(h, clock: clock)
        app.beginConversation(); await app.waitForOperations()
        await clock.advance(by: 599)
        await h.emit(.provisional("えっ"), at: 599)
        await clock.advance(by: 1)
        XCTAssertEqual(app.inactivity.state, .sleepy)
        await h.emitCompletedUtterance("えっと", at: 600)
        await app.waitForOperations()
        XCTAssertEqual(app.inactivity.state, .sleeping)
        XCTAssertEqual(h.sut.viewState.phase, .paused)
        let classifications = await h.classifier.calls, prompts = await h.reply.prompts
        XCTAssertTrue(classifications.isEmpty)
        XCTAssertTrue(prompts.isEmpty)
        app.scenePhaseDidChange(.background); await app.waitForOperations()
        await h.sut.shutdown()
    }

}
