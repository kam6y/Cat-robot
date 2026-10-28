# Face Redesign and Express Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. The user authorized implementation on 2026-10-26 and explicitly requested Claude to dispatch subagents and repeatedly compare/fix the vector face until visual discrepancies are resolved. Preserve Native execution for integration and use the requested Claude subagents for visual implementation/review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 黒い外装と一体になる猫の顔を描き、9種類の表情を会話状態とClaudeの`express`ツールに連動させる。

**Architecture:** SwiftUIのベクター描画に表情と口の状態を渡す。表情の予約・保持・取消は独立したMainActorコーディネーターが管理し、既存のターン通知を首と表情へ分配する。カメラ、BLE、音声合成エンジンには新しい処理を加えない。

**Tech Stack:** Swift 6、SwiftUI/Observation、Foundation Models、既存のClaudeForFoundationModels 0.2.3、XCTest、既存RobotClock、Ruby xcodeproj 1.27.0。

**Spec:** `docs/superpowers/specs/2026-10-24-face-expression-design.md`。元要件は`docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md` §6.4とFR-CONV-9。2026-10-26に通常顔B案と、目を大きくしてきらめかせたhappyを利用者が採用した。

**Implementation status:** 実装・自動試験・静止画像の比較は完了。最終ソースは `41e16c68d3c53bb63d80bfdaa1881649ce05ba24`（初期統合 `468df75`、輪郭調整 `5d223d2`、9表情への共通化 `41e16c6`）。Claudeの独立した視覚レビューはRound 8で未解消0件。全体試験709件（実機専用2件スキップ）・最終描画差分12件は失敗0件。[検証記録](../../validation/2026-10-24-face-expression.md)と[最終レビュー](../../design/face-expression-2026-10-26/visual-review-final.md)を保存した。実機確認は未実施。専用ブランチを保持し、統合・pushは行っていない。

**Approved visual references:** [通常顔B](../../design/face-expression-2026-10-26/neutral-b.png) / [happy](../../design/face-expression-2026-10-26/happy-b.png)。生成画像は設計資料として参照し、アプリではSwiftUIで再現する。

## Visual comparison loop

Claudeがベクター描画の実装と視覚比較のsubagentを担当する。採用画像の画面内の顔と、実際のSwiftUI静止レンダーを同じ顔領域・倍率で比較し、目の輪郭と間隔、瞳、ハイライト、配色、鼻、口、ひげ、happyの拡大と光の差分を具体的に指摘する。実装者が修正したら再レンダーし、新しい画像を比較subagentが再確認する。撮影された筐体・背景・反射は顔のベクター比較に含めず、同一ピクセルであるとは主張しない。レビューで顔の形・配置・色に未解消の相違が残らなくなるまで繰り返し、各回のレンダーと指摘、対応を記録する。これは以下の最終コードレビューとは別の反復であり、コードレビューの回数制限を適用しない。

## Global Constraints

- iOS 27以上、Swift 6、横向き両方向。追加パッケージなし。Xcodeプロジェクトは`ruby scripts/generate_project.rb`で生成し、手編集しない。
- 黒背景、画面内の耳なし、目・鼻・口・ひげだけ。9表情: neutral / happy / curious / thinking / listening / speaking / sleepy / surprised / sorry。
- 通常顔はB案の丸い琥珀色の目。happyは目を開いたまま大きくし、明るい金色と瞳内のきらめき、控えめな縁の光で表す。静止時は閉じた笑顔。細めた笑い目へ変更しない。
- `express(expression, hold_seconds)`、保持1〜10秒・既定3秒。未知の表情はneutral、秒数は1〜10へ丸める。発話前は最後の1件だけ予約し、最初の実再生開始から保持時間を測る。
- `MotionTurnID` / `MotionTurnContext`を再利用する。新しいターンID体系、イベントバス、表情の永続化、常駐ポーリングは追加しない。
- 口は既存のMouthPoseを再利用し、Supertonicでは文開始/終了に同期する。単語時刻を推測しない。文内の周期的な口パクは追加しない。
- 字幕は通常下部1〜2行。完全なcaptionは保持しVoiceOverへ渡す。最大Dynamic Type・キーボード・エラー/記憶復旧時は操作と全文の可読性を優先しスクロール可能にする。
- Reduce Motion、VoiceOver、Reduce Transparency、コントラスト設定、44pt以上の操作領域、顔タップの停止/再開、既存の設定・文字入力・復旧を維持する。システムstatus barは現状どおり表示。
- `look`、おやすみ本体、瞳の実カメラ追従、端末内モデルへのツール追加、権限オンボーディング再編は別課題。`sleepy`を選んでもマイク・カメラ・首の状態を変えない。
- 実装時は`feature/claude-neck`を基点に`feature/face-expression`の専用worktreeを用意する。mainへの統合・pushはこの計画に含めない。既存のローカル音声資産・開発用認証資産を追跡対象へ加えない。

