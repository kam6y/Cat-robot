# Conversation Memory Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gemmaの確定済み会話を端末に保存し、再起動後に復元でき、明示的に忘れられるようにする。

**Architecture:** Gemmaサービスが確定記憶と操作世代を所有し、注入した単一ファイルストアへスナップショットを直列保存する。記憶管理専用の境界をUIに公開し、保存警告と復元・削除の停止状態を区別する。ネイティブ推論状態は保存しない。

**Tech Stack:** Swift concurrency、FoundationファイルI/O/Codable、SwiftUI、XCTest、既存LiteRT-LM。外部依存の追加なし。

**Spec:** [承認済み設計書](../specs/2026-09-23-conversation-memory-persistence-design.md)。2026-09-23のユーザー「ok」で承認。実行方式はユーザー「推奨でいいよ」に基づきnative実装。

## 実行結果（2026-09-23）

Tasks 1〜5の実装と回帰テスト、Task 6の独立レビュー・Simulator全体テスト・実機の別プロセス保存/復元/忘却と2回要約後の復元を完了。
実際の結果と計画からの変更は[検証記録](../../validation/2026-09-23-conversation-memory-persistence.md)に記載する。
以下のチェックリストは作成時の手順として残す。段階ごとの小コミット・障害注入フック・既存テストの全コンストラクタ変更は、記録した判断によりまとめたコミット・実権限エラー・インメモリ既定値へ置き換えた。
UIの手動タップ、ロック中の実機復旧、I/O単体の時間測定は未実施。通常ViewModel/Coordinatorの回帰テストと実機プロセステストの結果を、その代わりに手動検証済みとは扱わない。
mainへの統合は今回の範囲外であり、featureブランチを保持する。

## Global Constraints

- `feature/conversation-memory-persistence` を使い、main `392e763482c2bf8efe42deccf48f9c6bbe53f9fa` の既存動作を基準にする。
- Gemma 4 E2B、上限12,288、要約開始8,192、直近2,048以上を往復単位で保持、要約出力512、返答160を変更しない。
- 保存先は `Library/Application Support/CatRobot/ConversationMemory/current.json`、単一会話、schemaVersion=1、1MiB上限。
- 完了した要約＋往復のみ保存。生音声、宛先判定、未完の出力、全文アーカイブ、KV、システム指示は保存しない。
- ファイル保護はロック中アクセス不可。記憶をバックアップから除外。原子的置換を保存の確定点とする。
- 保存失敗はRAMと返答を維持。復元失敗は旧ファイルを保持して会話開始を止める。削除失敗は成功表示せず停止する。
- actorの再入を考慮し、保存をfire-and-forgetにしない。忘却のゲートは最初のawaitより前に立てる。
- 会話内容を本番ログへ出さない。保存・復元でマイクを勝手に再開しない。
- AFMを保持し、Gemmaの保存形式を流用しない。iOS deployment target 26.0を維持。
- Swiftファイル変更後は `ruby scripts/generate_project.rb` と `ruby scripts/test_generate_project.rb`。生成されたプロジェクトを手編集しない。
- 基準mainの直近通常テストは261成功・3スキップ・失敗0。実装時には新しい作業場所で改めてベースラインを取得する。

## Review Focus

1. 保存ファイルは正しいJSONでも、異なるモデルの記憶や過大な要約を含み得る。旧ファイルを上書きせず復元を止める（Task 1/3）。
2. 保存待ち中にユーザーが一時停止すると、生成がすでに確定した往復まで取り消してしまい得る。確定点以後は保存まで完了させる（Task 3）。
3. 忘却中に古いロード・保存再試行が終わると記憶が復活し得る。削除は全旧操作より後で、以後は新世代のみ（Task 4）。
4. 会話状態遷移や通常エラーの表示が保存警告を消し得る。記憶の通知状態を別に保持し、再表示も検証する（Task 5）。
5. 既存の実機テストはlive構成を作りresetする。保存を有効化する前にテスト保存先を隔離し、利用者の記憶を保護する（Task 5/6）。

---

## ファイル構成と責務

新規ファイル:

