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
    func testOldTraceDecodesWithoutSentenceOrdinal() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","point":"speechStarted","at":1,"part":"first"}"#.utf8)
        let event = try JSONDecoder().decode(ReplyTraceEvent.self, from: data)
        XCTAssertNil(event.sentenceOrdinal)
    }
}
