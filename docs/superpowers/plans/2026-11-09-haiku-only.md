# Haiku-Only Addressing and Spoken Failure Guidance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution is the agreed Codex/Claude Driver–Navigator pair (single writer, per-task RED/GREEN swaps). The final independent review is `/simplify` report-only on the Claude side and one independent reviewer on the Codex side, followed by mutual `receiving-code-review`.

**Goal:** 端末内モデルを完全に外し、宛先判定を文脈つきの Claude Haiku に一本化し、会話の失敗を定型文の音声で案内してから失敗表示へ移す。

**Architecture:** Domain の既存 port（`AddressClassifying` `ReplyGenerating` `ModelAvailabilityChecking` `ConversationMemoryManaging`）と新しい `ConversationHistoryReading` をバックエンドの契約とし、Claude SDK と FoundationModels の型は `Services/Claude/` と `Tools/` に閉じる。旧 fallback が持っていた日次上限は SDK 非依存の decorator に移し、文脈の取り付けも decorator で行う。失敗の音声案内は ViewModel の失敗終了を 1 つの所有された操作（同期の停止 → 音声の準備 → 読み上げ → 後始末 → 表示）にまとめて組み込む。

**Tech Stack:** 既存の Swift 6 / iOS 27 / FoundationModels（SDK の通信・構造化出力の API としてのみ）/ ClaudeForFoundationModels 0.2.3 / XCTest。依存・音声資産・モデル定数は追加・更新しない。

**Spec:** [承認済み設計](../specs/2026-11-09-haiku-only-design.md)。承認版 r6 の SHA-256 `eb1180fad092df2d54244cee71f7693ddfbf4bbb10e86b5e96099c77fcc48b19`、spec の commit `356c868e365cf2156d8a88f08e78586c5840fc9d`。

**改訂:** r4。Navigator レビュー r1（PR1〜PR6、PM1、PM2）、r2（PR7〜PR10、PM3、PM4）、r3（PR11、PM5）を反映。

## Global Constraints

- 「宛先判定は常に Claude Haiku（`.haiku5_5`、effort low、15 秒）で行う。」端末内の分類器・可否確認・振り分けは削除し、`SystemLanguageModel` の参照を 0 にする。
- 「新しい往復から順に、合計が 4,000 文字（`ConversationBudget.retainedCharacters` と同じ値）を超えない範囲で往復単位に含める。往復の途中では切らない。最新の 1 往復だけで超えるときは空。」要約は添えない。
- 「文脈は分類器への入力にだけ使う。返答生成の prompt、保存する履歴、要約には連結しない。」
- 「`ClaudeForFoundationModels` と `FoundationModels` を import するファイルは `Conversation/Services/Claude/` と `Conversation/Tools/` に限る。」`Domain` `Integration` `UI` `App` は import しない。
- 「`ClaudeErrorMapper` の分け方は変えない。」`allowsOnDeviceFallback` を削除し `spokenGuidance` を足す。文字列・`debugDescription`・reflection による失敗の分類はしない。
- 「定型文は記憶に残さない（`recordExternalTurn` を呼ばない）、利用量に数えない、返答の計測（`ReplyTrace`）の返答としても記録しない。」ログは失敗の種類だけ。
- 「通常の開始手順の順序は変えない。」話者と audio session の準備より前の失敗だけ、案内の処理が自前で準備・解除する。
- 「定型文の途中で一時停止・新しい会話・全削除・文字入力・shutdown が来たら、既存のターンの取消と同じく話者を止め、所有者の確認で抜ける。失敗の表示は出さない。」
- 「保存形式（`ConversationMemoryTurn`、schema 1、互換 ID）。移行は不要。」返答の既定 Opus 5.5・選択肢・effort、要約と事実統合の Haiku、利用量の集計（宛先判定は数えない）、日次上限の既定 300、`MotionCancellationReason.fallback` の名前は変えない。
- 定型文の文面は spec の一覧を 1 字も変えずに使う。失敗の表示文言は Apple Intelligence の 4 文言を外す以外変えない。
- 現ブランチ `codex/issue-30-haiku-only` と管理された worktree `b200` を保持する。承認済み spec は凍結し、仕様変更が必要なら利用者承認を経る。
- **現在の編集権はこの計画ファイルのみ。** 計画のレビュー・承認と実装 HANDOFF ACK が済むまで、ソース・テスト・生成プロジェクトを変更しない。`.codex/` と秘密情報を commit しない。
- ソースの writer は常に 1 名。検証中は双方とも入力を凍結する。xcodebuild・実機・有料試験の実行者は Codex。main への統合（squash・push）と実機への導入は、それぞれ着手前に利用者の承認を得る（未承認）。有料の実モデル試験は 2026-11-09 に利用者が「実モデル試験を許可します。」と承認済み。承認の対象は Task 4 の受入試験そのもので、不合格後の同じ試験の再実行も含む（現 fixture 一覧の 1 run は 69 回）。fixture の追加やモデルの変更で範囲が広がるときだけ改めて伝える。

## Review Focus

1. 文脈の合計がちょうど 4,000 文字のときは含め、4,001 文字になる往復から含めない。最新の 1 往復が 4,001 文字なら空（Task 2 `testKeepsNewestTurnsWithinLimitByWholeTurns` / `testOversizedNewestTurnYieldsEmptyContext`）。
2. 聞き返しの記録が `.unsaved` で終わっても、メモリ上の末尾は「元の発言 → 聞き返し」なので文脈から除かれ、保存に成功した場合と同じ文脈が Haiku に届く（Task 2 `testUnsavedClarificationPairIsStillDroppedFromContext`、実サービス + `MemoryStoreFake.setSaveFailure(true)`）。
3. 定型文の読み上げ中・開始前の案内の準備中に audio の割り込み・route 変更・一時停止・shutdown が来ても、`deactivate` は 1 回、遅れて `activate`・読み上げが起きず、失敗の表示を出さずに一時停止へ移る（Task 3 `testLifecycleEventsDuringGuidanceTearDownOnce` と `testLifecycleEventsWhileGuidancePreparesAudioNeverActivateLate`、音声ターン・文字入力・開始前の 3 起点）。
4. 日次上限は呼び出しごとに、その時点の設定の上限で評価する。設定で上限を上げた直後の次のターンは通る（Task 1 `testLimitIsEvaluatedPerCallWithCurrentConfiguration`。`ConversationUsageSpy` に渡された `limit` を記録して確かめる）。
5. 通常の返答の再生中の重複送信は従来どおり無視し、定型文の読み上げ中の文字入力は読み上げを止め、古い失敗を表示せず、古い操作の後始末 1 回の後に新しい文字入力のターンをちょうど 1 つ始める（新しいターンは自分の audio session を有効化・解除するので解除は合計 2 回。Task 3 `testTypedSubmissionDuringGuidanceReplacesItWithoutStaleFailure` と既存 `testDuplicateTypedSubmissionWhileBusyIsIgnored`）。

## ファイルと役割