- `CatRobot/Conversation/Domain/ConversationMemory.swift`: スナップショット・状態・エラー・保存/管理プロトコル。
- `CatRobot/Conversation/Services/Memory/FileConversationMemoryStore.swift`: ファイルの読み書きと削除のみ。
- `CatRobot/Conversation/Services/Memory/InMemoryConversationMemoryStore.swift`: テストや明示的な非永続構成用。
- `CatRobot/Conversation/Services/Memory/UnsupportedConversationMemoryManager.swift`: AFM/既存fake用の非対応実装。
- `CatRobot/Conversation/Services/Gemma/GemmaConversationMemory.swift`: 既存のprivate記憶型を抽出。保持開始位置・再計数・保存形式への変換。
- `CatRobot/Conversation/UI/ConversationMemoryPresentation.swift`: 状態を日本語・回復操作・入力可否へ変換する純粋な表示方針。
- `CatRobotTests/Conversation/Services/ConversationMemorySnapshotTests.swift`
- `CatRobotTests/Conversation/Services/FileConversationMemoryStoreTests.swift`
- `CatRobotTests/Conversation/Services/GemmaMemoryPersistenceTests.swift`
- `CatRobotTests/Conversation/Services/GemmaTestRuntime.swift`: 既存のGemma fakeを移動し複数テストで共有。
- `CatRobotTests/Conversation/Services/MemoryStoreFake.swift`: 失敗・遅延を制御するストア。
- `CatRobotTests/Conversation/Integration/ConversationMemoryIntegrationTests.swift`
- `CatRobotTests/Conversation/UI/ConversationMemoryPresentationTests.swift`

既存ファイルの変更は各Taskで列挙する。ViewModelの全面分割や推論アダプターの変更は行わない。

## 共通の実行方法

作業ディレクトリは `/Users/goodapple/.codex/worktrees/conversation-memory-persistence/Cat_robot`。開始時にstatusとHEADを確認し、既存の未コミット変更は上書きしない。

```bash
xcrun simctl list devices available
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

実装担当者は一覧から利用可能なSimulator UDIDを `MEMORY_SIMULATOR_UDID` に設定する。テストは以下を基本に、該当する `-only-testing:CatRobotTests/<TestClass>` を追加する。各実行のログ/結果は別名で保存し、失敗後の結果を成功扱いしない。

```bash
GIT_LFS_SKIP_SMUDGE=1 xcodebuild \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination "platform=iOS Simulator,id=${MEMORY_SIMULATOR_UDID}" \
  -derivedDataPath /private/tmp/cat-memory-persistence/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-gemma-20260921/packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Swift追加後はプロジェクトを再生成してからテストする。REDは対象の動作が欠けていることによる失敗を確認し、署名・環境エラーをREDの証拠にしない。

## Task 1: 保存形式と記憶管理の契約を定義する

**Files:** 新規 `Domain/ConversationMemory.swift`、`ConversationMemorySnapshotTests.swift`、`InMemoryConversationMemoryStore.swift`、`UnsupportedConversationMemoryManager.swift`。プロジェクト再生成。

**Interfaces / Produces:**

```swift
struct ConversationMemoryTurn: Codable, Equatable, Sendable {
    let prompt: String
    let response: String
}
struct ConversationMemorySnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let memoryCompatibilityID: String
    let revision: UInt64
    let savedAt: Date
    let summary: String
    let turns: [ConversationMemoryTurn]
    func validate(expectedCompatibilityID: String) throws
}
enum ConversationMemoryError: Error, Equatable, Sendable {
    case invalidData, unsupportedSchema, incompatibleModel, tooLarge
    case readFailed, writeFailed, deleteFailed, unavailable, unsupported
}
enum ConversationMemoryState: Equatable, Sendable {
    case unsupported, unprepared, loading, ready, saving, unsaved
    case restoreFailed(ConversationMemoryError)
    case forgetting, forgetFailed(ConversationMemoryError)
}
protocol ConversationMemoryStore: Sendable {
    func load() async throws -> ConversationMemorySnapshot?
    func save(_ snapshot: ConversationMemorySnapshot) async throws
    func clear() async throws
}
protocol ConversationMemoryManaging: Sendable {
    func prepareMemory() async throws
    func memoryState() async -> ConversationMemoryState
    func memoryUpdates() async -> AsyncStream<ConversationMemoryState>
    func retryMemoryOperation() async throws
    func forgetConversation() async throws
}
```

