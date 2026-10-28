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
            let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
            let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker, mode: .sentencePrefetch)
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
        XCTAssertEqual(dependencies.replyPlaybackMode, .sentencePrefetch)
    }
}
