# Independent Memory Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build transactional local memory and four Foundation Models tools without LiteRT or reply-session integration.

**Architecture:** An actor-backed store commits an atomic JSON snapshot, while a separate actor owns per-turn staged mutations, search authorization, and result allowances. Four Foundation Models tools share one actor-backed call budget; current date/time uses an injected read-only provider.

**Tech Stack:** Swift 6.0 strict concurrency, Foundation, FoundationModels `Tool`, iOS 26 deployment target, Xcode 27 beta 5, XCTest, Ruby xcodeproj 1.27.0.

**Spec:** `docs/superpowers/specs/2026-08-24-gemma4-independent-tools-design.md`

## Global Constraints

- Work only in `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-independent-tools` on `feature/gemma4-independent-tools`.
- Do not add LiteRT-LM, Gemma factories/services, `LanguageModelSession` composition, UI, speech, lifecycle integration, live inference, vision, calibration, or acceptance code.
- Do not expose the tools to `FoundationModelAddressClassifier`, `FoundationModelReplyService`, or any compaction session.
- Normalize user text, fact text, query text, and supporting quotes with `precomposedStringWithCanonicalMapping`.
- Four tools share one 12-call budget. Calls 1-12 execute; call 13 throws before semantic validation/body execution. Repeated and semantically rejected decoded calls count.
- Search exposes at most eight results and at most 1,024 UTF-8 bytes per turn, shared across repeated searches.
- Remember/forget require a nonempty exact supporting-quote substring from the current normalized user text. Forget accepts only IDs returned by search in the current turn.
- Persist facts only after explicit commit; rollback and persistence failure leave committed state unchanged.
- Use `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild` and device `00008140-000610311A90801C` for targeted XCTest; do not change global `xcode-select`.
- The nine baseline `SpeechAudioConverterTests` crashes are out of scope; all new and targeted tests must have zero failures.
- Do not push, pull, fetch, create a PR, merge, rebase, cherry-pick, or alter another worktree/branch.

---

### Task 1: Add atomic memory persistence and turn transactions

**Files:**
- Create: `CatRobot/Conversation/Memory/MemoryFact.swift`
- Create: `CatRobot/Conversation/Memory/LocalMemoryStore.swift`
- Create: `CatRobot/Conversation/Memory/MemoryToolContext.swift`
- Create: `CatRobotTests/Conversation/Memory/LocalMemoryStoreTests.swift`
- Create: `CatRobotTests/Conversation/Memory/MemoryToolContextTests.swift`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Foundation `UUID`, `Date`, `Codable`, `FileManager`, and a `MemoryPersisting` boundary.
- Produces: `MemoryFact`, `MemoryNotice`, `LocalMemoryStore`, and `MemoryToolContext` with the signatures in the design spec.

- [ ] **Step 1: Write failing store tests**

Create real-temporary-directory tests with literal facts that cover missing-file startup, restart reload, deterministic encoded ordering, committed-state stability after injected save failure, and production persistence metadata.

```swift
func testRestartReloadsOnlySuccessfullyCommittedFacts() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memories.json")
    let firstFact = MemoryFact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        fact: "青が好き",
        supportingQuote: "青が好き",
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 10),
        sourceTurnID: 1
    )
    let first = try LocalMemoryStore(fileURL: url)
    try await first.replaceCommittedFacts([firstFact])

    let restarted = try LocalMemoryStore(fileURL: url)

    XCTAssertEqual(await restarted.committedFacts(), [firstFact])
}
```

- [ ] **Step 2: Run store tests and verify RED**

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotMemoryStoreRed -only-testing:CatRobotTests/LocalMemoryStoreTests
```

Expected: compilation fails because the memory types do not exist.

- [ ] **Step 3: Implement `MemoryFact` and atomic persistence**

Use these public-to-module contracts and keep persistence details internal:

```swift
struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fact: String
    var supportingQuote: String
    let createdAt: Date
    var updatedAt: Date
    var sourceTurnID: UInt64
}

struct MemorySearchResult: Codable, Equatable, Sendable {
    let id: String
    let fact: String
}

protocol MemoryPersisting: Sendable {
    func load() throws -> [MemoryFact]
    func save(_ facts: [MemoryFact]) throws
}