## Review Focus

- 発話開始前にholdが切れる/複数文でholdや首が再開始する: 表情の時計は最初の実再生開始を起点にする。Task 2・4。
- 前のターンのツール、期限、generationFinished、speechFinishedが新しい表情を消す: IDと表示tokenを照合する。Task 2・3。
- 返答が終わった後も残る表情が、停止・設定・背景・fallbackで再登場する: 再生中以外の取消入口も同期的に閉じる。Task 2・3。
- happy/sorry等を保持すると口が動かない、またはsleepy/speakingツールが録音/音声を開始する: 表情と実再生の口を独立させる。Task 1・4。
- 大きい文字、Dynamic Island、キーボード、エラー/記憶復旧で顔や操作が隠れる: 通常レイアウトと操作優先レイアウトの両方で確認する。Task 5。

## Files and ownership

| 領域 | ファイルと責務 |
|---|---|
| 表情の値 | `CatRobot/Conversation/Face/FaceExpression.swift`: 9種類、正規化、自動状態の対応 |
| 描画 | `CatRobot/Conversation/UI/CatFaceAppearance.swift`、既存`CatFaceView.swift` / `CatFaceShapes.swift`: プリセットの形と描画、口・まばたきの合成 |
| 表情の制御 | `CatRobot/Conversation/Face/FaceExpressionControlling.swift` / `FaceExpressionCoordinator.swift`: 予約、保持、取消、no-op |
| ターンの通知 | `CatRobot/Conversation/Integration/ReplyTurnObserving.swift`: 既存5通知のプロトコルと状態を持たないmulticaster |
| ツール | `CatRobot/Conversation/Tools/ExpressTool.swift`、既存provider/instructions |
| 接続 | 既存dependencies/composition、生成・再生・fallback、view model/app coordinator/root |
| 表示 | 既存`ConversationView.swift` / `ConversationViewState.swift`: 一時表情の値、顔と字幕の配置 |
| 試験 | `CatRobotTests/Face/`と既存Conversation/Motion/FaceTracking試験。ManualRobotClockと既存再生・ツールprobeを再利用 |

## Verification commands

実装の最初に利用可能なiOS 27 Simulatorを`xcrun simctl list devices available`で選ぶ。各コマンドは**今回のworktree内**から実行する。以前の`/private/tmp/cat-ios-link/run-tests.sh`は顔追尾worktreeへcdするため、この計画では流用しない。

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination "platform=iOS Simulator,id=${FACE_SIMULATOR_UDID}" \
  -derivedDataPath /private/tmp/cat-face-expression/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-ios-link/packages \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

以下の「関連試験」はこのtestコマンドへ`-only-testing:CatRobotTests/<Tests名>`を必要数追加する。全体は末尾の絞り込みなし。各Taskで関連試験、最終変更後に全体試験を行う。変更のない同一内容で全体を繰り返さない。各TaskのコミットはFiles欄にある当該変更と再生成projectだけを含める。

### Task 1: 9表情を描けるベクターの顔

**Files:** Create `CatRobot/Conversation/Face/FaceExpression.swift`, `CatRobot/Conversation/UI/CatFaceAppearance.swift`, `CatRobotTests/Face/FaceExpressionTests.swift`, `CatRobotTests/Face/FaceRenderingTests.swift`. Modify `CatRobot/Conversation/UI/CatFaceView.swift`, `CatFaceShapes.swift`, `ConversationViewState.swift`, `ConversationView.swift`, `CatRobot/Conversation/Integration/ConversationViewModel.swift`, `CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift`, `CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift`; regenerate project.

