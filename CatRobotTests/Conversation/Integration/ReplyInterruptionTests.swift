import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ReplyInterruptionTests: XCTestCase {
    func testInterruptionRemovesUnheardTailAndPreservesEarlierMemory() async throws {
        let seed = ConversationMemorySnapshot(schemaVersion: 1,
            memoryCompatibilityID: ClaudeMemoryCompatibility.current, revision: 1, savedAt: Date(),
            summary: "好きな飲み物はほうじ茶", turns: [.init(prompt: "前の話", response: "覚えているよ。")])
        let store = InMemoryConversationMemoryStore(snapshot: seed)
        let factory = StubSessionFactory(scripts: [
            ScriptedSessionClient(chunks: ["最初の文。まだ聞いていない秘密。"]),
            ScriptedSessionClient(chunks: ["次の返事。"])
        ])
        let service = makeClaudeService(factory, store: store)
        let speaker = ControlledSpeaker()
        let updates = PlaybackUpdates()
        let coordinator = ReplyPlaybackCoordinator(reply: service, speaker: speaker)
        let run = Task { try await coordinator.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
        await speaker.waitUntilCallCount(1)
        await speaker.complete()
        await updates.waitForSentenceFinishes(1)
        await speaker.waitUntilCallCount(2)
        await speaker.emit(.started)
        await updates.waitForSentenceStarts(2)
        await coordinator.interruptAndWait()
        _ = try? await run.value

        let saved = await store.load()
        XCTAssertEqual(saved?.summary, seed.summary)
        XCTAssertEqual(saved?.turns.first, seed.turns.first)
        XCTAssertEqual(saved?.turns.count, 2)
        let interrupted = try XCTUnwrap(saved?.turns.last)
        XCTAssertEqual(interrupted.prompt, "質問")
        XCTAssertTrue(interrupted.response.hasPrefix("最初の文。"))
        XCTAssertFalse(interrupted.response.contains("まだ聞いていない秘密"))
        XCTAssertTrue(interrupted.response.contains("中断"))

        // The next model session must be rebuilt from corrected delivery memory.
        let stream = try await service.streamReply(to: "訂正するね")
        for try await _ in stream {}
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("最初の文。"))
        XCTAssertFalse(sessions.last!.configuration.instructions.contains("まだ聞いていない秘密"))
    }

    func testInterruptionAfterFullPlaybackPreservesCompletedMemory() async throws {
        let store = InMemoryConversationMemoryStore()
        let service = makeClaudeService(StubSessionFactory(scripts: [
            ScriptedSessionClient(chunks: ["最後まで読み終えた返答。"])
        ]), store: store)
        let speaker = ControlledSpeaker()
        let coordinator = ReplyPlaybackCoordinator(reply: service, speaker: speaker)
        let run = Task {
            try await coordinator.run(prompt: "質問", trace: nil) { update in
                if case .speechFinished(.full) = update {
                    // Arrive before run() resumes and removes its active operation.
                    coordinator.interrupt()
                }
            }
        }
        await speaker.waitUntilCallCount(1)
        await speaker.complete()
        let result = await run.result
        await coordinator.cancelAndWait()

        switch result {
        case .success(let response): XCTAssertEqual(response, "最後まで読み終えた返答。")
        case .failure(let error): XCTFail("Completed playback must remain successful: \(error)")
        }
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.last?.response, "最後まで読み終えた返答。")
    }

    func testInterruptionBeforePlaybackDoesNotClaimGeneratedTextWasHeard() async throws {
        let store = InMemoryConversationMemoryStore()
        let service = makeClaudeService(StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["未再生の返答。"])]), store: store)
        let speaker = ControlledSpeaker()
        let coordinator = ReplyPlaybackCoordinator(reply: service, speaker: speaker)
        let run = Task { try await coordinator.run(prompt: "元の質問", trace: nil, onUpdate: { _ in }) }
        await speaker.waitUntilCallCount(1)
        await coordinator.interruptAndWait()
        _ = try? await run.value
        let saved = await store.load()
        let interrupted = try XCTUnwrap(saved?.turns.last)
        XCTAssertEqual(interrupted.prompt, "元の質問")
        XCTAssertFalse(interrupted.response.contains("未再生の返答"))
        XCTAssertTrue(interrupted.response.contains("中断"))
        let revision = saved?.revision
        await coordinator.interruptAndWait()
        let repeated = await store.load()
        XCTAssertEqual(repeated?.revision, revision, "A repeated interrupt must not duplicate a turn")
    }
    func testInterruptedGenerationKeepsOnlyCompletedSentencesWithoutAFullReplyCommit() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let store = InMemoryConversationMemoryStore()
        let service = makeClaudeService(StubSessionFactory(scripts: [held]), store: store)
        let speaker = ControlledSpeaker()
        let updates = PlaybackUpdates()
        let coordinator = ReplyPlaybackCoordinator(reply: service, speaker: speaker)
        let run = Task { try await coordinator.run(prompt: "長い返事", trace: nil, onUpdate: updates.record) }
        await held.waitUntilStarted()
        held.yield("聞こえた文。未生成の続き")
        await speaker.waitUntilCallCount(1)
        await speaker.complete()
        await updates.waitForSentenceFinishes(1)
        let before = await store.load()
        XCTAssertNil(before, "Generation has not committed a complete reply")
        await coordinator.interruptAndWait()
        _ = try? await run.value
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertTrue(saved?.turns.last?.response.hasPrefix("聞こえた文。") == true)
        XCTAssertFalse(saved?.turns.last?.response.contains("未生成の続き") == true)
    }

    func testStaleReceiptCannotChangeANewerReplyOrResurrectResetAndForgottenMemory() async throws {
        for superseding in ["reply", "reset", "forget"] {
            let store = InMemoryConversationMemoryStore()
            let service = makeClaudeService(store: store)
            let old = UUID()
            try await generate(service, id: old, prompt: "古い質問")
            switch superseding {
            case "reply": try await generate(service, id: UUID(), prompt: "新しい質問")
            case "reset": await service.reset()
            default: try await service.forgetConversation()
            }
            let before = await store.load()
            await service.interruptReply(.init(id: old, prompt: "古い質問", completedText: "古い文。", interruptedSentence: true))
            let after = await store.load()
            XCTAssertEqual(after, before, superseding)
        }
    }

    func testInterruptionCorrectionPersistsAfterCompactionAndSaveRetry() async throws {
        let seed = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "", turns: [.init(prompt: "以前の会話です", response: "以前の返答です")])
        let store = MemoryStoreFake(snapshot: seed)
        let service = makeClaudeService(store: store, budget: .init(compactionTriggerCharacters: 5, retainedCharacters: 0))
        let id = UUID()
        try await generate(service, id: id, prompt: "今回の質問")
        await store.setSaveFailure(true)
        await service.interruptReply(.init(id: id, prompt: "今回の質問", completedText: "", interruptedSentence: false))
        let warning = await service.memoryState()
        XCTAssertEqual(warning, .unsaved)
        await store.setSaveFailure(false)
        try await service.retryMemoryOperation()
        let saved = await store.snapshot
        XCTAssertEqual(saved?.summary, "要約1")
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.last?.prompt, "今回の質問")
        XCTAssertFalse(saved?.turns.last?.response.contains("にゃん") == true)
        XCTAssertTrue(saved?.turns.last?.response.contains("中断") == true)
    }

    func testFallbackAndMotionWrappersPreserveDeliveryIdentity() async throws {
        let store = InMemoryConversationMemoryStore()
        let usage = ConversationUsageSpy()
        await usage.setLimitReached(true)
        let primary = makeClaudeService(store: store, usage: usage)
        let secondary = ControlledReply()
        let fallback = OnDeviceFallbackReplyGenerator(primary: primary, secondary: secondary,
            secondaryAvailability: OnDeviceFallbackReplyGeneratorTests.Availability(value: .available),
            usage: usage, configuration: { .init() })
        let routed = MotionReplyGenerator(base: fallback, motion: NoopRobotMotionController())
        let speaker = ControlledSpeaker()
        let coordinator = ReplyPlaybackCoordinator(reply: routed, speaker: speaker)
        let run = Task { try await coordinator.run(prompt: "代替モデルへの質問", trace: nil, onUpdate: { _ in }) }
        await secondary.waitUntilRequested()
        await secondary.yield("まだ聞かせていない返答。")
        await secondary.finish()
        await speaker.waitUntilCallCount(1)
        await coordinator.interruptAndWait()
        _ = try? await run.value
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.first?.prompt, "代替モデルへの質問")
        XCTAssertFalse(saved?.turns.first?.response.contains("まだ聞かせていない返答") == true)
        let receipts = await secondary.interruptions
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.prompt, "代替モデルへの質問")
    }

    private func generate(_ service: ClaudeConversationService, id: UUID, prompt: String) async throws {
        try await ReplyDeliveryContext.$current.withValue(id) {
            let stream = try await service.streamReply(to: prompt)
            for try await _ in stream {}
        }
    }

}