struct AtomicJSONMemoryPersistence: MemoryPersisting {
    init(fileURL: URL)
    func load() throws -> [MemoryFact]
    func save(_ facts: [MemoryFact]) throws
}

actor LocalMemoryStore {
    init(fileURL: URL) throws
    init(persistence: any MemoryPersisting) throws
    static func applicationSupport() throws -> LocalMemoryStore
    func committedFacts() -> [MemoryFact]
    func replaceCommittedFacts(_ facts: [MemoryFact]) throws
}
```

Encode sorted by lowercase UUID for stable bytes. Save to a temporary sibling, mark complete file protection and backup exclusion, replace atomically, and update the actor cache only after `save` succeeds. `applicationSupport()` resolves `<Application Support>/CatRobot/memories.json` and creates its parent directory.

- [ ] **Step 4: Write failing transaction tests**

Cover canonical quote validation, duplicate update, deterministic exact-before-substring search, empty-query ordering, shared 8-result/1,024-byte allowance, current-turn staged visibility, search-authorized deletion, stale/unknown deletion rejection, more than four staged mutations, commit, rollback, and persistence-failure rollback.

```swift
func testForgetRejectsIDNotReturnedByCurrentTurnSearchWithoutPartialMutation() async throws {
    let firstFact = MemoryFact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        fact: "青が好き",
        supportingQuote: "青が好き",
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 20),
        sourceTurnID: 1
    )
    let secondFact = MemoryFact(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        fact: "朝は紅茶を飲む",
        supportingQuote: "朝は紅茶を飲む",
        createdAt: Date(timeIntervalSince1970: 10),
        updatedAt: Date(timeIntervalSince1970: 10),
        sourceTurnID: 2
    )
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = try LocalMemoryStore(fileURL: fileURL)
    try await store.replaceCommittedFacts([firstFact, secondFact])
    let context = MemoryToolContext(
        store: store,
        now: { Date(timeIntervalSince1970: 30) },
        makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000003")! }
    )
    await context.beginTurn(id: 9, userText: "青が好きだったことは忘れて")

    let result = await context.stageForget(
        memoryIDs: [firstFact.id, secondFact.id],
        supportingQuote: "青が好きだったことは忘れて"
    )

    XCTAssertEqual(result, "Forget rejected: search for every memory ID in this turn first.")
    XCTAssertEqual(await context.search(query: "", limit: 8), [firstFact, secondFact])
}
```

- [ ] **Step 5: Run transaction tests and verify RED**

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotMemoryContextRed -only-testing:CatRobotTests/MemoryToolContextTests
```

Expected: compilation fails because `MemoryToolContext` and `MemoryNotice` do not exist.

- [ ] **Step 6: Implement the minimal transaction actor**

```swift
enum MemoryNotice: Equatable, Sendable {
    case remembered(String)
    case forgotten(String)
}

actor MemoryToolContext {
    init(
        store: LocalMemoryStore,
        now: @escaping @Sendable () -> Date = { .now },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    )
    func beginTurn(id: UInt64, userText: String) async
    func search(query: String, limit: Int) async -> [MemoryFact]
    func stageRemember(fact: String, supportingQuote: String) async -> String
    func stageForget(memoryIDs: [UUID], supportingQuote: String) async -> String
    func commitTurn() async throws -> [MemoryNotice]
    func rollbackTurn() async
}
```

Validate every multi-ID forget before removing any candidate. Preserve the previous committed snapshot until store replacement succeeds. Use the exact success/rejection strings from the design spec. `search` builds `MemorySearchResult` prefixes and encodes them with sorted keys to apply the shared eight-result/1,024-byte allowance to the same representation returned by `SearchMemoryTool`. Do not log facts or quotes.

- [ ] **Step 7: Run the Task 1 validation bundle**

```bash
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotMemoryTaskGreen -only-testing:CatRobotTests/LocalMemoryStoreTests -only-testing:CatRobotTests/MemoryToolContextTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination generic/platform=iOS -derivedDataPath /tmp/CatRobotMemoryTaskBuild CODE_SIGNING_ALLOWED=NO
```

Expected: generator contract passes, both test classes pass with zero failures, and build exits 0.

- [ ] **Step 8: Commit**