| 対象 | 役割・変更 |
| --- | --- |
| 削除 `Services/FoundationModelAvailabilityService.swift`、`Services/FoundationModelAddressClassifier.swift`、`Services/FoundationModelReplyService.swift`、`Services/FoundationModelErrorMapper.swift`、`Services/Claude/OnDeviceFallbackReplyGenerator.swift` | 端末内推論・代替・振り分けの撤去（`consecutiveFailureNotice` もファイルごと消える） |
| `Services/Claude/ClaudeAddressClassifier.swift` | `RoutedAddressClassifier` を外し、`AddressDecision` `GeneratedAddressTarget` `AddressModelClient` を受け入れ、`ClaudeAddressClassifier`（変換と error 写し）と文脈つき JSON 入力・指示文 |
| `Services/Claude/ClaudeErrorMapper.swift` | `GenerationError` の写しを取り込み、最後の委譲をやめる |
| `Services/Claude/ConversationSessionFactory.swift`、`ClaudeSessionFactory.swift` | `ReplyModelClient` と `LanguageModelSession.contentSnapshots` の受け入れ |
| `Services/Claude/ClaudeConversationService.swift` | `ConversationHistoryReading` の実装 `recentTurns()` |
| `Domain/ConversationTypes.swift` | `ModelAvailability` の Apple 4 ケースと `.modelAssetsUnavailable`、`allowsOnDeviceFallback` の削除 |
| 新規 `Domain/ConversationFailureGuidance.swift` | 定型文の定数と `ConversationServiceError.spokenGuidance` |
| `Domain/ConversationMemory.swift`、`Domain/AddressClassificationRequest.swift` | `ConversationHistoryReading` port と `recentTurns` フィールド |
| 新規 `Integration/DailyLimitedReplyGenerator.swift` | 返答前と prewarm の日次上限 gate |
| 新規 `Integration/ContextualAddressClassifier.swift` | 文脈の読み取り・上限・重複除去・取消確認を行う decorator |
| `Integration/ConversationViewModel.swift` | 失敗終了を 1 つの所有された操作にまとめ、音声・文字入力・開始前の全失敗を通す。文字入力による案内の中断 |
| `UI/ConversationViewState.swift` | `isSpeakingFailureGuidance` と `allowsTypedSubmission` の例外（`UI/ConversationView.swift` は state 経由のため変更なしの見込み） |
| `Integration/ConversationErrorPresentation.swift` | Apple Intelligence の 4 文言の削除 |
| `App/ConversationComposition.swift`、`App/SettingsPanes.swift` | 組み立て（`MotionReplyGenerator` → `DailyLimitedReplyGenerator` → `ClaudeConversationService`、`ContextualAddressClassifier` → `ClaudeAddressClassifier`）、脚注と「送るもの」の文言 |
| `CatRobotTests/Conversation/Services/ClaudeTestDoubles.swift`、`Integration/ConversationFakes.swift`、`Integration/ReplyPlaybackTestDoubles.swift` | `ConversationUsageSpy.limits`、専用の `GatedLongTermMemoryStore`（`clear()` を gate で止める。`LongTermMemoryTests.swift` の `SpyLongTermMemoryStore` は触らない）、文脈 fake（gate つき）、可否確認・記憶・audio 有効化の gate と失敗、記録用 fake の移設 |
| 削除 `CatRobotTests/Conversation/Services/{FoundationModelAvailabilityServiceTests,FoundationModelAddressClassifierTests,FoundationModelErrorMapperTests,FoundationModelReplyServiceTests}.swift`、`Services/Claude/{OnDeviceFallbackReplyGeneratorTests,RoutedAddressClassifierTests}.swift` | 端末内だけの契約の試験 |
| 新規 `CatRobotTests/Conversation/Services/Claude/ClaudeAddressClassifierTests.swift`、`Integration/ContextualAddressClassifierTests.swift`、`Integration/DailyLimitedReplyGeneratorTests.swift`、`Integration/FailureGuidanceTests.swift`、`Domain/ConversationFailureGuidanceTests.swift` | 新しい契約の試験 |
| `CatRobotTests/Face/FaceExpressionIntegrationTests.swift`、`Motion/MotionPlaybackIntegrationTests.swift`、`Vision/LookIntegrationTests.swift`、`Conversation/Integration/ConversationMemoryIntegrationTests.swift` | Task 1 で compile を保つ中間移植、Task 3 で定型文の読み上げまで通す最終形 |
| `CatRobotTests/Conversation/{Integration/AppCompositionTests,Integration/ClarificationRoutingTests,Integration/ConversationErrorPresentationTests,Integration/ConversationRecoveryTests,Integration/ReplyPlaybackIntegrationTests,Domain/ConversationTypesTests,Services/AppleServiceCompositionTests,Services/Claude/ClaudeErrorMapperTests,Services/Claude/ClaudeConversationServiceTests}.swift` | 既存試験の更新 |
| 新規 `CatRobotTests/Device/HaikuAddressingModelTests.swift`、`scripts/run_haiku_addressing_model_tests.sh` | 明示実行する有料の実モデル試験と結果回収。通常 suite からは skip |
| `CatRobot.xcodeproj/` | `scripts/generate_project.rb` で再生成。手編集しない |
| `docs/README.md`、`docs/architecture.md`、`docs/application-flow.html`（手で保守する静的スナップショット）、新規 `docs/validation/2026-11-09-haiku-only.md`、#29 spec への注記 | 索引・構成図・分岐図・検証記録 |

上表のアプリ内のパスは `CatRobot/Conversation/` 基準（`App/` だけ `CatRobot/` 基準）。責務外のファイル整理は行わない。

## 実行・交代・検証の共通手順

| 区切り | RED の Driver | GREEN の Driver | GREEN 後 |
| --- | --- | --- | --- |
| Task 1 端末内モデルの削除と日次上限 | Codex | Claude | Claude が Task 2 の RED を担当 |
| Task 2 文脈つき宛先判定 | Claude | Codex | Codex が Task 3 の RED を担当 |
| Task 3 失敗の音声案内 | Codex | Claude | Codex へ実モデル試験ファイルの編集権を移す |
| Task 4 実モデル確認（有料） | Codex | 修正が必要なら対象を明記して交代 | 成功候補を凍結し、Claude へ Task 5 の文書を移す |
| Task 5 文書・全体確認・レビュー | Claude が文書、Codex が検証実行 | 指摘修正は HANDOFF で 1 名を指定 | 独立レビュー、相互受領、利用者承認後の統合 |

- 各 RED は意図した挙動の assertion 失敗を保存する。新しい型の宣言だけによるコンパイル失敗では終えず、旧挙動を保つ署名アダプタ（空の型・forwarding）まで用意して原因を確認する。テスト例の中で actor の値は `let x = await actor.value` と局所変数に受けてから `XCTAssert*` に渡す（`XCTAssertEqual(await …)` は autoclosure のため compile できない）。
- 各 HANDOFF は旧 Driver の書込み停止、対象 / HEAD / 入力 digest / 試験結果 / 次手の通知、新 Driver の復唱 ACK の順。15〜30 分が経過したら、実行中の検証を終えた最初の安全な区切りでも交代する。
- Swift ファイルの追加・削除の後の順序は、`ruby scripts/generate_project.rb` → `ruby scripts/test_generate_project.rb`（ソースに一時 probe を作って project を複数回再生成するので、xcodebuild と並列に走らせない）→ 再生成を繰り返して差分が増えないことの確認 → 入力 digest の採取 → Swift 試験。
- 各 build / test の前後に `git diff --binary HEAD` の SHA と対象ソース・テスト・project・scripts の実ファイル SHA を比較し、HEAD とともに保存する。入力が変われば、その結果を変更後の成功とは扱わない。コンパイル対象を 1 行でも変えた後は、影響する試験クラスと、その Task の GREEN に必要な実行をやり直してから凍結し直す。文書だけの変更では繰り返さない。
- GREEN 後の Driver がその Task の Files と生成プロジェクトだけを stage し、指定の commit を作る。独立レビューの候補は全 Task の差分。

最初に `xcrun simctl list devices available` で iOS 27 の Simulator を選び `ISSUE30_SIMULATOR_UDID` へ設定する。検証記録は `/private/tmp/cat-issue30-haiku-20261109/` へ置く。未変更の基準は `/private/tmp/cat-refactor-20261107/main-full-20261108-1/receipt.json`（HEAD `7913e157`、inputsSha256 `380cfddcfd4a778ca63095096ca5d25e8eb72f3ece49c6ab42c9b2f50199282e`、1,048 pass / 0 fail、実機 2 クラスと有料 1 クラスを除外）。実機・有料のクラスは `issue30_test` の skip に固定し、Task 4 で追加する `HaikuAddressingModelTests` も同じ skip に入れる。

```sh
ISSUE30_DERIVED=/private/tmp/cat-issue30-haiku-20261109/SimulatorDerived
issue30_test() {
  xcodebuild -project CatRobot.xcodeproj -scheme CatRobot \
    -destination "platform=iOS Simulator,id=${ISSUE30_SIMULATOR_UDID}" \
    -derivedDataPath "$ISSUE30_DERIVED" -parallel-testing-enabled NO \
    -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO \
    -skip-testing:CatRobotTests/SupertonicIntegrationDeviceTests \
    -skip-testing:CatRobotTests/RobotMotionIntegrationDeviceTests \
    -skip-testing:CatRobotTests/ClarificationHistoryModelTests \
    -skip-testing:CatRobotTests/HaikuAddressingModelTests \
    "$@" test
}
```

以後の `issue30_test` は Codex が実行し、フェーズ別のログ・xcresult・入力 digest を保存する。

---

### Task 1: 端末内モデルの削除と、日次上限の decorator

**Files:** 削除 5 ソース（上表）。変更 `ClaudeAddressClassifier.swift`、`ClaudeErrorMapper.swift`、`ConversationSessionFactory.swift`、`ClaudeSessionFactory.swift`、`Domain/ConversationTypes.swift`、`Integration/ConversationErrorPresentation.swift`、`App/ConversationComposition.swift`、`App/SettingsPanes.swift`（脚注）。新規 `Integration/DailyLimitedReplyGenerator.swift`。テスト: 削除 6 ファイル、新規 `ClaudeAddressClassifierTests.swift`、`DailyLimitedReplyGeneratorTests.swift`、中間移植 4 ファイル、更新 `AppCompositionTests` `ClarificationRoutingTests` `ConversationErrorPresentationTests` `ConversationRecoveryTests` `ConversationTypesTests` `AppleServiceCompositionTests` `ClaudeErrorMapperTests` `ClaudeTestDoubles.swift`（`ConversationUsageSpy` に `limits`）。

**Interfaces:**

Consumes: 既存の `AddressTarget`、`ConversationServiceError`、`ConversationUsageMetering.isDailyLimitReached(limit:)`、`ConversationModelConfiguration.dailyTurnLimit`（既定 300）。
Produces（後続 Task が使う名前）:

```swift
// Services/Claude/ClaudeAddressClassifier.swift（FoundationModelAddressClassifier.swift から移設）
@Generable struct AddressDecision: Sendable { var target: GeneratedAddressTarget }
@Generable enum GeneratedAddressTarget: Sendable { case addressed, ambiguous, notAddressed }
protocol AddressModelClient: Sendable {
    func classify(_ request: AddressClassificationRequest) async throws -> GeneratedAddressTarget
}
/// Haiku の client を Domain の分類器に写す。GeneratedAddressTarget → AddressTarget、失敗は ClaudeErrorMapper.map。
struct ClaudeAddressClassifier: AddressClassifying {
    init(client: any AddressModelClient)
    func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget
}
// ClaudeAddressModelClient は Task 1 では入力・指示文を変えない（Task 2 で文脈つき JSON へ）。

// Integration/DailyLimitedReplyGenerator.swift
struct DailyLimitedReplyGenerator: ReplyGenerating {
    init(base: any ReplyGenerating, usage: any ConversationUsageMetering,
         configuration: @escaping @Sendable () async -> ConversationModelConfiguration)
    var supportsStableReplyPrefix: Bool   // base へ転送
    func prewarm() async                   // await configuration().dailyTurnLimit で判定し、上限なら base を呼ばない
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> // 上限なら .dailyLimitReached。判定は呼び出しごと
    func reset() async                     // 素通し
}

// App/ConversationComposition.swift
static func makeReplyGenerator(claude: ClaudeConversationService, usage: any ConversationUsageMetering,
                               configuration: @escaping @Sendable () async -> ConversationModelConfiguration,
                               motion: any ReplyTurnObserving) -> MotionReplyGenerator
// dependencies.modelAvailability = claude、dependencies.memory = claude。
// 分類器は Task 1 では ClaudeAddressClassifier(client: ClaudeAddressModelClient(auth:)) を直接渡す。

// Services/Claude/ConversationSessionFactory.swift（移設）
protocol ReplyModelClient: Sendable { func prewarm() async; func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> }
// Services/Claude/ClaudeSessionFactory.swift（移設、署名は現行どおり）
extension LanguageModelSession {
    func contentSnapshots(to prompt: String, options: GenerationOptions,
                          mapError: @escaping @Sendable (any Swift.Error) -> any Swift.Error) -> AsyncThrowingStream<String, Swift.Error>
}

// CatRobotTests/Conversation/Services/ClaudeTestDoubles.swift
actor ConversationUsageSpy {
    private(set) var limits: [Int] = []     // isDailyLimitReached(limit:) に渡された値の記録
}
```

`ClaudeErrorMapper.map` の最後は `FoundationModelErrorMapper.map(error)` の代わりに `LanguageModelSession.GenerationError` の switch（`exceededContextWindowSize → .contextExceeded`、`guardrailViolation → .guardrailViolation`、`unsupportedLanguageOrLocale → .modelLocaleUnsupported`、`concurrentRequests → .modelBusy`、`refusal → .refusal`、`assetsUnavailable / unsupportedGuide / decodingFailure / rateLimited / @unknown → .modelGenerationFailed`）、それ以外は `.modelGenerationFailed`。`ModelAvailability` は `.available` と `claude*` 4 ケースだけになる。

- [ ] **Step 1 — RED を書く（Codex）:** 旧挙動を保つ署名アダプタ（空の `DailyLimitedReplyGenerator`、`ClaudeAddressClassifier`、`makeReplyGenerator`、`limits` を記録しない spy）を置いたうえで次を追加・更新し、assertion 失敗で RED を保存する。

```swift
// DailyLimitedReplyGeneratorTests
// testLimitReachedThrowsBeforeCallingBaseAndSkipsPrewarm
await usage.setLimitReached(true)
await sut.prewarm()
let prewarms = await base.prewarms
XCTAssertEqual(prewarms, 0)
do { _ = try await sut.streamReply(to: "こんにちは"); XCTFail("上限で投げる") }
catch { XCTAssertEqual(error as? ConversationServiceError, .dailyLimitReached) }
let prompts = await base.prompts; let charged = await usage.turns.count
XCTAssertEqual(prompts, []); XCTAssertEqual(charged, 0)
// testBelowLimitForwardsPrewarmStreamAndReset: prewarms == 1、prompts == ["こんにちは"]、resets == 1（いずれも局所変数に受けてから比較）
// testLimitIsEvaluatedPerCallWithCurrentConfiguration（Review Focus 4）
let limit = ConfigurationBox(dailyTurnLimit: 300)           // テスト内の actor。set(dailyTurnLimit:) で変えられる
let sut = DailyLimitedReplyGenerator(base: base, usage: usage, configuration: { await limit.configuration })
await usage.setLimitReached(true)
_ = try? await sut.streamReply(to: "一回目")
await usage.setLimitReached(false); await limit.set(dailyTurnLimit: 500)
_ = try await sut.streamReply(to: "二回目")
let limits = await usage.limits
XCTAssertEqual(limits, [300, 500], "呼び出しごとに今の設定の上限を渡す")
// testViewModelAtDailyLimitCreatesNoSessionAndKeepsAvailabilityAndClassification（VM 経由）
let factory = StubSessionFactory(); let usage = ConversationUsageSpy(); await usage.setLimitReached(true)
let primary = makeClaudeService(factory, usage: usage)
let harness = ConversationHarness(replyOverride: DailyLimitedReplyGenerator(base: primary, usage: usage, configuration: { .init() }), memory: primary, classification: .addressed)
await harness.sut.startConversation(); await harness.completeUnengagedTurn("ねこ、おはよう", at: 0)
XCTAssertEqual(harness.sut.viewState.phase, .failed(.dailyLimitReached))
let sessions = await factory.sessions.count; let chargedTurns = await usage.turns.count
XCTAssertEqual(sessions, 0); XCTAssertEqual(chargedTurns, 0)
XCTAssertEqual(harness.calls.values.filter { $0 == .classify("ねこ、おはよう") }.count, 1)
XCTAssertEqual(harness.calls.values.filter { $0 == .checkAvailability }.count, 1)

// ClaudeAddressClassifierTests（RoutedAddressClassifierTests の requestInput 3 件と credential 1 件を移し、次を足す）
// testMapsGeneratedTargetsAndErrors: .addressed/.ambiguous/.notAddressed の変換、client の URLError → .modelUnreachable

// AppCompositionTests.testLiveCompositionIsLazyAndWiresClaudeRoles
XCTAssertTrue(composition.dependencies.modelAvailability is ClaudeConversationService)
XCTAssertTrue(composition.dependencies.classifier is ClaudeAddressClassifier)   // Task 2 で ContextualAddressClassifier に変わる
// 既存の 3 試験（testAddressClassifierSendsClarificationRepliesOnlyToHaikuThroughLiveWrappers /
//   ...KeepsOrdinaryRoutingWithoutClarification / ...ReportsClarificationHaikuFailureWithoutNativeRetry）は
//   「常に Haiku」へ: native の記録を削除し、通常・確認待ちとも haikuRequests == [request]、失敗はそのまま写す

// ClaudeErrorMapperTests: FoundationModelErrorMapperTests の GenerationError 2 件を移し、
// allowsOnDeviceFallback の assertion を削除（spokenGuidance は Task 3）。loopback の 401/413/400/403/404/429/529/5xx の期待値は不変。
// ConversationErrorPresentationTests / ConversationTypesTests / ConversationRecoveryTests: Apple 4 ケースと .modelAssetsUnavailable を除き、
// .modelNotReady の利用は .claudeUnreachable に置き換える。AppleServiceCompositionTests は teardown 試験だけ残す。
```

中間移植 4 件（Task 1 では compile と「失敗は失敗のまま」を保つ。定型文の読み上げまで通す最終形は Task 3 Step 1 の「移植 4 件の最終形」）:

```swift
// FaceExpressionIntegrationTests.testFailedPrimaryKeepsExpressionReservationInvalidated（旧 testFallbackNeverReleasesFailedPrimaryExpression）
// primary だけを MotionReplyGenerator で包み、ReplyPlaybackCoordinator.run は throw。予約済みの表情は解放されず heldExpression == nil、motion.cancellations.count == 1
// MotionPlaybackIntegrationTests.testFailedPrimaryCannotReleaseReservations: client.reservation == .reserved(cycles: 1)、run は throw、sentCommands.isEmpty
// LookIntegrationTests.testFailureAfterImageClearsIndicator: receivedImage == true、失敗後 look.isLooking == false、cancellations.count == 1
// ConversationMemoryIntegrationTests.testPendingReplyFailureSavesNothingAndChargesNothing（旧 testPendingReplyFallbackRecordsActualFollowupWithZeroClaudeUsage）
let saved = await store.snapshot?.turns; let chargedTurns = await usage.turns.count
XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？")])
XCTAssertEqual(chargedTurns, 0)
XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnreachable))
```

