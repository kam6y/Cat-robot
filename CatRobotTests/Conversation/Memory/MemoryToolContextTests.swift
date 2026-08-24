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

    func resumeSaves() {
        lock.withLock { shouldFailSave = false }
    }
}

private final class BlockingMemoryPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFacts: [MemoryFact]
    private let saveStarted = DispatchSemaphore(value: 0)
    private let allowSave = DispatchSemaphore(value: 0)

    init(facts: [MemoryFact] = []) {
        storedFacts = facts
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { storedFacts }
    }

    func save(_ facts: [MemoryFact]) throws {
        saveStarted.signal()
        _ = allowSave.wait(timeout: .now() + 5)
        lock.withLock { storedFacts = facts }
    }

    func waitUntilSaveStarts() -> Bool {
        saveStarted.wait(timeout: .now() + 5) == .success
    }

    func allowPendingSave() {
        allowSave.signal()
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

    func testSearchSharesEightResultCapAcrossRepeatedSearches() async throws {
        let facts = (1...9).map { number in
            fact(
                id: String(format: "00000000-0000-0000-0000-%012d", number),
                text: "fact \(number)",
                updatedAt: Double(100 - number)
            )
        }
        let store = try makeStore(facts: facts)
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "")

        let first = await context.search(query: "", limit: 8)
        let second = await context.search(query: "", limit: 8)

        XCTAssertEqual(first.count, 8)
        XCTAssertTrue(second.isEmpty)
    }

    func testSearchShares1024BytePrefixCapAcrossRepeatedSearches() async throws {
        let large = String(repeating: "x", count: 700)
        let facts = (1...2).map { number in
            fact(
                id: String(format: "00000000-0000-0000-0000-%012d", number),
                text: "\(large)\(number)",
                updatedAt: Double(100 - number)
            )
        }
        let store = try makeStore(facts: facts)
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "")

        let first = await context.search(query: "", limit: 8)
        let second = await context.search(query: "", limit: 8)

        XCTAssertEqual(first.count, 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(
            first.map { MemorySearchResult(id: $0.id.uuidString.lowercased(), fact: $0.fact) }
        )
        XCTAssertLessThanOrEqual(encoded.count, 1_024)
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

    func testForgetRejectsAnUnknownUUIDWithoutMutation() async throws {
        let memory = fact(id: "00000000-0000-0000-0000-000000000001", text: "青が好き", updatedAt: 10)
        let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let store = try makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "青が好きだったことは忘れて")

        let result = await context.stageForget(
            memoryIDs: [unknownID],
            supportingQuote: "青が好きだったことは忘れて"
        )
        let matches = await context.search(query: "", limit: 8)

        XCTAssertEqual(result, "Forget rejected: search for every memory ID in this turn first.")
        XCTAssertEqual(matches, [memory])
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

    func testCommitSaveFailureRollsBackCandidateAndClearsStaleNotices() async throws {
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
        let visibleAfterFailure = await context.search(query: "", limit: 8)
        persistence.resumeSaves()
        let laterNotices = try await context.commitTurn()

        XCTAssertEqual(committed, [original])
        XCTAssertEqual(visibleAfterFailure, [original])
        XCTAssertTrue(laterNotices.isEmpty)
    }

    func testCanonicallyEquivalentStoredFactIsNormalizedAndUpdatedWithoutDuplication() async throws {
        let decomposedFact = "cafe\u{301}が好き"
        let existing = MemoryFact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            fact: decomposedFact,
            supportingQuote: decomposedFact,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            sourceTurnID: 1
        )
        let store = try makeStore(facts: [existing])
        let context = makeContext(store: store, now: 30)
        await context.beginTurn(id: 2, userText: "caféが好き")

        let result = await context.stageRemember(fact: "caféが好き", supportingQuote: "caféが好き")
        let matches = await context.search(query: "café", limit: 8)
        _ = try await context.commitTurn()
        let committed = await store.committedFacts()

        XCTAssertEqual(result, "Remember staged: caféが好き")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.fact, "caféが好き")
        XCTAssertEqual(matches.first?.supportingQuote, "caféが好き")
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.fact, "caféが好き")
        XCTAssertEqual(committed.first?.supportingQuote, "caféが好き")
        XCTAssertEqual(
            committed.first?.fact.unicodeScalars.map(\.value),
            "caféが好き".unicodeScalars.map(\.value)
        )
        XCTAssertEqual(
            committed.first?.supportingQuote.unicodeScalars.map(\.value),
            "caféが好き".unicodeScalars.map(\.value)
        )
    }

    func testQueuedMutationCannotDivergeContextFromBlockedCommit() async throws {
        let persistence = BlockingMemoryPersistence()
        let store = try LocalMemoryStore(persistence: persistence)
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "first second")
        _ = await context.stageRemember(fact: "first", supportingQuote: "first")

        let commitTask = Task { try await context.commitTurn() }
        XCTAssertTrue(persistence.waitUntilSaveStarts())
        let mutationStarted = DispatchSemaphore(value: 0)
        let queuedMutation = Task {
            mutationStarted.signal()
            return await context.stageRemember(fact: "second", supportingQuote: "second")
        }
        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 5), .success)
        await Task.yield()
        persistence.allowPendingSave()

        let notices = try await commitTask.value
        let mutationResult = await queuedMutation.value
        let committed = await store.committedFacts()
        await context.beginTurn(id: 2, userText: "")
        let visible = await context.search(query: "", limit: 8)

        XCTAssertEqual(notices, [.remembered("first")])
        XCTAssertEqual(mutationResult, "Remember rejected: supporting quote must match the current user text.")
        XCTAssertEqual(committed.map(\.fact), ["first"])
        XCTAssertEqual(visible.map(\.fact), ["first"])
    }

    func testQueuedRollbackCannotDivergeContextFromBlockedCommit() async throws {
        let persistence = BlockingMemoryPersistence()
        let store = try LocalMemoryStore(persistence: persistence)
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "first")
        _ = await context.stageRemember(fact: "first", supportingQuote: "first")

        let commitTask = Task { try await context.commitTurn() }
        XCTAssertTrue(persistence.waitUntilSaveStarts())
        let rollbackStarted = DispatchSemaphore(value: 0)
        let rollbackTask = Task {
            rollbackStarted.signal()
            await context.rollbackTurn()
        }
        XCTAssertEqual(rollbackStarted.wait(timeout: .now() + 5), .success)
        await Task.yield()
        persistence.allowPendingSave()

        let notices = try await commitTask.value
        await rollbackTask.value
        let committed = await store.committedFacts()
        let visible = await context.search(query: "", limit: 8)

        XCTAssertEqual(notices, [.remembered("first")])
        XCTAssertEqual(committed.map(\.fact), ["first"])
        XCTAssertEqual(visible.map(\.fact), ["first"])
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