```bash
git add CatRobot/Conversation/Memory CatRobotTests/Conversation/Memory CatRobot.xcodeproj
git commit -m "feat: add transactional local memory"
```

---

### Task 2: Add the shared call budget and read-only date/time tool

**Files:**
- Create: `CatRobot/Conversation/Tools/ReplyToolCallBudget.swift`
- Create: `CatRobot/Conversation/Tools/CurrentDateTimeTool.swift`
- Create: `CatRobotTests/Conversation/Tools/ReplyToolCallBudgetTests.swift`
- Create: `CatRobotTests/Conversation/Tools/CurrentDateTimeToolTests.swift`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: FoundationModels `Tool`, `@Generable`, Foundation date/calendar/timezone and JSON encoding.
- Produces: `ReplyToolCallBudget`, `ReplyToolCallLimitExceeded`, `CurrentDateTimeSnapshot`, `CurrentDateTimeProviding`, `LiveCurrentDateTimeProvider`, `CurrentDateTimeArguments`, and `CurrentDateTimeTool`.

- [ ] **Step 1: Write failing budget tests**

Test arbitrary sequential and concurrent consumption through 12 calls, the dedicated 13th-call error, same-turn `beginTurn` preserving the count, and a distinct turn resetting it.

```swift
func testThirteenthCallThrowsAndNewTurnResets() async throws {
    let budget = ReplyToolCallBudget()
    await budget.beginTurn(id: 41)
    for _ in 0..<12 { try await budget.consumeCall() }

    do {
        try await budget.consumeCall()
        XCTFail("Expected the thirteenth call to throw")
    } catch {
        XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
    }

    await budget.beginTurn(id: 42)
    try await budget.consumeCall()
}
```

- [ ] **Step 2: Run budget tests and verify RED**

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotToolBudgetRed -only-testing:CatRobotTests/ReplyToolCallBudgetTests
```

Expected: compilation fails because the budget types do not exist.

- [ ] **Step 3: Implement the budget actor**

```swift
struct ReplyToolCallLimitExceeded: Error, Equatable, Sendable {}

actor ReplyToolCallBudget {
    static let maximumCallsPerTurn = 12
    func beginTurn(id: UInt64)
    func consumeCall() throws
}
```

If `beginTurn` receives the current turn ID, keep the existing count. Serialize concurrent consumers through the actor so exactly twelve succeed.

- [ ] **Step 4: Write failing date/time tests**

Use literal fixed/sequenced providers. Verify the exact Monday snapshot for `2026-08-24T12:34:56+09:00`, seconds/no-seconds output, sorted-key JSON decoding, one provider read per repeated call, and shared budget consumption.

```swift
private final class SequencedCurrentDateTimeProvider: CurrentDateTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CurrentDateTimeSnapshot]
    private var storedReadCount = 0

    init(_ snapshots: [CurrentDateTimeSnapshot]) {
        self.snapshots = snapshots
    }

    var readCount: Int { lock.withLock { storedReadCount } }

    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot {
        lock.withLock {
            storedReadCount += 1
            return snapshots.removeFirst()
        }
    }
}

func testRepeatedCallsReadFreshSnapshotsAndShareBudget() async throws {
    let firstSnapshot = CurrentDateTimeSnapshot(
        iso8601: "2026-08-24T12:34:56+09:00",
        localDate: "2026-08-24",
        localTime: "12:34:56",
        isoWeekday: 1,
        timeZoneIdentifier: "Asia/Tokyo",
        utcOffsetSeconds: 32_400
    )
    let secondSnapshot = CurrentDateTimeSnapshot(
        iso8601: "2026-08-24T12:34:57+09:00",
        localDate: "2026-08-24",
        localTime: "12:34:57",
        isoWeekday: 1,
        timeZoneIdentifier: "Asia/Tokyo",
        utcOffsetSeconds: 32_400
    )
    let provider = SequencedCurrentDateTimeProvider([
        firstSnapshot,
        secondSnapshot,
    ])
    let budget = ReplyToolCallBudget()
    await budget.beginTurn(id: 7)
    let tool = CurrentDateTimeTool(provider: provider, budget: budget)

    let first = try await tool.call(arguments: .init(includeSeconds: true))
    let second = try await tool.call(arguments: .init(includeSeconds: true))

    let decoder = JSONDecoder()
    XCTAssertEqual(
        try decoder.decode(CurrentDateTimeSnapshot.self, from: Data(first.utf8)),
        firstSnapshot
    )
    XCTAssertEqual(
        try decoder.decode(CurrentDateTimeSnapshot.self, from: Data(second.utf8)),
        secondSnapshot
    )
    XCTAssertEqual(provider.readCount, 2)
}
```

- [ ] **Step 5: Run date/time tests and verify RED**

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotDateTimeRed -only-testing:CatRobotTests/CurrentDateTimeToolTests
```

