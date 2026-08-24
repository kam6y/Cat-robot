# 通常起動アプリへのReply Tool統合 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 通常起動したsigned iPhone appのtyped/voice replyで4つのtoolを利用可能にし、memory transactionを安全にcommitして通知しつつ、将来のGemma backendをsession factoryの差し替えだけで導入できるようにする。

**Architecture:** Backend非依存のToolEnabledReplyServiceがturn ID、shared tool budget、memory transaction、draft/commit event、rollback、transcript restoreを一元管理する。Apple固有のSystemLanguageModelとLanguageModelSessionはReplySessionFactory / ReplySessionClientの内側だけに置き、Domain、ViewModel、UI、memory、toolはbackendを知らない。

**Tech Stack:** Swift 6、SwiftUI、Observation、FoundationModels、XCTest、Xcode 27 beta、iOS deployment target 26.0、xcodeproj 1.27.0。

**Spec:** docs/superpowers/specs/2026-08-24-live-reply-tools-integration-design.md

## Global Constraints

- 作業対象は /Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-independent-tools の feature/gemma4-independent-tools branchだけとする。
- 実装前に上記spec全文と、前提spec docs/superpowers/specs/2026-08-24-gemma4-independent-tools-design.md を読む。
- 開始基盤は commit c85da4cc640340f60187b289cd5184ae2eacb48f。既存のmemory/tool実装とそのvalidation evidenceをsource of truthとして再利用し、そのvalidation、authorization、normalization、budget logicを複製しない。
- live reply backendはApple SystemLanguageModel(useCase: .general, guardrails: .default)。content-tagging classifierは既存どおり別のtool-free sessionとする。
- Reply sessionへ登録するtoolは rememberMemory、forgetMemory、searchMemory、getCurrentDateTime の厳密な4つだけとし、1つのMemoryToolContextと1つのReplyToolCallBudgetを共有する。
- tool callingはiOS 27 runtimeで明示的に.allowed、temperatureは0.5、maximumResponseTokensは256とする。.requiredは使わない。
- project deployment targetは26.0、Swift language modeは6、strict concurrencyを維持し、Swift PackageやLiteRT/Gemma dependencyを追加しない。
- backend差し替え境界はReplySessionFactory / ReplySessionClientだけとする。SystemLanguageModelとLanguageModelSessionはServices以外へ出さず、Domain、Integration、Memory、Tools、UIはApple/Gemma/LiteRT型を参照しない。
- typed requestはclassifierを通さず、voice requestはspeech recognition → Apple content-tagging classifier → tool-enabled reply → memory commit → speechの順序を維持する。
- draftはcaptionへ表示してよいが、speech、memory notice、durableな成功はReplyTurnCommitの後だけ開始する。
- commit前のstore/session準備失敗、generation/tool decode失敗、13 call目、空reply、cancellation、pause/background/shutdown、persistence失敗では、memory rollbackとturn開始前Transcriptへのrestoreを完了してからstream/lifecycleを終了する。
- ReplyGeneratingは承認済みspecどおりprepare、streamReply、resetの3 methodだけとする。AsyncThrowingStream.onTerminationだけではawaitできないrollback/restoreはconcrete ToolEnabledReplyServiceのfunc cancelActiveReply() asyncをConversationDependencies.replyCleanup closureへcomposeし、Domain contractを拡張せずpause/shutdown側のbarrierにする。
- memory noticeは「記憶しました」「記憶を削除しました」「記憶を更新しました」の3種類だけとし、fact、supporting quote、UUID、search result、tool argument、raw prompt/resultをUI、caption、transcript、production logへ出さない。
- 新しいnoticeは古いnoticeを置換し、古いdismiss taskが新しいnoticeを消さない。noticeはnoninteractive、Dynamic Type対応、reduced transparency対応、accessibility label付きとする。
- 新規Swift fileはscripts/generate_project.rbでのみprojectへ追加し、CatRobot.xcodeproj/project.pbxprojを手編集しない。
- 各implementation taskはred/green TDD、task scope review、code-quality review、指定focused validationを通過してから記載単位でcommitする。Critical/Important findingは同じtask内で修正し再検証する。
- validation evidenceはprivateな会話内容を含めず、docs/validation/2026-08-24-live-reply-tools-integration.mdへcommand、exit status、test count、result bundle、build/install/launch、review結果だけを記録する。
- 自動validationでは確率的なlive inference promptを実行しない。実際の使用感確認は上書きinstall/launch後にuserが行う。
- blocked/comparison worktreeを変更せず、push、PR作成、merge、rebase、cherry-pick、app uninstallを行わない。
- tracked worktreeがcleanになるまで完了を主張しない。

## File Structure

### 新規production files

- CatRobot/Conversation/Domain/ReplyTurn.swift
  - backend非依存のReplyTurnRequest、ReplyMemoryChange、ReplyTurnCommit、ReplyStreamEventだけを定義する。
- CatRobot/Conversation/Services/ReplySession.swift
  - FoundationModelsをimportし、ReplySessionFactory、ReplySessionClient、ReplyGenerationPolicyを定義する。
- CatRobot/Conversation/Services/AppleSystemReplySessionFactory.swift
  - Apple general modelのavailability、instructions、LanguageModelSession生成、snapshot streaming、Transcript restoreだけを担当する。
- CatRobot/Conversation/Services/ToolEnabledReplyService.swift
  - persistent tool runtime、session、single-generation exclusion、turn transaction、commit/rollback、notice集約、cleanup barrierを所有する。
- CatRobot/Conversation/UI/MemoryNoticePresentation.swift
  - privacy-safeな固定copyとnoninteractive accessibility presentation policyだけを定義する。

### 変更production files

- CatRobot/Conversation/Domain/ConversationServices.swift
  - ReplyGeneratingを承認済みturn/event contractへ移行する。
- CatRobot/Conversation/Domain/ConversationTypes.swift
  - recoverableなtoolRuntimeFailed errorを追加する。
- CatRobot/Conversation/Services/FoundationModelReplyService.swift
  - live migration完了時に削除する。Apple model生成を二重に残さない。
- CatRobot/Conversation/Integration/ConversationDependencies.swift
  - Apple factory → ToolEnabledReplyServiceをcomposeし、reply cleanup barrierとnotice dismiss delayを注入可能にする。
- CatRobot/Conversation/Integration/ConversationViewModel.swift
  - typed/voiceのrequest/event consumption、commit後speech、draft cleanup、notice lifecycle、reply cleanup待機を実装する。
- CatRobot/Conversation/Integration/ConversationErrorPresentation.swift
  - toolRuntimeFailedのgeneric recovery copyを追加する。
- CatRobot/Conversation/UI/ConversationViewState.swift
  - optional memoryNoticeをpresentation-only stateとして追加する。
- CatRobot/Conversation/UI/ConversationView.swift
  - compact top overlayを追加する。

### 新規または置換test files

- CatRobotTests/Conversation/Services/AppleSystemReplySessionFactoryTests.swift
- CatRobotTests/Conversation/Services/ToolEnabledReplyServiceTests.swift
- CatRobotTests/Conversation/Services/ReplySessionTestDoubles.swift

### 削除test file

- CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift
  - old service削除に合わせて削除し、上記2 suiteへ置換する。

### 変更test files

- CatRobotTests/Conversation/Integration/ConversationFakes.swift
- CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift
- CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift
- CatRobotTests/Conversation/Integration/AppCompositionTests.swift
- CatRobotTests/Conversation/Integration/ConversationErrorPresentationTests.swift
- CatRobotTests/Conversation/Services/AppleServiceCompositionTests.swift
- CatRobotTests/Conversation/UI/ConversationViewStateTests.swift
- CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift
- CatRobot.xcodeproj/project.pbxproj
  - generator outputだけをcommitする。

### 新規host contract

- scripts/test_live_reply_architecture.rb
  - repository sourceをphysical-device XCTestから読まず、backend boundary、privacy、logging、live compositionをhost上で検証する。

## Validation Budget and Evidence Reuse