- [ ] スナップショットの不正形式・互換性・空白のみの往復・revision=0のテストを書く。空の記憶（summary空、turns空、revision=0）は有効とし、非空の記憶でrevision=0は不正とする。

```swift
func testForeignModelIsRejected() {
    let value = ConversationMemorySnapshot(
        schemaVersion: 1, memoryCompatibilityID: "foreign", revision: 1,
        savedAt: Date(timeIntervalSince1970: 0), summary: "",
        turns: [.init(prompt: "好きな飲み物はほうじ茶", response: "覚えたよ")])
    XCTAssertThrowsError(try value.validate(expectedCompatibilityID: "gemma-test-v1")) {
        XCTAssertEqual($0 as? ConversationMemoryError, .incompatibleModel)
    }
}
```

- [ ] `ConversationMemorySnapshotTests` を実行し、期待する失敗を確認する。
- [ ] 上記データ型とバリデーションを実装。型の不一致はdecode時、schema/互換性/空白/世代はvalidate時に拒否する。保存日時は順序制御に使わない。
- [ ] `InMemoryConversationMemoryStore` actorを実装。`init(snapshot: ConversationMemorySnapshot? = nil)`、loadは現在値、saveは置換、clearはnil。
- [ ] `UnsupportedConversationMemoryManager` を実装。prepare/retryはno-op、stateはunsupported、updatesはunsupportedを一度yieldしてfinish、forgetはunsupportedをthrowする。AFM向けUIでは忘却機能を表示しない。
- [ ] テストを再実行し、プロジェクト生成の決定性を確認してコミットする: `Define conversation memory contracts and snapshot format`。

## Task 2: 原子的なファイルストアを作る

**Files:** 新規 `FileConversationMemoryStore.swift`、`FileConversationMemoryStoreTests.swift`。

**Consumes:** Task 1のsnapshot/store/error。

**Produces:** `FileConversationMemoryStore(directory: URL, compatibilityID: String, beforeCommit: @escaping @Sendable () throws -> Void = {})` actor。`beforeCommit` はファイル書き込み/属性設定後、rename前の障害注入用。`static func defaultDirectory() throws -> URL` はApplication Support配下を返す。ファイル実装の `load/save/clear` 本体はawaitを含まない同期I/Oでactor内に直列化し、別storeインスタンスの同時利用は構成側で禁止する。

- [ ] 一時ディレクトリ上で、別インスタンスからの復元と置換直前の失敗を確認するテストを書く。

```swift
func testFailedReplacementPreservesOldSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: "test",
        revision: 1, savedAt: Date(), summary: "前の記憶",
        turns: [.init(prompt: "A", response: "B")])
    let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
    try await store.save(first)
    let failing = FileConversationMemoryStore(directory: directory, compatibilityID: "test",
        beforeCommit: { throw ConversationMemoryError.writeFailed })
    let second = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: "test",
        revision: 2, savedAt: Date(), summary: "新しい記憶",
        turns: [.init(prompt: "C", response: "D")])
    do { try await failing.save(second); XCTFail("Expected write failure") }
    catch { XCTAssertEqual(error as? ConversationMemoryError, .writeFailed) }
    let restored = try await store.load()
    XCTAssertEqual(restored, first)
}
```

