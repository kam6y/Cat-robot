import XCTest
@testable import CatRobot

final class LongTermMemoryTests: XCTestCase {
    private func fact(_ text: String, _ category: LongTermFactCategory = .preference, at seconds: TimeInterval,
                      id: TimeInterval? = nil) -> LongTermFact {
        LongTermFact(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012.0f", id ?? seconds))!,
                     category: category, text: text, createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testRenderedBlockIsByteStableAcrossInsertionOrder() {
        let a = fact("ほうじ茶が好き", at: 1), b = fact("名前はさくら", .person, at: 2)
        XCTAssertEqual(LongTermMemoryPolicy.render([a, b]), LongTermMemoryPolicy.render([b, a]))
        XCTAssertEqual(LongTermMemoryPolicy.render([a, b]), "覚えていること:\n- [好み] ほうじ茶が好き\n- [人] 名前はさくら")
        XCTAssertEqual(LongTermMemoryPolicy.render([]), "")
        // 同時刻は id 順で安定。日時は本文に含めない（キャッシュ前方を壊さない）。
        let first = fact("先", .event, at: 3, id: 31), second = fact("後", .promise, at: 3, id: 32)
        XCTAssertEqual(LongTermMemoryPolicy.render([second, first]), "覚えていること:\n- [出来事] 先\n- [約束] 後")
    }

    func testManagerDeduplicatesTrimsAndCapsLength() async throws {
        let store = SpyLongTermMemoryStore()
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        let first = try await manager.remember("  ほうじ茶が好き ", category: .preference)
        let second = try await manager.remember("ほうじ茶が好き", category: .other)
        let long = try await manager.remember(String(repeating: "あ", count: 100), category: .event)
        XCTAssertEqual(first, .saved); XCTAssertEqual(second, .duplicate); XCTAssertEqual(long, .saved)
        let facts = try await manager.facts()
        XCTAssertEqual(facts.map(\.text), ["ほうじ茶が好き", String(repeating: "あ", count: 60)])
        let saved = await store.saved
        XCTAssertEqual(saved.last?.count, 2)
    }

    func testOverCapTriggersConsolidationAndFallsBackToDeterministicTrim() async throws {
        let store = SpyLongTermMemoryStore()
        var seeded = (0..<LongTermMemoryPolicy.maximumFacts).map { fact("事実\($0)", at: TimeInterval($0)) }
        seeded[0] = fact("古いその他", .other, at: 0)
        await store.seed(seeded)
        let consolidating = LongTermMemoryManager(store: store, consolidate: { facts in Array(facts.suffix(10)) })
        _ = try await consolidating.remember("新しい事実", category: .promise)
        let consolidated = try await consolidating.facts()
        XCTAssertEqual(consolidated.count, 10)
        await store.seed(seeded)
        struct Boom: Error {}
        let failing = LongTermMemoryManager(store: store, consolidate: { _ in throw Boom() })
        _ = try await failing.remember("新しい事実", category: .promise)
        let trimmed = try await failing.facts()
        XCTAssertEqual(trimmed.count, LongTermMemoryPolicy.maximumFacts)
        XCTAssertFalse(trimmed.contains { $0.text == "古いその他" }, "最古の other から落とす")
        XCTAssertTrue(trimmed.contains { $0.text == "新しい事実" })
        // 統合結果が空、または統合してもなお超過するときも、決定的な切り詰めに落とす。
        await store.seed(seeded)
        let emptying = LongTermMemoryManager(store: store, consolidate: { _ in [] })
        _ = try await emptying.remember("新しい事実", category: .promise)
        let afterEmpty = try await emptying.facts()
        XCTAssertEqual(afterEmpty.count, LongTermMemoryPolicy.maximumFacts, "空の統合結果は採用しない")
        XCTAssertTrue(afterEmpty.contains { $0.text == "新しい事実" })
        await store.seed(seeded)
        let stillOver = LongTermMemoryManager(store: store, consolidate: { $0 })
        _ = try await stillOver.remember("新しい事実", category: .promise)
        let afterStillOver = try await stillOver.facts()
        XCTAssertEqual(afterStillOver.count, LongTermMemoryPolicy.maximumFacts)
        XCTAssertFalse(afterStillOver.contains { $0.text == "古いその他" })
    }

    func testCharacterLimitAlsoTriggersDeterministicTrim() async throws {
        let store = SpyLongTermMemoryStore()
        let body = String(repeating: "い", count: LongTermMemoryPolicy.maximumFactLength - 2)
        // 66 件 × 60 文字 = 3,960 文字。次の 59 文字で 4,019 文字になり、件数は上限内でも文字数で超過する。
        await store.seed((0..<66).map { fact(body + String(format: "%02d", $0), at: TimeInterval($0)) })
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        let result = try await manager.remember(body + "新", category: .promise)
        XCTAssertEqual(result, .saved)
        let facts = try await manager.facts()
        XCTAssertEqual(facts.count, 66)
        XCTAssertLessThanOrEqual(facts.reduce(0) { $0 + $1.text.count }, LongTermMemoryPolicy.maximumCharacters)
        XCTAssertFalse(facts.contains { $0.text == body + "00" }, "other が無ければ最古から落とす")
        XCTAssertTrue(facts.contains { $0.text == body + "新" })
    }

    func testForgetAndClearWriteThrough() async throws {
        let store = SpyLongTermMemoryStore()
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        _ = try await manager.remember("A", category: .other); _ = try await manager.remember("B", category: .other)
        let id = try await manager.facts().first!.id
        try await manager.forget(id: id)
        let afterForget = try await manager.facts().map(\.text)
        XCTAssertEqual(afterForget, ["B"])
        try await manager.clear()
        let afterClear = try await manager.facts()
        XCTAssertTrue(afterClear.isEmpty)
        let clears = await store.clears
        XCTAssertEqual(clears, 1)
        let block = await manager.renderedBlock()
        XCTAssertEqual(block, "")
    }

    func testLoadFailureYieldsEmptyBlockAndIsNotCached() async throws {
        let store = SpyLongTermMemoryStore()
        await store.setFailsLoad(true)
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        let block = await manager.renderedBlock()
        XCTAssertEqual(block, "")
        do { _ = try await manager.facts(); XCTFail("expected readFailed") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .readFailed) }
        await store.setFailsLoad(false)
        await store.seed([fact("A", .other, at: 1)])
        let recovered = try await manager.facts().map(\.text)
        XCTAssertEqual(recovered, ["A"], "失敗した読み込みは cache せず、復旧後に読める")
    }

    func testSaveFailurePropagatesAndKeepsPreviousFacts() async throws {
        let store = SpyLongTermMemoryStore()
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        _ = try await manager.remember("A", category: .other)
        await store.setFailsSave(true)
        do { _ = try await manager.remember("B", category: .other); XCTFail("expected writeFailed") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .writeFailed) }
        let kept = try await manager.facts().map(\.text)
        XCTAssertEqual(kept, ["A"], "保存できなかった事実を一覧に残さない")
        await store.setFailsSave(false)
        _ = try await manager.remember("B", category: .other)
        let after = try await manager.facts().map(\.text)
        XCTAssertEqual(after, ["A", "B"], "失敗後もロックが解放されていて続けて書ける")
    }