- TaskごとのREDはbehavior clusterごとに1回だけ取得する。compile migration中の同一原因の重複REDは再取得しない。
- TaskごとのGREENはそのtaskのfocused suiteを1回通す。失敗した場合は原因を特定してscope内の最小修正後に最大2回まで再実行する。
- 最終hard budgetはgenerator contract 1回、focused device bundle 1回、full device regression 1回、signed device build 1回、上書きinstall 1回、launch 1回とする。environment/sandboxだけが原因でcommand自体が開始されなかった場合はbudgetを消費しない。
- independent whole-change reviewでCritical/Important findingが出た場合、最大2 fix waveまで許可する。各waveはfindingに対応するfocused RED/GREENだけを行い、最終focused/regression/buildは未消費なら実行し、消費済みなら該当resultを再利用せずbudget exhaustionとして停止・報告する。
- 既存memory/tool evidence docs/validation/2026-08-24-gemma4-foundationmodels-poc.md とc85da4c時点のfresh device resultsは不変layerの根拠として再利用できる。ただし今回変更するreply、ViewModel、composition、UIと最終branch全体にはfresh resultが必要。

---

### Task 1: Backend非依存contractとApple session seam

**Files:**
- Create: CatRobot/Conversation/Domain/ReplyTurn.swift
- Create: CatRobot/Conversation/Services/ReplySession.swift
- Create: CatRobot/Conversation/Services/AppleSystemReplySessionFactory.swift
- Create: CatRobotTests/Conversation/Services/AppleSystemReplySessionFactoryTests.swift
- Modify: CatRobot/Conversation/Domain/ConversationTypes.swift
- Modify: CatRobot/Conversation/Integration/ConversationErrorPresentation.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationErrorPresentationTests.swift
- Modify generated: CatRobot.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: FoundationModels.Tool、GenerationOptions、Transcript、SystemLanguageModel、LanguageModelSession、FoundationModelErrorMapper。
- Produces:

~~~swift
struct ReplyTurnRequest: Equatable, Sendable {
    let turnID: UInt64
    let userText: String
}

enum ReplyMemoryChange: Equatable, Sendable {
    case remembered
    case forgotten
    case updated
}

struct ReplyTurnCommit: Equatable, Sendable {
    let finalText: String
    let memoryChange: ReplyMemoryChange?
}

enum ReplyStreamEvent: Equatable, Sendable {
    case draft(String)
    case committed(ReplyTurnCommit)
}

protocol ReplySessionFactory: Sendable {
    func prepare() async throws
    func makeSession(tools: [any Tool]) async throws -> any ReplySessionClient
}

protocol ReplySessionClient: Sendable {
    func prewarm() async
    func transcript() async -> Transcript
    func restoreTranscript(_ transcript: Transcript) async
    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error>
}

struct ReplyGenerationPolicy: Equatable, Sendable {
    static let live = Self(temperature: 0.5, maximumResponseTokens: 256)
    let temperature: Double
    let maximumResponseTokens: Int
    func makeOptions() -> GenerationOptions
}
~~~

Apple factory exposes these exact initializers so production and deterministic tests use one implementation:

~~~swift
struct AppleSystemReplySessionFactory: ReplySessionFactory {
    init()

    init(
        model: SystemLanguageModel = SystemLanguageModel(
            useCase: .general,
            guardrails: .default
        ),
        availability: @escaping @Sendable () -> SystemLanguageModel.Availability,
        makeClient: @escaping @Sendable (
            SystemLanguageModel,
            [any Tool],
            String
        ) async -> any ReplySessionClient = { model, tools, instructions in
            AppleSystemReplySessionClient(
                model: model,
                tools: tools,
                instructions: instructions
            )
        }
    )
}
~~~

- Produces ConversationServiceError.toolRuntimeFailed with generic retry/typed-input presentation.

- [x] **Step 1: Add RED tests for the domain values, Apple policy, readiness mapping, tool forwarding, and generic error presentation**

Add tests with these exact expectations:

~~~swift
func testLivePolicyUsesTemperatureHalfAnd256Tokens() {
    let options = ReplyGenerationPolicy.live.makeOptions()
    XCTAssertEqual(options.temperature, 0.5)
    XCTAssertEqual(options.maximumResponseTokens, 256)
    if #available(iOS 27.0, *) {
        XCTAssertEqual(options.toolCallingMode, .allowed)
    }
}

func testPrepareMapsGeneralModelNotReadyWithoutRunningInference() async {
    let factory = AppleSystemReplySessionFactory(
        availability: { .unavailable(.modelNotReady) }
    )
    do {
        try await factory.prepare()
        XCTFail("Expected modelNotReady")
    } catch let error as ConversationServiceError {
        XCTAssertEqual(error, .modelUnavailable(.modelNotReady))
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func testMakeSessionForwardsAllProvidedToolsInOrder() async throws {
    let recorder = AppleSessionConstructionRecorder()
    let tools = ReplySessionTestTool.makeFour()
    let factory = AppleSystemReplySessionFactory(
        availability: { .available },
        makeClient: { model, receivedTools, instructions in
            await recorder.record(
                toolNames: receivedTools.map { $0.name },
                instructions: instructions
            )
            return RecordingReplySessionClient()
        }
    )

    _ = try await factory.makeSession(tools: tools)

    let recordedToolNames = await recorder.toolNames
    let recordedInstructions = await recorder.instructions
    XCTAssertEqual(
        recordedToolNames,
        ["rememberMemory", "forgetMemory", "searchMemory", "getCurrentDateTime"]
    )
    XCTAssertTrue(recordedInstructions.contains("supportingQuote"))
    XCTAssertTrue(recordedInstructions.contains("現在の日付"))
}

func testToolRuntimeFailureOffersRetryAndTypedInputWithoutPrivateDetail() {
    let presentation = ConversationErrorPresentation(.toolRuntimeFailed)
    XCTAssertEqual(
        presentation.message,
        "記憶機能を使った返事を完了できませんでした。もう一度話しかけてください。"
    )
    XCTAssertEqual(presentation.recoveries.map(\.action), [.retry, .showTypedInput])
}
~~~

ReplySessionTestToolはこのtest file内で次のとおり定義し、live inferenceは呼ばない。

~~~swift
@Generable
private struct ReplySessionTestArguments {
    var value: String
}

private struct ReplySessionTestTool: Tool {
    let name: String
    let description = "Test-only tool."

    func call(arguments: ReplySessionTestArguments) async throws -> String {
        arguments.value
    }

    static func makeFour() -> [any Tool] {
        [
            Self(name: "rememberMemory"),
            Self(name: "forgetMemory"),
            Self(name: "searchMemory"),
            Self(name: "getCurrentDateTime")
        ]
    }
}
~~~

AppleSessionConstructionRecorderはactor、RecordingReplySessionClientはTranscript()と空streamを返すtest doubleとする。

- [x] **Step 2: Regenerate the project and run RED**

Run:

~~~bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask1Red \
  -only-testing:CatRobotTests/AppleSystemReplySessionFactoryTests \
  -only-testing:CatRobotTests/ConversationErrorPresentationTests
~~~

Expected: FAIL because ReplyTurn、ReplySessionFactory、ReplyGenerationPolicy、AppleSystemReplySessionFactory、toolRuntimeFailedがまだ存在しない。

- [x] **Step 3: Implement the domain values and session protocols exactly as declared**

ReplyTurn.swiftはFoundationだけをimportする。ReplySession.swiftだけがFoundationModelsをimportする。ReplyGenerationPolicy.makeOptions()はdeployment target 26を維持して次のavailability branchを使う。

~~~swift
func makeOptions() -> GenerationOptions {
    if #available(iOS 27.0, *) {
        return GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens,
            toolCallingMode: .allowed
        )
    }
    return GenerationOptions(
        temperature: temperature,
        maximumResponseTokens: maximumResponseTokens
    )
}
~~~

- [x] **Step 4: Implement AppleSystemReplySessionFactory and AppleSystemReplySessionClient**