- [ ] `FileConversationMemoryStoreTests` を実行しREDを確認する。
- [ ] Foundationの対応APIを公式文書で確認して実装する。loadは不存在だけnil。1MiB+1バイトまでの上限付き読み込みを使い、サイズメタデータだけに依存せず過大な入力を拒否する。JSON decode後にvalidateを実行する。
- [ ] saveはvalidate→encode→1MiB判定→ディレクトリ準備→同一ディレクトリのUUID一時ファイルへ完全書き込み→保護属性とバックアップ除外→beforeCommit→原子的置換の順序。初回作成も置換と同じ確定保証を持つAPIを使う。失敗時は一時ファイルを掃除し、旧current.jsonを維持する。
- [ ] clearはストア専用ディレクトリ内の `current.json` とストア命名の一時ファイルのみ削除する。いずれかの削除失敗はdeleteFailed。不在は成功。残存一時ファイルをloadの代替に使わない。
- [ ] 読み取り権限エラー、壊れたJSON、schema不一致、互換性不一致、1MiB境界、空ファイル、孤立した一時ファイル、clearの再実行のケースを追加する。権限失敗を再現できないSimulator条件ではfakeによるサービス検証と実機確認を併用し、未確認を明示する。
- [ ] 初回/置換後の属性を検査し、Task 1/2テストをGREENにしてコミットする: `Persist conversation snapshots with atomic file replacement`。

## Task 3: Gemmaの確定記憶を保存し、初回に復元する

**Files:** `GemmaConversationService.swift`、`ConversationDependencies.swift`、`GemmaAppDeviceTests.swift`、新規 `GemmaConversationMemory.swift`、`GemmaMemoryPersistenceTests.swift`、`MemoryStoreFake.swift`、`GemmaTestRuntime.swift`。既存 `GemmaConversationServiceTests.swift` のprivate fakeを共有ファイルに移し、テスト本文の意味は変えない。

**Consumes:** Task 1/2の境界。既存 `ConversationTestGate`（wait/waitUntilEntered/open）をテストで再利用。

**Produces:**

```swift
// GemmaConversationServiceの指定初期化子。暗黙の本番ファイルアクセスを禁止する。
init(runtime: any GemmaRuntime = LiteRTGemmaRuntime(),
     memoryStore: any ConversationMemoryStore,
     compatibilityID: String = GemmaMemoryCompatibility.current)

// GemmaMemoryCompatibilityはGemmaConversationMemory.swiftで定義。
// 固定モデルのSHA-256 + "memory-v1"を組み合わせたStringをcurrentとする。
// countTokensの計数方法/履歴解釈を変えるときに互換性の要否を判断する。
```

`MemoryStoreFake` actorは `init(snapshot: ConversationMemorySnapshot? = nil, loadGate: ConversationTestGate? = nil, saveGate: ConversationTestGate? = nil)`、storeの3メソッド、`setSaveFailure(_ enabled: Bool)`、`setClearFailure(_ enabled: Bool)`、`snapshot`、`loadCount`、`saveCount`、`clearCount` を公開する。load/saveは対応gateで待ち、成功時だけ状態を変える。

- [ ] 既存Gemmaテストの全コンストラクタへ明示的な `InMemoryConversationMemoryStore()` を注入する。サービス単体の実機テストもこの段階で非永続ストアを注入し、意図せず本番記憶に触れないようにする。live内のGemma生成にもこのTaskでは同じインメモリストアを注入してビルドを維持し、ファイル保存の有効化はTask 5のUI接続と同時に行う。
- [ ] 以下のテストを追加しREDを確認する。`drain` は同テストファイルで定義し、ストリームの終端まで消費する。

```swift
private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws {
    for try await _ in stream {}
}
func testNewServiceRestoresSavedTurns() async throws {
    let store = InMemoryConversationMemoryStore()
    let first = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
    try await drain(first.streamReply(to: "好きな飲み物はほうじ茶"))
    let runtime = RecordingGemmaRuntime()
    let second = GemmaConversationService(runtime: runtime, memoryStore: store)
    try await drain(second.streamReply(to: "何が好きだった？"))
    let configs = await runtime.configurations
    XCTAssertEqual(configs.first?.history.map(\.prompt), ["好きな飲み物はほうじ茶"])
}
```

