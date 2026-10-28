import XCTest
@testable import CatRobot

private actor LookingReply: ReplyGenerating {
    nonisolated let supportsStableReplyPrefix = true
    let base = ControlledReply()
    let look: any LookControlling
    private(set) var scopes: [MotionTurnID?] = []
    private(set) var imageCount = 0
    init(look: any LookControlling) { self.look = look }
    func prewarm() async {}
    func reset() async { await base.reset() }
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        scopes.append(MotionTurnContext.current)
        let output = try await LookTool(look: look).call(arguments: .init(purpose: "目の前を確認"))
        if output.image != nil { imageCount += 1 }
        return try await base.streamReply(to: utterance)
    }
}

@MainActor
final class LookIntegrationTests: XCTestCase {
    func testFallbackAfterImageClearsIndicatorAndKeepsConversationFunctional() async throws {
        let look = LookCoordinator(camera: ImmediateSnapshotCamera(), clock: SystemRobotClock())
        look.setVisible(true)
        let motion = MotionControllerSpy(), observer = ReplyTurnMulticaster([motion, look])
        let client = FailingLookSession(look: look)
        let primary = makeClaudeService(StubSessionFactory(scripts: [client]))
        let fallback = OnDeviceFallbackReplyGenerator(primary: primary,
            secondary: FixedIntegrationReply(text: "今は画像を確認できないけれど、話を続けよう。"),
            secondaryAvailability: OnDeviceFallbackReplyGeneratorTests.Availability(value: .available),
            usage: ConversationUsageSpy(), configuration: { .init() }, motion: observer)
        let speaker = ControlledSpeaker()
        let sut = ReplyPlaybackCoordinator(reply: MotionReplyGenerator(base: fallback, motion: observer),
            speaker: speaker, mode: .completeResponse, motion: observer)
        let run = Task { try await sut.run(prompt: "見て", trace: nil, onUpdate: { _ in }) }
        await speaker.waitUntilCallCount(1)
        let receivedImage = await client.receivedImage
        XCTAssertTrue(receivedImage)
        XCTAssertFalse(look.isLooking)
        XCTAssertEqual(motion.cancellations.count, 1)
        await speaker.emit(.started)
        await speaker.complete()
        _ = try await run.value
        XCTAssertFalse(look.isLooking)
    }