    func testMutationsAreSerializedAndStaleWritersAreRejected() async throws {
        let store = SpyLongTermMemoryStore()
        let gate = ConversationTestGate()
        await store.setSaveGate(gate)
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        let staleWriter = await manager.makeWriter()
        // A の保存が store で止まっている間に clear を要求する。clear は A の後に実行され、A が復活することはない。
        let first = Task { try await manager.remember("A", category: .other) }
        await gate.waitUntilEntered()
        let clearing = Task { try await manager.clear() }
        await gate.open()
        _ = try await first.value
        try await clearing.value
        let afterClear = try await manager.facts()
        XCTAssertTrue(afterClear.isEmpty)
        // 削除前に作った writer からの書き込みは拒否され、現在の writer は通る。
        let stale = try await staleWriter.remember("B", category: .other)
        XCTAssertEqual(stale, .rejected)
        let fresh = try await manager.makeWriter().remember("C", category: .other)
        XCTAssertEqual(fresh, .saved)
        let texts = try await manager.facts().map(\.text)
        XCTAssertEqual(texts, ["C"])
        let saves = await store.saved
        XCTAssertEqual(saves.map { $0.map(\.text) }, [["A"], ["C"]])
        let clears = await store.clears
        XCTAssertEqual(clears, 1)
    }

