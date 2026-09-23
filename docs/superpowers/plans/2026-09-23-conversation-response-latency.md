# Conversation Response Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 返答を読み始めるまでの待ち時間を測り、最初の一文を先に読む方式を実機で比較し、採用基準を満たす場合だけ通常アプリへ反映する。

**Architecture:** 既存の累積字幕を維持し、純粋な文境界抽出器と、一つのターンの生成・最大二つの音声を所有するコーディネータを追加する。計測は本文を持たないイベントへ分離し、Gemma内部の要約・再構築・保存とUI側の時刻を関連付ける。Gemmaの生成成功・保存・キャンセル境界は変えない。

**Tech Stack:** Swift 6 concurrency、SwiftUI、OSLog、既存AVSpeechSynthesizer／LiteRT-LM 0.17.1、XCTest、集計用Python標準ライブラリ。外部依存追加なし。

**Spec:** [承認済みspec](../specs/2026-09-23-conversation-response-latency-design.md)。ユーザー「おk」で承認。本文の先行提示後に失敗し得ることと、生成成功後は音声停止にかかわらず記憶を保存する契約を含む。本計画はレビュー待ち。実行方式は前回の選択を引き継ぐnativeを推奨する。

## Global Constraints

- `feature/conversation-response-latency`、起点main `066e3a6d75b9a75e1819124d056d59b406807d2b`。作業場所 `/Users/goodapple/.codex/worktrees/conversation-response-latency/Cat_robot`。
- Gemma 4 E2B、12,288上限、8,192要約開始、直近2,048以上、要約512、返答160、分類16、無音1.2秒、最大発話20秒を維持。
- 現在のApple合成音声・プロンプト・記憶保存形式・iOS 26.0最低対応を維持。
- 先行一文と正常終了後の残りの最大二部分。相づち追加、文字数での強制分割、無制限キューは作らない。
- 先行文は生成済みの接頭部分が変わらないサービスだけに適用。AFMは従来の全文待ち。
- キャンセルに`ReplyGenerating.reset()`を使わない。現在のGemma resetは永続記憶を消す。
- 分類・要約・返答のネイティブ並列実行は禁止。返答生成とTTSだけ重ねる。
- 通常ログへ音声・認識文・返答文を出さない。測定fixtureと保存先はテストUUIDで分離。
- 生成確定前の中断では新規記憶なし、確定後は保存まで完了。読み上げ済み部分だけを保存しない。
- 実装の採用ゲートはspec §9の値をそのまま使う。実測後に閾値を緩めない。
- Swift追加後は`ruby scripts/generate_project.rb`。生成されたproject/schemeを手編集せず`ruby scripts/test_generate_project.rb`で決定性を確認。
- mainへマージ／pushしない。実装完了時はfeatureブランチで報告する。

## Review Focus

1. 先行音声のエラーで生成ストリームだけが残り、新規往復が後から保存される事故。確定前・確定後の両方で境界を検証（Task 3/5）。
2. 一文目の終了とpause／forget／次ターンが競合し、旧cleanupが新しい音声を停止する事故。終了待ちと世代ガードを検証（Task 4/5）。
3. `。」`が分割到着、引用符が片側だけ、URLの`?`、複合Unicodeが含まれる入力。誤分割・重複・脱落なしを検証（Task 2）。
4. TTSのstarted欠落・重複・willSpeak先行で「最初の音声」の計測が二重／誤成功になる事故。代理値を分類し、成功・キャンセル各終端を検証（Task 1/3）。
5. Gemmaの保存中に先行文が終了するとマイクが先に再開する事故。ストリーム終端と全音声の合流が必要なことを検証（Task 4/5）。

---

## ファイル構成