Expected: compilation fails because the date/time types do not exist.

- [ ] **Step 6: Implement the provider and Foundation Models tool**

```swift
struct CurrentDateTimeSnapshot: Codable, Equatable, Sendable {
    let iso8601: String
    let localDate: String
    let localTime: String
    let isoWeekday: Int
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
}

protocol CurrentDateTimeProviding: Sendable {
    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot
}

struct LiveCurrentDateTimeProvider: CurrentDateTimeProviding {
    init(
        now: @escaping @Sendable () -> Date = { .now },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    )
    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot
}

@Generable
struct CurrentDateTimeArguments {
    var includeSeconds: Bool
}

struct CurrentDateTimeTool: Tool {
    let name = "getCurrentDateTime"
    let description: String
    func call(arguments: CurrentDateTimeArguments) async throws -> String
}
```

Call the budget first, call the provider every time, and encode the snapshot with `JSONEncoder.outputFormatting = [.sortedKeys]`. The live provider constructs fresh POSIX formatters per call and performs no side effects.

- [ ] **Step 7: Run the Task 2 validation bundle**

```bash
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotDateTimeTaskGreen -only-testing:CatRobotTests/ReplyToolCallBudgetTests -only-testing:CatRobotTests/CurrentDateTimeToolTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination generic/platform=iOS -derivedDataPath /tmp/CatRobotDateTimeTaskBuild CODE_SIGNING_ALLOWED=NO
```

Expected: generator contract passes, both test classes pass with zero failures, and build exits 0.

- [ ] **Step 8: Commit**

```bash
git add CatRobot/Conversation/Tools CatRobotTests/Conversation/Tools CatRobot.xcodeproj
git commit -m "feat: add shared tool budget and date time"
```

---

### Task 3: Add Foundation Models memory tools

**Files:**
- Create: `CatRobot/Conversation/Memory/RememberMemoryTool.swift`
- Create: `CatRobot/Conversation/Memory/ForgetMemoryTool.swift`
- Create: `CatRobot/Conversation/Memory/SearchMemoryTool.swift`
- Create: `CatRobotTests/Conversation/Memory/MemoryToolTests.swift`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MemoryToolContext`, `ReplyToolCallBudget`, FoundationModels `Tool`, and `@Generable`.
- Produces: `RememberMemoryArguments`, `ForgetMemoryArguments`, `SearchMemoryArguments` and the three named memory tools.

- [ ] **Step 1: Write failing memory-tool tests**

Directly call each tool with generated argument values. Verify exact names, successful remember/search/forget routing, semantic rejection without mutation, invalid UUID rejection, search JSON exposing only `id` and `fact`, repeated call execution, shared arbitrary ordering through call 12, and call 13 preventing the context body from running.

```swift
func testThirteenthMixedToolCallDoesNotExecuteMemoryBody() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let store = try LocalMemoryStore(fileURL: fileURL)
    let context = MemoryToolContext(
        store: store,
        now: { Date(timeIntervalSince1970: 1) },
        makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    )
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
    XCTAssertEqual(await context.search(query: "", limit: 8), [])
}
```

- [ ] **Step 2: Run tool tests and verify RED**

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotMemoryToolsRed -only-testing:CatRobotTests/MemoryToolTests
```

Expected: compilation fails because the argument and tool types do not exist.

- [ ] **Step 3: Implement the three tools**