    /// store の clear が完了するまで、上限時間つきで待つ（10 ms 刻み）。完了しなければ false。
    private func waitForClear(on store: SpyLongTermMemoryStore, upTo milliseconds: Int) async -> Bool {
        for _ in 0..<(milliseconds / 10) {
            if await store.clears >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await store.clears >= 1
    }

    func testLoadInFlightDoesNotResurrectClearedFacts() async throws {
        let store = SpyLongTermMemoryStore()
        await store.seed([fact("A", .other, at: 1)])
        let loadGate = ConversationTestGate()
        await store.setLoadGate(loadGate)
        addTeardownBlock { await loadGate.open() }   // 途中で失敗しても読み込みを解放し、タスクを残さない
        let manager = LongTermMemoryManager(store: store, consolidate: { $0 })
        // 1. 初回の読み込みが store から戻る前で止まる（読み取り自体は済んでいる）。
        let reading = Task { await manager.renderedBlock() }
        await loadGate.waitUntilEntered()
        // 2. その間に clear を要求する。読み込みを待たずに clear が完了するか、読み込みの完了まで待つかを store の完了イベントで観測する。
        let clearing = Task { try await manager.clear() }
        let clearedWhileLoadPending = await waitForClear(on: store, upTo: 300)
        // 3. 止めていた読み込みを戻す。どちらの順序でも、削除後の一覧が古い読み込み結果で上書きされてはいけない。
        await loadGate.open()
        _ = await reading.value
        try await clearing.value
        let afterClear = try await manager.facts()
        XCTAssertTrue(afterClear.isEmpty, "読み込み保留中に clear 完了=\(clearedWhileLoadPending)。古い読み込み結果で削除後の cache を上書きしない")
        _ = try await manager.remember("B", category: .other)
        let saved = await store.saved
        XCTAssertEqual(saved.last?.map(\.text), ["B"], "読み込み保留中に clear 完了=\(clearedWhileLoadPending)。削除した事実が次の保存で復活しない")
        let clears = await store.clears
        XCTAssertEqual(clears, 1)
    }
}

/// テスト用の記録付きストア。製品側の InMemoryLongTermMemoryStore とは別物。
actor SpyLongTermMemoryStore: LongTermMemoryStore {
    private var facts: [LongTermFact] = []
    private(set) var saved: [[LongTermFact]] = []
    private(set) var clears = 0
    private var failsLoad = false
    private var failsSave = false
    private var loadGate: ConversationTestGate?
    private var saveGate: ConversationTestGate?
    func seed(_ value: [LongTermFact]) { facts = value }
    func setFailsLoad(_ value: Bool) { failsLoad = value }
    func setFailsSave(_ value: Bool) { failsSave = value }
    func setLoadGate(_ gate: ConversationTestGate) { loadGate = gate }
    func setSaveGate(_ gate: ConversationTestGate) { saveGate = gate }
    /// 読み取りは先に済み、戻りだけが遅れる非同期ストアを模す（戻りが遅れた読み込みが、その間の削除を追い越さないことを試す）。
    func load() async throws -> [LongTermFact] {
        let value = facts
        if let loadGate { await loadGate.wait() }
        if failsLoad { throw ConversationMemoryError.readFailed }
        return value
    }
    func save(_ value: [LongTermFact]) async throws {
        if let saveGate { await saveGate.wait() }
        if failsSave { throw ConversationMemoryError.writeFailed }
        facts = value
        saved.append(value)
    }
    func clear() { facts = []; clears += 1 }
}