| ファイル | 責務 |
| --- | --- |
| 新規 `CatRobot/Conversation/Domain/ReplySentenceBuffer.swift` | 接頭文の抽出、再通知・書き換えの検査、残りの算出 |
| 新規 `CatRobot/Conversation/Domain/ReplyTrace.swift` | 本文なしのイベント、sink、相関・時刻・終端、TaskLocal |
| 新規 `CatRobot/Conversation/Integration/OSReplyTraceSink.swift` | 既存ConversationLatencyと同じOSLog categoryへの段階イベント出力 |
| 新規 `CatRobot/Conversation/Integration/ReplyPlaybackCoordinator.swift` | 一つの生成ターンと先行／残り音声の所有・合流・停止 |
| 変更 `ConversationServices.swift` | ReplyGeneratingの接頭部分保証の宣言 |
| 変更 `GemmaConversationService.swift` | 保証宣言、処理段階の計測。保存／キャンセル規則は維持 |
| 変更 `ConversationDependencies.swift` | 再生方式と計測sinkの注入。通常既定は比較完了まで全文待ち |
| 変更 `ConversationViewModel.swift` | voice/typedの生成再生経路、既存停止処理、表示、計測を接続 |
| 参照 `AppleSpeechSynthesizer.swift` | speak/stopの既存契約を利用。ネイティブキューの新APIは作らない |
| 新規 `CatRobotTests/Conversation/Domain/ReplySentenceBufferTests.swift` | 分割の入出力契約 |
| 新規 `CatRobotTests/Conversation/Integration/ReplyTraceTests.swift` | 計測の時刻・終端・本文非収録 |
| 新規 `CatRobotTests/Conversation/Integration/ReplyPlaybackCoordinatorTests.swift` | 生成と音声の並行進行・失敗・停止 |
| 新規 `CatRobotTests/Conversation/Integration/ReplyPlaybackTestDoubles.swift` | 明示イベントとgateで駆動するreply/speaker、待機用probe |
| 新規 `CatRobotTests/Conversation/Integration/ReplyPlaybackIntegrationTests.swift` | ViewModel・保存・ライフサイクルの回帰 |
| 新規 `CatRobotTests/Device/ReplyLatencyDeviceTests.swift` | 実Gemmaと実TTSで旧／新方式を比較 |
| 新規 `CatRobotTests/Device/ReplyLatencyFixtures.swift` | 固定質問、隔離履歴、実行順 |
| 新規 `scripts/summarize_reply_latency.py` と `scripts/test_summarize_reply_latency.py` | 生データ検証、集計、採用判定 |
| 新規 `docs/validation/2026-09-23-conversation-response-latency.md` | 生データへのリンク、性能・試聴・回帰・未検証事項 |

## 共通の検証コマンド

開始時にstatusとHEADを確認。現行mainの直近結果は292成功・4スキップ。実装前に新しいworktreeで通常テストを実行する。以下のコマンドの末尾へ`-only-testing:CatRobotTests/ReplySentenceBufferTests`等を追加して対象を絞れる。

```bash
GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -derivedDataPath /private/tmp/cat-response-latency/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-gemma-20260921/packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
ruby scripts/test_generate_project.rb
```

ログは`/private/tmp/cat-response-latency/`へ保存し、RED/GREEN/基準/候補を別名にする。Simulatorは同時実行しない。署名や起動失敗はREDの根拠としない。各Taskの対象テスト後、Task 5と最終採用前には全通常テストを実行する。

## Task 1: 計測を先に追加し、現行動作の基準を取る

**Files:** `ReplyTrace.swift`、`OSReplyTraceSink.swift`、`ConversationDependencies.swift`、`ConversationViewModel.swift`、`GemmaConversationService.swift`、`ReplyTraceTests.swift`、既存`ConversationLatencyTests.swift`。

**Interfaces:** 次の型をこのTaskで作る。sinkは同期・Sendableとし、テストの記録器はlock内で配列へ追加する。TaskLocalにより、Gemma内の所有Taskにも同じtraceを伝える。