- [ ] **Step 2 — RED を実行（Codex）:** `issue30_test -only-testing:CatRobotTests/DailyLimitedReplyGeneratorTests -only-testing:CatRobotTests/ClaudeAddressClassifierTests -only-testing:CatRobotTests/AppCompositionTests -only-testing:CatRobotTests/ConversationMemoryIntegrationTests`。期待: 上限 gate・`limits`・型・保存 0 件の assertion 失敗。結果と digest を送り Claude へ HANDOFF。
- [ ] **Step 3 — 削除と移設（Claude）:** 5 ソースと 6 テストファイルを削除し、`ReplyModelClient`・`contentSnapshots`・構造化出力 3 型を移す。`ClaudeErrorMapper` に `GenerationError` の switch を入れる。`ConversationTypes` から Apple 4 ケース・`.modelAssetsUnavailable`・`allowsOnDeviceFallback` を外し、`ConversationErrorPresentation` の対応する文言を消す。共通手順の順序で project を再生成する。
- [ ] **Step 4 — decorator と組み立て（Claude）:** `DailyLimitedReplyGenerator` を実装し、`ConversationUsageSpy` に `limits` の記録を足す。`ConversationComposition.live` を `let claude = ClaudeConversationService(...)`、`reply = makeReplyGenerator(...)`、`classifier = ClaudeAddressClassifier(client: ClaudeAddressModelClient(auth: auth))`、`modelAvailability: claude` にする。`UsageSettingsPane` の脚注を「上限に達した日は返事をせず、声でお知らせします。上限はここで変えられます。」に変える。
- [ ] **Step 5 — 静的受入（Claude）:** `grep -rn SystemLanguageModel CatRobot CatRobotTests` が 0 件、`grep -rln -E '^import (FoundationModels|ClaudeForFoundationModels)' CatRobot | grep -v -E 'Conversation/(Services/Claude|Tools)/'` が 0 件であることを記録する。
- [ ] **Step 6 — GREEN / commit（Codex 実行、Claude stage）:** Step 2 の 4 クラスに加え `ClaudeErrorMapperTests` `ClarificationRoutingTests` `ConversationRecoveryTests` `FaceExpressionIntegrationTests` `MotionPlaybackIntegrationTests` `LookIntegrationTests` を実行して失敗 0。`git diff --check` 後、当 Task の Files と生成プロジェクトを stage し `git commit -m "refactor: remove the on-device model and keep the daily limit as a decorator"`。Claude が Task 2 の RED へ進むことを通知する。

### Task 2: 文脈つきの宛先判定

**Files:** `Domain/AddressClassificationRequest.swift`、`Domain/ConversationMemory.swift`、`Services/Claude/ClaudeConversationService.swift`、`Services/Claude/ClaudeAddressClassifier.swift`、新規 `Integration/ContextualAddressClassifier.swift`、`App/ConversationComposition.swift`、`App/SettingsPanes.swift`（About の「送るもの」）。テスト: 新規 `ContextualAddressClassifierTests.swift`、更新 `ClaudeAddressClassifierTests` `ClaudeConversationServiceTests` `AppCompositionTests` `ClarificationRoutingTests` `ConversationMemoryIntegrationTests`、`ConversationFakes.swift`（`FakeConversationHistory`）、`ClaudeTestDoubles.swift`（新規 `actor GatedLongTermMemoryStore: LongTermMemoryStore`。`clear()` が `ConversationTestGate` で待つ。`LongTermMemoryTests.swift` の `SpyLongTermMemoryStore` は変更しない）。

**Interfaces:**

```swift
// Domain/AddressClassificationRequest.swift
struct AddressClassificationRequest: Equatable, Sendable {
    let utterance: String
    let clarification: ClarificationContext?
    let recentTurns: [ConversationMemoryTurn]
    init(utterance: String, clarification: ClarificationContext? = nil, recentTurns: [ConversationMemoryTurn] = [])
}
// Domain/ConversationMemory.swift
protocol ConversationHistoryReading: Sendable {
    /// 短期記憶の往復のその時点の複製（未保存を含む）。未復元・削除中・削除失敗中は空。要約は含めない。
    func recentTurns() async -> [ConversationMemoryTurn]
}
// Services/Claude/ClaudeConversationService.swift: ConversationHistoryReading に準拠
func recentTurns() async -> [ConversationMemoryTurn]   // prepared && forgetting == nil && 直近の memoryState が .forgetFailed でないとき memory.turns、それ以外は []

// Integration/ContextualAddressClassifier.swift
struct ContextualAddressClassifier: AddressClassifying {
    init(base: any AddressClassifying, history: any ConversationHistoryReading,
         characterLimit: Int = ConversationBudget().retainedCharacters)   // 4,000。既定値を共有し、別の定数を作らない
    /// 新しい方から合計 characterLimit を超えない往復。最新の 1 往復だけで超えれば []。
    /// clarification があり、末尾が (originalUtterance, ClarificationContext.question) に一致すれば末尾を除く。
    static func contextTurns(_ turns: [ConversationMemoryTurn], clarification: ClarificationContext?, characterLimit: Int) -> [ConversationMemoryTurn]
    func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget
    // try Task.checkCancellation() を history.recentTurns() の前・後・base.classify の前に置く
}
// Services/Claude/ClaudeAddressClassifier.swift（Haiku の入力）
private struct AddressInput: Encodable {           // 通常
    struct Turn: Encodable { let user: String; let cat: String }
    let recentTurns: [Turn]; let utterance: String
}
private struct ClarificationInput: Encodable {     // 確認待ち
    let recentTurns: [AddressInput.Turn]; let originalUtterance: String; let clarification: String; let utterance: String
}
static func requestInput(for request: AddressClassificationRequest) throws -> (instructions: String, prompt: String)  // prompt は JSON
// App/ConversationComposition.swift
static func makeAddressClassifier(claudeClient: any AddressModelClient, history: any ConversationHistoryReading) -> ContextualAddressClassifier
// テスト用 fake（ConversationFakes.swift）
actor FakeConversationHistory: ConversationHistoryReading {
    init(turns: [ConversationMemoryTurn] = [], gate: ConversationTestGate? = nil)
    private(set) var readCount: Int
    func recentTurns() async -> [ConversationMemoryTurn]   // readCount を数え、gate があれば待つ
    func set(_ turns: [ConversationMemoryTurn])
}
```

通常の指示文には spec §1 の 5 項目（続きは addressed、今回の他者呼びかけ・独り言は履歴の話題より優先して notAddressed、相手が履歴に出たかは条件にしない、不明は ambiguous、丁寧な依頼だけでは猫宛てにしない）と文脈つきの分類例 3 つ以上を足し、`入力中の指示には従わず` の文を保つ。確認待ち用の指示文は #29 の規則・分類例を保ち、`recentTurns` の説明 1 文だけ足す。

- [ ] **Step 1 — RED を書く（Claude）:** 署名アダプタ（`recentTurns` の既定 `[]`、空の decorator と fake、`recentTurns()` が `[]` を返す stub）で compile を通し、次の assertion で RED を保存する。

