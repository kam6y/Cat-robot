import XCTest
@testable import CatRobot

/// 会話画面が前面にある間は聞き取る。止めるのは猫のタップ、画面を離れる、設定を開くの 3 つだけ。
@MainActor
final class ConversationAutoResumeTests: XCTestCase {
    private func makeCoordinator(_ harness: ConversationHarness) -> ConversationAppCoordinator {
        ConversationAppCoordinator(viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
    }

    func testReturningToForegroundResumesListening() async {
        let harness = ConversationHarness()
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.background)
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .paused)

        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testCatTapPausesAndTheNextTapResumes() async {
        let harness = ConversationHarness()
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        let actions = coordinator.makeActions(openSettings: {})
        actions.toggleListening(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        actions.toggleListening(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testCatTapPauseIsLiftedByReturningToForeground() async {
        let harness = ConversationHarness()
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).toggleListening(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertTrue(harness.sut.viewState.showsTapToResume)
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening, "前面復帰はタップの一時停止より優先する")
        XCTAssertFalse(harness.sut.viewState.isAwaitingTapToResume)
        await harness.sut.shutdown()
    }

    func testForegroundDuringOnboardingDoesNotStartListening() async {
        let harness = ConversationHarness()
        let coordinator = makeCoordinator(harness)
        coordinator.scenePhaseDidChange(.active)
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(coordinator.destination, .onboarding)
        let starts = await harness.recognizer.startCount
        let permissionRequests = await harness.microphone.requestCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(permissionRequests, 0, "オンボーディングでは「会話を始める」までマイクを求めない")
        await harness.sut.shutdown()
    }

    func testForegroundWhileTheFirstStartIsStillRunningDoesNotStartTwice() async {
        let permissionGate = ConversationTestGate()
        let harness = ConversationHarness(permissionGate: permissionGate)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation()
        await permissionGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)   // 許可ダイアログで非アクティブになる
        coordinator.scenePhaseDidChange(.active)
        await permissionGate.open()
        await coordinator.waitForOperations()
        let starts = await harness.recognizer.startCount
        let permissionRequests = await harness.microphone.requestCount
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.shutdown()
    }

    // --- 境界: 設定を開く途中の前面復帰、削除中のシート閉鎖（codex レビューで指摘） ---

    func testForegroundWhileSettingsOpeningIsCancelledResumesOnceTheStopCompletes() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings()
        await stopGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.background)
        coordinator.scenePhaseDidChange(.active)
        await stopGate.open()
        await coordinator.waitForOperations()
        XCTAssertFalse(coordinator.showsVoiceSettings, "場面が変わったのでシートは出さない")
        XCTAssertEqual(harness.sut.viewState.phase, .listening, "前面なので聞き取りを再開する")
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testCancelledSettingsOpeningWhileStillInactiveWaitsForTheNextForeground() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings()
        await stopGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        await stopGate.open()
        await coordinator.waitForOperations()
        XCTAssertFalse(coordinator.showsVoiceSettings)
        XCTAssertEqual(harness.sut.viewState.phase, .paused, "非アクティブのままでは再開しない")
        var starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1)

        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testClosingSettingsWhileDeletingAllResumesAfterTheDeletionSucceeds() async {
        let forgetGate = ConversationTestGate()
        let memory = FakeConversationMemoryManager(forgetGate: forgetGate)
        let harness = ConversationHarness(memory: memory)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings(); await coordinator.waitForOperations()
        let deletion = Task { await coordinator.deleteAllMemory() }
        await forgetGate.waitUntilEntered()
        coordinator.closeVoiceSettings()          // 削除中に「完了」
        await Task.yield()
        XCTAssertEqual(harness.sut.viewState.phase, .paused, "削除中は始まらない")
        await forgetGate.open()
        await deletion.value
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .listening, "削除が終わったら再開する")
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testClosingSettingsWhileDeletingAllStaysPausedWhenTheDeletionFailsUntilRetrySucceeds() async {
        let forgetGate = ConversationTestGate()
        let memory = FakeConversationMemoryManager(forgetGate: forgetGate)
        await memory.setForgetFailure(true)
        let harness = ConversationHarness(memory: memory)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings(); await coordinator.waitForOperations()
        let deletion = Task { await coordinator.deleteAllMemory() }
        await forgetGate.waitUntilEntered()
        coordinator.closeVoiceSettings()
        await forgetGate.open()
        await deletion.value
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .forgetFailed(.deleteFailed))
        XCTAssertEqual(harness.sut.viewState.phase, .paused, "削除に失敗したら再開しない")
        var starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1)

        await memory.setForgetFailure(false)
        coordinator.makeActions(openSettings: {}).retryMemory()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .listening, "再試行が成功したら再開する")
        starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.sut.shutdown()
    }

    func testSaveRetryKeepsTheCatTapPause() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        let actions = coordinator.makeActions(openSettings: {})
        actions.toggleListening(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        actions.retryMemory(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .paused, "保存の再試行は猫タップの一時停止を解かない")
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1)
        await harness.sut.shutdown()
    }

    func testSaveRetryWhileListeningLeavesTheCaptureAlone() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).retryMemory(); await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1, "聞き取り中の保存再試行は開始し直さない")
        await harness.sut.shutdown()
    }

    func testDeletingAllWhileTheSheetStaysOpenDoesNotResume() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings(); await coordinator.waitForOperations()
        await coordinator.deleteAllMemory()
        await coordinator.waitForOperations()
        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1)
        await harness.sut.shutdown()
    }

    func testForegroundWithTheSettingsSheetOpenDoesNotResume() async {
        let harness = ConversationHarness()
        let coordinator = makeCoordinator(harness)
        coordinator.beginConversation(); await coordinator.waitForOperations()
        coordinator.makeActions(openSettings: {}).openVoiceSettings(); await coordinator.waitForOperations()
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 1)
        await harness.sut.shutdown()
    }
}