```swift
@Generable
struct RememberMemoryArguments {
    var fact: String
    var supportingQuote: String
}

@Generable
struct ForgetMemoryArguments {
    var memoryIDs: [String]
    var supportingQuote: String
}

@Generable
struct SearchMemoryArguments {
    var query: String
    var limit: Int
}

struct RememberMemoryTool: Tool {
    init(context: MemoryToolContext, budget: ReplyToolCallBudget)
    func call(arguments: RememberMemoryArguments) async throws -> String
}

struct ForgetMemoryTool: Tool {
    init(context: MemoryToolContext, budget: ReplyToolCallBudget)
    func call(arguments: ForgetMemoryArguments) async throws -> String
}

struct SearchMemoryTool: Tool {
    init(context: MemoryToolContext, budget: ReplyToolCallBudget)
    func call(arguments: SearchMemoryArguments) async throws -> String
}
```

Each tool conforms to `Tool`, has the exact names `rememberMemory`, `forgetMemory`, and `searchMemory`, and returns `String`. Consume the shared budget as the first statement in every `call`. Return the exact semantic-rejection strings from the design spec. Parse all forget UUIDs before calling the context. Map returned facts to `MemorySearchResult` and encode that array with sorted keys, exposing only `id` and `fact`.

- [ ] **Step 4: Run the Task 3 validation bundle**

```bash
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotMemoryToolsGreen -only-testing:CatRobotTests/MemoryToolTests -only-testing:CatRobotTests/MemoryToolContextTests -only-testing:CatRobotTests/ReplyToolCallBudgetTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination generic/platform=iOS -derivedDataPath /tmp/CatRobotMemoryToolsBuild CODE_SIGNING_ALLOWED=NO
```

Expected: generator contract passes, all three targeted test classes pass with zero failures, and build exits 0.

- [ ] **Step 5: Commit**

```bash
git add CatRobot/Conversation/Memory CatRobotTests/Conversation/Memory CatRobot.xcodeproj
git commit -m "feat: add Foundation Models memory tools"
```

---

### Task 4: Validate the independent foundation as one branch

**Files:**
- Modify: `docs/superpowers/plans/2026-08-24-content-tagging-availability.md`
- Modify: `docs/superpowers/plans/2026-08-24-independent-memory-tools.md`

**Interfaces:**
- Consumes: all production and test interfaces from the preceding tasks.
- Produces: fresh branch-level evidence and checked plan boxes; no new production behavior.

- [ ] **Step 1: Run final generator, targeted suite, baseline-excluding suite, and build**

```bash
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotIndependentToolsFinalTargeted -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests -only-testing:CatRobotTests/FoundationModelAddressClassifierTests -only-testing:CatRobotTests/LocalMemoryStoreTests -only-testing:CatRobotTests/MemoryToolContextTests -only-testing:CatRobotTests/ReplyToolCallBudgetTests -only-testing:CatRobotTests/CurrentDateTimeToolTests -only-testing:CatRobotTests/MemoryToolTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotIndependentToolsFinalRegression -skip-testing:CatRobotTests/SpeechAudioConverterTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination generic/platform=iOS -configuration Debug -derivedDataPath /tmp/CatRobotIndependentToolsFinalBuild CODE_SIGNING_ALLOWED=NO
```

Expected: every command exits 0 and every executed test has zero failures.

- [ ] **Step 2: Confirm forbidden dependencies and integrations are absent**

```bash
rg -n "LiteRT" CatRobot/Conversation/Memory CatRobot/Conversation/Tools CatRobot.xcodeproj/project.pbxproj
rg -n "LanguageModelSession" CatRobot/Conversation/Memory CatRobot/Conversation/Tools
git diff 29958332f4a3b0e5f90bfb45f06effc4d0d79666 -- CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift CatRobot/Conversation/Services/FoundationModelReplyService.swift CatRobot/Conversation/Integration CatRobot/Conversation/UI
```

Expected: the first command has no matches; the diff shows no classifier, reply-service, integration, or UI changes except the intentional availability-service file outside those paths.

- [ ] **Step 3: Check all completed boxes and commit evidence-only plan updates**

```bash
git add docs/superpowers/plans/2026-08-24-content-tagging-availability.md docs/superpowers/plans/2026-08-24-independent-memory-tools.md
git commit -m "docs: record independent tools validation"
```

- [ ] **Step 4: Confirm the worktree is clean**

```bash
git status --short --branch
```

Expected: branch header only, with no modified or untracked paths.