- [ ] `GemmaConversationMemory` を切り出し、既存rawTokens/retentionStartを維持。snapshotから再構築するときprompt/responseをtokenizerで再計数し、要約も512以下を検査する。過大要約を黙って切らずinvalidDataで復元を止める。12Kに対する最終判定は既存テンプレート込みチェックで行う。
- [ ] 準備状態/一つの準備Task/現在の状態/購読者をサービスに追加。`prepareMemory()` は同時呼び出しを同じTaskへ合流させ、復元成功後の呼び出しはno-op。load不在は空でready、load失敗はrestoreFailed。初回のstreamReply/classifyからも準備を必ず通す。
- [ ] `memoryUpdates()` は購読者ごとに新しいAsyncStreamを作り、登録と現在値yieldを同じactor呼び出し内で実施する。onTerminationで購読者を除去する。複数UIやテスト購読者でイベントを取り合わない。観測タスクはサービスを永遠に保持しない。
- [ ] 既存 `control.finish()` による成功確定後、memoryを更新しrevisionを増やす。activeを残したままsnapshot保存をawaitし、成功ならready、失敗ならunsaved。保存失敗でストリームをthrowしない。旧世代を再度メモリへ戻さない。
- [ ] `ConversationMemoryManaging` へ適合させる。このTaskの `forgetConversation()` は準備/推論/保存が進行中ならmodelBusy、アイドル時はforgettingを最初のawait前に設定してclear→RAMとsessionの消去→readyとする。clear失敗はforgetFailedを保持する。Task 4で進行中の操作を安全に待つ動作へ拡張する。
- [ ] `retryMemoryOperation()` はunsavedなら最新snapshot保存、restoreFailedなら準備再試行、forgetFailedならforgetConversationを再実行、ready/unsupportedならno-op。実行中の推論と競合した場合はmodelBusyとし、後で再試行可能にする。
- [ ] 保存再試行Taskもサービスが追跡し、推論と相互排他にする。キャンセル済み推論を待つ既存処理に「確定後の保存待ち」が含まれるようにする。字幕の終端/activeの解放より前に保存状態を通知する。
- [ ] 次の独立した振る舞いをテストする: summaryを含む復元、二重prepareのloadCount=1、保存失敗後も返答成功、再試行で最新内容保存、停止が確定前なら保存なし/確定後なら保存完了、summary成功後の返答失敗で旧snapshot維持、classifierの結果非保存、復元失敗後の返答拒否、8K超え復元後の既存要約経路。
- [ ] 全Gemma単体テストをGREENにしてコミットする: `Restore and save committed Gemma conversation memory`。

## Task 4: 忘却と非同期処理の競合を閉じる

**Files:** `GemmaConversationService.swift`、`GemmaMemoryPersistenceTests.swift`、`MemoryStoreFake.swift`。

**Consumes:** Task 3の準備/推論/保存Taskと状態通知。

**Produces:** `forgetConversation() async throws` の進行中操作との直列化、既存 `reset() async` の忘却への集約、forgetFailedからの再試行と多重呼び出しの保証。

- [ ] 保存gateを使う以下のテストと、復元gate中の忘却テストを書く。テスト側の `waitForMemoryState(_:_: )` はmemoryUpdatesを終端条件まで消費する関数として定義する。

```swift
private func waitForMemoryState(_ service: GemmaConversationService,
                                _ expected: ConversationMemoryState) async {
    for await state in await service.memoryUpdates() {
        if state == expected { return }
    }
}
func testForgetWaitsForSaveThenRemovesIt() async throws {
    let gate = ConversationTestGate()
    let store = MemoryStoreFake(saveGate: gate)
    let service = GemmaConversationService(runtime: RecordingGemmaRuntime(), memoryStore: store)
    let turn = Task { try await self.drain(service.streamReply(to: "覚えて")) }
    await gate.waitUntilEntered()
    let forgetting = Task { try await service.forgetConversation() }
    await waitForMemoryState(service, .forgetting)
    let clearsBeforeSave = await store.clearCount
    XCTAssertEqual(clearsBeforeSave, 0)
    await gate.open()
    _ = try? await turn.value
    try await forgetting.value
    let snapshot = await store.snapshot
    XCTAssertNil(snapshot)
    let runtime = RecordingGemmaRuntime()
    let restored = GemmaConversationService(runtime: runtime, memoryStore: store)
    try await drain(restored.streamReply(to: "こんにちは"))
    let configs = await runtime.configurations
    XCTAssertTrue(configs.first?.history.isEmpty == true)
}
```