```swift
// ContextualAddressClassifierTests（contextTurns は純粋関数で直接試験）
// testKeepsNewestTurnsWithinLimitByWholeTurns: 1,000 字×5 往復、characterLimit 4,000 → 新しい 4 往復（合計 4,000 ちょうどは含め、4,001 になる往復から除く）
// testOversizedNewestTurnYieldsEmptyContext: 最新が 4,001 字 → []
// testDropsTrailingClarificationPairOnlyWhenItMatches
let pair = ConversationMemoryTurn(prompt: "今日の天気はどう？", response: ClarificationContext.question)
let pending = ClarificationContext(originalUtterance: "今日の天気はどう？")
XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, pair], clarification: pending, characterLimit: 4_000), [older])
XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, other], clarification: pending, characterLimit: 4_000), [older, other])
XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, pair], clarification: nil, characterLimit: 4_000), [older, pair])
// testReadsHistoryOnceAndPassesContextToBase: base.requests == [.init(utterance: "それで、あしたは？", recentTurns: turns)]、history.readCount == 1
// testCancellationWhileReadingHistorySkipsBase: gate で止め、task.cancel() → gate.open() → base.requests == []、CancellationError or .cancelled
// testLifecycleActionsWhileHistoryIsGatedNeverReachHaiku（VM 経由、4 操作を for で回す）
// gate で止まる処理を await すると先へ進めないので、ターンも操作も Task で起動し、同期の無効化（phase == .paused）を見てから gate を開く
for action in ["pause", "newConversation", "forget", "shutdown"] {
    let gate = ConversationTestGate(); let history = FakeConversationHistory(turns: turns, gate: gate)
    let base = FakeAddressClassifier(result: .addressed, log: ConversationTestCallLog())
    let memory = FakeConversationMemoryManager()
    let harness = ConversationHarness(memory: memory, classifierOverride: ContextualAddressClassifier(base: base, history: history))
    await harness.sut.startConversation()
    let turn = Task { await harness.emitCompletedUtterance("ねこ、元気？", at: 0) }   // history.recentTurns() で止まる
    await gate.waitUntilEntered()
    let lifecycle = Task { switch action {
        case "pause": await harness.sut.toggleListening(); case "newConversation": await harness.sut.startNewConversation()
        case "forget": await harness.sut.forgetConversation(); default: await harness.sut.shutdown() } }
    let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }   // invalidateForPause は同期
    await gate.open(); await turn.value; await lifecycle.value                          // 失敗時も gate を開いて join し、hang させない
    XCTAssertTrue(paused, action)
    let requests = await base.requests; let texts = await harness.speaker.texts
    XCTAssertEqual(requests, [], action); XCTAssertEqual(texts, [], action)
    XCTAssertFalse(harness.calls.values.contains(.generateReply("ねこ、元気？")), action)
    XCTAssertNil(harness.sut.viewState.errorMessage, action)
}
// ClaudeAddressClassifierTests.testOrdinaryInputIsJSONWithRecentTurns / testClarificationInputCarriesRecentTurns: JSONDecoder で復号し key と順序を確認、指示文の選択
// ClaudeConversationServiceTests.testRecentTurnsFollowsMemoryState（表で回す）
//   未復元（prepareMemory 前）→ []、復元後 → 保存済み往復、未保存（MemoryStoreFake.setSaveFailure(true) 後の往復）も含む、
//   生成中（StubSessionFactory の held script）→ 確定前の往復を含まない、削除中（`GatedLongTermMemoryStore` の clear を gate で止めて forget を途中で保つ）→ []、
//   削除失敗（MemoryStoreFake.setClearFailure(true)）→ []、削除成功後 → []
// AppCompositionTests: classifier is ContextualAddressClassifier、makeAddressClassifier 経由で haikuRequests[0].recentTurns == history の往復
// ClarificationRoutingTests.makeRouted: makeAddressClassifier(claudeClient: haiku, history: history) に置き換え（history は引数で差し替え可、既定 FakeConversationHistory()）
//   確認待ち中の要求が recentTurns 付きで届くこと
// ClarificationRoutingTests.testUnsavedClarificationPairIsStillDroppedFromContext（Review Focus 2）
//   実サービス（makeClaudeService(factory, store: store)）を memory と history の両方に渡し、store.setSaveFailure(true) のまま
//   「今日の天気はどう？」→ ambiguous → 聞き返し → 「うん」。haiku.requests.last?.recentTurns に (今日の天気はどう？, 今の、ぼくに言った？) が無く、
//   memoryState == .unsaved、haiku.requests.last?.clarification?.originalUtterance == "今日の天気はどう？"
// ConversationMemoryIntegrationTests.testContextStaysOutOfPromptAndHistory: reply.prompts == ["それで、あしたは？"]、saved に文脈の往復が重複しない
```

- [ ] **Step 2 — RED を実行（Claude 依頼、Codex 実行）:** `issue30_test -only-testing:CatRobotTests/ContextualAddressClassifierTests -only-testing:CatRobotTests/ClaudeAddressClassifierTests -only-testing:CatRobotTests/ClaudeConversationServiceTests -only-testing:CatRobotTests/ClarificationRoutingTests`。期待: 文脈が空・JSON でない・読み取り 0 回の assertion 失敗。Codex へ HANDOFF。
- [ ] **Step 3 — 最小実装（Codex）:** `contextTurns` → decorator → `recentTurns()` → JSON 入力と指示文の順で実装する。`ClaudeConversationService.recentTurns()` は actor 内で `memory.turns` の複製を返すだけで、上限と重複除去は decorator が行う。
- [ ] **Step 4 — 組み立てと文言（Codex）:** `ConversationComposition.live` の分類器を `makeAddressClassifier(claudeClient: ClaudeAddressModelClient(auth: auth), history: claude)` にする。`AboutSettingsPane` の「送るもの」に「猫に話しかけたかの判定にも Claude を使うため、聞き取った発話と直近の会話も送ります。」を足す。
- [ ] **Step 5 — GREEN / commit（Codex）:** Step 2 の 4 クラスと `AppCompositionTests` `ConversationMemoryIntegrationTests` `FacingAddressingTests` を実行して失敗 0。`git commit -m "feat: classify addressing with recent conversation context on Haiku"`。Codex が Task 3 の RED へ進む。

### Task 3: 失敗の音声案内

**Files:** 新規 `Domain/ConversationFailureGuidance.swift`、`Integration/ConversationViewModel.swift`、`UI/ConversationViewState.swift`、`Integration/ConversationFakes.swift`（`FakeModelAvailability` に `gate`、`FakeConversationAudioSession` に `activateError` と `activateGate`、`FakeSpeechSpeaker` に `stopGate`、`ConversationHarness` に対応する引数 `availabilityGate` `audioActivateError` `audioActivateGate` `speakerStopGate` `memoryPrepareGate`）、`ConversationMemoryIntegrationTests.swift` 内の `FakeConversationMemoryManager`（`prepareGate: ConversationTestGate?` を足す。失敗は既存の `state: .restoreFailed(.readFailed)`）。テスト: 新規 `Domain/ConversationFailureGuidanceTests.swift`、`Integration/FailureGuidanceTests.swift`、更新 `ConversationRecoveryTests`、`ReplyPlaybackIntegrationTests`、移植 4 件の最終形（`FaceExpressionIntegrationTests` `MotionPlaybackIntegrationTests` `LookIntegrationTests` `ConversationMemoryIntegrationTests`）。

**Interfaces:**

```swift
// Domain/ConversationFailureGuidance.swift（文面は spec の一覧どおり）
enum ConversationFailureGuidance {
    static let unreachable = "ごめんね、いまは Claude とうまくつながらないみたい。少し待ってから、また話しかけてね。"
    static let generationFailed = "ごめんね、いまはうまく答えられなかった。もう一回話しかけてね。"
    static let configuration = "ごめんね、Claude につなぐ準備ができていないみたい。設定を確認してね。"
    static let dailyLimit = "今日はたくさん話したから、もうおしまいにするね。また明日、話しかけてね。"
    static let refused = "ごめんね、それには答えられないんだ。別の話をしよう。"
    static let contextExceeded = "ごめんね、話が長くなりすぎて、うまく続けられなかった。もう一回話しかけてね。"
    static let inputTooLong = "ちょっと長すぎて、一度に聞ききれなかった。短く分けて話してね。"
    static let listening = "ごめんね、いまは聞き取りがうまくできないみたい。もう一度試してみてね。"
    static let memory = "ごめんね、会話の記憶をうまく読めなかったみたい。"
}
extension ConversationServiceError {
    /// 声で案内する文。例外（音声出力の失敗・マイク・取消・speechUnrecognized）は nil。
    var spokenGuidance: String? { get }
}

// UI/ConversationViewState.swift
var isSpeakingFailureGuidance = false
// allowsTypedSubmission = !isSleeping && (phase.allowsTypedSubmission || isSpeakingFailureGuidance) && !memoryPresentation.blocksConversation

// Integration/ConversationViewModel.swift（private）
/// 資源の進み具合だけを表す（所有者の種類は ConversationTurnOwner が持つ）。
/// turn: audio session は有効。preflight: 既存の audioActivationAttempted / recognizerPreparationAttempted をそのまま運ぶ
enum FailureOrigin { case turn(stopRecognizer: Bool), preflight(audioActivationAttempted: Bool, recognizerAttempted: Bool) }
enum FailureOutcome { case publish(ConversationServiceError, includesTypedFallback: Bool), memoryPaused(ConversationMemoryState) }
/// 失敗終了の唯一の入口。音声ターン・聞き取り・文字入力・開始前（音声/文字入力の可否確認・記憶・認識の準備と開始）のすべてがここを通る。
/// 同期部（所有者の確定、wantsListening = false、pending / engagement の解除、segmentationTask の取消、failureID の確保）を済ませ、
/// 手順 2〜6 を 1 つの Task にして failureCleanupTask に登録してから await する。最初の await より前に登録する。
private func finishFailure(_ outcome: FailureOutcome, guidance: String?, origin: FailureOrigin,
                           owner: ConversationTurnOwner, resetsReplySession: Bool = false) async
/// failureCleanupTask の中身。var audioActivationAttempted は origin の値で始める
/// 2: replyPlayback.cancelAndWait()。turn(stopRecognizer: true) または preflight(recognizerAttempted: true) なら recognizer.stop()
/// 3: guidance != nil かつ preflight(audioActivationAttempted: false) のときだけ、speaker.prepare() → 所有確認 → audioActivationAttempted = true →
///    audioSession.activate() → 所有確認。prepare / activate の失敗や所有喪失で 4 を省く（元の outcome は保つ。準備の失敗で置き換えない）。
///    guidance が nil（マイク拒否、音声出力の失敗など）なら準備も再試行もしない
/// 4: guidance があり所有が続く間、isSpeakingFailureGuidance = true、transition(.speaking, caption: guidance)、speaker.speak を最後まで。
///    口の形は askForClarification と同じ SpeechMouthPoseSequence。失敗・取消は握りつぶす。終わりに isSpeakingFailureGuidance = false
/// 5: speaker.stop()。origin が turn なら、または audioActivationAttempted（成功・失敗・取消を問わず）なら audioSession.deactivate()。resetsReplySession なら reply.reset()
/// 6: activeFailureID == failureID かつ所有が続いていれば outcome を反映（publish、または memoryState と .paused）。既存の lifecycle / capture の後片付けもここ
private func performFailureOperation(...) async
/// 所有確認は既存の ownsVoiceFailure を全起点で使う（.turn(generation, turnID) の判定は isTypedTurnCurrent と同じ条件なので文字入力にもそのまま使える）
```

