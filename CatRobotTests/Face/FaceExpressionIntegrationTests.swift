import FoundationModels
import XCTest
@testable import CatRobot

actor FaceReservingReply: ReplyGenerating {
    nonisolated let supportsStableReplyPrefix = true
    let base: ControlledReply
    let expressions: any FaceExpressionControlling
    let motion: any RobotMotionControlling
    let holdSeconds: Int
    private(set) var scopes: [MotionTurnID?] = []

    init(base: ControlledReply, expressions: any FaceExpressionControlling,
         motion: any RobotMotionControlling, holdSeconds: Int = 8) {
        self.base = base; self.expressions = expressions; self.motion = motion; self.holdSeconds = holdSeconds
    }
    func prewarm() async {}
    func reset() async { await base.reset() }
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        scopes.append(MotionTurnContext.current)
        _ = try await ExpressTool(expressions: expressions).call(arguments: .init(expression: "happy", hold_seconds: holdSeconds))
        _ = try await MoveHeadTool(motion: motion).call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
        return try await base.streamReply(to: utterance)
    }
}

private actor FailingFaceSession: ConversationSessionClient {
    let expressions: any FaceExpressionControlling
    private(set) var reservation = ""
    init(expressions: any FaceExpressionControlling) { self.expressions = expressions }
    func prewarm() async {}
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        do {
            reservation = try await ExpressTool(expressions: expressions).call(arguments: .init(expression: "happy", hold_seconds: 8))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}

@MainActor
final class FaceExpressionIntegrationTests: XCTestCase {
    func testExpressAndMoveHeadShareTurnAndReleaseOnceForVoiceAndTypedReplies() async {
        for voice in [false, true] {
            let h = FaceExpressionHarness(), motion = MotionControllerSpy(), base = ControlledReply()
            let observer = ReplyTurnMulticaster([motion, h.sut])
            let reserving = FaceReservingReply(base: base, expressions: h.sut, motion: motion)
            let reply = MotionReplyGenerator(base: reserving, motion: observer)
            let playback = PlaybackIntegrationHarness(service: reply, motion: motion,
                                                       expressions: h.sut, replyTurnObserver: observer)
            let run: Task<Void, Never>
            if voice { run = await playback.beginVoiceTurn() }
            else { run = Task { await playback.viewModel.submitTypedText("質問") } }
            await base.waitUntilRequested()
            await h.clock.advance(by: 20)
            XCTAssertNil(h.sut.heldExpression)
            let scopes = await reserving.scopes
            XCTAssertEqual(scopes.compactMap { $0 }, motion.begins)
            XCTAssertEqual(motion.reservations.map(\.turn), motion.begins)
            await base.yield("最初。続き")
            await playback.speaker.waitUntilCallCount(1)
            XCTAssertNil(h.sut.heldExpression)
            await playback.speaker.emit(.started)
            await playback.waitForPhase(.speaking)
            XCTAssertEqual(h.sut.heldExpression, .happy)
            await h.clock.advance(by: 7.99)
            XCTAssertEqual(h.sut.heldExpression, .happy)
            await playback.speaker.complete()
            await playback.waitForState { $0.mouthPose == .closed }
            XCTAssertEqual(playback.viewModel.viewState.phase, .speaking)
            await base.finish()
            await playback.speaker.waitUntilCallCount(2)
            await playback.speaker.emit(.started)
            await playback.waitForPhase(.speaking)
            XCTAssertEqual(h.sut.heldExpression, .happy)
            XCTAssertEqual(motion.speechStarts.count, 1)
            await h.clock.advance(by: 0.01)
            XCTAssertNil(h.sut.heldExpression)
            XCTAssertEqual(FaceExpression.automatic(for: playback.viewModel.viewState.phase), .speaking)
            await playback.speaker.complete()
            await run.value
            XCTAssertEqual(motion.speechStarts.count, 1)
            await playback.viewModel.shutdown()
        }
    }

    func testHappyMouthFollowsThreeActualSentencesWithoutRestartingExpressionOrHead() async {
        for voice in [false, true] {
            let h = FaceExpressionHarness(), motion = MotionControllerSpy(), base = ControlledReply()
            let observer = ReplyTurnMulticaster([motion, h.sut])
            let reserving = FaceReservingReply(base: base, expressions: h.sut, motion: motion)
            let player = ControlledPCMPlayer()
            let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
                synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
            let playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: reserving, motion: observer),
                sentenceSpeaker: speaker, motion: motion,
                expressions: h.sut, replyTurnObserver: observer)
            let run: Task<Void, Never>
            if voice { run = await playback.beginVoiceTurn() }
            else { run = Task { await playback.viewModel.submitTypedText("三文で答えて") } }
            await base.waitUntilRequested()
            await h.clock.advance(by: 20)
            XCTAssertNil(h.sut.heldExpression)
            XCTAssertEqual(playback.viewModel.viewState.mouthPose, .closed)
            let captions = ["一文目。二", "一文目。二文目。三", "一文目。二文目。三文目。"]
            let poses: [MouthPose] = [.wide, .medium, .small]
            for index in 0..<3 {
                await base.yield(captions[index])
                if index == 2 { await base.finish() }
                await player.waitForCalls(index + 1)
                player.emit(.started, index: index) // duplicate callbacks must not advance the mouth twice
                await robotDrain()
                XCTAssertEqual(playback.viewModel.viewState.mouthPose, poses[index])
                XCTAssertEqual(playback.viewModel.viewState.phase, .speaking)
                XCTAssertEqual(playback.viewModel.viewState.caption, captions[index])
                XCTAssertEqual(h.sut.heldExpression, .happy)
                XCTAssertEqual(motion.speechStarts.count, 1)
                if index < 2 {
                    player.complete(index)
                    await robotDrain()
                    XCTAssertEqual(playback.viewModel.viewState.mouthPose, .closed, "Close while waiting for the next sentence")
                    XCTAssertEqual(playback.viewModel.viewState.phase, .speaking, "A sentence boundary does not resume capture")
                }
                await h.clock.advance(by: 2)
            }
            await h.clock.advance(by: 2)
            XCTAssertNil(h.sut.heldExpression, "The eight-second hold starts only once")
            XCTAssertEqual(motion.speechStarts.count, 1)
            player.complete(2)
            await run.value
            XCTAssertEqual(playback.viewModel.viewState.mouthPose, .closed)
            XCTAssertEqual(playback.viewModel.viewState.caption, captions.last)
            await playback.viewModel.shutdown()
        }
    }

    func testFailureGuidanceNeverReleasesFailedPrimaryExpression() async throws {
        let h = FaceExpressionHarness(), motion = MotionControllerSpy()
        let observer = ReplyTurnMulticaster([motion, h.sut])
        let client = FailingFaceSession(expressions: h.sut)
        let primary = makeClaudeService(StubSessionFactory(scripts: [client]))
        let speaker = ControlledSpeaker()
        let playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: primary, motion: observer),
            memory: primary, speaker: speaker, motion: motion, expressions: h.sut, replyTurnObserver: observer)
        let turn = Task { await playback.viewModel.submitTypedText("質問") }
        let observed = await playback.infrastructure.waitUntil {
            let texts = await speaker.texts
            if !texts.isEmpty { return true }
            if case .failed = playback.viewModel.viewState.phase { return true }
            return false
        }
        let texts = await speaker.texts
        XCTAssertTrue(observed)
        XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable])
        XCTAssertNil(h.sut.heldExpression, "The failed primary's expression must remain invalid during guidance")
        await speaker.complete()
        await turn.value
        let reservation = await client.reservation
        XCTAssertTrue(reservation.contains("予約しました"))
        XCTAssertNil(h.sut.heldExpression)
        XCTAssertEqual(playback.viewModel.viewState.phase, .failed(.modelUnreachable))
        XCTAssertEqual(motion.begins.count, 1)
        XCTAssertEqual(motion.cancellations.count, 1)
        await playback.viewModel.shutdown()
    }

    func testFinishedReplyHoldClearsOnSettingsPauseNewConversationBackgroundAndShutdown() async {
        for action in ["settings", "pause", "newConversation", "background", "shutdown"] {
            let clock = ManualRobotClock()
            let expressions = FaceExpressionCoordinator(clock: clock)
            // This controller starts hidden; only the real app coordinator may make it visible.
            let base = ControlledReply(), motion = MotionControllerSpy()
            let observer = ReplyTurnMulticaster([motion, expressions])
            let source = FaceReservingReply(base: base, expressions: expressions, motion: motion, holdSeconds: 10)
            let playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: source, motion: observer),
                motion: motion, expressions: expressions, replyTurnObserver: observer)
            let app = ConversationAppCoordinator(viewModel: playback.viewModel,
                wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(), expressions: expressions)
            app.beginConversation()
            await app.waitForOperations()
            let run = Task { await playback.viewModel.submitTypedText("質問") }
            await base.waitUntilRequested()
            await base.yield("返事。")
            await base.finish()
            await playback.speaker.waitUntilCallCount(1)
            await playback.speaker.emit(.started)
            await playback.waitForPhase(.speaking)
            XCTAssertEqual(expressions.heldExpression, .happy, action)
            await playback.speaker.complete()
            await run.value
            XCTAssertEqual(playback.viewModel.viewState.phase, .listening)
            XCTAssertEqual(expressions.heldExpression, .happy, action)
            switch action {
            case "settings": app.openVoiceSettings()
            case "pause": await playback.viewModel.toggleListening()
            case "newConversation": await playback.viewModel.startNewConversation()
            case "background": app.scenePhaseDidChange(.background)
            default: await playback.viewModel.shutdown()
            }
            XCTAssertNil(expressions.heldExpression, action)
            await app.waitForOperations()
            if let old = motion.begins.first {
                expressions.speechStarted(old)
                XCTAssertEqual(expressions.reserve(.init(expression: .sorry), for: old),
                               action == "settings" || action == "background" ? .unavailable : .invalidated)
            }
            await clock.advance(by: 20)
            XCTAssertNil(expressions.heldExpression, action)
            await playback.viewModel.shutdown()
        }
    }

    func testFaceExpressionsWorkWithoutRobotOrCameraAndHideSynchronously() async {
        let h = FaceExpressionHarness()
        let playback = PlaybackIntegrationHarness(expressions: h.sut)
        let app = ConversationAppCoordinator(viewModel: playback.viewModel,
            wakeLock: TestIdleTimerStorage(initialValue: false).makeWakeLock(), expressions: h.sut)
        app.beginConversation()
        await app.waitForOperations()
        h.sut.setConversationPhase(.thinking)
        let turn = h.begin()
        XCTAssertEqual(h.sut.reserve(.init(expression: .happy), for: turn), .reserved)
        h.sut.speechStarted(turn)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        app.scenePhaseDidChange(.inactive)
        XCTAssertNil(h.sut.heldExpression)
        XCTAssertEqual(h.sut.reserve(.init(expression: .happy), for: turn), .unavailable)
        await app.waitForOperations()
        app.scenePhaseDidChange(.active)
        await app.waitForOperations()
        h.sut.speechStarted(turn)
        XCTAssertNil(h.sut.heldExpression)
        await playback.viewModel.shutdown()
    }

    func testRealSDKPreservesHoldSecondsAndRejectsOldMissingAndCancelledScopes() async throws {
        let h = FaceExpressionHarness(), turn = h.begin()
        let model = ToolProbeLanguageModel(toolName: "express", argumentsJSON: "{\"expression\":\"happy\",\"hold_seconds\":8}")
        let session = LanguageModelSession(model: model, tools: [ExpressTool(expressions: h.sut)])
        _ = try await MotionTurnContext.$current.withValue(turn) { try await session.respond(to: "first") }
        XCTAssertNil(h.sut.heldExpression)
        h.sut.speechStarted(turn)
        await h.clock.advance(by: 7.99)
        XCTAssertEqual(h.sut.heldExpression, .happy)
        await h.clock.advance(by: 0.01)
        XCTAssertNil(h.sut.heldExpression)
        let next = h.begin()
        _ = try await MotionTurnContext.$current.withValue(turn) { try await session.respond(to: "old") }
        _ = try await session.respond(to: "unscoped")
        h.sut.speechStarted(next)
        XCTAssertNil(h.sut.heldExpression)
        let cancelledTurn = h.begin()
        let cancelled = Task {
            try await MotionTurnContext.$current.withValue(cancelledTurn) { try await session.respond(to: "cancelled") }
        }
        cancelled.cancel()
        _ = await cancelled.result
        h.sut.speechStarted(cancelledTurn)
        XCTAssertNil(h.sut.heldExpression)
    }
}