```swift
enum ReplyTracePoint: String, Codable, Sendable {
    case captureBoundary, captureClosed, classificationStarted, classificationFinished
    case request, firstCaption, firstSentence, generationFinished, streamFinished
    case compactionStarted, compactionFinished, sessionStarted, sessionFinished
    case saveStarted, saveFinished, speechEnqueued, speechStarted, speechFinished, finished
}
enum ReplyTraceOutcome: String, Codable, Sendable {
    case success, cancelled, generationFailure, speechFailure, saveWarning, noResponse, ambiguous
}
enum ReplySpeechPart: String, Codable, Sendable { case first, remainder, full }
enum ReplySpeechStartSource: String, Codable, Sendable { case started, willSpeakFallback }
struct ReplyTraceEvent: Codable, Sendable {
    let id: UUID
    let point: ReplyTracePoint
    let at: TimeInterval
    let part: ReplySpeechPart?
    let source: ReplySpeechStartSource?
    let outcome: ReplyTraceOutcome?
}
protocol ReplyTraceSink: Sendable { func record(_ event: ReplyTraceEvent) }
// Final class with lock protecting once-only milestones and final outcome.
// init(id: UUID = UUID(), sink: any ReplyTraceSink, now: @escaping @Sendable () -> TimeInterval)
// mark(_:part:source:outcome:) takes the types above, optional arguments default nil.
// finish(_ outcome: ReplyTraceOutcome) emits .finished exactly once.
// Use enum ReplyTraceContext { @TaskLocal static var current: ReplyTrace? }
```

- [ ] 記録器`RecordingReplyTraceSink`をテストファイルで定義し、固定時計で最初の字幕と終端が重複しないREDを書く。以下の記録器は`events: [ReplyTraceEvent]`のコピーをlock下で返す。

```swift
func testFirstCaptionAndTerminalAreRecordedOnce() {
    let sink = RecordingReplyTraceSink()
    let trace = ReplyTrace(sink: sink, now: { 12.5 })
    trace.mark(.firstCaption)
    trace.mark(.firstCaption)
    trace.finish(.cancelled)
    trace.finish(.success)
    XCTAssertEqual(sink.events.map(\.point), [.firstCaption, .finished])
    XCTAssertEqual(sink.events.last?.outcome, .cancelled)
    XCTAssertEqual(sink.events.first?.at, 12.5)
}
```

- [ ] テストを実行して型欠落によるREDを確認し、型とOSLog出力を実装する。区間開始・終了は再構築等の繰り返しがあるため全てを一律にdeduplicateしない。firstCaption/firstSentence、各partのspeechStartedと全体finishedだけを一回にする。startedがない場合の代用は別sourceに分類し、後からstartedが来ても二回計上しない。
- [ ] ViewModelの音声ターン生成時にtraceを保持し、終了判定・認識停止完了・分類・生成要求・字幕・音声開始・終端を既存所有権で記録する。文字入力も新しいtraceを作る。既存の高速／分類signpostと関連付けるため、音声経路ではbeginVoiceTurnの戻り値のtoken.rawValueをReplyTraceのidへ渡し、経路・cold/warm・最後の認識更新時刻はテストのrun metadataとして記録する。
- [ ] `ReplyTraceContext.$current.withValue(trace) { ... }`の中でclassifier／replyを呼ぶ。Gemmaのsummary・session作成は開始とdefer終端で記録し、成功／失敗を付ける。生成終了は返答consume成功直後、保存はsaveMemoryの実処理、streamFinishedはストリーム終了直前。traceはnilなら何もしない。
- [ ] 保存はUIのキャンセル後も完了し得るため、trace.finishはUIターンの終端だけを閉じる。開始済みsave区間等の後着終端は同じIDで受け付ける。新しいUI milestoneはfinish後に追加しない。失敗・非応答・曖昧・途中キャンセルも必ず終端を持つテストを追加する。
- [ ] fake時計と実Gemmaサービス＋fake runtimeでTaskLocalの相関が維持されること、計測に本文が出ないこと、保存完了が生成終了より後であることを検証する。通常コードへテスト専用の待機hookは追加しない。
- [ ] 対象テスト・既存latencyテスト・project生成確認を通して`Measure response generation and playback stages`でコミット。先行読み上げを有効にする前の基準としてこのcommit SHAを記録する。実機の基準実行はTask 6の共通fixture完成後、全文待ち方式でも取得する。

## Task 2: 最初の一文を安全に取り出す

**Files:** `ReplySentenceBuffer.swift`、`ConversationServices.swift`、`GemmaConversationService.swift`、`ReplySentenceBufferTests.swift`。