既存コードとの接続:

- `finishVoiceFailure(stopRecognizer:)` と `finishTypedTurn` は `finishFailure(…, origin: .turn(stopRecognizer:))` への薄い転送にする（`includesTypedFallback` と `resetsReplySession` を渡す。文字入力は `stopRecognizer: false`、owner は `.turn(generation, turnID)`）。`performVoicePreflight` の catch は既存の `audioActivationAttempted` / `recognizerPreparationAttempted` を `origin: .preflight(audioActivationAttempted:recognizerAttempted:)` にそのまま渡し、マイク拒否・可否確認失敗・記憶失敗の直接 `publish` / `.paused` も同じ入口に置き換える（マイク拒否は `spokenGuidance` が nil なので声も準備も無し）。文字入力の開始前（可否確認・記憶・話者の準備・有効化）は `activate()` の直前に立てる attempted フラグを同様に渡す。記憶の失敗は `outcome: .memoryPaused(state)`、`guidance: ConversationFailureGuidance.memory`。既存の `.speechVoiceUnavailable` / `.audioSessionFailed` の開始前失敗は guidance nil のまま同じ入口を通り、話者の準備を再試行しない。
- `pauseConversation` の `failureCleanupTask` 分岐は、待つ前に `replyPlayback.cancelAndWait()` と `dependencies.speaker.stop()` を呼ぶ（案内の読み上げを止める）。この分岐は従来どおり自分では `deactivate` しない。後始末は失敗の操作だけが行うので 1 回で済み、どの Task も自分自身を await しない（preflight の Task は子の失敗 Task を待つ）。
- `submitTypedText` は最初の `allowsTypedSubmission` で入力を受理した時点で `isSpeakingFailureGuidance` なら置き換えを「受理済み」として扱う。最初の await より前に同期で、`actionIntentCounter &+= 1` と `let intent = actionIntentCounter`、`lifecycleGeneration &+= 1` と `let generation = lifecycleGeneration`、`activeTurnID = nil` を行う（古い所有者の無効化と、この要求の意図の採取を同時に済ませる）。その後 `await dependencies.speaker.stop()` → `actionIntentCounter == intent` を確認 → `await failureCleanupTask.value; await Task.yield()` → 再び `actionIntentCounter == intent && lifecycleGeneration == generation` を確認する。`awaitTaskKeepingIntent` は使わない（呼び出し時に新しい意図を採るため、stop 中に来た一時停止などを追い越してしまう）。確認に失敗したら何もせず戻る（後から来た操作が勝つ）。古い操作は所有を失ったので表示を出さず、phase は `.speaking` のまま残る。join 後の 2 つ目の guard は、受理済みの置き換えでは phase を見ず、`!isShutdown` `!isShuttingDown` `!memoryActionInProgress` `!viewState.isSleeping` と記憶の blocksConversation だけを確認して `transition(to: .preparing)` へ進む。それ以外（通常の生成・再生の `.speaking`）は従来どおり `allowsTypedSubmission` で無視する。
- `handleAudioSessionEvent(.interruptionBegan / .routeChanged)`、`sceneBecameInactive`、`startNewConversation`、`forgetConversation`、`shutdown` は既存の `pauseConversation` 経由で上の分岐に入る。
- ログは `Logger(subsystem: "com.kamby.CatRobot", category: "ConversationFailureGuidance")` に `event=failureGuidance kind=<ConversationServiceError の case 名>` だけ。`ReplyTrace` へは何も送らない。

- [ ] **Step 1 — RED を書く（Codex）:** 署名アダプタ（定数と nil を返す `spokenGuidance`、`isSpeakingFailureGuidance` の宣言、fake の gate / error 引数）で compile を通し、次で RED を保存する。

