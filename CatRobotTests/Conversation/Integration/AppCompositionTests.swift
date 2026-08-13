import XCTest
@testable import CatRobot

@MainActor
final class AppCompositionTests: XCTestCase {
    func testRootConstructionLeavesAllConversationServicesLazy() async {
        let harness = ConversationHarness()
        let idleTimer = TestIdleTimerStorage(initialValue: false)

        _ = AppRootView(
            dependencies: harness.dependencies,
            wakeLock: idleTimer.makeWakeLock()
        )

        let microphoneRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let speakerPreparations = await harness.speaker.prepareCount
        let recognizerPreparations = await harness.recognizer.prepareCount
        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertEqual(availabilityChecks, 0)
        XCTAssertEqual(speakerPreparations, 0)
        XCTAssertEqual(recognizerPreparations, 0)
        XCTAssertEqual(recognizerStarts, 0)
        XCTAssertEqual(audioActivations, 0)
        XCTAssertEqual(idleTimer.writes, [])
    }

    func testPermissionPromptInactiveIsDeferredAndOriginalStartFinishesExactlyOnce() async {
        let permissionGate = ConversationTestGate()
        let harness = ConversationHarness(permissionGate: permissionGate)
        let idleTimer = TestIdleTimerStorage(initialValue: false)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: idleTimer.makeWakeLock()
        )

        coordinator.beginConversation()
        XCTAssertEqual(coordinator.destination, .conversation)
        await permissionGate.waitUntilEntered()
        XCTAssertTrue(harness.sut.isAwaitingMicrophonePermission)

        coordinator.scenePhaseDidChange(.inactive)
        XCTAssertEqual(harness.sut.viewState.phase, .preparing)
        XCTAssertFalse(idleTimer.value)

        await permissionGate.open()
        let advancedWhileInactive = await harness.waitUntil(timeout: .milliseconds(50)) {
            await harness.modelAvailability.checkCount > 0
        }
        XCTAssertFalse(advancedWhileInactive)
        XCTAssertEqual(harness.sut.viewState.phase, .preparing)

        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()

        let microphoneRequests = await harness.microphone.requestCount
        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertEqual(recognizerStarts, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertTrue(idleTimer.value)
    }

    func testPermissionCompletionRechecksSceneAfterImmediateActiveInactivePair() async {
        let permissionGate = ConversationTestGate()
        let harness = ConversationHarness(permissionGate: permissionGate)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock()
        )

        coordinator.beginConversation()
        await permissionGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        await permissionGate.open()

        coordinator.scenePhaseDidChange(.active)
        coordinator.scenePhaseDidChange(.inactive)

        let advancedDuringSecondInactive = await harness.waitUntil(timeout: .milliseconds(50)) {
            await harness.modelAvailability.checkCount > 0
        }
        XCTAssertFalse(advancedDuringSecondInactive)
        XCTAssertEqual(harness.sut.viewState.phase, .preparing)

        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()

        let microphoneRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertEqual(availabilityChecks, 1)
        XCTAssertEqual(recognizerStarts, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testBackgroundDuringPermissionPromptInvalidatesLateGrantAndDoesNotResumeOnActive() async {
        let permissionGate = ConversationTestGate()
        let harness = ConversationHarness(permissionGate: permissionGate)
        let idleTimer = TestIdleTimerStorage(initialValue: false)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: idleTimer.makeWakeLock()
        )

        coordinator.beginConversation()
        await permissionGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.background)
        await permissionGate.open()
        await coordinator.waitForOperations()

        let microphoneRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let recognizerStartsAfterGrant = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertEqual(availabilityChecks, 0)
        XCTAssertEqual(recognizerStartsAfterGrant, 0)
        XCTAssertEqual(audioActivations, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertFalse(idleTimer.value)

        coordinator.scenePhaseDidChange(.active)
        await Task.yield()

        let recognizerStartsAfterActive = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStartsAfterActive, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertTrue(idleTimer.value)
    }