Default factoryはSystemLanguageModel(useCase: .general, guardrails: .default)を1つ所有する。test initializerはavailability closureとclient construction closureだけを差し替える。prepare()はavailabilityを次へmapする。

~~~swift
case .available:
    return
case .unavailable(.deviceNotEligible):
    throw ConversationServiceError.modelUnavailable(.deviceNotEligible)
case .unavailable(.appleIntelligenceNotEnabled):
    throw ConversationServiceError.modelUnavailable(.appleIntelligenceNotEnabled)
case .unavailable(.modelNotReady):
    throw ConversationServiceError.modelUnavailable(.modelNotReady)
@unknown default:
    throw ConversationServiceError.modelUnavailable(.modelNotReady)
~~~

Apple clientはmodel、tools、instructions、mutable sessionをactor内に保持する。初期sessionはLanguageModelSession(model:tools:instructions:)で作り、restoreTranscriptは同じmodelと同じ4 toolでLanguageModelSession(model:tools:transcript:)を再生成する。snapshotsは累積snapshot.contentだけをyieldし、onTerminationでsource Taskをcancelする。

instructionsには既存のCat Robot人格とspecのremember/search/forget/current-date規則を全文で固定する。reasoning UIやraw tool result loggingを追加しない。

- [x] **Step 5: Add toolRuntimeFailed and its presentation**

ConversationTypes.swiftへcase toolRuntimeFailedを追加する。ConversationErrorPresentationは上記の固定messageと[.retry, .typedInput]だけを返す。error associated dataやunderlying ErrorをUIへ渡さない。

- [x] **Step 6: Run GREEN and the generator contract**

Run:

~~~bash
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask1Green \
  -only-testing:CatRobotTests/AppleSystemReplySessionFactoryTests \
  -only-testing:CatRobotTests/FoundationModelErrorMapperTests \
  -only-testing:CatRobotTests/ConversationErrorPresentationTests
~~~

Expected: generator PASS、selected tests 0 failures、live inference 0 calls。

- [x] **Step 7: Review Task 1 and commit**

Review only Task 1 against the spec: FoundationModels import locality、iOS 26 compile、iOS 27 .allowed、instructions completeness、generic error privacy、no second model call。Critical/Important findingを修正し同じGREEN bundleを再実行する。

~~~bash
git diff --check
git add CatRobot/Conversation/Domain/ReplyTurn.swift \
  CatRobot/Conversation/Domain/ConversationTypes.swift \
  CatRobot/Conversation/Services/ReplySession.swift \
  CatRobot/Conversation/Services/AppleSystemReplySessionFactory.swift \
  CatRobot/Conversation/Integration/ConversationErrorPresentation.swift \
  CatRobotTests/Conversation/Services/AppleSystemReplySessionFactoryTests.swift \
  CatRobotTests/Conversation/Integration/ConversationErrorPresentationTests.swift \
  CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: add replaceable reply session backend"
~~~

---

### Task 2: Transactional ToolEnabledReplyService

**Files:**
- Create: CatRobot/Conversation/Services/ToolEnabledReplyService.swift
- Create: CatRobotTests/Conversation/Services/ReplySessionTestDoubles.swift
- Create: CatRobotTests/Conversation/Services/ToolEnabledReplyServiceTests.swift
- Modify generated: CatRobot.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: ReplySessionFactory、ReplySessionClient、ReplyGenerationPolicy.live、LocalMemoryStore、MemoryToolContext、ReplyToolCallBudget、4 tool、MemoryNotice。
- Produces the final concrete service API, before formal ReplyGenerating conformance in Task 3:

~~~swift
actor ToolEnabledReplyService {
    init(
        sessionFactory: any ReplySessionFactory,
        makeMemoryStore: @escaping @Sendable () throws -> LocalMemoryStore = {
            try LocalMemoryStore.applicationSupport()
        },
        dateTimeProvider: any CurrentDateTimeProviding = LiveCurrentDateTimeProvider()
    )

    func prepare() async throws
    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error>
    func cancelActiveReply() async
    func reset() async
}
~~~

- Internal ToolRuntime contains one store、one context、one budget、and stable [any Tool] in remember/forget/search/date order.
- streamReplyはisGeneratingを最初のawaitより前にreserveし、準備とturn setup後にone producer Taskを作る。cancelActiveReply cancels and awaits that same Task, so its return is the cleanup completion barrier.

- [x] **Step 1: Build deterministic fakes and write the service RED suite**

ReplySessionTestDoubles.swiftにactor ReplySessionFactorySpyとactor ReplySessionClientSpyを作る。Factory spyはreceived tool arrays、make count、prepare countを記録する。Client spyはTranscript checkpoint、restore history、options、promptsを記録し、test closureが渡されたactual tool valuesをdowncastしてcallできるようにする。

同fileに次のtest-only interfaceを定義し、下記snippetのharness参照をすべて満たす。

~~~swift
enum RecordingMemoryPersistenceError: Error {
    case saveFailed
}

final class RecordingMemoryPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let timeline: ReplyServiceTimelineRecorder
    private var facts: [MemoryFact]
    private var shouldFailSave: Bool

    init(
        facts: [MemoryFact] = [],
        shouldFailSave: Bool = false,
        timeline: ReplyServiceTimelineRecorder
    ) {
        self.facts = facts
        self.shouldFailSave = shouldFailSave
        self.timeline = timeline
    }

    var savedFacts: [MemoryFact] {
        lock.withLock { facts }
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { facts }
    }

    func save(_ facts: [MemoryFact]) throws {
        try lock.withLock {
            guard !shouldFailSave else {
                throw RecordingMemoryPersistenceError.saveFailed
            }
            self.facts = facts
        }
        timeline.append(.memorySaved)
    }
}

final class ReplyServiceTimelineRecorder: @unchecked Sendable {
    enum Event: Equatable { case draft, memorySaved, committed }
    private let lock = NSLock()
    private var storage: [Event] = []

    var values: [Event] {
        lock.withLock { storage }
    }

    func append(_ event: Event) {
        lock.withLock { storage.append(event) }
    }
}

protocol ToolEnabledReplyServiceHarnessing {
    var service: ToolEnabledReplyService { get }
    var client: ReplySessionClientSpy { get }
    var store: LocalMemoryStore { get }
    var persistence: RecordingMemoryPersistence { get }
    var timeline: ReplyServiceTimelineRecorder { get }
    func collect(request: ReplyTurnRequest) async throws -> [ReplyStreamEvent]
    func waitUntilRestoreStarted() async
    func releaseRestore() async
    var didEmitCommitted: Bool { get async }
}
~~~

Concrete ToolEnabledReplyServiceHarnessはこのprotocolへ適合する。collectはdraft/committed受信時にtimelineへ追加する。initializerはstoreとserviceが同じpersistenceを共有するように構成し、restore gateをclient spyへ渡す。

Add these exact behavior tests:

~~~swift
func testPrepareIsLazyAndRegistersExactlyFourStableSharedTools() async throws
func testSuccessfulReplyEmitsDraftsThenOneCommittedAfterMemoryCommit() async throws
func testCommitAggregatesRememberNoticesAsRemembered() async throws
func testCommitAggregatesForgetNoticesAsForgotten() async throws
func testCommitAggregatesMixedNoticesAsUpdated() async throws
func testSearchAndDateOnlyReplyCommitsWithoutMemoryChange() async throws
func testGenerationFailureRollsBackStagedMemoryAndRestoresTranscript() async throws
func testToolDecodingFailureRollsBackAndRestoresTranscript() async throws
func testCancellationAfterDraftWaitsForRollbackAndRestoresTranscript() async throws
func testThirteenthToolCallDoesNotRunToolBodyAndRollsBack() async throws
func testPersistenceFailureRestoresCheckpointAndDoesNotEmitCommitted() async throws
func testStoreInitializationFailureDoesNotCreateSessionOrEmitEvents() async throws
func testSessionPreparationFailureDoesNotBeginMemoryTurnOrEmitEvents() async throws
func testResetCreatesFreshSessionAndRetainsPersistentToolRuntime() async throws
func testSameTurnIDDoesNotResetBudgetButNewTurnIDDoes() async throws
func testConcurrentStreamReplyIsRejectedUntilCleanupCompletes() async throws
func testEmptyFinalSnapshotRollsBackAndDoesNotCommit() async throws
func testNewServiceInstanceLoadsCommittedFactsFromSharedFile() async throws
~~~

