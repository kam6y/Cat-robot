import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class GemmaMemoryPersistenceTests: XCTestCase {
    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws {
        for try await _ in stream {}
    }
    private func seed(summary: String = "好きな飲み物はほうじ茶", id: String = GemmaMemoryCompatibility.current) -> ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: id, revision: 1, savedAt: Date(),
              summary: summary, turns: [.init(prompt: "こんにちは", response: "やあ")])
    }
    func testNewServiceRestoresSummaryAndTurns() async throws {
        let store = InMemoryConversationMemoryStore(snapshot: seed())
        let first = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        try await drain(first.streamReply(to: "金沢へ行く"))
        let runtime = RecordingGemmaRuntime()
        let second = GemmaConversationService(runtime: runtime, memoryStore: store)
        try await drain(second.streamReply(to: "どこへ行く？"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.first?.history.map(\.prompt), ["こんにちは", "金沢へ行く"])
        XCTAssertEqual(configs.first?.summary, "好きな飲み物はほうじ茶")
    }
    func testSaveFailurePreservesReplyAndRetryUsesLatestMemory() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        try await drain(service.streamReply(to: "A"))
        try await drain(service.streamReply(to: "B"))
        let state = await service.memoryState()
        XCTAssertEqual(state, .unsaved)
        await store.setSaveFailure(false)
        try await service.retryMemoryOperation()
        let saved = await store.snapshot
        XCTAssertEqual(saved?.turns.map(\.prompt), ["A", "B"])
        let recovered = await service.memoryState()
        XCTAssertEqual(recovered, .ready)
    }
    func testConcurrentPreparationLoadsOnceAndPauseDoesNotReload() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(snapshot: seed(), loadGate: gate)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        let first = Task { try await service.prepareMemory() }
        await gate.waitUntilEntered()
        let second = Task { try await service.prepareMemory() }
        await gate.open()
        try await first.value
        try await second.value
        try await service.prepareMemory()
        let loads = await store.loadCount
        XCTAssertEqual(loads, 1)
    }
    func testInvalidRestorationBlocksReplyAndDoesNotOverwriteFile() async throws {
        for snapshot in [seed(id: "foreign"), seed(summary: String(repeating: "x", count: 513))] {
            let store = InMemoryConversationMemoryStore(snapshot: snapshot)
            let runtime = RecordingGemmaRuntime()
            let service = GemmaConversationService(runtime: runtime, memoryStore: store)
            do { try await drain(service.streamReply(to: "hello")); XCTFail("Must block") } catch {}
            let configs = await runtime.configurations
            XCTAssertTrue(configs.isEmpty)
            let saved = await store.load()
            XCTAssertEqual(saved, snapshot)
        }
    }
    func testClassificationDoesNotSaveAndFailedReplyKeepsOldSnapshot() async throws {
        let initial = seed()
        let store = InMemoryConversationMemoryStore(snapshot: initial)
        let runtime = RecordingGemmaRuntime(failFirstRebuiltReply: true)
        let service = GemmaConversationService(runtime: runtime, memoryStore: store)
        _ = try await service.classify("猫？")
        do { try await drain(service.streamReply(to: "続き")); XCTFail("Expected failure") } catch {}
        let saved = await store.load()
        XCTAssertEqual(saved, initial)
    }
    func testRestoredConversationAboveTriggerCompactsBeforeReply() async throws {
        let initial = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: GemmaMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "前の記憶",
            turns: (0..<4).map { .init(prompt: "\($0)" + String(repeating: "x", count: 2100), response: "R") })
        let store = InMemoryConversationMemoryStore(snapshot: initial)
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime, memoryStore: store)
        try await drain(service.streamReply(to: "続き"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.map(\.kind), [.summary, .reply])
        let saved = await store.load()
        XCTAssertEqual(saved?.summary, "memory-1")
        XCTAssertEqual(saved?.turns.count, 2)
    }
    private func waitForState(_ service: GemmaConversationService, _ target: ConversationMemoryState) async {
        for await state in await service.memoryUpdates() { if state == target { return } }
    }
    func testForgetWaitsForSaveThenRemovesIt() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(saveGate: gate)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        let turn = Task { try await self.drain(service.streamReply(to: "覚えて")) }
        await gate.waitUntilEntered()
        let forget = Task { try await service.forgetConversation() }
        await waitForState(service, .forgetting)
        let clears = await store.clearCount
        XCTAssertEqual(clears, 0)
        await gate.open()
        _ = try? await turn.value
        try await forget.value
        let saved = await store.snapshot
        XCTAssertNil(saved)
        let runtime = RecordingGemmaRuntime()
        let restarted = GemmaConversationService(runtime: runtime, memoryStore: store)
        try await drain(restarted.streamReply(to: "hello"))
        let configs = await runtime.configurations
        XCTAssertEqual(configs.first?.history.count, 0)
    }
    func testForgetInvalidatesInflightRestore() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(snapshot: seed(), loadGate: gate)
        let runtime = RecordingGemmaRuntime()
        let service = GemmaConversationService(runtime: runtime, memoryStore: store)
        let prepare = Task { try await service.prepareMemory() }
        await gate.waitUntilEntered()
        let forget = Task { try await service.forgetConversation() }
        await waitForState(service, .forgetting)
        await gate.open()
        _ = try? await prepare.value
        try await forget.value
        try await drain(service.streamReply(to: "新しい会話"))
        let configs = await runtime.configurations
        XCTAssertTrue(configs.first?.history.isEmpty == true)
        XCTAssertEqual(configs.first?.summary, "")
    }
    func testConsumerCancellationAfterCommitStillFinishesSaving() async throws {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(saveGate: gate)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        let reader = Task { try await self.drain(service.streamReply(to: "保存する往復")) }
        await gate.waitUntilEntered()
        reader.cancel()
        _ = try? await reader.value
        await gate.open()
        await waitForState(service, .ready)
        let saved = await store.snapshot
        XCTAssertEqual(saved?.turns.map(\.prompt), ["保存する往復"])
    }

    func testForgetJoinsSaveRetryBeforeClearing() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        try await drain(service.streamReply(to: "忘れる前の会話"))
        await store.setSaveFailure(false)
        let gate = ConversationTestGate()
        await store.setSaveGate(gate)
        let retry = Task { try await service.retryMemoryOperation() }
        await gate.waitUntilEntered()
        let forget = Task { try await service.forgetConversation() }
        await waitForState(service, .forgetting)
        let otherForget = Task { try await service.forgetConversation() }
        let clears = await store.clearCount
        XCTAssertEqual(clears, 0)
        await gate.open()
        _ = try? await retry.value
        try await forget.value
        try await otherForget.value
        let saved = await store.snapshot
        XCTAssertNil(saved)
    }

    func testForgetWaitsForNativeCancellationToDrain() async throws {
        let session = StubGemmaSession(chunks: nil)
        let store = MemoryStoreFake()
        let service = GemmaConversationService(runtime: StubGemmaRuntime(reply: session), memoryStore: store)
        let reader = Task { try await self.drain(service.streamReply(to: "まだ生成中")) }
        await session.waitUntilStarted()
        let forget = Task { try await service.forgetConversation() }
        await session.waitUntilCancelled()
        let clears = await store.clearCount
        XCTAssertEqual(clears, 0)
        session.finish()
        _ = try? await reader.value
        try await forget.value
        let saved = await store.snapshot
        XCTAssertNil(saved)
    }

    func testNewReplyDuringForgetIsRejectedWithoutWaitingForNativeDrain() async throws {
        let session = StubGemmaSession(chunks: nil)
        let store = MemoryStoreFake()
        let service = GemmaConversationService(runtime: StubGemmaRuntime(reply: session), memoryStore: store)
        let reader = Task { try await self.drain(service.streamReply(to: "まだ生成中")) }
        await session.waitUntilStarted()
        let forget = Task { try await service.forgetConversation() }
        await session.waitUntilCancelled()
        let rejected = expectation(description: "A request during forget must be rejected immediately")
        let newcomer = Task {
            do { _ = try await service.streamReply(to: "削除中の新規入力"); XCTFail("Must reject new inference") }
            catch { XCTAssertEqual(error as? ConversationMemoryError, .unavailable) }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 1)
        session.finish()
        _ = try? await reader.value
        try await forget.value
        await newcomer.value
        let saved = await store.snapshot
        XCTAssertNil(saved)
    }

    func testFailedResetBlocksReplyUntilDeletionRetrySucceeds() async throws {
        let store = MemoryStoreFake(snapshot: seed())
        await store.setClearFailure(true)
        let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
        await service.reset()
        let state = await service.memoryState()
        XCTAssertEqual(state, .forgetFailed(.deleteFailed))
        do { try await drain(service.streamReply(to: "hello")); XCTFail("Must block") } catch {}
        await store.setClearFailure(false)
        try await service.retryMemoryOperation()
        let saved = await store.snapshot
        XCTAssertNil(saved)
    }
}