    func testInactiveDuringLaterPreflightPausesInsteadOfUsingPermissionDeferral() async {
        let prepareGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerPrepareGate: prepareGate)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock()
        )

        coordinator.beginConversation()
        await prepareGate.waitUntilEntered()
        XCTAssertFalse(harness.sut.isAwaitingMicrophonePermission)

        coordinator.scenePhaseDidChange(.inactive)
        await prepareGate.open()
        await coordinator.waitForOperations()

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStarts, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testDuplicateInactiveAndBackgroundForwardOnlyOnePause() async {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock()
        )
        coordinator.beginConversation()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.background)
        await coordinator.waitForOperations()

        let audioDeactivations = await harness.audio.deactivateCount
        let recognizerStops = await harness.recognizer.stopCount
        XCTAssertEqual(audioDeactivations, 1)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testAsyncActionQueuedBeforeInactiveCannotRestartAfterPause() async {
        let actionGate = ConversationTestGate()
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(),
            beforeActionOperation: { await actionGate.wait() }
        )
        coordinator.beginConversation()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let actions = coordinator.makeActions(openSettings: {})

        actions.toggleListening()
        await actionGate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        let didPause = await harness.waitUntil {
            harness.sut.viewState.phase == .paused
        }
        XCTAssertTrue(didPause)

        await actionGate.open()
        await coordinator.waitForOperations()

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStarts, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testActionInvokedWhileInactiveIsNotReplayedAfterActive() async {
        let actionGate = ConversationTestGate()
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(),
            beforeActionOperation: { await actionGate.wait() }
        )
        coordinator.beginConversation()
        await coordinator.waitForOperations()
        coordinator.scenePhaseDidChange(.inactive)
        let didPause = await harness.waitUntil {
            harness.sut.viewState.phase == .paused
        }
        XCTAssertTrue(didPause)

        coordinator.makeActions(openSettings: {}).toggleListening()
        coordinator.scenePhaseDidChange(.active)
        await actionGate.open()
        await coordinator.waitForOperations()

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStarts, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testSendActionSnapshotsTextBeforeLaunchingAsyncTurnAndPreservesNewDraft() async {
        let harness = ConversationHarness(replySnapshots: nil)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock()
        )
        let actions = coordinator.makeActions(openSettings: {})
        actions.updateTypedText("最初の質問")

        actions.sendTypedText()
        actions.updateTypedText("次の下書き")
        await harness.reply.waitUntilPromptCount(1)

        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["最初の質問"])
        XCTAssertEqual(harness.sut.viewState.typedText, "次の下書き")

        await harness.reply.finish()
        await coordinator.waitForOperations()
    }

    func testRecoveryActionsRemainExplicitAndSettingsOpeningIsSynchronous() {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock()
        )
        var settingsOpenCount = 0
        let actions = coordinator.makeActions {
            settingsOpenCount += 1
        }

        actions.performRecovery(.showTypedInput)
        XCTAssertTrue(harness.sut.viewState.showsTypedInput)

        actions.performRecovery(.openSettings)
        XCTAssertEqual(settingsOpenCount, 1)
    }

    func testWakeLockRestoresPriorValueOnlyAfterItsFinalKnownToken() {
        let idleTimer = TestIdleTimerStorage(initialValue: false)
        let wakeLock = idleTimer.makeWakeLock()
        let foreignWakeLock = TestIdleTimerStorage(initialValue: false).makeWakeLock()

        let first = wakeLock.acquire()
        let second = wakeLock.acquire()
        let foreign = foreignWakeLock.acquire()
        XCTAssertTrue(idleTimer.value)

        wakeLock.release(foreign)
        wakeLock.release(first)
        wakeLock.release(first)
        XCTAssertTrue(idleTimer.value)

        wakeLock.release(second)
        XCTAssertFalse(idleTimer.value)
    }

    func testWakeLockPreservesAnAlreadyDisabledIdleTimer() {
        let idleTimer = TestIdleTimerStorage(initialValue: true)
        let wakeLock = idleTimer.makeWakeLock()

        let token = wakeLock.acquire()
        wakeLock.release(token)

        XCTAssertTrue(idleTimer.value)
        XCTAssertEqual(idleTimer.writes.last, true)
    }

    func testRepeatedActiveDoesNotLeakTheCoordinatorWakeLease() {
        let harness = ConversationHarness()
        let idleTimer = TestIdleTimerStorage(initialValue: false)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: idleTimer.makeWakeLock()
        )

        coordinator.beginConversation()
        coordinator.scenePhaseDidChange(.active)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertTrue(idleTimer.value)

        coordinator.scenePhaseDidChange(.inactive)
        XCTAssertFalse(idleTimer.value)
    }
}

@MainActor
private final class TestIdleTimerStorage {
    var value: Bool
    private(set) var writes: [Bool] = []

    init(initialValue: Bool) {
        value = initialValue
    }

    func makeWakeLock() -> ConversationScreenWakeLock {
        ConversationScreenWakeLock(
            readIdleTimerDisabled: { [weak self] in self?.value ?? false },
            writeIdleTimerDisabled: { [weak self] newValue in
                self?.value = newValue
                self?.writes.append(newValue)
            }
        )
    }
}