The core success assertion must verify commit ordering, not only values:

~~~swift
let events = try await harness.collect(
    request: .init(turnID: 41, userText: "青が好きです")
)
XCTAssertEqual(
    events,
    [
        .draft("わかった"),
        .draft("わかった、覚えたよ"),
        .committed(
            .init(finalText: "わかった、覚えたよ", memoryChange: .remembered)
        )
    ]
)
let savedFacts = harness.persistence.savedFacts
let timeline = harness.timeline.values
XCTAssertEqual(savedFacts.count, 1)
XCTAssertEqual(
    timeline,
    [.draft, .draft, .memorySaved, .committed]
)
~~~

Cancellation test must keep restore blocked, cancel the consumer, call cancelActiveReply(), and assert the cleanup call does not return until restore is released:

~~~swift
let completion = CompletionProbe()
let cleanup = Task {
    await harness.service.cancelActiveReply()
    await completion.markCompleted()
}
await harness.waitUntilRestoreStarted()
let completedWhileRestoreWasBlocked = await completion.isCompleted
XCTAssertFalse(completedWhileRestoreWasBlocked)
await harness.releaseRestore()
await cleanup.value
let committedFacts = await harness.store.committedFacts()
let restoreCount = await harness.client.restoreCount
let didEmitCommitted = await harness.didEmitCommitted
XCTAssertTrue(committedFacts.isEmpty)
XCTAssertEqual(restoreCount, 1)
XCTAssertFalse(didEmitCommitted)
~~~

CompletionProbeはReplySessionTestDoubles.swiftに置くactorで、private(set) var isCompleted = falseとfunc markCompleted()を持つ。Decode testはclient spyのsourceをLanguageModelSession.GenerationError.decodingFailure相当のtest failureで終了させ、rollback/restore/no commitをassertする。13th-call test invokes the actual CurrentDateTimeTool 13 times from the fake client and asserts provider call count is12、the 13th body did not run、store is unchanged、restoreCount is1、committed event is absent。Store/session preparation failure testsはstream以前のthrow、0 tool body、0 memory save、0 committed eventをassertする。Restart testは1つのtemporary memories.json URLを2つのmakeMemoryStore closureで共有し、first serviceのactual remember toolでcommit後にserviceを破棄し、second serviceのactual search toolが同じfactを返すことをassertする。Application Support implementation自体は既存LocalMemoryStore.applicationSupport()を変更せず、live initializerのdefault closureがそれを直接呼ぶことをcomposition testでassertする。

- [x] **Step 2: Regenerate and run RED**

Run:

~~~bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask2Red \
  -only-testing:CatRobotTests/ToolEnabledReplyServiceTests
~~~

Expected: FAIL because ToolEnabledReplyService does not exist。

- [x] **Step 3: Implement one lazy persistent ToolRuntime and idempotent prepare**

Use this exact runtime shape and order:

~~~swift
private struct ToolRuntime: Sendable {
    let store: LocalMemoryStore
    let context: MemoryToolContext
    let budget: ReplyToolCallBudget
    let tools: [any Tool]
}

private func makeRuntime() throws -> ToolRuntime {
    let store = try makeMemoryStore()
    let context = MemoryToolContext(store: store)
    let budget = ReplyToolCallBudget()
    return ToolRuntime(
        store: store,
        context: context,
        budget: budget,
        tools: [
            RememberMemoryTool(context: context, budget: budget),
            ForgetMemoryTool(context: context, budget: budget),
            SearchMemoryTool(context: context, budget: budget),
            CurrentDateTimeTool(provider: dateTimeProvider, budget: budget)
        ]
    )
}
~~~

prepare()はfactory.prepare()、runtimeの1回だけの生成、sessionFactory.makeSession(tools:)、client.prewarm()を行う。actor reentrancyによる二重session生成を防ぐためprivate var preparationTask: Task<any ReplySessionClient, Error>?とactivePreparationIDを持ち、既存taskがあれば同じvalueをawaitする。runtimeは最初のawaitより前にactor stateへ保存し、成功時だけclientへ保存する。preparationTask/activePreparationIDは成功・failure・cancellationのすべてでin-flight ownerがclearし、completed Taskをstateへ残さない。store init failureは.toolRuntimeFailed、factoryが投げたConversationServiceErrorはそのまま伝播する。

- [x] **Step 4: Implement the serialized transaction and terminal event**

streamReplyはguard !isGeneratingの直後、最初のawaitより前にisGenerating = trueとして重複requestをreserveする。setup errorではdeferではなくcatchでtransaction開始有無を確認してrollback/restoreし、isGeneratingをclearする。sequenceは次を崩さない。

~~~swift
guard !isGenerating else {
    throw ConversationServiceError.modelBusy
}
isGenerating = true
try await prepare()
let checkpoint = await client.transcript()
await runtime.context.beginTurn(id: request.turnID, userText: request.userText)
await runtime.budget.beginTurn(id: request.turnID)
let source = await client.snapshots(
    for: request.userText,
    options: ReplyGenerationPolicy.live.makeOptions()
)
~~~

checkpoint取得後、beginTurn後、budget開始後、source取得後にもTask.checkCancellation()を置き、setup中のcaller cancellationを同じrollback/restore pathへ送る。Producerは各snapshotの前にTask.checkCancellation()し、累積snapshotを.draftでyieldし、最後のnonblank snapshotを保持する。source終了後、もう一度Task.checkCancellation()し、空なら.modelGenerationFailedをthrowする。次にcommitTurn()し、成功した直後にだけ次をyieldする。

~~~swift
continuation.yield(
    .committed(
        ReplyTurnCommit(
            finalText: finalText,
            memoryChange: aggregate(notices)
        )
    )
)
continuation.finish()
~~~

aggregate rulesは[]→nil、rememberedだけ→.remembered、forgottenだけ→.forgotten、両方→.updated。associated Stringをservice外へ返さない。

- [x] **Step 5: Implement atomic failure cleanup and the awaitable barrier**

Commit成功前のcatch pathだけで、source producer cancellation → context.rollbackTurn() → client.restoreTranscript(checkpoint)の順にawaitする。commit後はcancellation/TTS failureでmemoryを戻さない。isGenerating/activeProducerをclearするのはrollback/restoreの後だけにする。

~~~swift
func cancelActiveReply() async {
    guard let producer = activeProducer else { return }
    producer.cancel()
    await producer.value
}
~~~

AsyncThrowingStream.onTerminationはproducer.cancel()だけを行う。cleanup完了の証明はcancelActiveReply()のawaitで行う。generation errorはFoundationModelErrorMapper、ReplyToolCallLimitExceeded/store/commit errorは.toolRuntimeFailed、CancellationErrorは.cancelledへmapする。

reset()はactive producerがあればcancel/awaitする。次にin-flight preparationTaskをcancelしてresultをawaitし、そのTaskとactivePreparationIDとclientをclearしてから、同じToolRuntimeを保持した新しいprepare()を1回呼ぶ。これによりreset前のcompleted/in-flight Taskがold clientを復活させない。nonthrowing reset中のfactory failureはpreparation stateとclientをnilのままにし、次のthrowing prepare()でvisibleにする。

- [x] **Step 6: Run GREEN with unchanged memory/tool suites**

Run:

~~~bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask2Green \
  -only-testing:CatRobotTests/ToolEnabledReplyServiceTests \
  -only-testing:CatRobotTests/LocalMemoryStoreTests \
  -only-testing:CatRobotTests/MemoryToolContextTests \
  -only-testing:CatRobotTests/ReplyToolCallBudgetTests \
  -only-testing:CatRobotTests/CurrentDateTimeToolTests \
  -only-testing:CatRobotTests/MemoryToolTests
