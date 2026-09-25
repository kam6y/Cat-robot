import XCTest
@testable import CatRobot

@MainActor
final class SentenceReplyPlaybackTests: XCTestCase {
    func testVoiceCaptureWaitsForLastSentenceAndCaptionStaysOriginal() async throws {
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [0.1], sampleRate: 24_000) })
        let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker, mode: .sentencePrefetch)
        let run = await harness.beginVoiceTurn()
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("iPhoneです。Bluetoothです。最後。")
        await harness.reply.finish()
        await player.waitForCalls(1)
        player.complete(0); await player.waitForCalls(2)
        player.complete(1); await player.waitForCalls(3)
        let before = await harness.recognizer.startCount
        XCTAssertEqual(before, 1)
        XCTAssertEqual(harness.viewModel.viewState.caption, "iPhoneです。Bluetoothです。最後。")
        player.complete(2); await run.value
        let after = await harness.recognizer.startCount
        XCTAssertEqual(after, 2)
        XCTAssertEqual(harness.traces.events.filter { $0.point == .speechStarted }.compactMap(\.sentenceOrdinal), [0, 1, 2])
        await harness.viewModel.shutdown()
    }
    func testGenerationFailureStopsPlaybackAndKeepsError() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .sentencePrefetch)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested(); await reply.yield("一文目。続き")
        await player.waitForCalls(1)
        await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await run.value; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        XCTAssertGreaterThan(player.stops, 0)
    }
    func testGenerationFailureStopsPlaybackWhileSentenceQueueIsFull() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .sentencePrefetch)
        let stopped = expectation(description: "Generation failure ends playback without draining queued audio")
        var received: ConversationServiceError?
        let run = Task {
            do { _ = try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }); XCTFail("Expected failure") }
            catch { received = error as? ConversationServiceError }
            stopped.fulfill()
        }
        await reply.waitUntilRequested()
        await reply.yield("一文目。二文目。三文目。四文目。五文目。六文目。七文目。")
        await player.waitForCalls(1)
        await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
        await fulfillment(of: [stopped], timeout: 1)
        let stoppedBeforeCleanup = player.stops
        let failureBeforeCleanup = received
        await sut.cancelAndWait()
        await run.value
        XCTAssertGreaterThan(stoppedBeforeCleanup, 0)
        XCTAssertEqual(failureBeforeCleanup, .modelGenerationFailed)
        XCTAssertEqual(player.played.count, 1)
    }
    func testUnstableReplyWaitsForFinalAndMemoryKeepsOriginal() async throws {
        let reply = ControlledReply(stablePrefix: false)
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .sentencePrefetch)
        let updates = PlaybackUpdates()
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
        await reply.waitUntilRequested(); await reply.yield("仮の文。続き")
        await updates.waitForCaption("仮の文。続き")
        XCTAssertTrue(player.played.isEmpty)
        await reply.yield("確定。最後。"); await reply.finish()
        await player.waitForCalls(1); player.complete(0)
        await player.waitForCalls(2); player.complete(1)
        let result = try await run.value
        XCTAssertEqual(result, "確定。最後。")

        let store = InMemoryConversationMemoryStore()
        let gemma = GemmaConversationService(runtime: StubGemmaRuntime(reply: StubGemmaSession(chunks: ["iPhoneです。Bluetoothです。"])), memoryStore: store)
        let immediate = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {}, voice: { .f1 }, synthesize: { text, _ in
            XCTAssertFalse(text.contains("iPhone")); XCTAssertFalse(text.contains("Bluetooth"))
            return SpeechPCM(samples: [1], sampleRate: 24_000)
        })
        let actual = ReplyPlaybackCoordinator(reply: gemma, speaker: immediate, mode: .sentencePrefetch)
        let original = try await actual.run(prompt: "説明して", trace: nil, onUpdate: { _ in })
        let saved = await store.load()
        XCTAssertEqual(original, "iPhoneです。Bluetoothです。")
        XCTAssertEqual(saved?.turns.last?.response, original)
    }
    func testNewestSnapshotsRetainAllSentencesWhilePlaybackIsBlocked() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        var spoken: [String] = []
        speaker.onInput = { original, _ in spoken.append(original) }
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .sentencePrefetch)
        let updates = PlaybackUpdates()
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
        await reply.waitUntilRequested()
        let sentences = (1...8).map { "文\($0)。" }
        await reply.yield(sentences.prefix(6).joined())
        await player.waitForCalls(1)
        let final = sentences.joined()
        for index in final.indices where String(final[...index]).count > sentences.prefix(6).joined().count {
            await reply.yield(String(final[...index]))
        }
        await reply.finish()
        await updates.waitForCaption(final)
        for index in sentences.indices {
            await player.waitForCalls(index + 1)
            player.complete(index)
        }
        let result = try await run.value
        XCTAssertEqual(result, final)
        XCTAssertEqual(spoken, sentences)
    }
    func testOldTraceDecodesWithoutSentenceOrdinal() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","point":"speechStarted","at":1,"part":"first"}"#.utf8)
        let event = try JSONDecoder().decode(ReplyTraceEvent.self, from: data)
        XCTAssertNil(event.sentenceOrdinal)
    }
}
