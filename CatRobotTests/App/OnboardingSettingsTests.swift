import XCTest
@testable import CatRobot

@MainActor
final class OnboardingSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeCoordinator(_ harness: ConversationHarness, settings: OnboardingSettings?) -> ConversationAppCoordinator {
        ConversationAppCoordinator(viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }),
            onboardingSettings: settings)
    }

    func testCompletionPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = OnboardingSettings(defaults: defaults)
        XCTAssertFalse(first.isCompleted, "新規・既存利用者ともフラグが無ければ説明を出す")
        first.markCompleted()
        XCTAssertTrue(first.isCompleted)
        XCTAssertTrue(OnboardingSettings(defaults: defaults).isCompleted)
    }

    func testFirstLaunchShowsOnboardingAndBeginMarksCompleted() async {
        let settings = OnboardingSettings(defaults: makeDefaults())
        let h = ConversationHarness(microphoneAllowed: false)
        let coordinator = makeCoordinator(h, settings: settings)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(coordinator.destination, .onboarding)
        let before = await h.microphone.requestCount
        XCTAssertEqual(before, 0)
        coordinator.beginConversation()
        XCTAssertTrue(settings.isCompleted, "許可の成否ではなく開始ボタンを押した時点で保存する")
        await coordinator.waitForOperations()
        XCTAssertEqual(coordinator.destination, .conversation)
        XCTAssertEqual(h.sut.viewState.phase, .failed(.microphoneDenied))
        await h.sut.shutdown()
    }

    func testReturningLaunchStartsOnFirstActive() async {
        let defaults = makeDefaults()
        let settings = OnboardingSettings(defaults: defaults)
        settings.markCompleted()
        let h = ConversationHarness()
        let idleTimer = TestIdleTimerStorage(initialValue: false)
        let clock = ManualRobotClock()
        let coordinator = ConversationAppCoordinator(viewModel: h.sut, wakeLock: idleTimer.makeWakeLock(),
            onboardingSettings: settings, idleSettings: ConversationIdleSettings(defaults: defaults), idleClock: clock)
        XCTAssertEqual(coordinator.destination, .conversation)
        let before = await h.microphone.requestCount
        XCTAssertEqual(before, 0, "初期化だけではマイクを開始しない")
        await clock.advance(by: 600)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        XCTAssertEqual(coordinator.inactivity.state, .awake, "会話の計時起点は最初のactive")
        XCTAssertTrue(idleTimer.value)
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 1)
        coordinator.scenePhaseDidChange(.inactive)
        await coordinator.waitForOperations()
        XCTAssertFalse(idleTimer.value)
        await h.sut.shutdown()
    }

    func testReturningLaunchDoesNotRestartWhileMicrophonePromptIsOpen() async {
        let settings = OnboardingSettings(defaults: makeDefaults())
        settings.markCompleted()
        let gate = ConversationTestGate()
        let h = ConversationHarness(permissionGate: gate)
        let coordinator = makeCoordinator(h, settings: settings)
        coordinator.scenePhaseDidChange(.active)
        await gate.waitUntilEntered()
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        await gate.open()
        await coordinator.waitForOperations()
        let requests = await h.microphone.requestCount
        let starts = await h.recognizer.startCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        await h.sut.shutdown()
    }

    func testRepeatedActiveWithoutSceneChangeAddsNoPreflight() async {
        let settings = OnboardingSettings(defaults: makeDefaults())
        settings.markCompleted()
        let h = ConversationHarness()
        let coordinator = makeCoordinator(h, settings: settings)
        coordinator.scenePhaseDidChange(.active)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        let requests = await h.microphone.requestCount
        let starts = await h.recognizer.startCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(starts, 1)
        await h.sut.shutdown()
    }

    func testReturningLaunchStillResumesAfterOrdinaryBackground() async {
        let settings = OnboardingSettings(defaults: makeDefaults())
        settings.markCompleted()
        let h = ConversationHarness()
        let coordinator = makeCoordinator(h, settings: settings)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        coordinator.scenePhaseDidChange(.background)
        await coordinator.waitForOperations()
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        let starts = await h.recognizer.startCount
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(h.sut.viewState.phase, .listening)
        await h.sut.shutdown()
    }

    func testReturningLaunchWithDeniedMicrophoneShowsRecovery() async {
        let settings = OnboardingSettings(defaults: makeDefaults())
        settings.markCompleted()
        let h = ConversationHarness(microphoneAllowed: false)
        let coordinator = makeCoordinator(h, settings: settings)
        coordinator.scenePhaseDidChange(.active)
        await coordinator.waitForOperations()
        XCTAssertEqual(coordinator.destination, .conversation)
        XCTAssertEqual(h.sut.viewState.phase, .failed(.microphoneDenied))
        XCTAssertTrue(h.sut.viewState.recoveries.contains { $0.action == .openSettings })
        XCTAssertTrue(h.sut.viewState.recoveries.contains { $0.action == .showTypedInput })
        await h.sut.shutdown()
    }

    func testNilOnboardingSettingsAlwaysStartsAtOnboarding() async {
        let h = ConversationHarness()
        let first = makeCoordinator(h, settings: nil)
        first.beginConversation()
        await first.waitForOperations()
        let secondHarness = ConversationHarness()
        let second = makeCoordinator(secondHarness, settings: nil)
        second.scenePhaseDidChange(.active)
        await second.waitForOperations()
        XCTAssertEqual(second.destination, .onboarding)
        let requests = await secondHarness.microphone.requestCount
        XCTAssertEqual(requests, 0)
        await h.sut.shutdown()
        await secondHarness.sut.shutdown()
    }
}