**Interfaces:**

```swift
// ReplyGeneratingに追加。extensionの既定値false、Gemmaのみnonisolated true。
var supportsStableReplyPrefix: Bool { get }

struct ReplySentenceBuffer {
    init()
    mutating func receive(_ snapshot: String) throws -> String? // 先行文を一度だけ返す
    func remainder(in finalSnapshot: String) throws -> String // 未送信なら全文
}
// 接頭部分の書き換えはConversationServiceError.modelGenerationFailed。
```

- [ ] 文末と引用の閉じ記号が別々に届くREDを書く。

```swift
func testWaitsForClosingQuoteAndFollowingContent() throws {
    var buffer = ReplySentenceBuffer()
    XCTAssertNil(try buffer.receive("「こんにちは。"))
    XCTAssertNil(try buffer.receive("「こんにちは。」"))
    XCTAssertEqual(try buffer.receive("「こんにちは。」元"), "「こんにちは。」")
    XCTAssertNil(try buffer.receive("「こんにちは。」元"))
    XCTAssertEqual(try buffer.remainder(in: "「こんにちは。」元気です。"), "元気です。")
}
```

- [ ] 対象テストでREDを確認する。String.Indexで括弧スタックと終止記号候補を走査し、境界の後に内容文字が来たときだけ接頭部分を返す。一文目が渡されるまでの候補検査は現在snapshot全体でやり直せる。渡した後はhasPrefixで検査し、再通知・後続更新ではnil。
- [ ] spec §5の引用符6組を扱う。ASCII引用符はバックスラッシュによるエスケープを認識する。URLの`?`/`!`を文末と誤認しないよう、http://またはhttps://で始まる空白区切りtokenの内部は候補から外す。この追加はspecのURL途中分割禁止を具体化したものである。
- [ ] 一文字到着・連続終止記号・閉じない引用・二重の引用・ASCII小数と略語・URL・絵文字や結合文字・記号だけ・先頭空白をliteral tableで検証。未分割の場合は全文、分割時はfirst+remainderが原文と同じことを検証する。変更可能な未送信suffixと変更禁止の送信済みprefixを別ケースにする。
- [ ] unsupportedサービスで先行能力false、Gemmaでtrueとなる消費側テストはTask 3へ持ち越し、能力値だけの恒等テストは作らない。
- [ ] GREENと生成確認を通して`Extract the first stable spoken sentence`でコミット。

## Task 3: 生成と最大二部分の音声を一つの操作にする

**Files:** `ReplyPlaybackCoordinator.swift`、`ReplyPlaybackCoordinatorTests.swift`、`ReplyPlaybackTestDoubles.swift`。

**Interfaces / Consumes:** Task 1のReplyTrace、Task 2のReplySentenceBufferとsupportsStableReplyPrefix、既存ReplyGenerating/SpeechSpeaking。

```swift
enum ReplyPlaybackMode: Sendable { case completeResponse, firstSentence }
enum ReplyPlaybackUpdate: Sendable {
    case caption(String)
    case speechStarted(ReplySpeechPart, ReplySpeechStartSource)
    case willSpeak(ReplySpeechPart, Range<Int>)
    case speechFinished(ReplySpeechPart)
}
@MainActor
final class ReplyPlaybackCoordinator {
    init(reply: any ReplyGenerating, speaker: any SpeechSpeaking, mode: ReplyPlaybackMode)
    func run(prompt: String, trace: ReplyTrace?,
             onUpdate: @escaping @MainActor @Sendable (ReplyPlaybackUpdate) -> Void) async throws -> String
    func cancelAndWait() async
}
```

テスト用`ControlledReply` actorはstreamのcontinuation、`yield(_:)`、`finish(throwing: Error? = nil)`、`waitUntilRequested()`、`supportsStableReplyPrefix`、キャンセル通知probeを持つ。`ControlledSpeaker` actorは`texts`、`waitUntilCallCount(_:)`、`emit(_ SpeechEvent)`、`finish(throwing: Error? = nil)`とstopCountを持ち、stopで進行中streamへcancelledを返してfinishする。いずれもpending waiterを状態変化時に解放する。固定sleepやTask.yieldループで順序を判定しない。