- [ ] `GemmaMemoryPersistenceTests` を実行し、旧保存が復活する/忘却境界が欠けていることによるREDを確認する。
- [ ] forgetは最初のawait前に専用Taskとゲートを登録し、プロセス内のoperationEpochを増やす。新規推論/準備/再試行はゲートで拒否する。多重forgetは同じTaskに合流させる。
- [ ] cancellation.cancel→進行中推論の終端→準備/保存再試行Taskの完了→store.clearの順にjoinする。forgetが待つTaskからforgetをawaitしない。epochが古い完了はreadyやRAMの復元を発行しない。すでに始まった保存の実I/Oは最後まで待ってから削除する。
- [ ] clear成功後だけreplySessionをclose、memoryとrevisionを初期化、状態をreadyへ。operationEpochは初期化しない。clear失敗はforgetFailedを維持し、新規推論を拒否。retryで同じ忘却を完了させる。
- [ ] `reset()` はforgetを呼び、throwできない失敗をforgetFailed状態として残す。AFM実装は変更しない。
- [ ] 復元中/summary中/ネイティブdrain中/保存再試行中/多重forget、削除失敗→再試行、reset失敗→返答拒否のテストを加える。待機にはgate/state購読を使い、固定sleepを使わない。
- [ ] 全GemmaテストをGREENにしてコミットする: `Serialize forgetting with memory loading and persistence`。

## Task 5: 通常アプリへ保存状態と忘却操作を接続する

**Files:** `ConversationDependencies.swift`、`ConversationViewModel.swift`、`ConversationAppCoordinator.swift`、`ConversationViewState.swift`、`ConversationView.swift`、`OnboardingView.swift`、`ListeningControl.swift`。新規 `ConversationMemoryPresentation.swift`、`ConversationMemoryIntegrationTests.swift`、`ConversationMemoryPresentationTests.swift`。既存 `ConversationFakes.swift`、`AppCompositionTests.swift`、`GemmaAppDeviceTests.swift`。

**Interfaces:**

```swift
// ConversationDependencies
let memory: any ConversationMemoryManaging
// initの追加引数の既定値はUnsupportedConversationMemoryManager()
// liveは同じgemmaをreply/classifier/modelAvailability/memoryに注入する。
static func live(memoryStore: (any ConversationMemoryStore)? = nil) -> Self

// ConversationViewState: 既存state生成処理から独立して保持
var memoryState: ConversationMemoryState = .unsupported
var showsForgetConfirmation: Bool = false
var memoryNotice: String? = nil

// ConversationActions: 既存preview/fakeへの互換性のため空closureを既定値にする
var requestForget: () -> Void = {}
var cancelForget: () -> Void = {}
var confirmForget: () -> Void = {}
var retryMemory: () -> Void = {}

// ConversationViewModelの公開操作
func requestForgetConversation()
func cancelForgetConversation()
func confirmForgetConversation() async
func retryMemoryOperation() async
```

`ConversationMemoryPresentation` は `init(state: ConversationMemoryState)`、`message: String?`、`blocksConversation: Bool`、`canRetry: Bool`、`supportsForget: Bool` を提供する。保存警告とUIの最後の削除完了メッセージを混ぜない。

- [ ] ViewModel harnessへmemory依存の注入を追加する。新しい `FakeConversationMemoryManager` はstateを持ち、prepare失敗/forget失敗/遅延を制御し、updates購読者へ通知する。既存harnessはunsupportedで従来順序を維持する。
- [ ] 表示方針のテストを書く。

```swift
func testUnsavedMemoryDoesNotBlockConversation() {
    let value = ConversationMemoryPresentation(state: .unsaved)
    XCTAssertFalse(value.blocksConversation)
    XCTAssertTrue(value.canRetry)
    XCTAssertEqual(value.message,
        "会話を保存できませんでした。アプリを閉じると、最新の会話を忘れることがあります")
}
func testRestoreFailureBlocksConversation() {
    let value = ConversationMemoryPresentation(state: .restoreFailed(.invalidData))
    XCTAssertTrue(value.blocksConversation)
    XCTAssertTrue(value.supportsForget)
}
```