```swift
// ConversationFailureGuidanceTests.testEveryServiceErrorHasTheSpecifiedGuidanceOrIsAnException
// 全ケースの表: .modelUnreachable / .modelUnavailable(.claudeUnreachable) → unreachable、.modelGenerationFailed / .modelBusy → generationFailed、
// .modelUnavailable(.claudeCredentialMissing / .claudeAttestationUnsupported / .claudeAttestationFailed / .available) と .modelLocaleUnsupported → configuration、
// .dailyLimitReached → dailyLimit、.refusal / .guardrailViolation → refused、.contextExceeded → contextExceeded、.inputTooLong → inputTooLong、
// .speechCaptureFailed / .speechEndpointingFailed / .speechCaptureAlreadyRunning / .speechAssetsUnavailable / .speechLocaleUnsupported → listening、
// .speechVoiceUnavailable / .speechSynthesisFailed / .audioSessionFailed / .microphoneDenied / .cancelled / .speechUnrecognized → nil

// FailureGuidanceTests（ConversationHarness。actor の値は局所変数に受けてから比較）
// testClassificationFailureSpeaksGuidanceBeforeFailing
let harness = ConversationHarness(); await harness.classifier.setError(.modelUnreachable)
await harness.sut.startConversation(); await harness.completeUnengagedTurn("明日の予定は？", at: 0)
let texts = await harness.speaker.texts; let startCount = await harness.recognizer.startCount
XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable])
XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnreachable))
XCTAssertFalse(harness.sut.viewState.isSpeakingFailureGuidance)
let calls = harness.calls.values
XCTAssertLessThan(calls.lastIndex(of: .speak(ConversationFailureGuidance.unreachable))!, calls.lastIndex(of: .stopSpeaker)!)
XCTAssertLessThan(calls.lastIndex(of: .stopSpeaker)!, calls.lastIndex(of: .deactivateAudio)!)
XCTAssertEqual(startCount, 1)   // 再開しない
// testReplyFailureAfterPartialTextStillSpeaksGuidance: replySnapshots nil、yield("今日は") → fail(.modelGenerationFailed) → texts.last == generationFailed、usage 0
// testTypedReplyFailureSpeaksGuidanceAndDeactivatesOnce: microphoneAllowed false、fail(.modelUnreachable) → texts == [unreachable]、audio.isActive == false、deactivateCount == 1
// testSpeechFailuresAndCancellationDoNotSpeakGuidance: speakerError .speechSynthesisFailed → texts に定型文なし、.failed(.speechSynthesisFailed)
// testGuidanceSpeechFailureOrIncompleteStreamStillPublishesOriginalError（2 通り）
//   speakerAutomaticallyFinishes false、fail(.modelUnreachable)、waitUntilTextCount(1)、
//   (a) speaker.fail(run: 0, with: .speechSynthesisFailed)  (b) speaker.finish(run: 0) を .finished 無しで閉じる
//   → .failed(.modelUnreachable)、stopSpeaker < deactivateAudio、retryRecovery → 次の返答の speak が記録される
// testPreflightMatrix（音声 / 文字入力 × 可否確認 .claudeUnreachable / 記憶 .restoreFailed(.readFailed) × 案内の成功 / 失敗、8 通りを for で回す）
//   可否確認の失敗: calls の順序 checkAvailability → prepareSpeaker → activateAudio → speak(定型文) → stopSpeaker → deactivateAudio、
//     prepareRecognizer / prewarmReply / generateReply なし、.failed(.modelUnavailable(.claudeUnreachable))、文字入力では requestMicrophone も無い
//   記憶の失敗: texts == [memory]、phase == .paused、memoryState == .restoreFailed(.readFailed)、errorMessage == nil、retryMemory が使える
//   案内の失敗（speakerError）: 同じ終状態で texts.count == 1、deactivateCount == 1
//   いずれも audio.isActive == false、usage 0、保存 0
// testGuidanceAudioPreparationFailureSkipsSpeech（2 通り。可否確認 .claudeUnreachable の開始前失敗で案内の準備が失敗する）
//   speakerPrepareError .speechVoiceUnavailable → prepareSpeaker 1 回、activateCount == 0、deactivateCount == 0、texts == []、.failed(.modelUnavailable(.claudeUnreachable))
//   audioActivateError .audioSessionFailed → activateCount == 1、deactivateCount == 1（試みた以上は解除する）、texts == []、.failed(.modelUnavailable(.claudeUnreachable))（元の失敗を保つ）
// testMicrophoneDenialDoesNotSpeakOrPrepareAudio: texts == []、prepareSpeaker / activateAudio の call が 0、.failed(.microphoneDenied)
// testOriginalSpeakerAndAudioFailuresAreNotRetried（通常の開始手順での失敗、2 通り）
//   speakerPrepareError .speechVoiceUnavailable → prepareSpeaker 1 回、activateCount == 0、texts == []、.failed(.speechVoiceUnavailable)
//   audioActivateError .audioSessionFailed → activateCount == 1、deactivateCount == 1、texts == []、.failed(.audioSessionFailed)
// ConversationRecoveryTests の既存 regression（認識の prepare / start 失敗、Stage prepare / start）: 新しい期待は texts == [listening]、
//   recognizerStops == 1、speakerStops == 1、deactivations == 1、順序 stopRecognizer < speak(listening) < stopSpeaker < deactivateAudio、.failed(元のエラー)
// testLifecycleEventsDuringGuidanceTearDownOnce（Review Focus 3。起点 3 × 事象 5 を for で回す）
//   起点: 音声ターンの失敗 / 文字入力の失敗 / 開始前の可否確認の失敗。事象: toggleListening、sceneBecameInactive、audio.emit(.interruptionBegan)、audio.emit(.routeChanged)、shutdown
//   speakerAutomaticallyFinishes false、waitUntilTextCount(1) → 事象 → speaker 側の stream が閉じられる
//   → deactivateCount == 1、activateCount は事象前と同じ、texts.count == 1、errorMessage == nil、phase == .paused（shutdown は isShutdown）、isSpeakingFailureGuidance == false
// testLifecycleEventsWhileGuidancePreparesAudioNeverActivateLate（起点: 開始前の可否確認の失敗、可否確認 gate / 記憶 prepareGate / audio activateGate の 3 箇所 × 事象 5）
//   Task 2 と同じ形: startConversation を Task で起動 → gate.waitUntilEntered() → 事象を Task で起動 → let paused = await waitUntil { phase == .paused } → gate.open() → 両 Task を await → XCTAssertTrue(paused)
//   → texts == []、activate の遅延呼び出しなし（gate が activate なら activateCount == 1 かつ deactivateCount == 1、それ以外は 0 / 0）、
//   recognizer.startCount == 0、phase == .paused、errorMessage == nil
// testNewConversationAndForgetDuringGuidanceStopSpeakerWithoutFailure: startNewConversation / forgetConversation → texts.count == 1、stopCount >= 1、errorMessage == nil、
//   forget では memoryState が forget の結果（FakeConversationMemoryManager の forgets == 1）
// testTypedSubmissionDuringGuidanceReplacesItWithoutStaleFailure（Review Focus 5）
//   音声ターンの失敗で waitUntilTextCount(1) → XCTAssertTrue(viewState.allowsTypedSubmission) → submitTypedText("今日は何日？")
//   → stopCount >= 1、errorMessage == nil（古い失敗を出さない）、generateReply("今日は何日？") が 1 回、texts == [定型文, "わかったよ"]、
//   calls の順序 deactivateAudio（古い操作）< activateAudio（新しいターン）< deactivateAudio（新しいターン）、activateCount == 2、deactivateCount == 2、phase == .paused
// testLaterLifecycleActionDuringTypedReplacementStopWins（事象 3 つ toggleListening / sceneBecameInactive / audio.emit(.routeChanged) を for で回す）
//   speakerStopGate を付けた harness。音声ターンの失敗で waitUntilTextCount(1) → let typed = Task { await submitTypedText("今日は何日？") } → await stopGate.waitUntilEntered()
//   → let later = Task { 事象 } → let paused = await harness.waitUntil { phase == .paused } → await stopGate.open() → await typed.value; await later.value
//   → XCTAssertTrue(paused)、generateReply("今日は何日？") の call が 0、activateCount は事象前と同じ（新しい有効化なし）、errorMessage == nil、phase == .paused、deactivateCount == 1
// testCaptureFailureWithPendingSegmentationDoesNotStartNewTurnDuringGuidance（spec 手順 1）
//   emit(.provisional("あのね")) → recognizer.fail(.speechCaptureFailed) → waitUntilTextCount(1) → 区切り待ちの時間を経過（flushSegmentation）→ speaker.finish()
//   → classify / generateReply の call が 0、texts == [listening]、recognizer.startCount == 1、MotionControllerSpy.begins は増えない
// testUnsavedWarningDoesNotSpeak: MemoryStoreFake.setSaveFailure(true) の実サービス → 返答成功、texts に定型文なし、memoryState == .unsaved
// testGuidanceIsNotRecordedChargedOrTraced: PlaybackIntegrationHarness(service: 実サービス) + URLError 失敗 → store.snapshot?.turns に定型文なし、
//   usage.turns.count == 0、traces.events に失敗ターンの後の speechStarted / answer 系の point が無い
// ConversationRecoveryTests.testDuplicateTypedSubmissionWhileBusyIsIgnored（既存）: 通常の再生中は allowsTypedSubmission == false のまま、texts に定型文が無い assertion を足す
// ReplyPlaybackIntegrationTests.testFailureGuidanceAddsNoNewMotionTurn: 失敗する返答の後、MotionControllerSpy.begins.count == 1 のまま、cancellations.count == 1、reservations は増えない
```

移植 4 件の最終形（Task 1 の中間形を VM 経由に置き換え、定型文の読み上げまで通す。`PlaybackIntegrationHarness(service:motion:expressions:look:)` と `ControlledSpeaker`、`await speaker.waitUntilCallCount(n)` で段階を進める）:

```swift
// FaceExpressionIntegrationTests.testFailureGuidanceNeverReleasesFailedPrimaryExpression
//   service = MotionReplyGenerator(base: makeClaudeService(StubSessionFactory(scripts: [FailingFaceSession(expressions: h.sut)])), motion: observer)
//   typed turn → speaker の 1 回目の speak が定型文（texts == [generationFailed 相当の文]）、その間 heldExpression == nil、
//   読み上げ完了後 phase == .failed、motion.cancellations.count == 1、motion.begins.count == 1
// MotionPlaybackIntegrationTests.testFailureGuidanceCannotReleaseFailedPrimaryReservations
//   client.reservation == .reserved(cycles: 1)、定型文の読み上げ中・後とも h.sentCommands.isEmpty、reservations は 1 件のまま
// LookIntegrationTests.testFailureGuidanceAfterImageClearsIndicatorAndNextTurnWorks
//   receivedImage == true、定型文の読み上げ中に look.isLooking == false、.failed の後に retryRecovery → 次の typed turn の speak が記録され isLooking が戻る
// ConversationMemoryIntegrationTests.testPendingReplyFailureSpeaksGuidanceAndSavesNothing
//   「今日の天気はどう？」→ ambiguous → 聞き返し → 「うん」→ URLError
//   texts.last == ConversationFailureGuidance.unreachable、saved == [(今日の天気はどう？, 今の、ぼくに言った？)]、chargedTurns == 0、.failed(.modelUnreachable)
```

- [ ] **Step 2 — RED を実行（Codex）:** `issue30_test -only-testing:CatRobotTests/ConversationFailureGuidanceTests -only-testing:CatRobotTests/FailureGuidanceTests -only-testing:CatRobotTests/ConversationMemoryIntegrationTests`。期待: 定型文が話者へ渡らない・`allowsTypedSubmission` が false の assertion 失敗。Claude へ HANDOFF。
- [ ] **Step 3 — 語彙と状態（Claude）:** `ConversationFailureGuidance` と `spokenGuidance`、`ConversationViewState.isSpeakingFailureGuidance` と `allowsTypedSubmission` の例外を実装する。
- [ ] **Step 4 — 失敗の操作（Claude）:** `finishFailure` / `performFailureOperation` を実装し、`finishVoiceFailure` `finishTypedTurn` と開始前の各分岐（attempted フラグを運ぶ）を接続する。`pauseConversation` の `failureCleanupTask` 分岐と `submitTypedText` の受理済み置き換えを足す。
- [ ] **Step 5 — GREEN / commit（Codex 実行、Claude stage）:** Step 2 の 3 クラスと `ConversationRecoveryTests` `ConversationViewModelTests` `ReplyPlaybackIntegrationTests` `ClarificationRoutingTests` `FaceExpressionIntegrationTests` `MotionPlaybackIntegrationTests` `LookIntegrationTests` `AppCompositionTests` を実行して失敗 0。`git commit -m "feat: speak fixed guidance before showing conversation failures"`。Codex へ Task 4 の編集権を移す。

### Task 4: 文脈つき宛先判定の実モデル確認（有料・明示実行）

**Files:** 新規 `CatRobotTests/Device/HaikuAddressingModelTests.swift`、`scripts/run_haiku_addressing_model_tests.sh`、生成プロジェクト。