**Interfaces:**
- `enum FaceExpression: String, CaseIterable, Sendable`（9種類）。`static func normalized(_ raw: String) -> Self`、`static func automatic(for phase: ConversationPhase) -> Self`。
- `struct CatFaceAppearance: Equatable, Sendable` は目の大きさ・開き・傾き・瞳位置/大きさ・明るさとハイライト・縁の光・口の静止形・ひげ角度の値を持つ。`static func preset(_ expression: FaceExpression) -> Self`。パラメーター名/曲線の制御点はこのTask内に閉じ、他のTaskはpresetだけを使う。
- `CatFaceView.init(expression: FaceExpression, mouthPose: MouthPose, reduceMotion: Bool, isAnimating: Bool)`。`isAnimating`は周期的な装飾を動かしてよいかだけを表し、音声や首を開始しない。
- `ConversationViewState.heldExpression: FaceExpression? = nil`。表示は`heldExpression ?? FaceExpression.automatic(for: state.phase)`。旧`CatVisualState` / `catState`とViewModel/fixtureの代入を削除する。`ConversationRecoveryTests`のclarifyingに関する確認は、phaseとそこから導いたcuriousを検証する形へ置換する。

- [x] **Step 0: 実装開始時に作業環境を用意する。** `superpowers:using-git-worktrees`に従って専用worktreeを作り、基点・ブランチ・LocalAssetsの既存資産への参照・Simulatorを確認する。このTaskに着手するまで製品コードは変更しない。
- [x] **Step 1: 表情の値と形の既存/新規試験を書く。** `testAutomaticExpressionMatchesConversationPhase`で全phaseを設計表へ対応させる。`testExpressionNormalization`は`" HAPPY "→.happy`、空/未知→.neutral。`testEveryPresetFitsNormalizedCanvas`で全9表情×全MouthPoseの描画点が0...1内、閉口からwideまで開口が増えることを固定。旧参照画像の縦横比・耳・口周りの輪郭に依存した試験だけを新しい仕様へ置換する。
- [x] **Step 2: 関連試験を実行し未実装で失敗することを確認する。** `FaceExpressionTests` / `CatFaceGeometryTests`。失敗が新しい型/要件に起因することを確認する。
- [x] **Step 3: 上記の値と描画を実装する。** 16:9、目の中心(0.32,0.40)/(0.68,0.40)、目の幅0.22・高さ0.39、鼻(0.50,0.64)、口(0.50,0.73)、設計の初期配色を出発点とし、基準画像Bの丸い目へ調整する。happyは目を開いたまま約18%拡大し、瞳も少し大きくして、明るい金色・瞳内の四つ星形ハイライト・控えめな縁の光を加える。旧頭・耳・模様の不要な描画を取り除く。表情0.25秒補間、neutralかつidle/activeの時だけ3.5秒間隔・閉0.10/開0.12秒のまばたき。Reduce Motionまたは非activeでは補間/まばたきを停止する。happyのきらめきと縁の光は静的に描き、周期的な明滅を追加しない。`ConversationView`からphaseとscenePhaseに応じた`isAnimating`を渡す。口は全表情へ合成する。
- [x] **Step 4: 関連試験と描画確認。** `FaceExpressionTests` / `CatFaceGeometryTests` / `FaceRenderingTests` / `ConversationRecoveryTests`、生成契約を実行。UIHostingController＋UIGraphicsImageRendererで、固定サイズ・表情指定・isAnimating=falseの9表情一覧とhappy/sorry/sleepyの各口状態をXCTest添付画像に自動保存する。通常顔とhappyを採用した2枚の画像に照らし、丸い目・大きさ・配色・きらめきを確認する。happyは大きな瞳と閉じた笑顔、surprisedは小さな瞳と丸い口で違いが読めること、発話中もhappyの目が維持されることを目視する。目・瞳・ひげ・縁の光の欠けと黒背景への埋没を直す。SwiftUI previewは調整用として任意。装飾的な見た目を固定ピクセルのsnapshot比較だけで判定しない。
- [x] **Step 5: コミット。** `feat(face): render nine vector expressions on a black canvas`（`468df75`へ一括統合し、`5d223d2`・`41e16c6`で描画を追加修正）。

### Task 2: ターンに所属する表情予約と express ツール