- [ ] `ConversationMemoryPresentationTests` と統合テストでREDを確認する。統合テストは音声/文字の両方でprepare失敗時にreplyもマイクstartも呼ばれないこと、保存警告でも次の会話が成功することを検証する。
- [ ] liveでファイルストアを有効にする前に、既存Gemma実機テストの `ConversationDependencies.live()` を専用temporaryDirectoryのファイルストア注入へ変更する。AppCompositionの準備を伴うテストも実ファイルを使わない。非throwing live内でdefaultDirectory取得に失敗した場合は、同じファイルに定義する `UnavailableConversationMemoryStore`（loadはreadFailed、saveはwriteFailed、clearはdeleteFailedをthrow）を注入し、RAM保存へ黙ってフォールバックしない。
- [ ] ViewModelの音声preflightはavailability成功後・音声準備/activateより前にprepareMemoryをawait。文字経路もavailability後・prewarm/speakerより前に追加する。各await後に既存のlifecycleGeneration/turnIDとTask cancellationを確認する。
- [ ] 記憶エラーは一般のmodelGenerationFailedへ変換せず、状態を取得して停止/専用回復表示にする。UI更新購読は一度だけ登録し、shutdownでキャンセルして待つ。readyへの通知だけで会話開始やマイク再開を行わない。
- [ ] `transition` と `publish` はmemoryState/confirmation/noticeを消さない。特に `viewState = .failed(...)` の前後でこれらを保持する。入力可否はphaseとblocksConversationを両方見る。初回unprepared/loadingは準備フローに入れるが重複入力を拒否する。
- [ ] requestForgetは確認を表示するだけ。confirmForgetは二重操作を防ぎ、既存pause処理で入力/音声/ターンを止め、memory.forgetConversationをawait。成功でcaption/provisionalTranscript/typedText/聞き返し/engagementを消し、pausedを表示。失敗でもpausedを維持する。シーンが非アクティブになっても削除は途中放棄せず、音声再開しない。
- [ ] Coordinatorに新しいactionを接続する。削除はscene操作のキャンセルでディスク削除を中断しないサービス所有Taskとし、古いUI操作の完了が新しい画面状態を上書きしないことを検証する。
- [ ] SwiftUIの補助Menuと確認ダイアログを接続する。

```swift
Button("会話を忘れる", role: .destructive, action: actions.requestForget)
// confirmationDialogのBinding setterでfalseならactions.cancelForgetを呼ぶ。
// ダイアログ内:
Button("削除する", role: .destructive, action: actions.confirmForget)
Button("キャンセル", role: .cancel, action: actions.cancelForget)
// message:
Text("このiPhoneに保存した会話の記憶を削除します。元には戻せません。")
```

- [ ] 起動画面にspecの保存説明、通知カードに保存再試行/復元再試行を追加する。復元失敗時にもMenuから忘却可能にする。VoiceOverはmemoryメッセージが変わったときだけ通知し、既存の生成字幕更新ごとに繰り返さない。
- [ ] 統合テストに、確認キャンセルでは削除しない、削除成功で画面の文が消える、失敗で完了メッセージなし、background中削除、warningが通常エラーやpauseをまたいで維持される、AFM経路の非表示を追加する。
- [ ] UI/統合/サービスのテストをGREENにしてコミットする: `Expose persistent conversation memory and forgetting in the app`。

## Task 6: 再起動を含む実機検証とドキュメント

**Files:** `CatRobotTests/Device/GemmaAppDeviceTests.swift`、`ConversationDependencies.swift`（DEBUG専用の保存先分離）、`README.md`、新規 `docs/validation/2026-09-23-conversation-memory-persistence.md`。必要なテストscheme変更は `scripts/generate_project.rb` 経由。

**Consumes:** Task 1〜5の完成したlive構成と注入可能なストア。

**Produces:** 自動実機テスト、プロセスを終了/起動した通常UIの証跡、通常テスト結果、利用者向け説明。