- [ ] 実コーディネータが生成終端前にspeakerへ一文を渡すREDを書く。

```swift
@MainActor
func testSpeaksFirstSentenceBeforeGenerationEnds() async throws {
    let reply = ControlledReply(stablePrefix: true)
    let speaker = ControlledSpeaker()
    let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
    let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
    await reply.waitUntilRequested()
    await reply.yield("こんにちは。元")
    await speaker.waitUntilCallCount(1)
    let first = await speaker.texts
    XCTAssertEqual(first, ["こんにちは。"])
    await reply.yield("こんにちは。元気です。")
    await reply.finish()
    await speaker.emit(.started)
    await speaker.emit(.finished)
    await speaker.finish()
    await speaker.waitUntilCallCount(2)
    let all = await speaker.texts
    XCTAssertEqual(all, ["こんにちは。", "元気です。"])
    await speaker.emit(.started)
    await speaker.emit(.finished)
    await speaker.finish()
    let result = try await run.value
    XCTAssertEqual(result, "こんにちは。元気です。")
}
```

- [ ] REDを確認して実装。一つの所有Taskがproducer（snapshot消費）とconsumer（逐次speak）をtask groupで持つ。parts用AsyncThrowingStreamのbufferは最大2。先行文はproducerから即yield、残りは生成stream正常終了後だけyieldする。producerがspeakerの終了を待つ構造にしない。空白部分は読み上げ不要だが、返す最終全文を改変しない。
- [ ] task groupのfirst errorを保持し、残りをcancel、parts入力を閉じ、speaker.stopを呼び、両子タスクをjoinしてからrunを終了する。consumer cancellationでreply streamのonTerminationへ届くことをテストする。runの親キャンセルも同じ経路。先行音声の失敗を、後から起きた生成キャンセルで上書きしない。
- [ ] `cancelAndWait`は保存した所有Taskをcancelし、speaker.stop後にそのTaskへ合流する。所有Task自身からcancelAndWaitをawaitしない。新規runは旧runのcleanupが終わるまで拒否する。旧operation IDのdeferが新runを消さない。
- [ ] started/willSpeakFallbackはpartごとに一度、captionは逐次、speechFinishedは正常finishだけ発行。終了イベントのないstream終端はspeechSynthesisFailed。mode.completeResponseまたは能力falseでは、bufferを使わず正常終了した最終snapshotを一回読む。置換型snapshotの既存fakeをこの経路で検証する。
- [ ] RED→GREENを追加して、一文目が先に終わる／生成が先に終わる、字幕が再生中も進む、同じsnapshot、prefix違反、空返答、先行前後の生成失敗、speak開始失敗、TTS途中失敗、started欠落・重複、cancel二重呼び出し、次runとの競合を検証する。
- [ ] GREENと生成確認を通して`Coordinate first sentence playback with reply generation`でコミット。

## Task 4: 音声・文字入力と既存ライフサイクルへ接続する

**Files:** `ConversationDependencies.swift`、`ConversationViewModel.swift`、`ReplyPlaybackIntegrationTests.swift`、既存`ConversationFakes.swift`／`ConversationLatencyTests.swift`／`ConversationRecoveryTests.swift`。

**Interfaces:** dependenciesへ`replyPlaybackMode: ReplyPlaybackMode = .completeResponse`を追加。liveはここでは既定値を維持。ViewModelはdependenciesから一つのReplyPlaybackCoordinatorを作り保持する。テストharnessにmodeと安定prefix能力の注入を追加する。

- [ ] 既存harnessに上記引数とControlledSpeaker/Replyを注入できる専用の`PlaybackIntegrationHarness`をテストutilitiesへ作る。既存ConversationDependenciesを使用し、今あるfake microphone/recognizer/classifier/audio/memoryを再利用する。
- [ ] ViewModelの文字入力が一文目を読む間、マイクを再開しないREDを書く。harnessは`viewModel`、`reply`、`speaker`、`recognizer`を持つ。`waitForPhase(_ phase: ConversationPhase) async`はSwift Observationの状態変更をwithObservationTrackingで購読し、到達済みなら即時return、未到達なら継続を再登録して待つテスト専用utilityとする。製品ViewModelにテスト用callbackを追加しない。音声開始とturn完了のgateを使い、以下の順で検証する。