**Files:** Create `CatRobot/Conversation/Integration/ReplyTurnObserving.swift`, `CatRobot/Conversation/Face/FaceExpressionControlling.swift`, `FaceExpressionCoordinator.swift`, `CatRobot/Conversation/Tools/ExpressTool.swift`, `CatRobotTests/Face/FaceExpressionCoordinatorTests.swift`, `ExpressToolTests.swift`, `ReplyTurnMulticasterTests.swift`. Modify `CatRobot/Motion/RobotMotionControlling.swift`; regenerate project.

**Interfaces:**
- `@MainActor protocol ReplyTurnObserving: AnyObject, Sendable`: `beginTurn(_ id: MotionTurnID)`, `speechStarted(_ id: MotionTurnID)`, `speechFinished(_ id: MotionTurnID)`, `generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome)`, `cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason)`。既存RobotMotionControllingは継承し、重複宣言を移す。
- `@MainActor final class ReplyTurnMulticaster: ReplyTurnObserving`, `init(_ observers: [any ReplyTurnObserving])`。指定順に全通知を1回ずつ同期転送するだけ。
- `FaceExpressionRequest: Equatable, Sendable`, `init(expression: FaceExpression, holdSeconds: Int = 3)`。readonlyの`expression`と1...10へclamp済みの`holdSeconds`を持つ。
- `FaceExpressionReservationResult`: `.reserved`, `.invalidated`, `.unavailable`。
- `@MainActor protocol FaceExpressionControlling: ReplyTurnObserving`: `var heldExpression: FaceExpression? { get }`, `reserve(_ request: FaceExpressionRequest, for id: MotionTurnID) -> FaceExpressionReservationResult`, `setConversationPhase(_ phase: ConversationPhase)`, `setVisible(_ visible: Bool)`, `reset()`。
- `@Observable FaceExpressionCoordinator.init(clock: any RobotClock)`。初期値は非表示・paused・heldなし。`NoopFaceExpressionController`は`nonisolated init()`、held=nil、予約unavailable、その他no-op。
- `ExpressTool.init(expressions: any FaceExpressionControlling)`、`@Generable Arguments`のフィールドは`expression: String`, `hold_seconds: Int?`。`call(arguments:) async throws -> String`は取消とTaskLocalを検査し、正規化した値を予約する。

- [x] **Step 1: 時刻・所有権・ツールの試験を書く。** ManualRobotClockを再利用し、次の中心ケースを含める。

```swift
let clock = ManualRobotClock()
let sut = FaceExpressionCoordinator(clock: clock)
sut.setVisible(true)
sut.setConversationPhase(.thinking)
let turn = MotionTurnID()
sut.beginTurn(turn)
XCTAssertEqual(sut.reserve(.init(expression: .happy), for: turn), .reserved)
await clock.advance(by: 20)
XCTAssertNil(sut.heldExpression) // 生成/合成待ちはholdに数えない
sut.generationFinished(turn, outcome: .success)
sut.speechStarted(turn)
XCTAssertEqual(sut.heldExpression, .happy)
await clock.advance(by: 2.99)
XCTAssertEqual(sut.heldExpression, .happy)
await clock.advance(by: 0.01)
XCTAssertNil(sut.heldExpression)
```

  `testLatestReservationWinsAndReplacementRestartsHold`、`testSpeechFinishedPreservesHoldButClosesAdmission`、`testOldTurnAndOldExpiryCannotChangeNewHold`、`testSuccessfulGenerationKeepsPendingButRejectsLateTools`、`testFallbackFailurePauseAndHiddenInvalidateWithoutReplay`を追加する。Tool試験は全9種類、nil→3、0→1、11→10、未知→neutral、TaskLocal欠落/取消、予約がhold満了を待たないこと。Multicasterは5通知のID・outcome/reason・順序が双方で一致することを記録spyで検証する。