~~~

Expected: all selected tests PASS、0 skipped、0 expected failures。

- [x] **Step 7: Review Task 2 and commit**

Review actor reentrancy、producer ownership、commit/cancellation gap、same-turn budget、stable tools、private payload non-escape、all precommit failure paths。Critical/Important findingを修正しGREENを再実行する。

~~~bash
git diff --check
git add CatRobot/Conversation/Services/ToolEnabledReplyService.swift \
  CatRobotTests/Conversation/Services/ReplySessionTestDoubles.swift \
  CatRobotTests/Conversation/Services/ToolEnabledReplyServiceTests.swift \
  CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: orchestrate transactional reply tools"
~~~

---

### Task 3: ReplyGenerating migration、typed/voice flow、live composition

**Files:**
- Modify: CatRobot/Conversation/Domain/ConversationServices.swift
- Modify: CatRobot/Conversation/Services/ToolEnabledReplyService.swift
- Delete: CatRobot/Conversation/Services/FoundationModelReplyService.swift
- Delete: CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift
- Modify: CatRobot/Conversation/Integration/ConversationDependencies.swift
- Modify: CatRobot/Conversation/Integration/ConversationViewModel.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationFakes.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift
- Modify: CatRobotTests/Conversation/Integration/AppCompositionTests.swift
- Modify: CatRobotTests/Conversation/Services/AppleServiceCompositionTests.swift
- Modify generated: CatRobot.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: Task 1 ReplyTurn values、Task 2 ToolEnabledReplyService concrete API。
- Produces the final domain protocol:

~~~swift
protocol ReplyGenerating: Sendable {
    func prepare() async throws
    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error>
    func reset() async
}
~~~

- ToolEnabledReplyService conforms without adapter.
- ConversationDependencies adds the following field and initializer parameter with a no-op default so existing test construction remains source-compatible:

~~~swift
let replyCleanup: @Sendable () async -> Void
replyCleanup: @escaping @Sendable () async -> Void = {}
~~~

Place the initializer parameter immediately before the existing serviceTeardown parameter and assign self.replyCleanup = replyCleanup。live composition captures the concrete ToolEnabledReplyService and calls await reply.cancelActiveReply() from this closure。
- FakeReplyService implements the same event semantics and an internal cleanup gate; ConversationHarness injects { await reply.cancelActiveReply() } as replyCleanup so it remains the single integration stack.

- [x] **Step 1: Migrate FakeReplyService and write RED integration tests**

FakeReplyService records [ReplyTurnRequest]、prepareCount、prepareError、cancelActiveReplyCount。Manual helpers yield .draft and .committed. Existing replySnapshots convenience maps every snapshot to.draft and appends exactly one.committed using the last nonblank snapshot so old tests remain semantically equivalent。Rename promptWaiters/waitUntilPromptCount to requestWaiters/waitUntilRequestCount and retain a derived prompts property for old assertions。

Add or update these exact tests:

~~~swift
func testTypedDraftUpdatesCaptionButDoesNotSpeakUntilCommitted() async
func testTypedRequestForwardsExistingTurnIDAndSubmittedText() async
func testVoiceDraftUpdatesCaptionButDoesNotSpeakUntilCommitted() async
func testVoiceClassifierRunsBeforeToolEnabledReplyAndSpeech() async
func testCommittedFinalStartsSpeechExactlyOnce() async
func testReplyFailureClearsUncommittedDraftWithoutSpeech() async
func testReplyCancellationClearsUncommittedDraftWithoutSpeech() async
func testTypedPreparationDoesNotDependOnContentTaggingAvailability() async
func testVoicePreparationKeepsContentTaggingAvailabilityCheck() async
func testReplyPreparationFailurePublishesRecoveryWithoutStartingSpeech() async
func testPauseWaitsForReplyTransactionCleanup() async
func testSceneInactivityWaitsForReplyTransactionCleanup() async
func testShutdownWaitsForReplyTransactionCleanup() async
func testLiveCompositionUsesToolEnabledReplyService() async
~~~

The typed draft/commit test must explicitly gate the fake:

~~~swift
let submission = Task { @MainActor in
    await harness.sut.submitTypedText("青が好きです")
}
await harness.reply.waitUntilRequestCount(1)
await harness.reply.yield(.draft("わかった"))
await harness.waitUntil { harness.sut.viewState.caption == "わかった" }
let textsBeforeCommit = await harness.speaker.texts
XCTAssertEqual(harness.sut.viewState.caption, "わかった")
XCTAssertEqual(textsBeforeCommit, [])

await harness.reply.yield(
    .committed(.init(finalText: "わかった、覚えたよ", memoryChange: nil))
)
await harness.reply.finish()
await submission.value
let spokenTexts = await harness.speaker.texts
let requests = await harness.reply.requests
XCTAssertEqual(spokenTexts, ["わかった、覚えたよ"])
XCTAssertEqual(
    requests,
    [.init(turnID: 1, userText: "青が好きです")]
)
~~~

Pause test blocks FakeReplyService.cancelActiveReply() until a test continuation is released, starts pause, proves recognizer/audio teardown has not completed, releases cleanup, then proves pause returns。

- [x] **Step 2: Flip ReplyGenerating and run compile RED**

Change ConversationServices.swift to the final protocol above and add : ReplyGenerating to ToolEnabledReplyService。Regenerate and run:

~~~bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask3Red \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationRecoveryTests \
  -only-testing:CatRobotTests/AppCompositionTests \
  -only-testing:CatRobotTests/AppleServiceCompositionTests
~~~

Expected: FAIL at old prewarm/string-stream conformances and call sites。

- [x] **Step 3: Migrate preflight without coupling typed replies to the classifier**

Voice preflight keeps modelAvailability.availability() for.contentTagging, then uses:

~~~swift
try await dependencies.reply.prepare()
~~~

Typed preflight removes its modelAvailability check entirely and starts with:

~~~swift
try await dependencies.reply.prepare()
guard isTypedTurnCurrent(generation, turnID: turnID),
      !Task.isCancelled else { return }
~~~

Speaker/audio setup remains after reply prepare as today。prepare failure flows through existing finishTypedTurn/finishVoiceFailure with the mapped recoverable error。

- [x] **Step 4: Consume draft and committed events in both paths**

Both typed and voice generation pass the existing ID and accepted text:

Typed path uses the concrete existing method arguments:

~~~swift
let stream = try await dependencies.reply.streamReply(
    to: ReplyTurnRequest(turnID: turnID, userText: submitted)
)
var committed: ReplyTurnCommit?
for try await event in stream {
    guard isTypedTurnCurrent(generation, turnID: turnID),
          !Task.isCancelled else { return }
    switch event {
    case .draft(let text):
        viewState.caption = text
    case .committed(let value):
        guard committed == nil else {
            throw ConversationServiceError.modelGenerationFailed
        }
        committed = value
        viewState.caption = value.finalText
    }
}
guard let committed else {
    throw ConversationServiceError.modelGenerationFailed
}
await speakTypedReply(
    committed.finalText,
    shouldResumeVoice: shouldResumeVoice,
    generation: generation,
    turnID: turnID
)
~~~

Voice path applies the same switch to ReplyTurnRequest(turnID:turnID,userText:utterance)、uses isCurrent(generation,turnID:)、records first-caption latency for the first nonblank draft、and calls the existing speakAndResume only after guard let committed。No speech occurs for drafts or stream completion without exactly one committed event。A duplicate committed event is treated as.modelGenerationFailed。

Declare committedReply outside the do block in each typed/voice generation method so catch can inspect it。Catch paths set viewState.caption = "" only when committedReply == nil。After a commit, later TTS failure preserves final caption and committed memory semantics。

- [x] **Step 5: Await reply transaction cleanup in lifecycle paths**

In both pause branches, after cancelling oldTurn and before treating reply work as joined, call:

~~~swift
await dependencies.replyCleanup()
await oldTurn?.value
~~~

Do the same through shutdown’s forced pause path。Do not call reset() as a cancellation barrier。Failure cleanup and audio teardown may proceed only after the reply cleanup await in the branch owning the active turn。

- [x] **Step 6: Replace live composition and remove the old Apple service**

ConversationDependencies.live() composes:

実コードではconcrete valueを先に保持してReplyGenerating existentialとcleanup closureへcaptureする。

~~~swift
let replyService = ToolEnabledReplyService(
    sessionFactory: AppleSystemReplySessionFactory()
)
let reply: any ReplyGenerating = replyService
let replyCleanup: @Sendable () async -> Void = {
    await replyService.cancelActiveReply()
}
~~~

Delete FoundationModelReplyService.swift and its obsolete tests so SystemLanguageModel(.general) has one production owner only。FoundationModelAvailabilityService stays.contentTagging and is not injected into ToolEnabledReplyService。

- [x] **Step 7: Run GREEN integration and lifecycle suites**

Run:

~~~bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask3Green \
  -only-testing:CatRobotTests/ToolEnabledReplyServiceTests \
  -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests \
  -only-testing:CatRobotTests/FoundationModelAddressClassifierTests \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationRecoveryTests \
  -only-testing:CatRobotTests/AppCompositionTests \
  -only-testing:CatRobotTests/AppleServiceCompositionTests
~~~

Expected: all selected tests PASS、voice classifier order remains green、typed path succeeds when content-tagging fake is unavailable、pause/shutdown wait for cleanup。

- [x] **Step 8: Review Task 3 and commit**

Review every typed/voice early return、ownership guard、caption clearing、commit-before-speech、pause/background/shutdown ordering、old service absence、classifier independence。Critical/Important findingを修正しGREENを再実行する。

~~~bash
git diff --check
git add -A CatRobot/Conversation/Domain/ConversationServices.swift \
  CatRobot/Conversation/Services/FoundationModelReplyService.swift \
  CatRobot/Conversation/Services/ToolEnabledReplyService.swift \
  CatRobot/Conversation/Integration/ConversationDependencies.swift \
  CatRobot/Conversation/Integration/ConversationViewModel.swift \
  CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift \
  CatRobotTests/Conversation/Integration/ConversationFakes.swift \
  CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift \
  CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift \
  CatRobotTests/Conversation/Integration/AppCompositionTests.swift \
  CatRobotTests/Conversation/Services/AppleServiceCompositionTests.swift \
  CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: connect tool replies to conversations"
~~~

---

### Task 4: Privacy-safe transient memory notice

**Files:**
- Create: CatRobot/Conversation/UI/MemoryNoticePresentation.swift
- Modify: CatRobot/Conversation/Integration/ConversationDependencies.swift
- Modify: CatRobot/Conversation/Integration/ConversationViewModel.swift
- Modify: CatRobot/Conversation/UI/ConversationViewState.swift
- Modify: CatRobot/Conversation/UI/ConversationView.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationFakes.swift
- Modify: CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift
- Modify: CatRobotTests/Conversation/UI/ConversationViewStateTests.swift
- Modify: CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift
- Modify generated: CatRobot.xcodeproj/project.pbxproj

**Interfaces:**
- Consumes: ReplyTurnCommit.memoryChange from Task 3。
- Produces:

~~~swift
struct MemoryNoticePresentation: Equatable, Sendable {
    static let accessibilityLabel = "記憶の変更"
    static let allowsHitTesting = false
    let text: String

    init(change: ReplyMemoryChange) {
        switch change {
        case .remembered: text = "記憶しました"
        case .forgotten: text = "記憶を削除しました"
        case .updated: text = "記憶を更新しました"
        }
    }
}
~~~

- ConversationViewState gains var memoryNotice: String?。
- ConversationDependencies gains:

~~~swift
let memoryNoticeDelay: @Sendable (Duration) async -> Void
~~~

with default try? await Task.sleep(for: duration)。ConversationHarness initializerへ同名parameterを追加し、ConversationDependenciesへそのまま渡す。

- [x] **Step 1: Write RED tests for copy, publish timing, replacement, expiry, and accessibility**

Add these tests:

~~~swift
func testMemoryNoticeUsesOnlyGenericJapaneseCopy() {
    XCTAssertEqual(MemoryNoticePresentation(change: .remembered).text, "記憶しました")
    XCTAssertEqual(MemoryNoticePresentation(change: .forgotten).text, "記憶を削除しました")
    XCTAssertEqual(MemoryNoticePresentation(change: .updated).text, "記憶を更新しました")
}

func testCommittedMemoryChangePublishesNoticeWithoutBlockingSpeech() async
func testSearchOrDateOnlyCommitPublishesNoNotice() async
func testReplyFailureAndRollbackPublishNoNotice() async
func testNewMemoryNoticeReplacesPriorNoticeAndOldExpiryCannotClearIt() async
func testCommittedNoticeSurvivesLaterSpeechFailure() async
func testMemoryNoticeChangeDoesNotTriggerCaptionAnnouncement() async
~~~

The replacement test uses two independently controlled memoryNoticeDelay calls. Release the first after publishing the second and assert the second remains; release the second and assert nil。

~~~swift
let sleeper = ConversationTestSleeper()
let harness = ConversationHarness(
    replySnapshots: nil,
    memoryNoticeDelay: { duration in
        await sleeper.sleep(for: duration)
    }
)

let first = Task { @MainActor in
    await harness.sut.submitTypedText("ひとつ")
}
await harness.reply.waitUntilRequestCount(1)
await harness.reply.yield(
    .committed(.init(finalText: "ひとつ", memoryChange: .remembered)),
    run: 0
)
await harness.reply.finish(run: 0)
await first.value
await harness.waitUntil { (await sleeper.durations).count == 1 }
XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")

let second = Task { @MainActor in
    await harness.sut.submitTypedText("ふたつ")
}
await harness.reply.waitUntilRequestCount(2)
await harness.reply.yield(
    .committed(.init(finalText: "ふたつ", memoryChange: .forgotten)),
    run: 1
)
await harness.reply.finish(run: 1)
await second.value
await harness.waitUntil { (await sleeper.durations).count == 2 }
XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶を削除しました")

await sleeper.release(0)
await harness.waitUntil { await sleeper.completionCount == 1 }
XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶を削除しました")
await sleeper.release(1)
await harness.waitUntil { harness.sut.viewState.memoryNotice == nil }
XCTAssertNil(harness.sut.viewState.memoryNotice)
~~~

Extend ConversationTestSleeper with private(set) var completionCount = 0 and increment it after a stored continuation resumes。This makes the old-expiry race assertion deterministic rather than relying on Task.yield。

- [x] **Step 2: Regenerate and run RED**

Run:

~~~bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask4Red \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationViewStateTests \
  -only-testing:CatRobotTests/ConversationAccessibilityTests
~~~

Expected: FAIL because memory notice state/policy/lifecycle does not exist。

- [x] **Step 3: Implement ViewModel-owned notice lifecycle**

Add ObservationIgnored memoryNoticeDismissTask、notice counter、active notice ID。On committed memoryChange:

~~~swift
private func publishMemoryNotice(_ change: ReplyMemoryChange?) {
    guard let change else { return }
    memoryNoticeDismissTask?.cancel()
    memoryNoticeCounter &+= 1
    let noticeID = memoryNoticeCounter
    activeMemoryNoticeID = noticeID
    viewState.memoryNotice = MemoryNoticePresentation(change: change).text
    let delay = dependencies.memoryNoticeDelay
    memoryNoticeDismissTask = Task { @MainActor [weak self] in
        await delay(.seconds(3))
        guard !Task.isCancelled,
              let self,
              self.activeMemoryNoticeID == noticeID else { return }
        self.viewState.memoryNotice = nil
        self.activeMemoryNoticeID = nil
        self.memoryNoticeDismissTask = nil
    }
}
~~~

