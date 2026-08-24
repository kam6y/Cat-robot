import Foundation
import XCTest
@testable import CatRobot

private final class MemoryToolTestPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [MemoryFact]

    init(facts: [MemoryFact]) {
        self.facts = facts
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { facts }
    }

    func save(_ facts: [MemoryFact]) throws {
        lock.withLock { self.facts = facts }
    }
}

private final class MemoryToolTestDateTimeProvider: CurrentDateTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadCount = 0

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot {
        lock.withLock { storedReadCount += 1 }
        return CurrentDateTimeSnapshot(
            iso8601: "2026-08-24T12:34:56+09:00",
            localDate: "2026-08-24",
            localTime: "12:34:56",
            isoWeekday: 1,
            timeZoneIdentifier: "Asia/Tokyo",
            utcOffsetSeconds: 32_400
        )
    }
}

final class MemoryToolTests: XCTestCase {
    func testToolsExposeSpecifiedIdentitiesAndRouteRememberSearchAndForget() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 1, userText: "猫が好きだから覚えて、必要なら忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 1)
        let remember = RememberMemoryTool(context: context, budget: budget)
        let search = SearchMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)

        XCTAssertEqual(remember.name, "rememberMemory")
        XCTAssertEqual(
            remember.description,
            "Stage one concise, user-provided fact that will be useful in future conversations. The supporting quote must be copied exactly from the current user message."
        )
        XCTAssertEqual(forget.name, "forgetMemory")
        XCTAssertEqual(
            forget.description,
            "Stage deletion of specific memory IDs returned by searchMemory in this user turn. The supporting quote must be copied exactly from the current user message."
        )
        XCTAssertEqual(search.name, "searchMemory")
        XCTAssertEqual(
            search.description,
            "Search local committed and current-turn staged memories. Returns only memory IDs and fact text."
        )

        let remembered = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
        XCTAssertEqual(remembered, "Remember staged: 猫が好き")
        let output = try await search.call(arguments: .init(query: "猫", limit: 8))
        let results = try JSONDecoder().decode([MemorySearchResult].self, from: Data(output.utf8))
        XCTAssertEqual(results.map(\.fact), ["猫が好き"])
        let memoryID = try XCTUnwrap(results.first?.id)
        let forgotten = try await forget.call(arguments: .init(memoryIDs: [memoryID], supportingQuote: "忘れて"))
        XCTAssertEqual(forgotten, "Forget staged: 1 memory item(s).")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [])
    }

    func testRememberSemanticRejectionsDoNotMutateMemory() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 2, userText: "猫が好き")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 2)
        let tool = RememberMemoryTool(context: context, budget: budget)

        let empty = try await tool.call(arguments: .init(fact: "", supportingQuote: "猫が好き"))
        let mismatched = try await tool.call(arguments: .init(fact: "犬が好き", supportingQuote: "犬が好き"))

        XCTAssertEqual(empty, "Remember rejected: fact and supporting quote are required.")
        XCTAssertEqual(mismatched, "Remember rejected: supporting quote must match the current user text.")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [])
    }

    func testForgetSemanticRejectionsDoNotMutateMemory() async throws {
        let memory = makeFact(id: "00000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 3, userText: "猫を忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 3)
        let tool = ForgetMemoryTool(context: context, budget: budget)

        let empty = try await tool.call(arguments: .init(memoryIDs: [], supportingQuote: "猫を忘れて"))
        let badQuote = try await tool.call(
            arguments: .init(memoryIDs: [memory.id.uuidString], supportingQuote: "犬を忘れて")
        )
        let unsearched = try await tool.call(
            arguments: .init(memoryIDs: [memory.id.uuidString], supportingQuote: "猫を忘れて")
        )

        XCTAssertEqual(empty, "Forget rejected: provide at least one memory ID.")
        XCTAssertEqual(badQuote, "Forget rejected: supporting quote must match the current user text.")
        XCTAssertEqual(unsearched, "Forget rejected: search for every memory ID in this turn first.")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [memory])
    }

    func testForgetRejectsAnyInvalidUUIDBeforeContextMutation() async throws {
        let memory = makeFact(id: "00000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 4, userText: "猫を忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 4)
        let search = SearchMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)

        _ = try await search.call(arguments: .init(query: "猫", limit: 8))
        let result = try await forget.call(
            arguments: .init(
                memoryIDs: [memory.id.uuidString, "not-a-uuid"],
                supportingQuote: "猫を忘れて"
            )
        )

        XCTAssertEqual(result, "Forget rejected: every memory ID must be a UUID.")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [memory])
    }

    func testForgetAcceptsUppercaseUUIDReturnedBySearch() async throws {
        let memory = makeFact(id: "A0000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 41, userText: "猫を忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 41)
        let search = SearchMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)

        _ = try await search.call(arguments: .init(query: "猫", limit: 8))
        let result = try await forget.call(
            arguments: .init(memoryIDs: [memory.id.uuidString.uppercased()], supportingQuote: "猫を忘れて")
        )

        XCTAssertEqual(result, "Forget staged: 1 memory item(s).")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [])
    }

    func testForgetRejectsLimitedOutAndPriorTurnSearchIDsWithoutMutation() async throws {
        let first = makeFact(id: "00000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let second = makeFact(id: "00000000-0000-0000-0000-000000000002", fact: "犬が好き")
        let store = try await makeStore(facts: [first, second])
        let context = makeContext(store: store)
        let budget = ReplyToolCallBudget()
        let search = SearchMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)
        await context.beginTurn(id: 42, userText: "忘れて")
        await budget.beginTurn(id: 42)

        _ = try await search.call(arguments: .init(query: "", limit: 1))
        let limitedOut = try await forget.call(
            arguments: .init(memoryIDs: [second.id.uuidString], supportingQuote: "忘れて")
        )
        await context.beginTurn(id: 43, userText: "忘れて")
        await budget.beginTurn(id: 43)
        let priorTurn = try await forget.call(
            arguments: .init(memoryIDs: [first.id.uuidString], supportingQuote: "忘れて")
        )

        XCTAssertEqual(limitedOut, "Forget rejected: search for every memory ID in this turn first.")
        XCTAssertEqual(priorTurn, "Forget rejected: search for every memory ID in this turn first.")
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [first, second])
    }

    func testSearchRejectsNonpositiveLimitWithoutExposingMemory() async throws {
        let memory = makeFact(id: "00000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 5, userText: "猫")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 5)
        let tool = SearchMemoryTool(context: context, budget: budget)

        let zero = try await tool.call(arguments: .init(query: "猫", limit: 0))
        let negative = try await tool.call(arguments: .init(query: "猫", limit: -1))
        let stageForget = await context.stageForget(memoryIDs: [memory.id], supportingQuote: "猫")
        XCTAssertEqual(zero, "Search rejected: limit must be positive.")
        XCTAssertEqual(negative, "Search rejected: limit must be positive.")
        XCTAssertEqual(stageForget, "Forget rejected: search for every memory ID in this turn first.")
    }

    func testSearchReturnsSortedJSONContainingOnlyLowercaseIDAndFact() async throws {
        let memory = makeFact(id: "A0000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 6, userText: "猫")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 6)
        let tool = SearchMemoryTool(context: context, budget: budget)

        let output = try await tool.call(arguments: .init(query: "猫", limit: 8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(output, #"[{"fact":"猫が好き","id":"a0000000-0000-0000-0000-000000000001"}]"#)
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(object.first).keys), ["id", "fact"])
        XCTAssertEqual(object.first?["id"] as? String, "a0000000-0000-0000-0000-000000000001")
        XCTAssertEqual(object.first?["fact"] as? String, "猫が好き")
    }

    func testSearchEscapesHostileFactJSONWithOnlySortedDTOKeysAndPreservesOrder() async throws {
        let first = makeFact(
            id: "00000000-0000-0000-0000-000000000001",
            fact: "first \"quote\" \\ slash\nline"
        )
        let second = makeFact(
            id: "00000000-0000-0000-0000-000000000002",
            fact: "second <tag> & text"
        )
        let store = try await makeStore(facts: [first, second])
        let context = makeContext(store: store)
        await context.beginTurn(id: 61, userText: "")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 61)
        let tool = SearchMemoryTool(context: context, budget: budget)

        let output = try await tool.call(arguments: .init(query: "", limit: 8))
        let objects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )

        XCTAssertTrue(output.hasPrefix("[{\"fact\":"))
        XCTAssertEqual(objects.map { $0["fact"] as? String }, [first.fact, second.fact])
        XCTAssertEqual(
            objects.map { $0["id"] as? String },
            [first.id.uuidString.lowercased(), second.id.uuidString.lowercased()]
        )
        XCTAssertTrue(objects.allSatisfy { Set($0.keys) == ["id", "fact"] })
        XCTAssertFalse(output.contains("supportingQuote"))
        XCTAssertFalse(output.contains("createdAt"))
        XCTAssertFalse(output.contains("updatedAt"))
        XCTAssertFalse(output.contains("sourceTurnID"))
    }

    func testRepeatedIdenticalCallsExecuteAndConsumeTheSharedBudget() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 7, userText: "猫が好き")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 7)
        let tool = RememberMemoryTool(context: context, budget: budget)

        for _ in 0..<12 {
            let result = try await tool.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
            XCTAssertEqual(result, "Remember staged: 猫が好き")
        }
        _ = try await context.commitTurn()
        let committed = await store.committedFacts()
        XCTAssertEqual(committed.map(\.fact), ["猫が好き"])
        do {
            _ = try await tool.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }
    }

    func testMixedToolsExecuteInArbitraryOrderingThroughCallTwelve() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 8, userText: "猫が好きだから忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 8)
        let remember = RememberMemoryTool(context: context, budget: budget)
        let search = SearchMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)

        _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
        let firstSearch = try await search.call(arguments: .init(query: "猫", limit: 1))
        let memoryID = try XCTUnwrap(try JSONDecoder().decode([MemorySearchResult].self, from: Data(firstSearch.utf8)).first?.id)
        _ = try await forget.call(arguments: .init(memoryIDs: [memoryID], supportingQuote: "忘れて"))
        _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
        for _ in 0..<8 {
            _ = try await search.call(arguments: .init(query: "猫", limit: 1))
        }

        _ = try await context.commitTurn()
        let committed = await store.committedFacts()
        XCTAssertEqual(committed.map(\.fact), ["猫が好き"])
    }

    func testSemanticRejectionsCountThroughMixedCallTwelveWithoutConsumingSearchAllowance() async throws {
        let memory = makeFact(id: "00000000-0000-0000-0000-000000000001", fact: "猫が好き")
        let store = try await makeStore(facts: [memory])
        let context = makeContext(store: store)
        await context.beginTurn(id: 91, userText: "猫")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 91)
        let remember = RememberMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)
        let search = SearchMemoryTool(context: context, budget: budget)

        for _ in 0..<4 {
            let result = try await remember.call(arguments: .init(fact: "", supportingQuote: "猫"))
            XCTAssertEqual(result, "Remember rejected: fact and supporting quote are required.")
        }
        for _ in 0..<4 {
            let result = try await forget.call(arguments: .init(memoryIDs: ["invalid"], supportingQuote: "猫"))
            XCTAssertEqual(result, "Forget rejected: every memory ID must be a UUID.")
        }
        for _ in 0..<3 {
            let result = try await search.call(arguments: .init(query: "猫", limit: 0))
            XCTAssertEqual(result, "Search rejected: limit must be positive.")
        }

        let twelfth = try await search.call(arguments: .init(query: "猫", limit: 8))
        XCTAssertEqual(
            try JSONDecoder().decode([MemorySearchResult].self, from: Data(twelfth.utf8)).map(\.fact),
            ["猫が好き"]
        )
        do {
            _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫"))
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [memory])
    }

    func testThirteenthMixedToolCallDoesNotExecuteMemoryBody() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 11, userText: "猫が好き")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 11)
        let search = SearchMemoryTool(context: context, budget: budget)
        let remember = RememberMemoryTool(context: context, budget: budget)

        for _ in 0..<12 {
            _ = try await search.call(arguments: .init(query: "", limit: 1))
        }

        do {
            _ = try await remember.call(
                arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き")
            )
            XCTFail("Expected the thirteenth mixed call to throw")
        } catch {
            XCTAssertTrue(error is ReplyToolCallLimitExceeded)
        }
        let visible = await context.search(query: "", limit: 8)
        XCTAssertEqual(visible, [])
    }

    func testAllFourToolsShareOneBudgetAndThirteenthCallDoesNotReadProvider() async throws {
        let store = try await makeStore()
        let context = makeContext(store: store)
        await context.beginTurn(id: 101, userText: "猫が好きだから忘れて")
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 101)
        let provider = MemoryToolTestDateTimeProvider()
        let remember = RememberMemoryTool(context: context, budget: budget)
        let forget = ForgetMemoryTool(context: context, budget: budget)
        let search = SearchMemoryTool(context: context, budget: budget)
        let dateTime = CurrentDateTimeTool(provider: provider, budget: budget)

        _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
        let firstSearch = try await search.call(arguments: .init(query: "猫", limit: 1))
        let memoryID = try XCTUnwrap(
            try JSONDecoder().decode([MemorySearchResult].self, from: Data(firstSearch.utf8)).first?.id
        )
        _ = try await dateTime.call(arguments: .init(includeSeconds: true))
        _ = try await forget.call(arguments: .init(memoryIDs: [memoryID], supportingQuote: "忘れて"))
        _ = try await remember.call(arguments: .init(fact: "猫が好き", supportingQuote: "猫が好き"))
        for _ in 0..<4 {
            _ = try await dateTime.call(arguments: .init(includeSeconds: true))
        }
        for _ in 0..<3 {
            _ = try await search.call(arguments: .init(query: "猫", limit: 1))
        }

        XCTAssertEqual(provider.readCount, 5)
        do {
            _ = try await dateTime.call(arguments: .init(includeSeconds: true))
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }
        XCTAssertEqual(provider.readCount, 5)
    }

    private func makeStore(facts: [MemoryFact] = []) async throws -> LocalMemoryStore {
        try LocalMemoryStore(persistence: MemoryToolTestPersistence(facts: facts))
    }

    private func makeContext(store: LocalMemoryStore) -> MemoryToolContext {
        MemoryToolContext(
            store: store,
            now: { Date(timeIntervalSince1970: 1) },
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000099")! }
        )
    }

    private func makeFact(id: String, fact: String) -> MemoryFact {
        MemoryFact(
            id: UUID(uuidString: id)!,
            fact: fact,
            supportingQuote: fact,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sourceTurnID: 1
        )
    }
}