- [ ] 実機テストで専用ディレクトリへ短い訂正会話を保存し、別サービスインスタンスで復元する。自動要約後の再構築も既存の長会話fixtureで検証する。ファイル内テキストの一致とモデルの想起回答を別々に記録する。
- [ ] 実機テストでcold-loadの所要時間と各saveの所要時間、保護/バックアップ除外属性を測定する。ログは成功/失敗・所要時間・revisionのみ。合成データの想起回答はテストartifactに限定する。
- [ ] 本当のプロセス終了/再起動を安全に確認するため、DEBUGビルドだけで `CATROBOT_MEMORY_TEST_ID` という環境変数を読み取れるようにする。値はUUIDのみ許可し、保存先をApplication Support配下の `CatRobot/DeviceMemoryTests/<UUID>` に固定する。明示的にstoreが注入されていればそれを優先。無効値は `UnavailableConversationMemoryStore` を注入して記憶の準備失敗として停止し、本番保存先へフォールバックしない。Releaseではこの分岐をコンパイルしない。

```swift
// DEBUG環境変数の値の検証。自由なパスを受け取らない。
func memoryTestID(from environment: [String: String]) throws -> UUID? {
    guard let value = environment["CATROBOT_MEMORY_TEST_ID"] else { return nil }
    guard let id = UUID(uuidString: value) else { throw ConversationMemoryError.invalidData }
    return id
}
```

- [ ] `memoryTestID` の有効/無効/未指定をテストし、異なるUUIDが本番ディレクトリと交差しないことを検証する。DEBUG用注入は利用者向け設定画面には出さない。
- [ ] 全通常テストと生成の決定性を確認する。全テスト結果を保存し、新規失敗は原因を修正してから実機へ進む。
- [ ] 接続を確認し、必要な時点でiPhone 16 ProのUSB接続とロック解除を依頼する。モデル配置済みなら再ダウンロード/再転送しない。

```bash
xcrun devicectl list devices
scripts/run_gemma_app_test.sh 00008140-000610311A90801C
```

- [ ] DEBUG通常アプリをテストUUID指定で起動し、文字または音声で「好きな飲み物は麦茶」→「訂正、ほうじ茶」と会話する。保存成功後、プロセス終了→同じUUIDで再起動→「好きな飲み物は何？」を確認する。launch環境変数の渡し方は実行時に `xcrun devicectl device process launch --help` で確認する。
- [ ] 同じ隔離された会話で「会話を忘れる」→再起動し、空の記憶を確認する。ロック/バックグラウンドでマイク自動再開がないこと、保存失敗時の再試行を確認する。実機上で全手順ができなければ、未検証を具体的に残す。
- [ ] READMEに保存内容・保存失敗・削除・再起動後の継続・端末バックアップ非収録を記載。「会話ログ保存なし」は「全文ログは保存せず、要約と保持中の確定会話を保存」に更新する。既存の待ち時間/意味品質の制限を削除しない。
- [ ] 検証記録へ環境・テスト件数・計測・再起動/忘却の結果・未検証事項を記載。通常の保存済み記憶を消すcleanupは行わない。
- [ ] コミットする: `Verify memory persistence across device restarts`。

## 完了前の確認

- [ ] specの各節をTask 1〜6へ照合する。特にresetからの永続削除、保存失敗の非致命性、復元失敗時の上書き防止を確認する。
- [ ] 選択した実行方式に従ってコードレビューし、重要な指摘を修正する。テストは変更された挙動に応じて再実行する。
- [ ] `git diff --check`、作業ツリー、変更範囲、最終テスト結果を確認する。
- [ ] ブランチ上の実装完了と実機検証の実施状況を報告する。この計画だけでmainへのマージは行わない。

## 計画のセルフレビュー

- spec 1〜4（目的/方式/形式）→Task 1/2。
- spec 5〜7（責務/保存/復元）→Task 3/5。
- spec 8（忘却）→Task 4/5。
- spec 9〜10（画面/変更範囲）→Task 5。
- spec 11（検証）→各Taskの回帰テストとTask 6。
- spec 12（範囲外）→Global Constraintsと各Taskの変更範囲で維持。
- Review Focusの5項目はそれぞれ所有Taskにテストを割り当てた。
- 同じ保存ストアが複数の本番サービスから並行利用される構成は作らない。再起動テストでも旧サービスの全操作が完了してから新サービスを使う。