Call it immediately after receiving a valid.committed event and before starting speech。Nil change does nothing。Shutdown cancels the dismiss task。General state transitions and post-commit TTS failure preserve the notice; new committed mutation replaces it。

- [x] **Step 4: Add presentation-only state and top overlay**

Add memoryNotice:nil to every static ConversationViewState constructor。ConversationView wraps conversationBody in ZStack(alignment:.top) and shows a banner only when nonnil。Banner requirements:

~~~swift
Text(notice)
    .font(.body.weight(.semibold))
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(memoryNoticeBackground, in: Capsule())
    .accessibilityLabel(MemoryNoticePresentation.accessibilityLabel)
    .accessibilityValue(notice)
    .allowsHitTesting(MemoryNoticePresentation.allowsHitTesting)
~~~

memoryNoticeBackground uses Color(uiColor:.secondarySystemBackground) when reduceTransparency is true and.regularMaterial otherwise。Do not add Button、gesture、ConversationActions、caption mutation、transcript mutation。

- [x] **Step 5: Run GREEN UI/integration suites**

Run:

~~~bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask4Green \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationRecoveryTests \
  -only-testing:CatRobotTests/ConversationViewStateTests \
  -only-testing:CatRobotTests/ConversationAccessibilityTests
~~~

Expected: all selected tests PASS、notice never blocks speaker fake、old expiry cannot clear replacement。

- [x] **Step 6: Review Task 4 and commit**

Review generic copy only、state reconstruction、timer race、shutdown cancellation、reduced transparency、Dynamic Type、noninteractive/accessibility、no repeated caption announcement。Critical/Important findingを修正しGREENを再実行する。

~~~bash
git diff --check
git add CatRobot/Conversation/UI/MemoryNoticePresentation.swift \
  CatRobot/Conversation/Integration/ConversationDependencies.swift \
  CatRobot/Conversation/Integration/ConversationViewModel.swift \
  CatRobot/Conversation/UI/ConversationViewState.swift \
  CatRobot/Conversation/UI/ConversationView.swift \
  CatRobotTests/Conversation/Integration/ConversationFakes.swift \
  CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift \
  CatRobotTests/Conversation/UI/ConversationViewStateTests.swift \
  CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift \
  CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: show committed memory notices"
~~~

---

### Task 5: Host-side architecture、scope、privacy acceptance guard

**Files:**
- Create: scripts/test_live_reply_architecture.rb

**Interfaces:**
- Consumes: final production composition and presentation from Tasks 1-4。
- Produces: host filesystem上だけで動くdeterministic architecture contract。Physical-device XCTestからrepository sourceを読まない。

- [x] **Step 1: Run the missing host contract to establish RED**

Run:

~~~bash
ruby scripts/test_live_reply_architecture.rb
~~~

Expected: FAIL with LoadError because the contract script does not exist。

- [x] **Step 2: Implement the host contract**

Create the script with this exact behavior:

~~~ruby
#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)

def swift_source(root, relative_roots)
  relative_roots.flat_map do |relative_root|
    Dir.glob(File.join(root, relative_root, "**", "*.swift")).sort
  end.map { |path| [path, File.read(path, encoding: "UTF-8")] }
end

failures = []
backend_free_roots = %w[
  CatRobot/Conversation/Domain
  CatRobot/Conversation/Memory
  CatRobot/Conversation/Tools
  CatRobot/Conversation/Integration
  CatRobot/Conversation/UI
]
backend_tokens = %w[SystemLanguageModel LanguageModelSession Gemma LiteRT LiteRTLM]

swift_source(root, backend_free_roots).each do |path, source|
  backend_tokens.each do |token|
    failures << "#{path}: forbidden backend token #{token}" if source.include?(token)
  end
end

production_sources = swift_source(root, ["CatRobot"])
logging_pattern = /\b(?:print|debugPrint|dump|NSLog)\s*\(|\b(?:Logger|os_log)\b/
production_sources.each do |path, source|
  failures << "#{path}: production logging is forbidden" if source.match?(logging_pattern)
end

ui_integration_sources = swift_source(
  root,
  %w[CatRobot/Conversation/Integration CatRobot/Conversation/UI]
)
private_tokens = %w[
  supportingQuote
  MemoryFact
  MemorySearchResult
  RememberMemoryArguments
  ForgetMemoryArguments
  SearchMemoryArguments
]
ui_integration_sources.each do |path, source|
  private_tokens.each do |token|
    failures << "#{path}: private payload token #{token}" if source.include?(token)
  end
end

notice_path = File.join(
  root,
  "CatRobot/Conversation/UI/MemoryNoticePresentation.swift"
)
notice_source = File.read(notice_path, encoding: "UTF-8")
%w[記憶しました 記憶を削除しました 記憶を更新しました].each do |copy|
  failures << "#{notice_path}: missing generic copy #{copy}" unless notice_source.include?(copy)
end

apple_factory = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/AppleSystemReplySessionFactory.swift"
  ),
  encoding: "UTF-8"
)
unless apple_factory.include?("SystemLanguageModel(useCase: .general")
  failures << "Apple reply factory does not own the .general model"
end

general_model_owners = swift_source(
  root,
  ["CatRobot/Conversation/Services"]
).select { |_path, source| source.include?("useCase: .general") }
unless general_model_owners.length == 1 &&
       general_model_owners.first.first.end_with?(
         "AppleSystemReplySessionFactory.swift"
       )
  failures << "the Apple reply factory must be the only .general model owner"
end

old_reply_service = File.join(
  root,
  "CatRobot/Conversation/Services/FoundationModelReplyService.swift"
)
failures << "obsolete FoundationModelReplyService still exists" if File.exist?(
  old_reply_service
)

classifier = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift"
  ),
  encoding: "UTF-8"
)
failures << "content-tagging classifier must remain tool-free" if classifier.include?(
  "tools:"
)

tool_service = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Services/ToolEnabledReplyService.swift"
  ),
  encoding: "UTF-8"
)
unless tool_service.include?("LocalMemoryStore.applicationSupport()")
  failures << "live tool service does not default to Application Support"
end

composition = File.read(
  File.join(
    root,
    "CatRobot/Conversation/Integration/ConversationDependencies.swift"
  ),
  encoding: "UTF-8"
)
unless composition.include?("AppleSystemReplySessionFactory") &&
       composition.include?("ToolEnabledReplyService")
  failures << "live composition does not connect Apple factory to tool service"
end

abort(failures.join("\n")) unless failures.empty?
puts "live reply architecture contract passed"
~~~

Do not scan Services for the supportingQuote word because the approved Apple instructions must contain it。Instead, the all-production logging prohibition prevents Services from emitting prompt/tool/private content。

- [x] **Step 3: Run the host guard and focused runtime acceptance**

Run:

~~~bash
ruby scripts/test_live_reply_architecture.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination id=00008140-000610311A90801C \
  -derivedDataPath /tmp/CatRobotLiveReplyTask5 \
  -only-testing:CatRobotTests/AppCompositionTests \
  -only-testing:CatRobotTests/AppleServiceCompositionTests \
  -only-testing:CatRobotTests/ToolEnabledReplyServiceTests \
  -only-testing:CatRobotTests/ConversationAccessibilityTests \
  -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests
~~~

Expected: host contract PASS、selected device tests PASS。If a check fails, change only the source boundary/private leak it proves; do not add Gemma implementation、debug UI、logging、second classifier、or dependency。

- [x] **Step 4: Review Task 5 and commit**

Review the script for deterministic sorted reads、physical-device independence、false positives、and exact approved exceptions。

~~~bash
git diff --check
git add scripts/test_live_reply_architecture.rb
git commit -m "test: enforce reply tool architecture boundaries"
~~~

---

### Task 6: Whole-change review、fresh validation、evidence、signed install and launch

**Files:**
- Create: docs/validation/2026-08-24-live-reply-tools-integration.md
- Modify only if review finds a Critical/Important defect: files directly implicated by that finding and their focused tests。