```swift
let run = Task { await harness.viewModel.submitTypedText("二文で答えて") }
await harness.reply.waitUntilRequested()
await harness.reply.yield("こんにちは。元")
await harness.speaker.waitUntilCallCount(1)
await harness.speaker.emit(.started)
await harness.waitForPhase(.speaking)
XCTAssertEqual(harness.viewModel.viewState.caption, "こんにちは。元")
let startsWhileSpeaking = await harness.recognizer.startCount
XCTAssertEqual(startsWhileSpeaking, 0) // このケースは音声開始前の文字入力

await harness.reply.yield("こんにちは。元気です。")
await harness.reply.finish()
// 一文目と残りのfinishedを順に送り、run.value後にだけ元の再開規則へ進む。
```

- [ ] 対象テストでRED確認。generateReply/TypedReplyは共通coordinator.runを使う。onUpdateをgeneration/turnIDでguardし、captionは全文snapshot、speechStartedでspeakingと口、willSpeakで口、speechFinishedで閉じ口とthinkingを反映する。speechFinishedで先にマイクを開始しない。
- [ ] run正常終了後だけ音声経路はengagementを更新してresumeCapture、文字経路はshouldResumeVoiceに従って再開／deactivateしてpaused。生成回答用の旧speakTypedReply等で全文を再度読まない。定型返答用のspeakAndResumeは残す。
- [ ] pause/sceneInactive/routeChanged/typedReplacement/forget/shutdownのcleanupにcancelAndWaitを組み込む。新しい音声を始める前に旧cleanupをjoinする。failure cleanupから自分のturnTaskをawaitする循環は作らない。通常の音声エラー表示、保存警告、削除確認は維持する。
- [ ] 音声経路・文字経路・既存signpost・定型返答をテスト。ASRが1.2秒より前に閉じないこと、先行方式でも分類を省略しないこと、AFM経路が動くことを既存の振る舞いのテストで確認する。
- [ ] GREENと生成確認を通して`Use coordinated playback in voice and typed conversations`でコミット。

## Task 5: 保存確定と停止の競合を実サービスで検証する

**Files:** `ReplyPlaybackIntegrationTests.swift`、既存`GemmaMemoryPersistenceTests.swift`、`MemoryStoreFake.swift`、`GemmaTestRuntime.swift`、必要なTask 3/4の修正。

**Consumes:** コーディネータとViewModelの完成経路、実Gemmaサービス、既存fake native runtime/store。新しい製品APIは追加しない。

- [ ] 実Gemma＋制御可能native stream＋MemoryStoreFakeで、生成確定前のTTS失敗を再現するテストを書く。最初の文のspeak後にTTSを失敗させ、ネイティブcancelを確認して終端を送る。runがspeechSynthesisFailedで終了し、storeのsnapshotは旧revisionのままであることを検証する。
- [ ] 対照として保存gateに到達後のTTS失敗を作る。保存gateを開いた後に最新全文が一往復で保存されること、旧世代へ巻き戻らないことを検証する。生成成功の判定にTTS完了を結び付けない。
- [ ] 保存gate中に一文目・残りTTSを終えようとしても、stream未完のため残りが発行されずマイクも開始しないことを検証する。保存失敗を返す場合はwarningを維持し、先行音声を重複再生しないこと。
- [ ] 先行再生中のforgetでRAM・file・字幕が消え、旧producer/consumer完了が記憶や音声を復活させないこと。forget失敗時には既存どおり開始を拒否すること。
- [ ] 旧speakerの停止待ち中に新しい入力、背景移行中にTTS完了、prefix違反とcancelが同時という順序をgateで固定。新ターンの字幕・speaker・マイクが旧cleanupの影響を受けないことを検証する。
- [ ] 追加テストで期待する失敗を確認した場合は該当境界だけ修正し、成功確認後に全通常テストとproject生成確認を実行。新規コードの並行性レビューを行い`Preserve memory and lifecycle boundaries during early speech`でコミット。