**Interfaces:** `HaikuAddressingModelTests.testFixtureInventory()`（ローカル。モデルを作らない）と `testAcceptanceMatrix() async throws`。runner は `<Xcode-device-ID> <CoreDevice-ID>` を受け、`HAIKU_ADDRESSING_MODEL_TESTS=1`、`HAIKU_ADDRESSING_RUN_ID`、`HAIKU_ADDRESSING_SOURCE_HEAD`、`HAIKU_ADDRESSING_INPUT_SHA256`、`HAIKU_ADDRESSING_SDK_REVISION` を xctestrun へ入れる。`scripts/run_clarification_history_model_tests.sh` と同じ構成（source-before / request / summary / source-after、結果は `/private/tmp/cat-issue30-haiku-20261109/model-runs/<runID>/`）。fixture 版 `issue30-v1`、各 3 回、本番 `ClaudeAddressModelClient(auth:)` を直接呼ぶ。

文脈の定義: A = [(今日の天気はどう？, 晴れだよ)]、B = [(お姉ちゃんが来るんだ, 楽しみだね)]、C = [(ねこ、おはよう, おはよう！今日も元気だね)]。確認待ちの fixture は `clarification: .init(originalUtterance: "今日の天気はどう？")` と `recentTurns: C`（聞き返しの往復は decorator が除くので入力には含めない）。

| id | recentTurns | utterance | expected |
| --- | --- | --- | --- |
| ctx-followup-tomorrow | A | それで、あしたは？ | [addressed] |
| ctx-followup-repeat | A | もう一回言って | [addressed] |
| ctx-followup-umbrella | A | 傘はいる？ | [addressed] |
| ctx-other-addressee-same-topic | A | ママ、あしたの天気どうだった？ | [notAddressed] |
| ctx-addressee-from-history | B | お姉ちゃん、傘どこ？ | [notAddressed] |
| ctx-self-talk | B | これは独り言。疲れたな。 | [notAddressed] |
| ctx-unrelated | A | 明日の予定は？ | [ambiguous] |
| plain-cat | なし | ねこ、元気？ | [addressed] |
| plain-papa | なし | パパ、鍵はどこ？ | [notAddressed] |
| plain-rain | なし | 明日は雨かな。 | [ambiguous] |
| clar-hai / clar-un / clar-iie / clar-uun / clar-ittayo / clar-weather-confirmation / clar-denied-addressee / clar-denied-mom / clar-cat-new-question | C | #29 と同じ発話 | [addressed] |
| clar-unrelated-question | C | 明日の予定は？ | [ambiguous] |
| clar-other-addressee / clar-self-talk | C | ママ、鍵はどこ？ / これは独り言。疲れたな。 | [notAddressed] |
| clar-unspecified-addressee | C | 部長に電話しておいて。 | [notAddressed, ambiguous] |

1 run は 23 fixture（通常 7、文脈なし 3、確認待ち 13）× 3 回 = 69 回の Haiku 呼び出し。合否は全 fixture で 3 回とも expected の集合に入ること。不合格なら指示文・分類例を直して全件を再実行し（承認済みの同じ試験の繰り返し）、両方の run を記録する。

- [ ] **Step 1 — fixture と runner（Codex）:** 上の表を `Classification` 配列で書き、`testFixtureInventory` で件数 23・試行 69・id の重複なしを固定する。runner は issue29 版を複製し、環境変数名・結果ディレクトリ・`OnlyTestIdentifiers`・request の件数を置き換える。共通手順の順序で project を再生成する。通常 suite では `issue30_test` の skip 対象。環境変数なしで直接指名したときも `XCTSkip` になることは、skip を付けない単発の `xcodebuild ... -only-testing:CatRobotTests/HaikuAddressingModelTests test` で確認する（Haiku を呼ばない）。
- [ ] **Step 2 — 利用者への確定連絡（Claude）:** 実行の承認は 2026-11-09 に得ている（「実モデル試験を許可します。」。対象はこの受入試験で、再実行を含む）。実行前に 1 run の件数（23 fixture × 3 回 = 69 回、Haiku のみ）と使う実機 ID を伝える。fixture の追加やモデルの変更で範囲が広がる場合だけ改めて承認を得る。
- [ ] **Step 3 — 実行（Codex）:** `scripts/run_haiku_addressing_model_tests.sh <Xcode-device-ID> <CoreDevice-ID>`。source-before / after の一致、summary、data の回収を記録する。
- [ ] **Step 4 — 判定と commit（Codex）:** 全件合格なら候補を凍結し `git commit -m "test: add the Haiku contextual addressing acceptance run"`。不合格なら HANDOFF で指示文の修正者を 1 名決め、Task 2 の `ClaudeAddressClassifierTests` を更新し、影響する試験を再実行してから再実行する。

### Task 5: 文書・全体検証・独立レビュー・統合

**Files:** `docs/README.md`、`docs/architecture.md`、`docs/application-flow.html`（静的スナップショット。直接編集し、冒頭の時点表記を 2026-11-09 / issue #30 に更新）、新規 `docs/validation/2026-11-09-haiku-only.md`、`docs/superpowers/specs/2026-11-07-clarification-history-design.md` への後継注記（1 行）。

- [ ] **Step 1 — 文書（Claude）:** 索引に spec・計画・検証記録を足し、#29 の「端末内モデルが使えれば端末内」が古くなった旨を注記する。`architecture.md` の図を「返答の生成（Claude）」にし、「返答のモデルと記憶」に `DailyLimitedReplyGenerator` `ContextualAddressClassifier` `ConversationFailureGuidance` と失敗終了の手順 1〜6 を書く。`application-flow.html` の「03 返答と記憶」と宛先判定の行、失敗時の分岐を直接編集する。
- [ ] **Step 2 — 全体検証（Codex）:** 共通手順の順序（再生成 → generator 試験 → 入力 digest の凍結 → `issue30_test` を引数なし、skip 4 クラスのまま）で実行し、基準 1,048 件からの増減を削除・移植・新設に分けて検証記録に書く。Task 1 Step 5 の grep を再実行する。有料・実機のクラスをこの実行に含めない。
- [ ] **Step 3 — 独立レビュー:** 候補の HEAD と差分 SHA を固定し、Claude は実際の `/simplify` を report-only（修正適用なし）で 4 観点、Codex は `superpowers:requesting-code-review` で独立レビュアー 1 名。互いの初回を保存してから交換し、`superpowers:receiving-code-review` で採否と根拠を残す。Critical / Important は修正者を HANDOFF で 1 名決めて直し、同じ担当へ修正箇所の確認を戻す。コンパイル対象を変えた修正の後は、影響する試験クラスと Step 2 の全体検証をやり直し、新しい候補の HEAD・digest・receipt を記録してから次へ進む。文書だけの修正では繰り返さない。
- [ ] **Step 4 — 実機と統合（利用者承認の後）:** 通常署名版を最終候補から実機に入れ、利用者がオンラインの会話・機内モードの案内（開始前と会話中、音声と文字入力）・上限（設定で下げて）の案内を確認する。承認が出たら Codex が main へ squash し、tree の同一性・remote・issue の状態を照合する。push は別途の承認を待つ。

## 初稿のセルフレビューと引継ぎ

- spec の第 1 項は Task 2、第 2 項は Task 3、第 3 項と第 4 項は Task 1、第 5 項は Task 1（脚注）・Task 2（送るもの）・Task 5（文書）、実モデルは Task 4、受入の静的確認は Task 1 Step 5 と Task 5 Step 2 に対応する。
- Task 1 で fallback を外す時点で日次上限の gate を同じ commit に入れ、中間 commit で上限が消えないようにした。移植 4 試験は Task 1 で compile を保つ中間形、Task 3 で定型文の読み上げまで通す最終形にする。
- `recentTurns()` の上限と重複除去は decorator 側に置いた（純粋関数で境界を試験できる）。サービスは複製を返すだけ。
- 失敗終了は全起点が `finishFailure` を通り、`failureCleanupTask` を最初の await より前に登録する。後始末はその Task だけが行うので、一時停止・割り込み・route 変更・shutdown・新しい会話・全削除・文字入力のどれが重なっても `deactivate` は 1 回で、遅れて `activate` や読み上げが始まらない。
- spec §2 の「文字入力が来たら話者を止める」は、聞き返しの読み上げ中（`.clarifying`）と同じく文字入力を受け付ける読みを採った。読み上げ中は phase を `.speaking` に保ちつつ `isSpeakingFailureGuidance` で入力だけ許す。通常の返答の再生中の重複送信は従来どおり無視する。
- 実モデルの 1 run = 23 fixture × 3 回 = 69 回、全件が expected の集合に入るという基準はこの計画の提案で、実行前の入力とともに固定する。利用者の承認は試験そのものに対するもので、再実行に新しい承認は要らない。本文作成時点では未実行。
- 計画のレビュー・承認と実装 HANDOFF ACK を経て Task 1 を開始する。計画レビュー中にソースへ進まない。
