import XCTest
@testable import CatRobot

actor ReservingMotionReply: ReplyGenerating {
    nonisolated let supportsStableReplyPrefix = true
    let base: ControlledReply
    let motion: any RobotMotionControlling
    private(set) var scopes: [MotionTurnID?] = []
    init(base: ControlledReply, motion: any RobotMotionControlling) { self.base = base; self.motion = motion }
    func prewarm() async {}
    func reset() async { await base.reset() }
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        let turn = MotionTurnContext.current
        scopes.append(turn)
        if let turn { _ = await motion.reserve(.init(gesture: .nod, intensity: .large, repeats: 1), for: turn) }
        return try await base.streamReply(to: utterance)
    }
}

actor ReservingFailingMotionSession: ConversationSessionClient {
    let motion: any RobotMotionControlling
    private(set) var reservation: MotionReservationResult?
    private(set) var reservationCount = 0
    init(motion: any RobotMotionControlling) { self.motion = motion }
    func prewarm() async {}
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        if let id = MotionTurnContext.current {
            reservationCount += 1
            reservation = await motion.reserve(.init(gesture: .nod, intensity: .large, repeats: 1), for: id)
        }
        return AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
    }
}

@MainActor
final class MotionPlaybackIntegrationTests: XCTestCase {
    func testVoiceAndTypedReservedGesturesWaitForFirstSpeechAndFinishCurrentCycleAfterAudioEnds() async {
        for voice in [false, true] {
            let h = MotionHarness()
            let base = ControlledReply()
            let reserving = ReservingMotionReply(base: base, motion: h.motion)
            let wrapped = MotionReplyGenerator(base: reserving, motion: h.motion)
            let playback = PlaybackIntegrationHarness(service: wrapped, motion: h.motion)
            let run: Task<Void, Never>
            if voice { run = await playback.beginVoiceTurn() }
            else { run = Task { await playback.viewModel.submitTypedText("質問") } }
            await base.waitUntilRequested()
            let scopes = await reserving.scopes
            await h.drain()
            if voice { XCTAssertTrue(h.sentCommands.contains { if case .move = $0 { true } else { false } }) }
            XCTAssertEqual(scopes.compactMap { $0 }.count, 1)
            XCTAssertTrue(h.gestureCommands.isEmpty)
            if !voice { XCTAssertTrue(h.sentCommands.isEmpty) }
            await base.yield("一文です。")
            await base.finish()
            await playback.speaker.waitUntilCallCount(1)
            XCTAssertTrue(h.gestureCommands.isEmpty)
            if !voice { XCTAssertTrue(h.sentCommands.isEmpty) }
            await playback.speaker.emit(.willSpeak(range: 0..<1))
            await playback.speaker.emit(.started)
            await playback.speaker.emit(.started)
            await playback.waitForPhase(.speaking)
            await h.drain()
            XCTAssertEqual(h.gestureCommands.count, 1)
            await h.startCycle()
            await playback.speaker.complete()
            await run.value
            XCTAssertFalse(h.sentCommands.contains(.stop))
            await h.completeCycle(after: 1.52)
            XCTAssertEqual(h.gestureCommands.count, 1)
            if let turn = scopes.compactMap({ $0 }).first {
                XCTAssertEqual(h.motion.reserve(.init(gesture: .nod, intensity: .small, repeats: 1), for: turn), .invalidated)
            }
            await playback.viewModel.shutdown()
        }
    }

    func testSentencePrefetchReleasesOnlyOnceAcrossThreeSentences() async throws {
        let h = MotionHarness()
        let base = ControlledReply()
        let source = ReservingMotionReply(base: base, motion: h.motion)
        let wrapped = MotionReplyGenerator(base: source, motion: h.motion)
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
                                               synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: wrapped, speaker: speaker, motion: h.motion)
        let run = Task { try await sut.run(prompt: "三文", trace: nil, onUpdate: { _ in }) }
        await base.waitUntilRequested()
        await base.yield("一文目。二文目。三文目。")
        await base.finish()
        await player.waitForCalls(1)
        await h.drain()
        await h.startCycle()
        for index in 0..<3 {
            await player.waitForCalls(index + 1)
            player.complete(index)
        }
        _ = try await run.value
        XCTAssertEqual(h.gestureCommands.count, 1)
        XCTAssertEqual(h.trace.events.filter { $0.point == .speechStarted }.count, 1)
        XCTAssertFalse(h.sentCommands.contains(.stop))
        await h.completeCycle(after: 1.52)
    }

    func testFailureGuidanceCannotReleaseFailedPrimaryReservations() async throws {
        let h = MotionHarness()
        let client = ReservingFailingMotionSession(motion: h.motion)
        let primary = makeClaudeService(StubSessionFactory(scripts: [client]))
        let speaker = ControlledSpeaker()
        let playback = PlaybackIntegrationHarness(service: MotionReplyGenerator(base: primary, motion: h.motion),
            memory: primary, speaker: speaker, motion: h.motion)
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
        XCTAssertTrue(h.sentCommands.isEmpty, "Guidance must not release a motion reservation")
        await speaker.complete()
        await turn.value
        let reserved = await client.reservation
        let reservations = await client.reservationCount
        XCTAssertEqual(reserved, .reserved(cycles: 1))
        XCTAssertEqual(reservations, 1)
        XCTAssertTrue(h.sentCommands.isEmpty)
        XCTAssertEqual(playback.viewModel.viewState.phase, .failed(.modelUnreachable))
        await playback.viewModel.shutdown()
    }

    func testSpeechFailureCancelsCurrentMotionAndGeneration() async {
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
        await speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        do { _ = try await run.value; XCTFail() }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        await h.drain()
        XCTAssertEqual(h.sentCommands.filter { $0 == .stop }.count, 1)
    }

    func testGenerationFailureAlsoStopsAnAcknowledgementAlreadyInProgress() async {
        let h = MotionHarness()
        h.motion.utteranceConfirmed()
        await h.drain()
        let base = ControlledReply()
        let sut = ReplyPlaybackCoordinator(reply: MotionReplyGenerator(base: base, motion: h.motion),
                                           speaker: ControlledSpeaker(), motion: h.motion)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await base.waitUntilRequested()
        await base.finish(throwing: ConversationServiceError.modelGenerationFailed)
        _ = await run.result
        await h.drain()
        XCTAssertEqual(h.sentCommands.filter { $0 == .stop }.count, 1)
    }
}