**Interfaces:**
- Consumes: Tasks 1-5 commits and all existing independent memory/tool evidence。
- Produces: one evidence document with exact HEAD、toolchain/device versions、commands、exit status、test counts、xcresult paths、review findings、scope scans、build/install/launch result、known limitations。

- [x] **Step 1: Run an independent whole-change review before spending final validation budget**

Provide the reviewer the spec、this plan、base c85da4c、current HEAD、all task reports/diffs。Require severity-ranked findings with file:line evidence and explicit checks for:

- commit/rollback/transcript restore atomicity and cancellation races。
- exactly one terminal committed event and no speech/notice beforehand。
- same-turn budget preservation and 13th-call body exclusion。
- lazy Application Support store lifetime and reset reuse。
- backend seam sufficiency for a later Gemma factory-only swap。
- typed/classifier independence and voice ordering。
- private data non-exposure and notice timer race。
- Swift 6 actor/task safety and every error/early-return path。

If Critical/Important findings exist, perform a focused RED → minimal fix → focused GREEN wave and re-review。At most2 waves; do not perform unrelated simplification or scope expansion。

- [x] **Step 2: Re-enumerate the connected device and record exact identifiers**

Run:

~~~bash
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project CatRobot.xcodeproj -scheme CatRobot -showdestinations
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcrun devicectl list devices
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -version
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcrun swift --version
~~~

Expected current mapping is Xcode destination 00008140-000610311A90801C and CoreDevice 59199D1B-26D5-5063-8A43-BE38E8008EAD for the connected iPhone 16 Pro。Do not assume it: if fresh output differs, use the one connected/available iPhone shown by both tools and record the observed IDs。Do not use a simulator。

For every remaining command block, set CATROBOT_XCODE_DEVICE_ID and CATROBOT_CORE_DEVICE_ID to the exact values observed in this step。The assignments below show the currently expected values; replace only the right-hand side when fresh enumeration differs。

- [x] **Step 3: Run the one final generator contract**

Run:

~~~bash
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
git diff --exit-code -- CatRobot.xcodeproj/project.pbxproj
~~~

Expected: all exit0、generator rerun creates no diff。

- [x] **Step 4: Run the one fresh focused device bundle**

Run with the freshly confirmed destination ID:

~~~bash
CATROBOT_XCODE_DEVICE_ID='00008140-000610311A90801C'
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination "id=$CATROBOT_XCODE_DEVICE_ID" \
  -derivedDataPath /tmp/CatRobotLiveReplyFocused \
  -resultBundlePath /tmp/CatRobotLiveReplyFocused.xcresult \
  -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests \
  -only-testing:CatRobotTests/FoundationModelAddressClassifierTests \
  -only-testing:CatRobotTests/FoundationModelErrorMapperTests \
  -only-testing:CatRobotTests/AppleSystemReplySessionFactoryTests \
  -only-testing:CatRobotTests/LocalMemoryStoreTests \
  -only-testing:CatRobotTests/MemoryToolContextTests \
  -only-testing:CatRobotTests/ReplyToolCallBudgetTests \
  -only-testing:CatRobotTests/CurrentDateTimeToolTests \
  -only-testing:CatRobotTests/MemoryToolTests \
  -only-testing:CatRobotTests/ToolEnabledReplyServiceTests \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationRecoveryTests \
  -only-testing:CatRobotTests/AppCompositionTests \
  -only-testing:CatRobotTests/AppleServiceCompositionTests \
  -only-testing:CatRobotTests/ConversationErrorPresentationTests \
  -only-testing:CatRobotTests/ConversationViewStateTests \
  -only-testing:CatRobotTests/ConversationAccessibilityTests
~~~

Expected: exit0、0 failed、0 skipped、0 expected failures。Use xcresulttool to record exact executed/passed counts and device/OS。

- [x] **Step 5: Run the one fresh full device regression**

Run:

~~~bash
CATROBOT_XCODE_DEVICE_ID='00008140-000610311A90801C'
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination "id=$CATROBOT_XCODE_DEVICE_ID" \
  -derivedDataPath /tmp/CatRobotLiveReplyRegression \
  -resultBundlePath /tmp/CatRobotLiveReplyRegression.xcresult \
  -skip-testing:CatRobotTests/SpeechAudioConverterTests
~~~

Expected: exit0、every executed test passes。SpeechAudioConverterTests classだけが既知のunchanged exclusionであり、他のskipを追加しない。

- [x] **Step 6: Run final scope/privacy/worktree checks**

Run:

~~~bash
ruby scripts/test_live_reply_architecture.rb
rg -n "LiteRT|Gemma|LiteRTLM" CatRobot CatRobot.xcodeproj/project.pbxproj
rg -n "SystemLanguageModel|LanguageModelSession" \
  CatRobot/Conversation/Domain \
  CatRobot/Conversation/Memory \
  CatRobot/Conversation/Tools \
  CatRobot/Conversation/Integration \
  CatRobot/Conversation/UI
rg -n "supportingQuote|MemoryFact|MemorySearchResult|RememberMemoryArguments|ForgetMemoryArguments|SearchMemoryArguments|raw prompt|raw tool|print\\(|Logger|os_log" \
  CatRobot/Conversation/Integration \
  CatRobot/Conversation/UI
rg -n "print\\(|debugPrint\\(|dump\\(|Logger|os_log|NSLog" CatRobot
git diff --check
git status --short --branch
~~~

Expected: host contract PASS、privacy/dependency/logging scans empty、diff check exit0、status has branch header only as a pre-evidence cleanliness checkpoint。This is not the final clean result; Step10 repeats the check after the evidence commit。

- [x] **Step 7: Build the signed device app**

Run with the freshly confirmed destination:

~~~bash
CATROBOT_XCODE_DEVICE_ID='00008140-000610311A90801C'
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -configuration Debug \
  -destination "platform=iOS,id=$CATROBOT_XCODE_DEVICE_ID" \
  -derivedDataPath /tmp/CatRobotLiveReplyDevice \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
~~~

Expected: BUILD SUCCEEDED、automatic signing team VUB4VP6453、bundle com.kamby.CatRobot。CODE_SIGNING_ALLOWED=NOを使わない。

- [x] **Step 8: Overwrite-install without uninstall and launch normally**

Run with the freshly confirmed CoreDevice ID:

~~~bash
CATROBOT_CORE_DEVICE_ID='59199D1B-26D5-5063-8A43-BE38E8008EAD'
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcrun devicectl device install app \
  --device "$CATROBOT_CORE_DEVICE_ID" \
  /tmp/CatRobotLiveReplyDevice/Build/Products/Debug-iphoneos/CatRobot.app
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcrun devicectl device process launch \
  --device "$CATROBOT_CORE_DEVICE_ID" \
  --terminate-existing \
  com.kamby.CatRobot
~~~

Expected: install reports the existing bundle replaced/installed successfully without uninstall、launch reports a running process。Do not send a stochastic tool prompt; leave hands-on typed/voice verification to the user。

- [x] **Step 9: Write and commit validation evidence**

Create docs/validation/2026-08-24-live-reply-tools-integration.md with:

- exact validated implementation HEAD and base commit。
- Xcode/Swift/SDK/device/iOS versions and both fresh IDs。
- generator、focused、regression、scope/privacy、build、install、launch commands and exit status。
- focused/regression exact test totals and xcresult paths。
- independent review status and any fix-wave commit。
- SpeechAudioConverterTests exclusion as unchanged limitation。
- explicit statement that no live prompt/private memory content was captured。
- install/launch observed success and that no uninstall occurred。

~~~bash
git add docs/validation/2026-08-24-live-reply-tools-integration.md
git commit -m "docs: record live reply tool validation"
~~~

- [x] **Step 10: Prove final completion state**

Run:

~~~bash
git diff --check
git status --short --branch
git log -1 --oneline
~~~

Expected: diff check exit0、status exactly ## feature/gemma4-independent-tools、HEAD is the validation evidence commit。Report completion only if every spec completion condition has fresh evidence and there are no unresolved Critical/Important findings。