## Task 6: iPhoneで旧／新方式を比較できるfixtureと集計を作る

**Files:** `ReplyLatencyDeviceTests.swift`、`ReplyLatencyFixtures.swift`、`scripts/summarize_reply_latency.py`、`scripts/test_summarize_reply_latency.py`、`scripts/generate_project.rb`。

**Interfaces:** device testは通常のConversationViewModel/Dependencies経路を通す。modeは依存注入のみ。テスト限定のASRイベント再生と本当のマイク入力を区別し、両方を「音声入力の実測」と表記しない。fixtureは固定日時・固定snapshot・識別子で再現する。各trialのJSONは次のフィールドを持つ。

```json
{"schemaVersion":1,"fixture":"cat-sleep","mode":"completeResponse","path":"fast",
 "inputKind":"syntheticRecognition","repetition":0,"outcome":"success",
 "thermalState":"nominal","powerState":"unplugged","osVersion":"record-at-runtime",
 "voiceIdentifier":"record-at-runtime","initialRevision":1,
 "events":[],"earlySentenceUsed":false,"listeningResumed":true}
```

実行時の値は実機から埋める。eventsはReplyTraceEvent配列。先行文の文字数と生成全体の文字数はテストartifactに追加可能。acoustic measurementは別フィールドで実測がある時だけ記録し、推定値で埋めない。

- [ ] 固定質問10種をfixtureにする。両方式とも同一の利用者入力とシステム指示を使う。
  1. 猫がよく眠る理由を二文で教えて。
  2. 雨の日に家でできる遊びを二文で教えて。
  3. 朝の散歩のよいところを二文で教えて。
  4. 本を読む楽しさを二文で教えて。
  5. 緊張しているときの過ごし方を二文で教えて。
  6. 春の好きなところを二文で教えて。
  7. 机を片付けるコツを二文で教えて。
  8. 夕焼けがきれいな理由を二文で教えて。
  9. 旅行の持ち物を準備するコツを二文で教えて。
  10. お茶を飲んで休むよさを二文で教えて。
- [ ] 各質問について高速経路／分類経路を別fixture IDにする。fastは呼びかけprefix、classifiedは非engagedから既存分類を実行する入力。実分類がambiguous/noResponseならそのまま結果に残し、成功として偽装しない。性能比較に必要な成功件数が不足したら未評価扱いとする。文字経路は認識と分類を除く補助セット。
- [ ] 各版・各経路・各質問3回以上。ペアの順序を反復ごとにAB/BAで入れ替え、各trialで同じ履歴からサービスを再構築する。warm trialは事前準備を計測外で行い、coldは新プロセスで各版3回以上。context再構築／要約の有無もタグで分ける。
- [ ] 対照fixtureは「はい、と一語で」「好きな季節を一文で」「3.14を含む一文」「https://example.com/a?q=cat! の文字列を含む短い返答」「『こんにちは。』を引用してから一文続けて」。実モデルの指示不遵守も記録し、構造を強制した純粋分割テストと混同しない。
- [ ] testをDEBUG実機限定・明示環境変数`CATROBOT_REPLY_LATENCY_TESTS=1`で起動。未指定時はXCTSkip。記憶の保存先はランダムUUIDを既存ConversationMemoryLocationで解決し、一致確認後だけfixtureを書き込む。Releaseと通常の保存先には書き込まない。生成スクリプトにこの専用schemeを追加し、既存の通常schemeではskipさせる。
- [ ] 集計スクリプトのREDをPython unittestで作る。中央値・nearest-rank p90・失敗数・source別集計、欠落event、重複trial、片側mode不在、全失敗、ゼロ基準値を検証する。例えばbaseline中央値5.0／candidate3.5は30%・1.5秒改善、baseline5.0／candidate4.4は12%なので不採用。エラー試行を成功の最短時間へ変換しない。
- [ ] CLIは`python3 scripts/summarize_reply_latency.py INPUT_JSON --output OUTPUT_JSON`。schema不正は非zero、計測は正しいが採用ゲート不足は`adopt:false`と理由を出力する。median/p90はspecと同じ経路別・warm別で計算。試聴とacoustic実測の不足は自動採用できない理由として残す。
- [ ] `python3 -m unittest discover -s scripts -p 'test_summarize_reply_latency.py'`とSimulatorでdevice-test skipを確認し、`Add paired on-device response latency evaluation`でコミット。

