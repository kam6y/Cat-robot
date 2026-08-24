import Foundation
import XCTest
@testable import CatRobot

private final class MemoryContextFailingPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFacts: [MemoryFact]
    private var shouldFailSave = false

    init(facts: [MemoryFact]) {
        storedFacts = facts
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { storedFacts }
    }

    func save(_ facts: [MemoryFact]) throws {
        try lock.withLock {
            if shouldFailSave {
                throw CocoaError(.fileWriteUnknown)
            }
            storedFacts = facts
        }
    }

    func failFutureSaves() {
        lock.withLock { shouldFailSave = true }
    }
}

final class MemoryToolContextTests: XCTestCase {
    func testRememberAcceptsCanonicallyEquivalentSupportingQuote() async throws {
        let store = try makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "cafe\u{301}が好き")

        let result = await context.stageRemember(fact: "コーヒーが好き", supportingQuote: "café")

        XCTAssertEqual(result, "Remember staged: コーヒーが好き")
    }

    func testRememberUpdatesAnExistingNormalizedFactInsteadOfDuplicatingIt() async throws {
        let existing = fact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き", updatedAt: 10)
        let store = try makeStore(facts: [existing])
        let context = makeContext(store: store, now: 30)
        await context.beginTurn(id: 9, userText: "青が好き")

        let result = await context.stageRemember(fact: "青が好き", supportingQuote: "青が好き")
        let matches = await context.search(query: "青が好き", limit: 8)

        XCTAssertEqual(result, "Remember staged: 青が好き")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.id, existing.id)
        XCTAssertEqual(matches.first?.updatedAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(matches.first?.sourceTurnID, 9)
    }

    func testSearchRanksExactFactBeforeSubstringThenUsesUpdatedAtAndID() async throws {
        let exact = fact(id: "00000000-0000-0000-0000-000000000003", text: "cat", updatedAt: 1)
        let newestSubstring = fact(id: "00000000-0000-0000-0000-000000000002", text: "catalog", updatedAt: 30)
        let oldestSubstring = fact(id: "00000000-0000-0000-0000-000000000001", text: "catnip", updatedAt: 20)
        let store = try makeStore(facts: [oldestSubstring, newestSubstring, exact])
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "cat")

        let matches = await context.search(query: "cat", limit: 8)

        XCTAssertEqual(matches.map(\.id), [exact.id, newestSubstring.id, oldestSubstring.id])
    }

    func testEmptySearchUsesUpdatedAtDescendingThenLowercaseUUIDOrdering() async throws {
        let firstID = fact(id: "00000000-0000-0000-0000-000000000001", text: "first", updatedAt: 20)
        let secondID = fact(id: "00000000-0000-0000-0000-000000000002", text: "second", updatedAt: 20)
        let older = fact(id: "00000000-0000-0000-0000-000000000003", text: "older", updatedAt: 10)
        let store = try makeStore(facts: [older, secondID, firstID])
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "")

        let matches = await context.search(query: "", limit: 8)

        XCTAssertEqual(matches.map(\.id), [firstID.id, secondID.id, older.id])
    }

    func testSearchSharesEightResultAnd1024ByteAllowancesAcrossCalls() async throws {
        let large = String(repeating: "x", count: 700)
        let facts = (1...9).map { number in
            fact(
                id: String(format: "00000000-0000-0000-0000-%012d", number),
                text: number < 3 ? "\(large)\(number)" : "fact \(number)",
                updatedAt: Double(100 - number)
            )
        }
        let store = try makeStore(facts: facts)
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "")

        let first = await context.search(query: "", limit: 8)
        let second = await context.search(query: "", limit: 8)

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
    }

    func testStagedRememberIsVisibleToCurrentTurnSearchBeforeCommit() async throws {
        let store = try makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 2, userText: "猫が好き")
        _ = await context.stageRemember(fact: "猫が好き", supportingQuote: "猫が好き")

        let matches = await context.search(query: "猫", limit: 8)
        let committed = await store.committedFacts()

        XCTAssertEqual(matches.map(\.fact), ["猫が好き"])
        XCTAssertTrue(committed.isEmpty)
    }

    func testForgetRejectsIDNotReturnedByCurrentTurnSearchWithoutPartialMutation() async throws {
        let firstFact = fact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き", updatedAt: 20)
        let secondFact = fact(id: "00000000-0000-0000-0000-000000000002", text: "朝は紅茶を飲む", updatedAt: 10)
        let store = try makeStore(facts: [firstFact, secondFact])
        let context = makeContext(store: store)
        await context.beginTurn(id: 9, userText: "青が好きだったことは忘れて")
        _ = await context.search(query: "青", limit: 8)

        let result = await context.stageForget(
            memoryIDs: [firstFact.id, secondFact.id],
            supportingQuote: "青が好きだったことは忘れて"
        )

        XCTAssertEqual(result, "Forget rejected: search for every memory ID in this turn first.")
        let matches = await context.search(query: "", limit: 8)
        XCTAssertEqual(matches.map(\.id), [firstFact.id, secondFact.id])
    }

    func testForgetRequiresCurrentTurnSearchAuthorizationAndStagesDeletion() async throws {
        let memory = fact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き", updatedAt: 10)
        let store = try makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "青が好きだったことは忘れて")
        _ = await context.search(query: "青", limit: 8)

        let staged = await context.stageForget(
            memoryIDs: [memory.id],
            supportingQuote: "青が好きだったことは忘れて"
        )
        let matches = await context.search(query: "", limit: 8)
        XCTAssertEqual(staged, "Forget staged: 1 memory item(s).")
        XCTAssertTrue(matches.isEmpty)

        await context.beginTurn(id: 2, userText: "青が好きだったことは忘れて")
        let stale = await context.stageForget(
            memoryIDs: [memory.id],
            supportingQuote: "青が好きだったことは忘れて"
        )
        XCTAssertEqual(stale, "Forget rejected: search for every memory ID in this turn first.")
    }

    func testMoreThanFourStagedMutationsCommitTogether() async throws {
        let store = try makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 3, userText: "記憶して")

        for number in 1...5 {
            let result = await context.stageRemember(fact: "fact \(number)", supportingQuote: "記憶して")
            XCTAssertEqual(result, "Remember staged: fact \(number)")
        }
        let notices = try await context.commitTurn()
        let committed = await store.committedFacts()

        let expectedNotices: [MemoryNotice] = (1...5).map { .remembered("fact \($0)") }
        XCTAssertEqual(notices, expectedNotices)
        XCTAssertEqual(committed.map(\.fact).sorted(), (1...5).map { "fact \($0)" })
    }

    func testRollbackDiscardsStagedMutationWithoutPersisting() async throws {
        let store = try makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 4, userText: "猫が好き")
        _ = await context.stageRemember(fact: "猫が好き", supportingQuote: "猫が好き")

        await context.rollbackTurn()

        let committed = await store.committedFacts()
        XCTAssertTrue(committed.isEmpty)
    }

    func testCommitSaveFailureLeavesCommittedSnapshotUnchanged() async throws {
        let original = fact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き", updatedAt: 10)
        let persistence = MemoryContextFailingPersistence(facts: [original])
        let store = try LocalMemoryStore(persistence: persistence)
        let context = makeContext(store: store)
        await context.beginTurn(id: 5, userText: "猫が好き")
        _ = await context.stageRemember(fact: "猫が好き", supportingQuote: "猫が好き")
        persistence.failFutureSaves()

        do {
            _ = try await context.commitTurn()
            XCTFail("Expected persistence failure")
        } catch {}

        let committed = await store.committedFacts()
        XCTAssertEqual(committed, [original])
    }

    private func makeStore(facts: [MemoryFact] = []) throws -> LocalMemoryStore {
        let persistence = MemoryContextFailingPersistence(facts: facts)
        return try LocalMemoryStore(persistence: persistence)
    }

    private func makeContext(store: LocalMemoryStore, now: TimeInterval = 30) -> MemoryToolContext {
        MemoryToolContext(
            store: store,
            now: { Date(timeIntervalSince1970: now) },
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000099")! }
        )
    }

    private func fact(id: String, text: String, updatedAt: TimeInterval) -> MemoryFact {
        MemoryFact(
            id: UUID(uuidString: id)!,
            fact: text,
            supportingQuote: text,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            sourceTurnID: 1
        )
    }
}
