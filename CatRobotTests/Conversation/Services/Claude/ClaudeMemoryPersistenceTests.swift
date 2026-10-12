import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ClaudeMemoryPersistenceTests: XCTestCase {
    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws { for try await _ in stream {} }
    private func seed(summary: String = "好きな飲み物はほうじ茶", id: String = ClaudeMemoryCompatibility.current) -> ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: id, revision: 1, savedAt: Date(), summary: summary,
              turns: [.init(prompt: "こんにちは", response: "やあ")])
    }
    func testNewServiceRestoresSummaryAndTurns() async throws {
        let store = InMemoryConversationMemoryStore(snapshot: seed())
        try await drain(makeClaudeService(StubSessionFactory(), store: store).streamReply(to: "金沢へ行く"))
        let factory = StubSessionFactory()
        try await drain(makeClaudeService(factory, store: store).streamReply(to: "どこへ行く？"))
        let instructions = await factory.sessions.first!.configuration.instructions
        XCTAssertTrue(instructions.contains("好きな飲み物はほうじ茶"))
        XCTAssertTrue(instructions.contains("利用者: こんにちは\n猫: やあ"))
        XCTAssertTrue(instructions.contains("利用者: 金沢へ行く"))
    }
    func testSaveFailurePreservesReplyAndRetryUsesLatestMemory() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await drain(sut.streamReply(to: "A"))
        try await drain(sut.streamReply(to: "B"))
        let state = await sut.memoryState()
        XCTAssertEqual(state, .unsaved)
        await store.setSaveFailure(false)
        try await sut.retryMemoryOperation()
        let saved = await store.snapshot
        XCTAssertEqual(saved?.turns.map(\.prompt), ["A", "B"])
        let recovered = await sut.memoryState()
        XCTAssertEqual(recovered, .ready)
    }
    func testConcurrentPreparationLoadsOnce() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(snapshot: seed(), loadGate: gate)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        let first = Task { try await sut.prepareMemory() }
        await gate.waitUntilEntered()
        let second = Task { try await sut.prepareMemory() }
        await gate.open()
        try await first.value; try await second.value
        try await sut.prepareMemory()
        let loads = await store.loadCount
        XCTAssertEqual(loads, 1)
    }
    func testInvalidRestorationBlocksReplyAndDoesNotOverwriteFile() async throws {
        for snapshot in [seed(id: "foreign"), seed(summary: String(repeating: "x", count: 1_201))] {
            let store = InMemoryConversationMemoryStore(snapshot: snapshot)
            let factory = StubSessionFactory()
            do { try await drain(makeClaudeService(factory, store: store).streamReply(to: "hello")); XCTFail("Must block") } catch {}
            let sessions = await factory.sessions
            XCTAssertTrue(sessions.isEmpty)
            let saved = await store.load()
            XCTAssertEqual(saved, snapshot)
        }
    }
    func testRestoredConversationAboveTriggerCompactsBeforeReply() async throws {
        let initial = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "前の記憶",
            turns: (0..<4).map { .init(prompt: "\($0)" + String(repeating: "x", count: 4_100), response: "R") })
        let store = InMemoryConversationMemoryStore(snapshot: initial)
        let factory = StubSessionFactory(summaries: ["memory-1"])
        try await drain(makeClaudeService(factory, store: store).streamReply(to: "続き"))
        let requests = await factory.summaryRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.previousSummary, "前の記憶")
        let saved = await store.load()
        XCTAssertEqual(saved?.summary, "memory-1")
        XCTAssertEqual(saved?.turns.count, 2)
    }
    private func waitForState(_ sut: ClaudeConversationService, _ target: ConversationMemoryState) async {
        for await state in await sut.memoryUpdates() { if state == target { return } }
    }
    func testForgetWaitsForSaveThenRemovesIt() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(saveGate: gate)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        let turn = Task { try await self.drain(sut.streamReply(to: "覚えて")) }
        await gate.waitUntilEntered()
        let forget = Task { try await sut.forgetConversation() }
        await waitForState(sut, .forgetting)
        let clears = await store.clearCount
        XCTAssertEqual(clears, 0)
        await gate.open()
        _ = try? await turn.value
        try await forget.value
        let saved = await store.snapshot
        XCTAssertNil(saved)
    }
    func testForgetFailureBlocksRepliesUntilRetrySucceeds() async throws {
        let store = MemoryStoreFake()
        await store.setClearFailure(true)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await drain(sut.streamReply(to: "A"))
        do { try await sut.forgetConversation(); XCTFail("expected deleteFailed") } catch {}
        do { try await drain(sut.streamReply(to: "B")); XCTFail("blocked") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .unavailable) }
        // 削除失敗中の reset は新しい保存で .ready に戻さない（再試行で削除が成功するまでブロックを保つ）
        await sut.reset()
        let stillBlocked = await sut.memoryState()
        XCTAssertEqual(stillBlocked, .forgetFailed(.deleteFailed))
        do { try await drain(sut.streamReply(to: "B2")); XCTFail("still blocked") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .unavailable) }
        let savesBeforeRetry = await store.saveCount
        XCTAssertEqual(savesBeforeRetry, 1, "reset は削除失敗中に保存しない")
        await store.setClearFailure(false)
        try await sut.retryMemoryOperation()
        let state = await sut.memoryState()
        XCTAssertEqual(state, .ready)
        try await drain(sut.streamReply(to: "C"))
    }

    // --- ストア書き込みの直列化と最新保存の照合 ---

    func testForgetWaitsForInFlightExternalSave() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let store = MemoryStoreFake(saveGate: gate)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await sut.prepareMemory()
        let external = Task { await sut.recordExternalTurn(prompt: "削除前の外部質問", response: "削除前の外部返答") }
        await gate.waitUntilEntered()            // 外部往復の保存はストアに渡り、完了待ち
        let forget = Task { try await sut.forgetConversation() }
        // 旧実装は forget がこの保存を待たず、gate が閉じている間に clear を終えた。修正後は clear が保存の後ろに並ぶので、
        // 遅れて開く gate の長さに結果は依存しない。合否は完了順の記録と最終 snapshot で判定する。
        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        defer { opener.cancel() }
        await external.value
        try await forget.value
        _ = await opener.value
        let events = await store.events
        XCTAssertEqual(events, ["save", "clear"], "削除は先に始まった保存の完了後")
        let saved = await store.snapshot
        XCTAssertNil(saved, "削除前の外部往復が書き戻されない")
        let state = await sut.memoryState()
        XCTAssertEqual(state, .ready)
    }

    func testForgetWaitsForInFlightResetSave() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let store = MemoryStoreFake(snapshot: seed(), saveGate: gate)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await sut.prepareMemory()
        let reset = Task { await sut.reset() }   // 空の記憶の保存が gate で止まる
        await gate.waitUntilEntered()
        let forget = Task { try await sut.forgetConversation() }
        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        defer { opener.cancel() }
        await reset.value
        try await forget.value
        _ = await opener.value
        let events = await store.events
        XCTAssertEqual(events, ["save", "clear"], "reset の保存が clear を追い越さない")
        let saved = await store.snapshot
        XCTAssertNil(saved)
        let state = await sut.memoryState()
        XCTAssertEqual(state, .ready)
    }

    func testForgetProceedsAfterAFailedSave() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await drain(sut.streamReply(to: "A"))
        let unsaved = await sut.memoryState()
        XCTAssertEqual(unsaved, .unsaved)
        try await sut.forgetConversation()
        let events = await store.events
        XCTAssertEqual(events, ["saveFailed", "clear"], "失敗した保存がキューを止めない")
        let saved = await store.snapshot
        XCTAssertNil(saved)
        let state = await sut.memoryState()
        XCTAssertEqual(state, .ready)
    }

    func testStaleSaveCompletionDoesNotMaskThePendingSave() async throws {
        let first = ConversationTestGate()
        let second = ConversationTestGate()
        addTeardownBlock { await first.open(); await second.open() }
        let store = MemoryStoreFake(saveGate: first)
        let sut = makeClaudeService(StubSessionFactory(), store: store)
        try await sut.prepareMemory()
        let a = Task { await sut.recordExternalTurn(prompt: "A", response: "a") }
        await first.waitUntilEntered()           // A の保存はストアで停止中
        await store.setSaveGate(second)          // 次の保存（B）は第 2 gate で止める
        let b = Task { await sut.recordExternalTurn(prompt: "B", response: "b") }
        // B の保存は A の後ろに並ぶ。A を完了させても B はまだ保存中なので、状態は .saving のまま。
        await first.open()
        await a.value
        await second.waitUntilEntered()
        let whileBPending = await sut.memoryState()
        XCTAssertEqual(whileBPending, .saving, "古い保存の完了で最新の保存状態を上書きしない")
        await store.setSaveFailure(true)
        await second.open()
        await b.value
        let afterB = await sut.memoryState()
        XCTAssertEqual(afterB, .unsaved, "最新の保存が失敗したら .unsaved")
        let events = await store.events
        XCTAssertEqual(events, ["save", "saveFailed"])
        let saved = await store.snapshot
        XCTAssertEqual(saved?.turns.map(\.prompt), ["A"], "B は保存されていない")
    }
}