- [x] **Step 2: 関連試験を実行し新しい契約が未実装で失敗することを確認する。** `FaceExpressionCoordinatorTests` / `ExpressToolTests` / `ReplyTurnMulticasterTests`。
- [x] **Step 3: 上記インターフェースを実装する。** ターンの有効性、生成/発話の開始終了、最新予約1件、期限token付き表示1件に限定。生成成功後の予約受付は閉じるが、発話待ちの予約は残す。生成失敗/fallback/取消はそのIDを無効化する。phaseがidle/preparing/paused/failedまたは非表示なら全部取り消す。表示の1件だけに期限taskを作り、旧taskはtoken照合で無害化する。全9種類の日本語名で正規化後の予約結果を返す。
- [x] **Step 4: 関連試験と既存Motion試験を実行する。** 上記3suiteに`MotionCoordinatorTests` / `MotionTurnContextTests`を加える。共有通知プロトコル抽出だけで首の予約・完走・取消が変わらないことを確認する。
- [x] **Step 5: コミット。** `feat(face): reserve turn-scoped expressions with bounded holds`（共有差分を `468df75` へ一括統合）。

### Task 3: 会話・生成・取消・画面遷移へ接続する

**Files:** Modify `CatRobot/Conversation/Integration/ConversationDependencies.swift`, `MotionReplyGenerator.swift`, `ReplyPlaybackCoordinator.swift`, `ConversationViewModel.swift`, `CatRobot/Conversation/Services/Claude/OnDeviceFallbackReplyGenerator.swift`, `ConversationInstructions.swift`, `CatRobot/Conversation/Tools/ConversationToolProvider.swift`, `CatRobot/App/ConversationComposition.swift`, `ConversationAppCoordinator.swift`, `AppRootView.swift`. Create `CatRobotTests/Face/FaceExpressionIntegrationTests.swift`. Extend `CatRobotTests/Conversation/Integration/AppCompositionTests.swift`, `CatRobotTests/Conversation/Services/Claude/ConversationInstructionsTests.swift`, `CatRobotTests/Motion/ToolProbeLanguageModel.swift`; regenerate project.

**Interfaces:**
- `ConversationDependencies.faceExpressions: any FaceExpressionControlling`（init既定Noop）、`replyTurnObserver: any ReplyTurnObserving`（init引数はoptionalで、nilなら既存motionを使う）。`motion`自体の型/意味は変えない。
- `MotionReplyGenerator` / `ReplyPlaybackCoordinator` / `OnDeviceFallbackReplyGenerator`の`motion:`引数と保存先だけを`any ReplyTurnObserving`へ変更する。TaskLocalと既存の開始/終了/取消位置は維持する。
- `RobotConversationToolProvider.init(motion: any RobotMotionControlling, expressions: any FaceExpressionControlling = NoopFaceExpressionController())`。toolsはremember / move_head / expressの3種類。
- `ConversationAppCoordinator`へ`expressions: any FaceExpressionControlling = NoopFaceExpressionController()`を追加。`AppRootView`はdependenciesの同一インスタンスを保持し、conversationStateへheldExpressionを合成する。

- [x] **Step 1: 実際の生成/再生境界を通す試験を書く。** `testExpressAndMoveHeadShareTurnAndReleaseOnce`は実ツール、実FaceExpressionCoordinator、MotionControllerSpyと制御可能な再生fakeを組み、発話前は表示なし・開始でhappy/首1回・hold終了で最新phaseの表情になること。`testFallbackNeverReleasesFailedPrimaryExpression`、`testFinishedReplyHoldClearsOnSettingsPauseNewConversationAndBackground`、`testLateOldToolAndGenerationCannotTouchNewTurn`、`testFaceExpressionsWorkWithoutRobotOrCamera`、`testLiveCompositionIsInertAndUsesOneExpressionCoordinator`を追加する。
  SDK経由の試験では既存ToolProbeLanguageModelに既定値付き`toolName` / `argumentsJSON`を持たせ、executorはmodelの値を送る。既存probeの既定値は維持する。`{"expression":"happy","hold_seconds":8}`を実ExpressToolへ渡し、捕捉したターンと保持8秒を検証する。別ターン・取消済み・scopeなしも実SDK経由で確認する。
