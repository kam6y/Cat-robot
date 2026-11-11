import XCTest
@testable import CatRobot

@MainActor
final class AppCompositionTests: XCTestCase {
    func testLiveCompositionIsInertAndUsesOneExpressionCoordinator() async {
        let clock = ManualRobotClock(), transport = FakeRobotTransport()
        let source = FakeFaceCaptureSource(authorization: .notDetermined)
        let composition = ConversationComposition.live(auth: .missing, robotTransport: transport,
                                                       robotClock: clock, faceCaptureSource: source)
        let dependencies = composition.dependencies
        XCTAssertTrue(dependencies.faceExpressions is FaceExpressionCoordinator)
        let reply = dependencies.reply as? MotionReplyGenerator
        XCTAssertTrue(reply?.motion === dependencies.replyTurnObserver)
        XCTAssertNil(dependencies.faceExpressions.heldExpression)
        await robotDrain()
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(source.requests, 0)
        XCTAssertTrue(source.starts.isEmpty)
        dependencies.faceExpressions.setVisible(true)
        dependencies.faceExpressions.setConversationPhase(.thinking)
        let turn = MotionTurnID()
        dependencies.replyTurnObserver.beginTurn(turn)
        XCTAssertEqual(dependencies.faceExpressions.reserve(.init(expression: .happy), for: turn), .reserved)
        dependencies.replyTurnObserver.speechStarted(turn)
        XCTAssertEqual(dependencies.faceExpressions.heldExpression, .happy)
        await dependencies.serviceTeardown()
        XCTAssertNil(dependencies.faceExpressions.heldExpression)
    }

    func testLiveCompositionLeavesInjectedCameraInert() async {
        let source = FakeFaceCaptureSource(authorization: .notDetermined)
        let composition = ConversationComposition.live(auth: .missing, faceCaptureSource: source)
        await robotDrain()
        XCTAssertNotNil(composition.faceTracking)
        XCTAssertEqual(source.requests, 0)
        XCTAssertTrue(source.starts.isEmpty)
        await composition.dependencies.serviceTeardown()
    }

    /// 返事・可否・記憶・履歴は 1 つの Hermes の会話が受け持つ（別々に作ると「新しい会話」が記憶の失敗を消せない）。
    func testLiveCompositionIsLazyAndWiresOneHermesConversationToEveryRole() async throws {
        let defaults = UserDefaults(suiteName: "composition-\(UUID().uuidString)")!
        let keys = HermesKeyStoresFake(), server = FakeHermesServer()
        let composition = ConversationComposition.live(
            voiceSettings: SpeechVoiceSettings(defaults: defaults),
            connectionSettings: HermesConnectionSettings(defaults: defaults, credentials: { keys.store(for: $0) }),
            hermesTransport: server, sessionRecords: InMemoryHermesSessionRecordStore(), auth: .missing)
        let hermes = try XCTUnwrap(composition.dependencies.modelAvailability as? HermesConversationService)
        XCTAssertTrue((composition.dependencies.memory as? HermesConversationService) === hermes)
        let reply = try XCTUnwrap(composition.dependencies.reply as? MotionReplyGenerator)
        XCTAssertTrue((reply.base as? HermesConversationService) === hermes, "\(type(of: reply.base)) must not sit between the motion observer and Hermes")
        XCTAssertTrue((composition.history as? HermesConversationService) === hermes)
        XCTAssertTrue(composition.dependencies.motion is MotionCoordinator)
        XCTAssertTrue(composition.dependencies.classifier is ContextualAddressClassifier)
        // 構築だけでは Hermes にも Keychain にも触れない。未設定は未設定として報告し、別のモデルで代わりに答えない。
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(keys.requestedOrigins.isEmpty)
        let availability = await composition.dependencies.modelAvailability.availability()
        XCTAssertEqual(availability, .hermesNotConfigured)
    }