    func testVoiceAndTypedTurnsCaptureWithoutRobotAndContinueSpeaking() async throws {
        for voice in [false, true] {
            let clock = ManualRobotClock(), source = FakeFaceCaptureSource()
            let camera = ConversationCamera(source: source, clock: clock)
            let look = LookCoordinator(camera: camera, clock: clock)
            let motion = MotionControllerSpy()
            let observer = ReplyTurnMulticaster([motion, look])
            let base = LookingReply(look: look)
            let playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: base, motion: observer),
                motion: motion, replyTurnObserver: observer, look: look)
            let app = ConversationAppCoordinator(viewModel: playback.viewModel,
                wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(), camera: camera, look: look)
            app.beginConversation()
            await app.waitForOperations()
            let run: Task<Void, Never>
            if voice { run = await playback.beginVoiceTurn("猫ちゃん、見て") }
            else { run = Task { await playback.viewModel.submitTypedText("見て") } }
            let looking = await playback.infrastructure.waitUntil { look.isLooking }
            XCTAssertTrue(looking)
            XCTAssertTrue(source.starts.isEmpty)
            await clock.advance(by: 0.1)
            let request = try XCTUnwrap(source.snapshotRequests.last)
            XCTAssertEqual(source.starts.count, 1)
            request.completion(.success(.init(generation: request.generation, capturedAt: clock.now,
                image: try makeCameraTestImage())))
            await base.base.waitUntilRequested()
            let scopes = await base.scopes
            XCTAssertEqual(scopes.compactMap { $0 }, motion.begins)
            let images = await base.imageCount
            XCTAssertEqual(images, 1)
            XCTAssertEqual(source.stops, 1)
            await base.base.yield("見えたよ。")
            await base.base.finish()
            await playback.speaker.waitUntilCallCount(1)
            await playback.speaker.emit(.started)
            await playback.waitForPhase(.speaking)
            XCTAssertFalse(look.isLooking)
            await playback.speaker.complete()
            await run.value
            XCTAssertEqual(playback.viewModel.viewState.caption, "見えたよ。")
            await playback.viewModel.shutdown()
            camera.shutdown()
        }
    }

    func testSettingsBackgroundPauseNewConversationAndShutdownInvalidatePendingLook() async throws {
        for action in ["settings", "background", "pause", "newConversation", "shutdown"] {
            let clock = ManualRobotClock(), source = FakeFaceCaptureSource()
            let camera = ConversationCamera(source: source, clock: clock)
            let look = LookCoordinator(camera: camera, clock: clock)
            let playback = PlaybackIntegrationHarness(look: look)
            let app = ConversationAppCoordinator(viewModel: playback.viewModel,
                wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(), camera: camera, look: look)
            app.beginConversation()
            await app.waitForOperations()
            let turn = MotionTurnID()
            look.beginTurn(turn)
            let task = Task { try await look.capture(for: turn) }
            await robotDrain()
            await clock.advance(by: 0.1)
            let request = try XCTUnwrap(source.snapshotRequests.last)
            switch action {
            case "settings": app.openVoiceSettings()
            case "background": app.scenePhaseDidChange(.background)
            case "pause": await playback.viewModel.toggleListening()
            case "newConversation": await playback.viewModel.startNewConversation()
            default: await playback.viewModel.shutdown()
            }
            XCTAssertFalse(look.isLooking, action)
            await assertLookFailure(task, .cancelled)
            XCTAssertEqual(source.stops, 1, action)
            request.completion(.success(.init(generation: request.generation, capturedAt: clock.now,
                image: try makeCameraTestImage())))
            await robotDrain()
            XCTAssertFalse(look.isLooking)
            await app.waitForOperations()
            await playback.viewModel.shutdown()
            camera.shutdown()
        }
    }

    func testCameraEnvironmentWorksBeforeVoiceStartCompletesAndStopsAtUnavailablePhase() async throws {
        let microphone = ConversationTestGate()
        let conversation = ConversationHarness(permissionGate: microphone)
        let clock = ManualRobotClock(), source = FakeFaceCaptureSource()
        let camera = ConversationCamera(source: source, clock: clock)
        let app = ConversationAppCoordinator(viewModel: conversation.sut,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(), camera: camera)
        app.beginConversation()
        await microphone.waitUntilEntered()
        // Root forwards the phase of a typed generation even before voice startup succeeded.
        app.conversationPhaseDidChange(.thinking)
        let task = Task { try await camera.captureSnapshot() }
        await robotDrain()
        XCTAssertEqual(source.snapshotRequests.count, 1)
        app.conversationPhaseDidChange(.paused)
        await assertCameraFailure(task, .cancelled)
        app.scenePhaseDidChange(.background)
        await microphone.open()
        await app.waitForOperations()
        await conversation.sut.shutdown()
        camera.shutdown()
    }

    func testLiveCompositionUsesSharedCameraAndPermissionDoesNotEnableTracking() async throws {
        let clock = ManualRobotClock(), transport = FakeRobotTransport()
        let source = FakeFaceCaptureSource(authorization: .notDetermined)
        let defaults = UserDefaults(suiteName: "look-composition-\(UUID().uuidString)")!
        let preferences = RobotPreferences(defaults: defaults)
        preferences.trackingEnabled = false
        let composition = ConversationComposition.live(auth: .missing, robotTransport: transport,
            robotClock: clock, robotPreferences: preferences, faceCaptureSource: source)
        XCTAssertTrue(composition.dependencies.look is LookCoordinator)
        await robotDrain()
        XCTAssertEqual(source.requests, 0)
        XCTAssertTrue(source.starts.isEmpty)
        XCTAssertEqual(transport.starts, 0)
        let permission = Task { await composition.camera.requestAuthorization() }
        await robotDrain()
        source.resolveAuthorization(.authorized)
        _ = await permission.value
        XCTAssertFalse(preferences.trackingEnabled)
        XCTAssertTrue(source.starts.isEmpty)
        composition.camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: .thinking)
        let look = composition.dependencies.look
        look.setVisible(true)
        let turn = MotionTurnID()
        composition.dependencies.replyTurnObserver.beginTurn(turn)
        let capture = Task { try await look.capture(for: turn) }
        await robotDrain()
        await clock.advance(by: 0.1)
        let request = try XCTUnwrap(source.snapshotRequests.last)
        request.completion(.success(.init(generation: request.generation, capturedAt: clock.now,
            image: try makeCameraTestImage())))
        let snapshot = try await capture.value
        XCTAssertTrue(look.finishCapture(snapshot, for: turn))
        XCTAssertTrue(look.isLooking)
        composition.dependencies.replyTurnObserver.speechStarted(turn)
        XCTAssertFalse(look.isLooking)
        await composition.dependencies.serviceTeardown()
        await assertCameraFailure(Task { try await composition.camera.captureSnapshot() }, .unavailable)
    }
}

private actor FailingLookSession: ConversationSessionClient {
    let look: any LookControlling
    private(set) var receivedImage = false
    init(look: any LookControlling) { self.look = look }
    func prewarm() async {}
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        do {
            let output = try await LookTool(look: look).call(arguments: .init(purpose: "確認"))
            receivedImage = output.image != nil
            return AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
        } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
    }
}