- [x] **Step 2: 関連試験を実行して未配線を確認する。** `FaceExpressionIntegrationTests` / `AppCompositionTests` / `ConversationInstructionsTests` / `MotionTurnContextTests`。
- [x] **Step 3: 本番の配線を追加する。** compositionで表情1個と`ReplyTurnMulticaster([motion, expressions])`1個を作り、生成ラッパー・fallback・再生へ同じ通知先を渡す。ViewModelのphase通知と停止/新会話/shutdownで同期的に表情を失効させる。AppCoordinatorの既存可視条件更新地点でsetVisibleを必ず呼ぶ（faceTrackingがnilでも省略しない）。表示はRootでheldExpressionを観測する。instructionsへexpressの9種類・既定3秒・予約であること・非対応時に表示済みと主張しないことを固定文として追加する。fallbackの自動表情は維持し、端末内ツールは追加しない。
- [x] **Step 4: 関連回帰を実行する。** `FaceExpressionIntegrationTests` / `AppCompositionTests` / `ConversationInstructionsTests` / `MotionTurnContextTests` / `MotionReplyGeneratorTests` / `MotionPlaybackIntegrationTests` / `OnDeviceFallbackReplyGeneratorTests` / `RobotLifecycleIntegrationTests` / `FaceTrackingAppIntegrationTests`。生成前半/後半の失敗、再生取消、非表示、首未接続の境界を確認する。
- [x] **Step 5: コミット。** `feat(face): connect expressions to conversation turn lifecycle`（共有差分を `468df75` へ一括統合）。

### Task 4: 文の再生イベントで口を開閉する

**Files:** Modify `CatRobot/Conversation/Integration/ReplyPlaybackCoordinator.swift`, `SentenceReplyPlayback.swift`, `ConversationViewModel.swift`, `CatRobotTests/Conversation/Integration/SentenceReplyPlaybackTests.swift`, `ReplyPlaybackIntegrationTests.swift`, `ReplyPlaybackTestDoubles.swift`, `CatRobotTests/Motion/MotionPlaybackIntegrationTests.swift`, `CatRobotTests/Face/FaceExpressionIntegrationTests.swift`。追加enum caseの既存の網羅switchは同時に更新する。

**Interfaces:** `ReplyPlaybackUpdate.sentenceStarted(ordinal: Int)` / `.sentenceFinished(ordinal: Int)`。既存`.speechStarted` / `.speechFinished`は返答全体の通知のまま。文イベントでphaseを変えず、開始で`SpeechMouthPoseSequence.nextWordPose()`、終了で`.closed`を表示する。

- [x] **Step 1: 3文の実SupertonicSentenceSpeaker＋ControlledPCMPlayer試験を書く。** ordinal 0/1/2について、開始時はwide/medium/small、各終了イベントでclosed、合成待ちはclosed。文間の音声にギャップがないときの最小閉口表示時間は契約に含めない。全文captionは変わらず、首とexpressの開始は1回だけ。happy保持中でも同じ口の列が出ること。音声失敗/取消/旧runの遅いイベント後はclosed、旧イベントが次runの口を変えないこと。既存非文単位のwillSpeakでの口の列も維持する。
- [x] **Step 2: `SentenceReplyPlaybackTests` / `FaceExpressionIntegrationTests`を実行し文境界で口が変わらない既存動作を確認する。**
- [x] **Step 3: 文イベントを表示へ転送する。** 最初は既存speechStartedを通知してからsentenceStarted、最後はsentenceFinishedの後に既存speechFinishedを通知する。各ordinalの開始/終了は1回。ViewModelの音声/文字入力の双方が新しいcaseを扱い、首のreleaseMotionOnce、録音再開、最終caption、既存latency計測を文ごとに起動しない。古いrunの表示更新は既存所有権と同じ境界で拒否する。
- [x] **Step 4: 関連回帰を実行する。** `SentenceReplyPlaybackTests` / `ReplyPlaybackCoordinatorTests` / `ReplyPlaybackIntegrationTests` / `ConversationViewStateTests` / `MotionPlaybackIntegrationTests` / `FaceExpressionIntegrationTests`。実時間sleepで口やholdを推測する試験にしない。
- [x] **Step 5: コミット。** `feat(face): animate mouth poses at sentence playback boundaries`（共有差分を `468df75` へ一括統合）。

### Task 5: 顔を中心にした会話画面と最終検証

**Files:** Modify `CatRobot/Conversation/UI/ConversationView.swift`、必要な既存`ConversationAccessibility.swift`の表示補助。Create `CatRobotTests/Face/FaceConversationPresentationTests.swift`, `docs/validation/2026-10-24-face-expression.md`. Extend `CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift`; update READMEの表示/ツール説明。再生成projectを含める。