    /// 設定で保存した接続先とキーは、そのあとのターンからそのまま使われる（起動のやり直しは要らない）。
    func testLiveCompositionSendsTheTurnToTheSavedEndpointWithItsKey() async throws {
        let defaults = UserDefaults(suiteName: "composition-turn-\(UUID().uuidString)")!
        let keys = HermesKeyStoresFake()
        let settings = HermesConnectionSettings(defaults: defaults, credentials: { keys.store(for: $0) })
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "やあ")]])
        let composition = ConversationComposition.live(voiceSettings: SpeechVoiceSettings(defaults: defaults), connectionSettings: settings,
                                                       hermesTransport: server, sessionRecords: InMemoryHermesSessionRecordStore(), auth: .missing)
        let hermes = try XCTUnwrap(composition.dependencies.modelAvailability as? HermesConversationService)
        try await settings.save(endpointText: "https://hermes.test:8443", apiKey: "client-key")
        let availability = await hermes.availability()
        XCTAssertEqual(availability, .available)
        var outputs: [String] = []
        for try await text in try await hermes.streamReply(to: "こんにちは") { outputs.append(text) }
        XCTAssertEqual(outputs, ["やあ"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.map(\.url.absoluteString), ["https://hermes.test:8443/v1/runs"])
        XCTAssertEqual(posts.first?.headers["Authorization"], "Bearer client-key")
    }

    func testLiveReplyPipelineHasNoDailyLimitGateEvenWithTheRetiredLimitKeyStored() throws {
        // 日次上限は 2026-11-10 に撤去した。旧 key に上限 1 が残っていても、首の観察の内側は Hermes の会話そのもの。
        let defaults = UserDefaults(suiteName: "composition-limit-\(UUID().uuidString)")!
        defaults.set(1, forKey: "conversation.claude.dailyTurnLimit")
        let composition = ConversationComposition.live(
            voiceSettings: SpeechVoiceSettings(defaults: defaults),
            connectionSettings: HermesConnectionSettings(defaults: defaults, credentials: { _ in InMemoryHermesCredentialStore() }),
            hermesTransport: FakeHermesServer(), sessionRecords: InMemoryHermesSessionRecordStore(), auth: .missing)
        let reply = try XCTUnwrap(composition.dependencies.reply as? MotionReplyGenerator)
        XCTAssertTrue(reply.base is HermesConversationService, "\(type(of: reply.base)) must not sit between the motion observer and Hermes")
    }

    func testReplyPipelineCompletesAndPersistsWithRetiredDailyLimitSetting() async throws {
        let name = "retired-limit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1, forKey: "conversation.claude.dailyTurnLimit")
        let settings = ConversationModelSettings(defaults: defaults)
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["応答。"])])
        let service = makeClaudeService(factory, configuration: { await settings.configuration })
        let reply = ConversationComposition.makeReplyGenerator(
            base: service, motion: ReplyTurnMulticaster([]))

        var response = ""
        for try await text in try await reply.streamReply(to: "こんにちは") { response = text }

        let sessions = await factory.sessions
        let turns = await service.recentTurns()
        XCTAssertEqual(response, "応答。")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(turns, [.init(prompt: "こんにちは", response: "応答。")])
    }

    func testCompletedReplyLeavesRetiredAccountingAndUnrelatedPreferencesUntouched() async throws {
        let name = "retired-accounting-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let oldAccounting = Data("retired accounting record".utf8)
        defaults.set(oldAccounting, forKey: "conversation.claude.usage")
        defaults.set(1, forKey: "conversation.claude.dailyTurnLimit")
        defaults.set("keep-calibration", forKey: "unrelated-test-preference")
        let settings = ConversationModelSettings(defaults: defaults)
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["応答。"])])
        let service = ClaudeConversationService(
            factory: factory, memoryStore: InMemoryConversationMemoryStore(),
            longTermMemory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
            tools: StaticToolProvider([]), configuration: { await settings.configuration })

        var response = ""
        for try await text in try await service.streamReply(to: "こんにちは") { response = text }

        XCTAssertEqual(response, "応答。")
        XCTAssertEqual(defaults.data(forKey: "conversation.claude.usage"), oldAccounting)
        XCTAssertEqual(defaults.integer(forKey: "conversation.claude.dailyTurnLimit"), 1)
        XCTAssertEqual(defaults.string(forKey: "unrelated-test-preference"), "keep-calibration")
    }

    func testAddressClassifierSendsClarificationRepliesOnlyToHaikuThroughLiveWrappers() async throws {
        let turns = [ConversationMemoryTurn(prompt: "ねこ、おはよう", response: "おはよう！")]
        let haiku = RecordingAddressModelClient(result: .addressed)
        let history = FakeConversationHistory(turns: turns)
        let classifier = ConversationComposition.makeAddressClassifier(claudeClient: haiku, history: history)
        let reply = AddressClassificationRequest(utterance: "いいえ、あなたには言ってない",
                                                 clarification: .init(originalUtterance: "今日の天気はどう？"))
        let requestsBeforeUse = await haiku.requests
        XCTAssertEqual(requestsBeforeUse, [])
        let target = try await classifier.classify(reply)
        let requests = await haiku.requests, reads = await history.readCount
        XCTAssertEqual(target, .addressed)
        XCTAssertEqual(requests, [.init(utterance: reply.utterance, clarification: reply.clarification, recentTurns: turns)],
                       "the live wrapper attaches the recent conversation read from the shared history")
        XCTAssertEqual(reads, 1)
    }

    func testAddressClassifierUsesHaikuWithoutClarification() async throws {
        let turns = [ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")]
        let haiku = RecordingAddressModelClient(result: .addressed)
        let classifier = ConversationComposition.makeAddressClassifier(claudeClient: haiku, history: FakeConversationHistory(turns: turns))
        let target = try await classifier.classify("それで、あしたは？")
        let requests = await haiku.requests
        XCTAssertEqual(target, .addressed)
        XCTAssertEqual(requests, [.init(utterance: "それで、あしたは？", recentTurns: turns)])
    }

    func testAddressClassifierReportsClarificationHaikuFailureWithoutRetry() async {
        let haiku = RecordingAddressModelClient(result: .addressed, error: .modelUnreachable)
        let classifier = ConversationComposition.makeAddressClassifier(claudeClient: haiku, history: FakeConversationHistory())
        let reply = AddressClassificationRequest(utterance: "言ったよ", clarification: .init(originalUtterance: "今日の天気はどう？"))
        do { _ = try await classifier.classify(reply); XCTFail("The cloud failure must propagate") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let requests = await haiku.requests
        XCTAssertEqual(requests, [reply])
    }

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

    func testCompositionRootConstructionLeavesInjectedServicesAndCaptureLazy() async {
        let store = MemoryStoreFake()
        let harness = ConversationHarness(memory: makeClaudeService(store: store))
        let defaults = UserDefaults(suiteName: "composition-root-\(UUID().uuidString)")!
        let clock = ManualRobotClock()
        let link = RecordingRobotLink(clock: clock)
        let preferences = RobotPreferences(defaults: defaults)
        preferences.trackingEnabled = true
        let source = FakeFaceCaptureSource(authorization: .notDetermined)
        let camera = ConversationCamera(source: source, clock: clock)
        let tracking = FaceTrackingCoordinator(source: camera, link: link, clock: clock,
                                               preferences: preferences, motion: harness.dependencies.motion)
        let composition = ConversationComposition(
            dependencies: harness.dependencies,
            voiceSettings: SpeechVoiceSettings(defaults: defaults),
            connectionSettings: HermesConnectionSettings(defaults: defaults, credentials: { _ in InMemoryHermesCredentialStore() }),
            history: HermesConversationService(connection: { nil }, transport: FakeHermesServer(), records: InMemoryHermesSessionRecordStore()),
            robotLink: link, faceTracking: tracking, camera: camera,
            robotSettings: RobotSettingsModel(link: link, preferences: preferences, clock: clock))
        let onboarding = OnboardingSettings(defaults: defaults)
        onboarding.markCompleted()
        let root = AppRootView(composition: composition, onboardingSettings: onboarding)
        await robotDrain()

        let microphoneRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let speakerPreparations = await harness.speaker.prepareCount
        let recognizerPreparations = await harness.recognizer.prepareCount
        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        let replyPrewarms = await harness.reply.prewarmCount
        let memoryLoads = await store.loadCount
        XCTAssertEqual(microphoneRequests, 0)
        XCTAssertEqual(availabilityChecks, 0)
        XCTAssertEqual(speakerPreparations, 0)
        XCTAssertEqual(recognizerPreparations, 0)
        XCTAssertEqual(recognizerStarts, 0)
        XCTAssertEqual(audioActivations, 0)
        XCTAssertEqual(replyPrewarms, 0)
        XCTAssertEqual(memoryLoads, 0)
        XCTAssertEqual(source.requests, 0)
        XCTAssertTrue(source.starts.isEmpty)
        XCTAssertEqual(link.startCount, 0)
        withExtendedLifetime(root) {}
        await harness.sut.shutdown()
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

    func testBackgroundDuringPermissionPromptInvalidatesLateGrantAndResumesOnActive() async {
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
        await coordinator.waitForOperations()

        // 遅れて届いた許可は古い開始を進めない。前面復帰で新しく開始する。許可の問い合わせは開始ごとに行い、OS は保存済みの決定を返す。
        let recognizerStartsAfterActive = await harness.recognizer.startCount
        let microphoneRequestsAfterActive = await harness.microphone.requestCount
        XCTAssertEqual(recognizerStartsAfterActive, 1)
        XCTAssertEqual(microphoneRequestsAfterActive, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
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

        // 前面復帰で再開する。非アクティブ中のタップが再生されていれば、再開の後に一時停止へ戻ってしまう。
        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
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

    /// 接続の設定はアプリ内のシートを接続の欄で開く（会話を止める既存の経路を通る）。iOS の設定アプリは開かない。
    func testConnectionRecoveryOpensTheInAppSettingsAtTheConnectionPane() async {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
                                                     wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock())
        var systemSettingsOpenCount = 0
        let actions = coordinator.makeActions { systemSettingsOpenCount += 1 }

        actions.performRecovery(.openConnectionSettings)
        await coordinator.waitForOperations()

        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(coordinator.settingsCategory, .hermesConnection)
        XCTAssertEqual(systemSettingsOpenCount, 0)
        coordinator.closeVoiceSettings()
        coordinator.openVoiceSettings()
        await coordinator.waitForOperations()
        XCTAssertEqual(coordinator.settingsCategory, .conversation, "the menu still opens at 会話")
        await harness.sut.shutdown()
    }

    /// 会話画面のメニューの「会話の履歴」は、アプリ内の設定を履歴の欄で開く（正本は Hermes、端末は表示のたびに読む）。
    func testTheHistoryMenuOpensTheInAppSettingsAtTheHistoryPane() async {
        let harness = ConversationHarness()
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
                                                     wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock())
        let actions = coordinator.makeActions { XCTFail("the iOS Settings app is not the history") }

        actions.openHistory()
        await coordinator.waitForOperations()

        XCTAssertTrue(coordinator.showsVoiceSettings)
        XCTAssertEqual(coordinator.settingsCategory, .history)
        await harness.sut.shutdown()
    }

    /// 未設定の失敗から接続を設定して閉じると、開始前の確認をやり直して会話が始まる（「もう一度確認」を押さなくてよい）。
    func testClosingTheConnectionSettingsAfterAnUnconfiguredFailureStartsAgain() async {
        let harness = ConversationHarness(modelAvailabilityResult: .hermesNotConfigured)
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
                                                     wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock())
        coordinator.beginConversation()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnavailable(.hermesNotConfigured)))

        coordinator.makeActions(openSettings: {}).performRecovery(.openConnectionSettings)
        await coordinator.waitForOperations()
        await harness.modelAvailability.setResult(.available)
        coordinator.closeVoiceSettings()
        await coordinator.waitForOperations()

        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.shutdown()
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
final class TestIdleTimerStorage {
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