## Task 7: 実機評価、採用判断、ドキュメント

**Files:** `docs/validation/2026-09-23-conversation-response-latency.md`、`README.md`、採用時のみ`ConversationDependencies.swift`のlive既定値。

- [ ] iPhone 16 Proの接続・利用可能な無線開発接続・音声入力を確認。USB接続で再び無音なら取り外す。接続待ちの間は集計とテストを進め、端末待ちをコード不具合扱いしない。実機テストの署名・modelは既存構成を再利用する。
- [ ] 専用schemeでbuild-for-testingし、xctestrunの環境変数とOnlyTestIdentifiersを限定してtest-without-buildingする。装着端末が変わった場合は実際のUDIDを使い、旧UDIDに固定した成功記録を作らない。結果JSONとxcresultを保存し、syntheticRecognition／typedの比較を先に集計する。
- [ ] 本当の音声で固定fixtureを再生し、入力音声終端と返答の音が同じ外部録音に収まる形で各版を比較する。録音はテストの合成発話だけで行う。外部録音が用意できない場合、内部のASR更新時刻を音声終端に代用せず、体感区間の未検証を記録して採用判断を保留する。
- [ ] 二文セットの全回答を試聴し、文間の無音・語尾の不自然さ・重複・脱落を記録。短い回答の対照とコールド起動を別表にする。最低2回の要約を伴う既存GemmaAppDeviceTestsも隔離storeで実行し、保存・復元・想起を回帰確認する。
- [ ] spec §9の採用判定表をそのまま報告書に置く。中央値20%以上かつ0.5秒改善、各経路p90悪化0.5秒以内、一文対照の開始／終了中央値悪化0.3秒以内、文間p90 1秒目標、機能回帰ゼロを全て確認。平均だけで判定しない。
- [ ] 条件達成時のみliveの既定modeを.firstSentenceにする。未達／未検証時は.completeResponseのままにし、原因・候補方式の結果を報告する。失敗を隠すために質問・閾値・出力token上限を変えない。
- [ ] READMEに採用した動作と測定結果を記載。生成途中に音声が始まる場合の途中失敗と記憶の契約を説明。要約待ちの制限は残す。生データはテスト合成文だけをgitへ保存し、ユーザーの実記憶は含めない。
- [ ] 最終の全通常テスト、project生成確認、`git diff --check`を実行。変更全体を独立レビューして重要な指摘を修正し、変更に応じた再検証を行う。`Validate and select the response playback strategy`でコミットし、採用可否と未検証を報告する。

## 計画のセルフレビュー

- spec §1〜3/8→Task 1/6/7（目的、正しい起点、旧方式比較）。
- spec §4〜6→Task 2/3/4（境界、最大二部分、能力宣言、表示、合流）。
- spec §7→Task 3/5（失敗の優先、確定前後の記憶、忘却）。
- spec §9→Task 6/7（固定質問、AB/BA、採用ゲート、音声入力確認、試聴）。
- spec §10→Task 1〜6の各RED/GREENと最終全体テスト。
- spec §11→Global ConstraintsとFiles（範囲外の維持）。
- Review Focus 1/2/5→Task 3/4/5、3→Task 2、4→Task 1/3。
- ReplyPlaybackMode/Update/CoordinatorはTask 3で定義しTask 4が消費。ReplyTraceはTask 1、SentenceBufferはTask 2が所有。テスト用gate/probeはテストutilities内だけに置く。

## 実行の引き継ぎ

前回と同じnative実装を推奨する。生成・保存・音声停止の境界を複数Taskが共有するため、一人が順に実装し、最後に独立レビューする方式が適する。本計画の確認後に実装へ進み、mainへの統合は別の明示指示で行う。