**Interfaces:** Task 1の描画とTask 3の`heldExpression`を使う。新しい永続設定や製品用の表情選択画面は追加しない。既存ConversationActionsと`catListeningToggle` / `conversationSettings` / `showTypedInput`等の識別子を維持する。

- [x] **Step 1: 表示の検証fixtureを作る。** 通常の短い字幕、長い全文、空字幕、認識途中、記憶未保存/復旧、失敗と回復操作、文字入力/キーボード、最大Dynamic Typeを列挙。通常は下部2行・全文のaccessibilityValue、操作優先時は全文/操作へ到達できることを確認する。既存アクセシビリティ試験の意味を弱めない。
- [x] **Step 2: 既存の左右2カラム表示をfixtureで記録し、新しいレイアウトが必要な箇所を確認する。** 見た目の変更に形式的なRED用テストは作らず、配置と操作の受入条件を画像に照らす。
- [x] **Step 3: 会話画面を再配置する。** 純黒背景・中央の顔・下部字幕・上部のマイク/活動/接続/記憶通知と設定をsafe area内に配置。通常captionは`lineLimit(2).truncationMode(.head)`で省略し、全文値を保持。独自の末尾文字列抽出はしない。大きい文字/入力/エラー/記憶復旧では顔を縮小しスクロール可能にする。文字入力中の既存draft保持・送信中無効化・キーボード回避・復旧導線は保持する。
- [x] **Step 4: 関連表示試験と目視を行う。** `FaceConversationPresentationTests` / `FaceRenderingTests` / `ConversationAccessibilityTests` / `ConversationViewStateTests`。852×393の9表情一覧、通常/最大文字、Reduce Motion・高コントラスト、左右それぞれ60pt/下21ptの模擬safe areaを確認する。模擬値を実機の測定値と称しない。全fixtureで文字・ひげ・目が欠けず、操作が使えるよう調整する。
- [x] **Step 5: 最終全体試験・生成契約・差分検査を実行する。** 上記xcodebuild全体、`ruby scripts/test_generate_project.rb`、`git diff --check`。必要な修正後に一度、全体のコードレビューを行う。根拠のある指摘を修正し、その変更に関連する回帰を確認する。レビューのためだけの無限の再レビューはしない。
- [ ] **Step 6: 実機で見た目と併用動作を確認し、結果を記録する。** 署名ビルドのsource revisionを照合し、利用者が見られる状態で顔・字幕・happy/sorryと発話・短い/長い返答・中断・設定から復帰を確認する。首と追尾を併用する場合も既存の安全な動作範囲を変更しない。実機確認していない項目は未実施と記録する。静止レンダーを見た目の実機合格の代わりにはしない。**今回: 未実施。検証記録へ未実施であることを記載済み。**
- [x] **Step 7: READMEと検証記録を整えてコミット。** `feat(face): make the conversation screen a full black cat face`（製品とREADMEは `468df75`へ一括統合。最終画像・検証資料は `docs(face): preserve visual validation and test evidence`）。検証記録には実際のソースSHA、試験数、描画確認、実機の結果、FR-FACE-6/FR-LLM-5を別課題とした理由を残す。統合は利用者の指示に従う。

## 要件との対応と計画の確認

| 要件 | 実装・確認するTask |
|---|---|
| FR-FACE-1/2/3/8: 黒・耳なし・ベクター・9表情・デザイン | 1、5 |
| FR-FACE-4: expressと1〜10秒保持/状態への復帰 | 2、3 |
| FR-FACE-5: 状態連動・音声連動・待機まばたき | 1、3、4 |
| FR-FACE-7: 下部字幕とアクセシビリティ | 5 |
| FR-CONV-9: 表情の発話同期 | 2、3、4。既存の実再生開始通知に同期 |
| FR-FACE-6: 瞳の顔追従（推奨） | 別実装。表示とBLE接続条件の分離が必要 |
| FR-LLM-5: 端末内モデルのツール（推奨） | 別実装。今回はfallback時の取消と自動表示を保証 |

計画の自己確認: 上記の各必須要件に担当Taskを割り当てた。型名はFaceExpression/heldExpression/MotionTurnIDに統一し、ターン通知5種と文通知2種を分けた。Review Focusの5項目すべてを各Taskの試験へ割り当てた。詳細な曲線の制御点だけは描画Taskへ委ね、保持・取消・同期・画面遷移の契約は実装者に再決定させない。
