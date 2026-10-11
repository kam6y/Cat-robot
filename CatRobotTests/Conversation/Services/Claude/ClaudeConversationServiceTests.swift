import ClaudeForFoundationModels
import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ClaudeConversationServiceTests: XCTestCase {
    final class Settings: @unchecked Sendable {
        private let lock = NSLock(); private var value: ConversationModelConfiguration
        init(_ value: ConversationModelConfiguration = .init()) { self.value = value }
        var current: ConversationModelConfiguration { lock.withLock { value } }
        func set(_ new: ConversationModelConfiguration) { lock.withLock { value = new } }
    }
    actor UsageSpy: ConversationUsageMetering {
        private(set) var turns: [(ConversationModelChoice, Int, Int)] = []
        var limitReached = false
        func setLimitReached(_ value: Bool) { limitReached = value }
        func recordTurn(model: ConversationModelChoice, promptCharacters: Int, responseCharacters: Int) { turns.append((model, promptCharacters, responseCharacters)) }
        func isDailyLimitReached(limit: Int) -> Bool { limitReached }
        func summary() -> ConversationUsageSummary { .init(turnsToday: turns.count, turnsThisMonth: turns.count, estimatedCostUSDThisMonth: 0) }
    }
    func makeService(factory: StubSessionFactory = StubSessionFactory(),
                     store: any ConversationMemoryStore = InMemoryConversationMemoryStore(),
                     longTerm: LongTermMemoryManager = LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
                     settings: Settings = Settings(), usage: UsageSpy = UsageSpy(),
                     budget: ConversationBudget = .default) -> ClaudeConversationService {
        ClaudeConversationService(factory: factory, memoryStore: store, longTermMemory: longTerm,
                                  tools: RememberToolProvider(),
                                  configuration: { settings.current }, usage: usage, budget: budget)
    }
    func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []; for try await s in stream { out.append(s) }; return out
    }

    func testStreamsCumulativeSnapshotsCommitsTurnAndRecordsUsage() async throws {
        let factory = StubSessionFactory(); let store = InMemoryConversationMemoryStore(); let usage = UsageSpy()
        let service = makeService(factory: factory, store: store, usage: usage)
        let snapshots = try await collect(service.streamReply(to: "こんにちは"))
        XCTAssertEqual(snapshots, ["にゃ", "にゃん。"])
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [.init(prompt: "こんにちは", response: "にゃん。")])
        XCTAssertEqual(saved?.memoryCompatibilityID, "claude-memory-v1")
        let recorded = await usage.turns
        XCTAssertEqual(recorded.count, 1); XCTAssertEqual(recorded.first?.0, .opus5_5)
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.toolNames, ["remember"])
        XCTAssertTrue(sessions.first!.configuration.instructions.hasPrefix(ConversationInstructions.fixedPrefix))
    }

    func testSecondTurnReusesSessionAndRestartRebuildsFromMemory() async throws {
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory()
        let service = makeService(factory: factory, store: store)
        _ = try await collect(service.streamReply(to: "一回目"))
        _ = try await collect(service.streamReply(to: "二回目"))
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 1, "同じセッションを使い続ける")
        let second = StubSessionFactory()
        let restarted = makeService(factory: second, store: store)
        _ = try await collect(restarted.streamReply(to: "三回目"))
        let rebuilt = await second.sessions.first!.configuration.instructions
        XCTAssertTrue(rebuilt.contains("利用者: 一回目\n猫: にゃん。"))
        XCTAssertTrue(rebuilt.contains("利用者: 二回目"))
    }

    func testLongConversationCompactsBeforeTheNextReply() async throws {
        let factory = StubSessionFactory()
        let store = InMemoryConversationMemoryStore()
        let service = makeService(factory: factory, store: store, budget: .init(compactionTriggerCharacters: 400, retainedCharacters: 120))
        for index in 0..<6 { _ = try await collect(service.streamReply(to: "Turn \(index): " + String(repeating: "x", count: 150))) }
        let requests = await factory.summaryRequests
        XCTAssertGreaterThanOrEqual(requests.count, 1)
        XCTAssertFalse(requests[0].evictedTurns.isEmpty)
        let sessions = await factory.sessions
        XCTAssertGreaterThanOrEqual(sessions.count, 2, "要約後はセッションを作り直す")
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("これまでの会話の要約"))
        let saved = await store.load()
        XCTAssertEqual(saved?.summary.isEmpty, false)
        XCTAssertLessThan(saved!.turns.count, 6)
    }

    func testSummaryFailureFailsTheTurnWithoutCommittingOrResetting() async throws {
        let factory = StubSessionFactory(summaryError: URLError(.notConnectedToInternet))
        let store = InMemoryConversationMemoryStore()
        let service = makeService(factory: factory, store: store, budget: .init(compactionTriggerCharacters: 100, retainedCharacters: 20))
        // 2 往復（各 64 文字）で 128 文字になり、3 回目の返答の前に圧縮が走る。
        _ = try await collect(service.streamReply(to: String(repeating: "a", count: 60)))
        _ = try await collect(service.streamReply(to: String(repeating: "b", count: 60)))
        let before = await store.load()
        do { _ = try await collect(service.streamReply(to: "次")); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let after = await store.load()
        XCTAssertEqual(before, after)
    }

    func testModelSettingChangeAppliesOnlyWhenSessionIsRebuilt() async throws {
        let settings = Settings(.init(model: .opus5_5))
        let factory = StubSessionFactory()
        let usage = UsageSpy()
        let service = makeService(factory: factory, settings: settings, usage: usage)
        _ = try await collect(service.streamReply(to: "一回目"))
        settings.set(.init(model: .sonnet5_5, effort: .medium))
        _ = try await collect(service.streamReply(to: "二回目"))
        var sessions = await factory.sessions
        XCTAssertEqual(sessions.map(\.configuration.model), [.opus5_5], "進行中のセッションでは切り替えない")
        await service.reset()
        _ = try await collect(service.streamReply(to: "三回目"))
        sessions = await factory.sessions
        XCTAssertEqual(sessions.map(\.configuration.model), [.opus5_5, .sonnet5_5])
        XCTAssertEqual(sessions.last?.configuration.effort, .medium)
        let billed = await usage.turns.map { $0.0 }
        XCTAssertEqual(billed, [.opus5_5, .opus5_5, .sonnet5_5], "集計はそのターンを生成したセッションのモデルで行う")
    }

    func testResetDropsShortTermMemoryButKeepsLongTermFacts() async throws {
        let longStore = InMemoryLongTermMemoryStore()
        let longTerm = LongTermMemoryManager(store: longStore)
        _ = try await longTerm.remember("ほうじ茶が好き", category: .preference)
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory()
        let service = makeService(factory: factory, store: store, longTerm: longTerm)
        _ = try await collect(service.streamReply(to: "覚えてる？"))
        await service.reset()
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [])
        XCTAssertEqual(saved?.summary, "")
        _ = try await collect(service.streamReply(to: "新しい会話"))
        let instructions = await factory.sessions.last!.configuration.instructions
        XCTAssertTrue(instructions.contains("ほうじ茶が好き"))
        XCTAssertFalse(instructions.contains("覚えてる？"))
    }

    func testForgetClearsLongTermFactsAndRejectsLateRemember() async throws {
        let longStore = InMemoryLongTermMemoryStore()
        let longTerm = LongTermMemoryManager(store: longStore)
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory()
        let service = makeService(factory: factory, store: store, longTerm: longTerm)
        _ = try await longTerm.remember("A", category: .other)
        _ = try await collect(service.streamReply(to: "x"))
        // 忘れる前のセッションに渡された remember ツールを取り出しておく（遅れて届くツール呼び出しの再現）
        let firstSession = await factory.sessions.first
        let staleTool = try XCTUnwrap(firstSession?.tools.first { $0.name == "remember" } as? RememberTool)
        try await service.forgetConversation()
        let facts = try await longTerm.facts()
        XCTAssertTrue(facts.isEmpty)
        let saved = await store.load()
        XCTAssertNil(saved)
        // 削除前のセッションからの呼び出しは保存されない
        let late = try await staleTool.call(arguments: .init(fact: "B", category: "other"))
        XCTAssertEqual(late, "この記憶は保存できませんでした（会話がリセットされました）: B")
        let after = try await longTerm.facts()
        XCTAssertTrue(after.isEmpty)
        // 新しいセッションの remember は通る
        _ = try await collect(service.streamReply(to: "y"))
        let lastSession = await factory.sessions.last
        let freshTool = try XCTUnwrap(lastSession?.tools.first { $0.name == "remember" } as? RememberTool)
        let fresh = try await freshTool.call(arguments: .init(fact: "C", category: "other"))
        XCTAssertEqual(fresh, "覚えました: C")
        let texts = try await longTerm.facts().map(\.text)
        XCTAssertEqual(texts, ["C"])
    }

    func testOversizedPromptReportsInputTooLongWithoutCreatingSession() async throws {
        let factory = StubSessionFactory()
        let service = makeService(factory: factory)
        do { _ = try await collect(service.streamReply(to: String(repeating: "あ", count: 4_001))); XCTFail("expected inputTooLong") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .inputTooLong) }
        let sessions = await factory.sessions
        XCTAssertTrue(sessions.isEmpty)
    }

    func testConcurrentGenerationReportsBusyAndFailedTurnRebuildsSession() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let factory = StubSessionFactory(scripts: [held, ScriptedSessionClient(chunks: ["再開"])])
        let store = InMemoryConversationMemoryStore()
        let service = makeService(factory: factory, store: store)
        let stream = try await service.streamReply(to: "長い")
        let reader = Task { try await self.collect(stream) }
        await held.waitUntilStarted()
        do { _ = try await service.streamReply(to: "同時"); XCTFail("expected modelBusy") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelBusy) }
        held.yield("途中")
        held.fail(URLError(.networkConnectionLost))
        do { _ = try await reader.value; XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let saved = await store.load()
        XCTAssertNil(saved, "失敗した往復は保存しない")
        let recovered = try await collect(service.streamReply(to: "次"))
        XCTAssertEqual(recovered.last, "再開")
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2, "失敗後は確定済みの記憶からセッションを作り直す")
    }

    func testCancelledTurnIsNotCommitted() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let store = InMemoryConversationMemoryStore()
        let service = makeService(factory: StubSessionFactory(scripts: [held, ScriptedSessionClient(chunks: ["にゃ", "ん。"])]), store: store)
        let stream = try await service.streamReply(to: "キャンセル")
        let reader = Task { try await self.collect(stream) }
        await held.waitUntilStarted()
        held.yield("途")
        reader.cancel()
        _ = try? await reader.value
        held.finish()
        await Task.yield()
        let saved = await store.load()
        XCTAssertNil(saved)
        let next = try await collect(service.streamReply(to: "次"))
        XCTAssertEqual(next.last, "にゃん。")
    }

    func testAvailabilityMapsAuthenticationOutcomes() async {
        let ok = await makeService(factory: StubSessionFactory()).availability()
        XCTAssertEqual(ok, .available)
        let unsupported = await makeService(factory: StubSessionFactory(authenticationError: ClaudeError.attestationUnsupported)).availability()
        XCTAssertEqual(unsupported, .claudeAttestationUnsupported)
        let offline = await makeService(factory: StubSessionFactory(authenticationError: URLError(.notConnectedToInternet))).availability()
        XCTAssertEqual(offline, .claudeUnreachable)
    }

    func testExternalTurnIsCarriedIntoTheNextSession() async throws {
        let factory = StubSessionFactory()
        let store = InMemoryConversationMemoryStore()
        let service = makeService(factory: factory, store: store)
        _ = try await collect(service.streamReply(to: "一回目"))
        await service.recordExternalTurn(prompt: "電波が弱いとき", response: "簡単に答えたよ。")
        _ = try await collect(service.streamReply(to: "二回目"))
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("利用者: 電波が弱いとき\n猫: 簡単に答えたよ。"))
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.map(\.prompt), ["一回目", "電波が弱いとき", "二回目"])
    }

    func testPrewarmBuildsSessionOnceWithoutGenerating() async throws {
        let client = ScriptedSessionClient(chunks: ["x"])
        let factory = StubSessionFactory(scripts: [client])
        let service = makeService(factory: factory)
        await service.prewarm(); await service.prewarm()
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(client.prewarms, 2)
        XCTAssertTrue(client.prompts.isEmpty)
    }

    // --- 追加テスト（重点 5）: 取り消したターンの後始末が終わる前に次のターンを頼んだとき ---
    //
    // 事実: streamReply の worker は取り消し後も actor 上で後始末（isGenerating=false 等）を行う。
    // 後始末の前に次の streamReply が来ると plan 実装は modelBusy を返す。
    // 下の GatedSessionClient は snapshots(for:) の呼び出し自体をゲートで止め、取り消しに反応しないので、
    // 「取り消し済みだが後始末が終わっていない」状態を任意の長さで固定できる。

    /// snapshots(for:) をゲートで止める。ゲートは取り消しに反応しない（取り消し後の後始末が遅れる状況の再現）。
    final class GatedSessionClient: ConversationSessionClient {
        private let gate: ConversationTestGate
        private let inner: ScriptedSessionClient
        init(gate: ConversationTestGate, inner: ScriptedSessionClient) { self.gate = gate; self.inner = inner }
        func prewarm() async { await inner.prewarm() }
        func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
            await gate.wait()
            return await inner.snapshots(for: prompt)
        }
    }

    func waitForMemoryState(_ service: ClaudeConversationService, _ target: ConversationMemoryState) async {
        for await state in await service.memoryUpdates() { if state == target { return } }
    }

    func testNextTurnWaitsForCancelledTurnToUnwindInsteadOfReportingBusy() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }   // 失敗時もゲートを解放して worker を回収する
        let stuck = GatedSessionClient(gate: gate, inner: ScriptedSessionClient(chunks: nil))
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [stuck, ScriptedSessionClient(chunks: ["にゃ", "ん。"])])
        let service = makeService(factory: factory, store: store)
        let stream = try await service.streamReply(to: "キャンセル")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()          // worker は snapshots(for:) の中で止まっている
        reader.cancel()
        _ = try? await reader.value            // 利用側の購読は終わった。worker はまだ後始末に入れない
        // ゲートは少し遅れて開く。旧実装はこの間に次のターンが modelBusy になった（task6-red-cancel-unwind.log）。
        // 合否は待機後の返答・保存内容・セッション数で判定する。200 ms は観測窓であって完了保証ではない。
        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        defer { opener.cancel() }
        let next = try await collect(service.streamReply(to: "次"))
        _ = await opener.value
        XCTAssertEqual(next, ["にゃ", "にゃん。"])
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.map(\.prompt), ["次"], "取り消した往復は保存しない")
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2, "取り消し後は確定済みの記憶からセッションを作り直す")
    }

    func testExternalTurnRightAfterCancellationWaitsForCleanupAndIsSaved() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let stuck = GatedSessionClient(gate: gate, inner: ScriptedSessionClient(chunks: nil))
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [stuck, ScriptedSessionClient(chunks: ["にゃ", "ん。"])])
        let service = makeService(factory: factory, store: store)
        let stream = try await service.streamReply(to: "キャンセル")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()
        reader.cancel()
        _ = try? await reader.value
        let opener = Task {
            try? await Task.sleep(for: .milliseconds(200))
            await gate.open()
        }
        defer { opener.cancel() }
        // 旧実装は後始末前の !isGenerating 判定で黙って捨てた。修正後は後始末を待ってから記録する。
        await service.recordExternalTurn(prompt: "電波が弱いとき", response: "簡単に答えたよ。")
        _ = await opener.value
        let saved = await store.load()
        XCTAssertEqual(saved?.turns, [.init(prompt: "電波が弱いとき", response: "簡単に答えたよ。")])
        _ = try await collect(service.streamReply(to: "次"))
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.last!.configuration.instructions.contains("利用者: 電波が弱いとき\n猫: 簡単に答えたよ。"))
    }

    func testExternalTurnWaitingOnCancelledTurnIsDroppedWhenForgetStarts() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let stuck = GatedSessionClient(gate: gate, inner: ScriptedSessionClient(chunks: nil))
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [stuck, ScriptedSessionClient(chunks: ["にゃ", "ん。"])])
        let service = makeService(factory: factory, store: store)
        let stream = try await service.streamReply(to: "キャンセル")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()
        reader.cancel()
        _ = try? await reader.value
        // 外部往復は取り消し済み worker の後始末を待つ。その間に「忘れて」が始まる。
        let external = Task { await service.recordExternalTurn(prompt: "削除前の往復", response: "残ってはいけない") }
        let forget = Task { try await service.forgetConversation() }
        await waitForMemoryState(service, .forgetting)   // 忘れる処理の開始を観測してからゲートを開く
        await gate.open()
        await external.value
        try await forget.value
        let saved = await store.load()
        XCTAssertNil(saved, "削除前に頼まれた外部往復を新しい記憶へ書き戻さない")
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        _ = try await collect(service.streamReply(to: "次"))
        let instructions = await factory.sessions.last!.configuration.instructions
        XCTAssertFalse(instructions.contains("削除前の往復"))
        let after = await store.load()
        XCTAssertEqual(after?.turns.map(\.prompt), ["次"])
    }

    func testCancelledExternalTurnIsNotSaved() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let stuck = GatedSessionClient(gate: gate, inner: ScriptedSessionClient(chunks: nil))
        let store = InMemoryConversationMemoryStore()
        let factory = StubSessionFactory(scripts: [stuck, ScriptedSessionClient(chunks: ["にゃ", "ん。"])])
        let service = makeService(factory: factory, store: store)
        let stream = try await service.streamReply(to: "キャンセル")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()
        reader.cancel()
        _ = try? await reader.value
        // 外部往復の記録は取り消し済み worker の後始末を待つ。その呼び出し自体が取り消されたら保存しない。
        let external = Task { await service.recordExternalTurn(prompt: "取り消された外部往復", response: "保存してはいけない") }
        external.cancel()
        await gate.open()
        await external.value
        let saved = await store.load()
        XCTAssertNil(saved, "取り消された呼び出しの往復は保存しない")
        _ = try await collect(service.streamReply(to: "次"))
        let instructions = await factory.sessions.last!.configuration.instructions
        XCTAssertFalse(instructions.contains("取り消された外部往復"))
        let after = await store.load()
        XCTAssertEqual(after?.turns.map(\.prompt), ["次"])
    }

    // --- review 指摘 1: 生成途中に無効化が入った古いセッションを登録しない ---

    actor CallCounter {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }

    /// configuration の呼び出しを gate で止める。currentSession の生成途中に forget / reset / 外部往復を割り込ませる。
    func makeServiceGatedAtConfiguration(gate: ConversationTestGate, factory: StubSessionFactory,
                                         store: any ConversationMemoryStore, budget: ConversationBudget = .default,
                                         onlyCall: Int? = nil) -> ClaudeConversationService {
        let counter = CallCounter()
        return ClaudeConversationService(factory: factory, memoryStore: store,
                                         longTermMemory: LongTermMemoryManager(store: InMemoryLongTermMemoryStore()),
                                         tools: RememberToolProvider(),
                                         configuration: {
                                             let call = await counter.next()
                                             if onlyCall == nil || onlyCall == call { await gate.wait() }
                                             return .init()
                                         },
                                         usage: UsageSpy(), budget: budget)
    }

    func testPrewarmFinishingAfterForgetDoesNotResurrectTheOldSession() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let seed = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "削除前の秘密の要約",
            turns: [.init(prompt: "削除前の秘密の質問", response: "削除前の秘密の返事")])
        let store = InMemoryConversationMemoryStore(snapshot: seed)
        let stale = ScriptedSessionClient(chunks: ["古い"])
        let fresh = ScriptedSessionClient(chunks: ["新しい"])
        let factory = StubSessionFactory(scripts: [stale, fresh])
        let service = makeServiceGatedAtConfiguration(gate: gate, factory: factory, store: store)
        let warming = Task { await service.prewarm() }
        await gate.waitUntilEntered()            // currentSession は削除前の memory を捕捉し、configuration で止まっている
        try await service.forgetConversation()
        let erased = await store.load()
        XCTAssertNil(erased)
        await gate.open()
        await warming.value
        let next = try await collect(service.streamReply(to: "削除後の新しい質問"))
        XCTAssertEqual(next, ["新しい"], "次のターンは削除後の記憶から作った新しいセッションが答える")
        XCTAssertTrue(stale.prompts.isEmpty)
        XCTAssertEqual(stale.prewarms, 0, "古いセッションには prewarm も送らない")
        XCTAssertEqual(fresh.prompts, ["削除後の新しい質問"])
        let sessions = await factory.sessions
        let used = try XCTUnwrap(sessions.last)
        XCTAssertFalse(used.configuration.instructions.contains("削除前の秘密"))
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.map(\.prompt), ["削除後の新しい質問"])
    }

    func testPrewarmFinishingAfterResetOrExternalTurnBuildsTheNextSessionFromCurrentMemory() async throws {
        for variant in ["reset", "external"] {
            let gate = ConversationTestGate()
            addTeardownBlock { await gate.open() }
            let seed = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
                revision: 1, savedAt: Date(), summary: "", turns: [.init(prompt: "前の質問", response: "前の返事")])
            let store = InMemoryConversationMemoryStore(snapshot: seed)
            let stale = ScriptedSessionClient(chunks: ["古い"])
            let fresh = ScriptedSessionClient(chunks: ["新しい"])
            let factory = StubSessionFactory(scripts: [stale, fresh])
            let service = makeServiceGatedAtConfiguration(gate: gate, factory: factory, store: store)
            let warming = Task { await service.prewarm() }
            await gate.waitUntilEntered()
            if variant == "reset" {
                await service.reset()
            } else {
                await service.recordExternalTurn(prompt: "外の質問", response: "外の返事")
            }
            await gate.open()
            await warming.value
            let next = try await collect(service.streamReply(to: "次"))
            XCTAssertEqual(next, ["新しい"], variant)
            XCTAssertTrue(stale.prompts.isEmpty, variant)
            XCTAssertEqual(fresh.prompts, ["次"], variant)
            let sessions = await factory.sessions
            let instructions = try XCTUnwrap(sessions.last).configuration.instructions
            if variant == "reset" {
                XCTAssertFalse(instructions.contains("前の質問"), "reset 後は空の記憶から作る")
            } else {
                XCTAssertTrue(instructions.contains("利用者: 外の質問\n猫: 外の返事"), "外部往復を含む記憶から作る")
            }
        }
    }

    func testConcurrentPrewarmAndReplyShareOneSession() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let a = ScriptedSessionClient(chunks: ["A"])
        let b = ScriptedSessionClient(chunks: ["B"])
        let factory = StubSessionFactory(scripts: [a, b])
        let store = InMemoryConversationMemoryStore()
        let service = makeServiceGatedAtConfiguration(gate: gate, factory: factory, store: store)
        let warming = Task { await service.prewarm() }
        await gate.waitUntilEntered(1)           // prewarm が先に生成に入ったことを観測してから返答を始める
        let stream = try await service.streamReply(to: "一回目")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered(2)           // prewarm と返答の両方が configuration で止まった
        await gate.open()
        await warming.value
        let first = try await reader.value
        let second = try await collect(service.streamReply(to: "二回目"))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        let used = [a, b].filter { !$0.prompts.isEmpty }
        XCTAssertEqual(used.count, 1, "先に登録された 1 つのセッションに揃える")
        XCTAssertEqual(used.first?.prompts, ["一回目", "二回目"])
        let saved = await store.load()
        XCTAssertEqual(saved?.turns.map(\.prompt), ["一回目", "二回目"])
    }

    func testPrewarmDuringCompactedReplyDoesNotReinjectEvictedTurns() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let clients = (0..<3).map { _ in ScriptedSessionClient(chunks: ["にゃ", "ん。"]) }
        let factory = StubSessionFactory(scripts: clients)
        let store = InMemoryConversationMemoryStore()
        // 2 往復（各 64 文字）で 128 文字になり、3 回目の返答の前に圧縮が走る。圧縮後のセッション生成（2 回目の configuration）だけを止める。
        let service = makeServiceGatedAtConfiguration(gate: gate, factory: factory, store: store,
                                                      budget: .init(compactionTriggerCharacters: 100, retainedCharacters: 20), onlyCall: 2)
        let evicted = String(repeating: "a", count: 60)
        let retained = String(repeating: "b", count: 60)
        _ = try await collect(service.streamReply(to: evicted))
        _ = try await collect(service.streamReply(to: retained))
        let stream = try await service.streamReply(to: "次")
        let reader = Task { try await self.collect(stream) }
        await gate.waitUntilEntered()            // 圧縮は終わり、返答側は圧縮後の記憶からセッションを作っている途中
        await service.prewarm()                  // 返答生成中の prewarm は圧縮前の記憶からセッションを作ってはいけない
        await gate.open()
        let reply = try await reader.value
        XCTAssertEqual(reply.last, "にゃん。")
        let index = try XCTUnwrap(clients.firstIndex { $0.prompts.contains("次") })
        let sessions = await factory.sessions
        let instructions = sessions[index].configuration.instructions
        XCTAssertTrue(instructions.contains("これまでの会話の要約"), "実際に答えたセッションは新しい要約を持つ")
        XCTAssertTrue(instructions.contains("利用者: \(retained)"), "残した往復は注入される")
        XCTAssertFalse(instructions.contains(evicted), "退避した往復は再注入しない")
        let saved = await store.load()
        XCTAssertEqual(saved?.summary.isEmpty, false)
        XCTAssertEqual(saved?.turns.map(\.prompt), [retained, "次"])
    }

    func testCancelledCallerDoesNotRecordExternalTurn() async throws {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let store = InMemoryConversationMemoryStore()
        let service = makeService(store: store)
        try await service.prepareMemory()
        let recorder = Task {
            await gate.wait()
            await service.recordExternalTurn(prompt: "取り消された外部質問", response: "取り消された外部返答")
        }
        await gate.waitUntilEntered()
        recorder.cancel()
        await gate.open()
        await recorder.value
        let saved = await store.load()
        XCTAssertNil(saved, "取り消された呼び出し元の往復は保存しない")
    }
}
