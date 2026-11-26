import XCTest
@testable import CatRobot

@MainActor
final class VoiceSettingsIntegrationTests: XCTestCase {
    func testOpeningStopsConversationAndClosingRestartsIt() async {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut, wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings(); await coordinator.waitForOperations()
        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        coordinator.makeActions(openSettings: {}).toggleListening()
        await coordinator.waitForOperations()
        let startsWhileOpen = await harness.recognizer.startCount
        XCTAssertEqual(startsWhileOpen, 1, "シートが開いている間の操作は無視する")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        coordinator.closeVoiceSettings(); await coordinator.waitForOperations()
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2, "閉じたら自動で再開する")
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.shutdown()
    }
    /// 会話の履歴も設定と同じく、開く前に会話を止め、開いている間の操作を受けず、閉じたら再開する。
    /// 開く途中で背景に移ったら、遅れて履歴を出さない。
    func testHistorySheetStopsConversationAndClosingRestartsIt() async {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut, wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        coordinator.beginConversation(); await coordinator.waitForOperations()
        let actions = coordinator.makeActions(openSettings: {})
        actions.openHistory(); await coordinator.waitForOperations()
        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(coordinator.sheet, .history)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        actions.toggleListening()
        actions.requestNewConversation()
        await coordinator.waitForOperations()
        XCTAssertFalse(coordinator.confirmsNewConversation, "履歴を開いている間は会話メニューの操作を受けない")
        let startsWhileOpen = await harness.recognizer.startCount
        XCTAssertEqual(startsWhileOpen, 1, "履歴が開いている間の操作は無視する")
        coordinator.closeVoiceSettings(); await coordinator.waitForOperations()
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2, "閉じたら自動で再開する")
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        actions.openHistory()
        coordinator.scenePhaseDidChange(.background)
        await coordinator.waitForOperations()
        XCTAssertFalse(coordinator.showsVoiceSettings, "背景に移ったら遅れて履歴を出さない")
        await harness.sut.shutdown()
    }
    func testSettingsSupersedePermissionAndBackgroundDoesNotOpenLateSheet() async {
        for background in [false, true] {
            let gate = ConversationTestGate()
            let harness = ConversationHarness(permissionGate: gate)
            let coordinator = ConversationAppCoordinator(viewModel: harness.sut, wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
            coordinator.beginConversation(); await gate.waitUntilEntered()
            coordinator.makeActions(openSettings: {}).openVoiceSettings()
            if background { coordinator.scenePhaseDidChange(.background) }
            await gate.open(); await coordinator.waitForOperations()
            XCTAssertEqual(coordinator.showsVoiceSettings, !background)
            let starts = await harness.recognizer.startCount
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(harness.sut.viewState.phase, .paused)
            await harness.sut.shutdown()
        }
    }
    func testSettingsCancelThinkingAndSpeakingWithoutResettingMemory() async throws {
        for speaking in [false, true] {
            let player = ControlledPCMPlayer()
            let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
            let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker)
            let coordinator = ConversationAppCoordinator(viewModel: harness.viewModel, wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
            let run = Task { await harness.viewModel.submitTypedText("質問") }
            await harness.reply.waitUntilRequested()
            if speaking {
                await harness.reply.yield("一文目。続き")
                await player.waitForCalls(1)
            }
            coordinator.makeActions(openSettings: {}).openVoiceSettings()
            await coordinator.waitForOperations(); await run.value
            XCTAssertTrue(coordinator.showsVoiceSettings)
            XCTAssertEqual(harness.viewModel.viewState.phase, .paused)
            let resets = await harness.reply.resetCount
            XCTAssertEqual(resets, 0)
            coordinator.closeVoiceSettings()
            XCTAssertEqual(harness.viewModel.viewState.phase, .paused)
            await harness.viewModel.shutdown()
        }
    }
    func testLiveCompositionUsesSupertonicWithMeasuredSentencePrefetch() {
        let defaults = UserDefaults(suiteName: "LiveComposition.\(UUID())")!
        let dependencies = ConversationComposition.live(voiceSettings: SpeechVoiceSettings(defaults: defaults)).dependencies
        XCTAssertTrue(dependencies.speaker is SupertonicSentenceSpeaker)
    }
}
