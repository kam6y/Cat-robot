# UI Reorganization Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, as an agmsg pair: Codex (owner of git, project generation, xcodebuild/XCTest, device checks) and Claude (UI files below). Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 会話画面を「顔だけ＋必要なときだけ小さく知らせる」形にし、最初の画面を初回だけ・スクロールなしにし、設定を左カテゴリ／右中身の2列に作り直す。

**Architecture:** 表示の判断は `ConversationViewState` の派生値（状態チップ、顔を暗くするか）に集め、View はそれを描くだけにする。一時停止の理由・首の再接続・初回表示の完了は、動作を変えない表示専用の値として ViewModel／AppRootView／Coordinator が組み立てる。設定は既存の `ConversationSettingsView` の初期化引数を変えずに中身を2列に置き換え、ロボット・カメラの部品は右列の中身として再利用する。

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, `scripts/generate_project.rb`（Xcode プロジェクト生成）。

**Spec:** `docs/superpowers/specs/2026-10-27-ui-reorganization-design.md`

**作業場所:** `/Users/goodapple/.codex/worktrees/b200/Cat_robot`、ブランチ `feature/ui-reorganization`（基点 `feature/look` / `9ee8dac`）。

## Global Constraints

- 顔の枠は会話画面の幅・高さの85%（`0.85`）。safe area の水平中央・画面の垂直中央。
- 通常表示では返事の字幕・聞き取り中の文字・状態の文字（マイク／活動／首／記憶）を描かない。`caption` などの値と `ConversationAnnouncementPolicy` は変えない。
- 状態チップ: 左 safe area + 16pt、上10pt、高さ32pt、カプセル、背景 `#1C1C1E`、14pt。文言は spec の表どおり（「一時停止中・猫をタップで再開」「見ています」「待機中・タップで起こす」「首を再接続中」「熱のため顔追尾を一時停止」）。
- `memoryNotice` は下部中央のカプセル（`#1C1C1E`、15pt、下18pt）。表示時間は既存の期限処理のまま。
- ユーザー一時停止中だけ顔の不透明度 0.5。
- 最初の画面: 標準文字で 852×393 に縦スクロールなし。アクセシビリティ文字では1列・スクロール可。文言は spec の下書きどおり。
- 設定: 初期化引数は現状のまま。左列220pt・行44pt・選択背景 `#2C2C2E`、右列だけスクロール。アクセシビリティ文字では一覧→詳細。
- 校正中は「完了」無効・スワイプで閉じない・「停止」常時・戻る確認（現状維持）。校正画面は設定シート全体に重ねる。
- 44pt 以上の操作領域、VoiceOver ラベル、Reduce Transparency、両横向き。
- Claude は commit／merge／push／HEAD 移動／xcodebuild／実機・ロボット操作をしない。テストの実行はすべて Codex。

## 共有 API（G0 で合意してから着手）

`CatRobot/Conversation/UI/ConversationViewState.swift`（Codex）:

```swift
enum ConversationStatusChip: String, CaseIterable, Sendable {
    case paused, looking, sleeping, robotReconnecting, trackingPausedForHeat
    var title: String        // spec の文言。sleeping は ConversationViewState.standbyStatus
    var systemImage: String  // "mic.slash.fill", "camera.fill", "moon.fill", "arrow.triangle.2.circlepath", "thermometer.high"
    var isWarning: Bool      // robotReconnecting, trackingPausedForHeat が true（アイコン橙）
    var accessibilityIdentifier: String { "statusChip.\(rawValue)" }
}

extension ConversationViewState {
    // 追加する格納値
    var isAwaitingTapToResume: Bool                 // 既定 false。VM が設定
    var isRobotReconnecting: Bool          // 既定 false。AppRootView が設定
    var isFaceTrackingPausedForHeat: Bool  // 既定 false。AppRootView が設定
    // 派生値
    var showsTapToResume: Bool  // phase == .paused && isAwaitingTapToResume && !isSleeping && !blocksConversation
    var statusChips: [ConversationStatusChip]
    // 順に sleeping（isSleeping）, paused（showsTapToResume）, looking（isLooking && !isSleeping）,
    // robotReconnecting, trackingPausedForHeat。待機中は一時停止と見ていますを抑え、首と熱は併記する
    var faceOpacity: Double { showsTapToResume ? 0.5 : 1 }
}
```

`CatRobot/RobotLink/RobotSettingsModel.swift`（Codex）: `struct RobotReconnectIndicator { private(set) var isVisible: Bool; mutating func update(_ snapshot: RobotLinkSnapshot) }`
規則: `.reconnecting(_)` → true、`.connecting` / `.preparing` → 直前の値を保持、それ以外 → false。`snapshot.device?.id` が前回と変わったら、判定の前に false へ戻す（別の機器へ手動で変えた初回接続に持ち越さない）。

`CatRobot/App/OnboardingSettings.swift`（Codex）: `@MainActor final class OnboardingSettings { static let completedKey = "onboarding.completed"; init(defaults: UserDefaults = .standard); private(set) var isCompleted: Bool; func markCompleted() }`
`ConversationAppCoordinator.init(..., onboardingSettings: OnboardingSettings? = nil)`（nil は非永続＝毎回最初の画面。既存テストは共有 UserDefaults を汚さない）。`AppRootView.init(..., onboardingSettings: OnboardingSettings? = nil)`、`CatRobotApp` は `OnboardingSettings()` を渡す。

`CatRobot/Conversation/UI/OnboardingView.swift`（Claude）: `OnboardingView(onStart: @escaping () -> Void, isReview: Bool = false)`。既存の呼び出しはそのまま。`isReview` ではボタンを「閉じる」にし、押すと `onStart`（閉じる処理）を呼ぶだけにする。

`CatRobot/App/ConversationSettingsView.swift`（Claude）: 既存の初期化引数＋`initialCategory: SettingsCategory = .conversation`。`enum SettingsCategory: String, CaseIterable, Identifiable { case conversation, memory, cameraAndTracking, robot, usage, about }`（`title`: 会話／記憶／カメラと顔追尾／ロボット／利用量／このアプリについて、`systemImage`、識別子 `settingsCategory.<rawValue>`）。`ConversationSettingsIdentifier` の列挙は変えない（`ConversationAccessibilityTests` が全件を固定している）。

`CatRobot/RobotLink/RobotConnectionView.swift`（Claude）: `RobotConnectionView(model: RobotSettingsModel)`（`faceTracking` 引数を削除）。

## 分担とレビューの関所

| 担当 | ファイル |
|---|---|
| Codex | ConversationViewState, ConversationViewModel, RobotSettingsModel, AppRootView, ConversationAppCoordinator, CatRobotApp, OnboardingSettings（新規）, 動作テスト, `generate_project.rb` の実行, 設計書改訂と README |
| Claude | ConversationView, ConversationStatusChipsView（新規）, OnboardingView, ConversationSettingsView, SettingsPanes（新規）, CameraTrackingSettingsPane（新規）, RobotConnectionView, RobotCalibrationView, UI fixture（FaceConversationPresentationTests, RobotPresentationTests） |

- **G0:** 本計画と共有 API を Codex がレビューし、合意してから両者とも編集を始める。
- **G1:** Task 1–3 の差分を Claude が読み取り専用でレビュー（Codex が receiving-code-review）。
- **G2:** Task 4・5・6 の編集前に、Claude が対象ファイルと変更方針を送り、Codex が担当の凍結を確認する。編集後は Codex が navigator として差分と fixture 画像をレビュー。
- **G3:** 全体レビュー（双方）→ Codex が全テスト → Codex がコミット。
- 新規ファイルを足したら Codex が `ruby scripts/generate_project.rb` を実行する（再帰的に検出する）。
- xcodebuild の実行中は双方ともソースを凍結し、開始と解放を agmsg で知らせる。
- テストのコマンド（Codex が実行）: `xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=<UDID>' -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO -only-testing:<対象>`

## Review Focus

- 猫のタップで止めた後にバックグラウンド→前面に戻ると自動で再開する。再開後に「一時停止中」チップと顔の暗さが残らないこと（Task 1 のテスト）。
- 首の切断後、再試行で `.reconnecting` と `.connecting` が交互に来ても、チップがちらつかず、接続するまで出続けること（Task 2 のテスト）。
- 2回目以降の起動で、iOS の設定でマイク許可を取り消していた場合は、最初の画面に戻らず既存の回復カードが出ること（Task 3 のテスト）。
- 最大の標準文字（`.xxxLarge`）でチップが3つ並んでも、折り返して「…」ボタンに重ならないこと（Task 4 の fixture）。
- 校正の途中で設定の2列に戻れないこと、校正画面がシート全体を覆うこと（Task 6 の fixture）。

---

### Task 1: 状態チップの状態とユーザー一時停止（Codex）

**Files:**
- Modify: `CatRobot/Conversation/UI/ConversationViewState.swift`
- Modify: `CatRobot/Conversation/Integration/ConversationViewModel.swift`（`toggleListening()` の一時停止の分岐、`transition(to:)`、`presentFailure` 経路）
- Test: `CatRobotTests/Conversation/UI/ConversationViewStateTests.swift`, `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`

**Interfaces:**
- Produces: 「共有 API」の `ConversationStatusChip`, `isAwaitingTapToResume`, `isRobotReconnecting`, `isFaceTrackingPausedForHeat`, `showsTapToResume`, `statusChips`, `faceOpacity`

- [x] **Step 1: 失敗するテストを書く**

```swift
func testUserPauseChipNeedsTapPauseThatCanResume() {
    var state = ConversationViewState.idle; state.phase = .paused
    XCTAssertEqual(state.statusChips, [])
    state.isAwaitingTapToResume = true
    XCTAssertEqual(state.statusChips, [.paused]); XCTAssertEqual(state.faceOpacity, 0.5)
    state.memoryState = .forgetFailed(.deleteFailed)
    XCTAssertEqual(state.statusChips, []); XCTAssertEqual(state.faceOpacity, 1)
}
func testSleepingSuppressesPauseAndLookButKeepsWarnings() {
    var state = ConversationViewState.idle; state.phase = .paused; state.isAwaitingTapToResume = true
    state.isLooking = true; state.isRobotReconnecting = true; state.isFaceTrackingPausedForHeat = true
    state.inactivity = .sleeping
    XCTAssertEqual(state.statusChips, [.sleeping, .robotReconnecting, .trackingPausedForHeat])
    XCTAssertEqual(state.faceOpacity, 1)
}
func testStatusChipOrderAndCopy() {
    var state = ConversationViewState.thinking
    state.isLooking = true; state.isRobotReconnecting = true; state.isFaceTrackingPausedForHeat = true
    XCTAssertEqual(state.statusChips, [.looking, .robotReconnecting, .trackingPausedForHeat])
    XCTAssertEqual(ConversationStatusChip.paused.title, "一時停止中・猫をタップで再開")
    XCTAssertEqual(ConversationStatusChip.sleeping.title, ConversationViewState.standbyStatus)
    XCTAssertEqual(ConversationStatusChip.trackingPausedForHeat.title, "熱のため顔追尾を一時停止")
}
```

VM（既存のハーネスで）: `testTapPauseMarksUserPausedAndVoiceResumeClearsIt`、`testSceneInactiveNewConversationForgetAllAndFailureClearUserPause`、`testTypedTurnDuringUserPauseReturnsToUserPause`（文字の会話を挟んで `.paused` に戻ったら `isAwaitingTapToResume == true`）、`testForegroundAutoResumeClearsUserPause`。

- [x] **Step 2: 対象テストを実行し、未定義・期待値違いで失敗することを確認**
- [x] **Step 3: 実装する。** `private func pauseConversation(force: Bool = false, awaitsTapResume: Bool = false)` の先頭で `viewState.isAwaitingTapToResume = awaitsTapResume`。`toggleListening()` の停止分岐と `handleAudioSessionEvent` の割り込み開始・出力先変更で `true` を渡し、ほかの既存呼び出しは既定値のまま。再開の開始・失敗の公開・scene の同期的な無効化・shutdown で false に戻す。文字送信から `.paused` へ戻る経路では値を保持する。止まる・再開する動作は変えない。
- [x] **Step 4: 対象テストが通ることを確認**
- [x] **Step 5: G1（Claude が読み取り専用でレビュー）→ Codex がコミット** `feat(ui): derive status chips and user pause for the conversation screen`

### Task 2: 首の再接続と熱の表示を状態へ組み込む（Codex）

**Files:**
- Modify: `CatRobot/RobotLink/RobotSettingsModel.swift`（`RobotReconnectIndicator`）
- Modify: `CatRobot/App/AppRootView.swift`（更新ループで indicator を更新、`conversationState` で `isRobotReconnecting` と `isFaceTrackingPausedForHeat = faceTracking?.status == .pausedForHeat` を設定、熱のオーバーレイを削除）
- Test: `CatRobotTests/RobotLink/RobotStatusPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 の格納値
- Produces: `RobotReconnectIndicator`（共有 API）

- [x] **Step 1: 失敗するテストを書く**

```swift
func testReconnectIndicatorLatchesThroughRetriesUntilConnected() {
    var indicator = RobotReconnectIndicator()
    let steps: [(RobotLinkState, Bool)] = [
        (.connecting, false), (.connected, false), (.reconnecting(.timedOut), true), (.connecting, true),
        (.preparing, true), (.reconnecting(.timedOut), true), (.connected, false),
        (.reconnecting(.timedOut), true), (.suspended, false), (.connecting, false), (.unselected, false)
    ]
    for (state, expected) in steps {
        indicator.update(RobotLinkSnapshot(state: state, device: deviceA))
        XCTAssertEqual(indicator.isVisible, expected, "\(state)")
    }
}
func testReconnectIndicatorResetsWhenTheDeviceChanges() {
    var indicator = RobotReconnectIndicator()
    indicator.update(RobotLinkSnapshot(state: .reconnecting(.timedOut), device: deviceA))
    indicator.update(RobotLinkSnapshot(state: .connecting, device: deviceB))
    XCTAssertFalse(indicator.isVisible)
}
```

- [x] **Step 2: 失敗を確認**
- [x] **Step 3: 実装する。** `RobotConnectionStatus` と VoiceOver の読み上げは変えない。
- [x] **Step 4: 対象テストと既存の `RobotStatusPresentationTests` が通ることを確認**
- [x] **Step 5: G1 → Codex がコミット** `feat(ui): show neck reconnect and heat pause as conversation chips`

### Task 3: 最初の画面を初回だけにする（Codex）

**Files:**
- Create: `CatRobot/App/OnboardingSettings.swift`
- Modify: `CatRobot/App/ConversationAppCoordinator.swift`, `CatRobot/App/AppRootView.swift`, `CatRobot/App/CatRobotApp.swift`
- Test: Create `CatRobotTests/App/OnboardingSettingsTests.swift`; Modify `CatRobotTests/Conversation/Integration/ConversationAutoResumeTests.swift`
- `ruby scripts/generate_project.rb`

**Interfaces:**
- Produces: `OnboardingSettings`、`ConversationAppCoordinator.init(..., onboardingSettings:)`、`AppRootView.init(..., onboardingSettings:)`（共有 API）

- [x] **Step 1: 失敗するテストを書く**
  - `testCompletionPersistsAcrossInstances`（同じ suite の UserDefaults で2つ目のインスタンスが `isCompleted == true`）
  - `testFirstLaunchShowsOnboardingAndBeginMarksCompleted`（`destination == .onboarding`、`beginConversation()` 後に `isCompleted`）
  - `testReturningLaunchStartsOnFirstActive`（完了済みで生成→ `destination == .conversation`、最初の `.active` で開始処理）
  - `testReturningLaunchDoesNotRestartWhileMicrophonePromptIsOpen`（マイク許可のプロンプト中の `.active` → `.inactive` → `.active` では開始1回。通常のバックグラウンド復帰は既存どおり再開して2回）
  - `testRepeatedActiveWithoutSceneChangeAddsNoPreflight`（同じ `.active` の再通知や再描画で追加の preflight が走らない）
  - `testReturningLaunchWithDeniedMicrophoneShowsRecovery`（完了済み・マイク拒否 → `.failed` と既存の回復、最初の画面に戻らない）
  - `testNilOnboardingSettingsAlwaysStartsAtOnboarding`
- [x] **Step 2: 失敗を確認**
- [x] **Step 3: 実装する。** 完了済みなら初期 `destination = .conversation`、ルートの既存 `onChange(of: scenePhase, initial: true)` の最初の `.active` で、`beginConversation()` が行う処理（ロボットの scene 更新、wake lock、`inactivity.recordActivity()`、`launchStart()`）を一度だけ流す。`beginConversation()` は `markCompleted()` を呼ぶ。
- [x] **Step 4: 対象テストと既存の `ConversationAutoResumeTests`／`AppCompositionTests` が通ることを確認**
- [x] **Step 5: G1 → Codex がコミット** `feat(app): show onboarding only on first launch`

### Task 4: 会話画面（Claude）

**Files:**
- Modify: `CatRobot/Conversation/UI/ConversationView.swift`
- Create: `CatRobot/Conversation/UI/ConversationStatusChipsView.swift`（`ConversationStatusChipsView(chips: [ConversationStatusChip])`）
- Test: `CatRobotTests/Face/FaceConversationPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 の `statusChips`, `faceOpacity`, `isAwaitingTapToResume`, `isRobotReconnecting`, `isFaceTrackingPausedForHeat`

- [x] **Step 1: fixture を新しい状態の一覧へ置き換える。** fixture の擬似 safe area は、現行の左右対称（左右60・下21）をやめ、左62・右40・下11（`normal`）と、逆向きの左40・右62・下11（`normal-flipped`）の2種類にする。擬似 safe area はコンテナ由来の safe area を無効にしたテスト用 host と SwiftUI の `safeAreaInset` で与え、最終的な `GeometryProxy.safeAreaInsets` を実測して 62/40/11（逆向きは 40/62/11）に一致することを assert する。顔の枠が全画面寸法の85%で safe area の水平中央にあること、inset が二重に計上されていないことを、両方の画像で確認する。`normal`（listening）、`normal-flipped`、`speaking-long`（長い caption が描かれない）、`provisional`（途中の認識結果が描かれない）、`user-paused`、`system-paused`（チップなし・暗くしない）、`chips-all`（見ています＋首＋熱）、`notice`（memoryNotice）、`looking`、`sleeping`、`typed`、`failed`、`unsaved`、`restore`、`maximum-type`、`maximum-type-typed`、`maximum-type-error`、`largest-standard-type-chips`（`.xxxLarge` で `chips-all`）、`high-contrast`、`typed-short-viewport`、9表情。`testLookIndicatorAndRestoredCaptionRender` は「見ています」チップの確認に改める。
- [x] **Step 2: G2 の事前連絡 → Codex が変更前の fixture を取得**
- [x] **Step 3: 実装する。**
  - `statusHeader` の文字（マイク・活動・首・記憶）、字幕、聞き取り中の文字を削除する。「…」メニューと識別子（`conversationSettings`、`showTypedInput`、`openVoiceSettings`、`startNewConversation`）は残す。
  - 顔は全画面寸法（safe area を含む）の `static let faceScale: CGFloat = 0.85` の枠に描き、safe area の水平中央に置く。不透明度は `state.faceOpacity`。
  - チップは左上に重ね、`.xxxLarge` 以上では折り返す。各チップの識別子は `accessibilityIdentifier`。
  - `memoryNotice` は下部のカプセルにし、識別子 `memoryNotice` を引き継ぐ。
  - `prioritizesContent` の配置は、チップ、収まる大きさの顔、カード、下部の文字入力の順に並べる。
- [x] **Step 4: Codex が fixture を実行し、Global Constraints と Review Focus の4項目目を画像で確認**
- [x] **Step 5: G2（Codex の navigator レビュー）→ Codex がコミット** `feat(ui): show only the face and needed chips during conversation`

### Task 5: 最初の画面（Claude）

**Files:**
- Modify: `CatRobot/Conversation/UI/OnboardingView.swift`
- Test: `CatRobotTests/Face/FaceConversationPresentationTests.swift`

**Interfaces:**
- Produces: `OnboardingView(onStart:isReview:)`（Task 6 の見直しシートで使う）

- [x] **Step 1: 失敗するテストを書く**
  - `testOnboardingFitsWithoutScrollingAtStandardSize`: 852×393・`.large` で描画し、スクロールビューがない、または `contentSize.height <= bounds.height`
  - `testOnboardingScrollsAtAccessibilitySize`: `.accessibility5` で末尾までスクロールできる
  - どちらも fixture 画像を添付する
- [x] **Step 2: Codex が実行し、標準文字で失敗することを確認（現行は縦スクロール）**
- [x] **Step 3: 実装する。** spec の2列の寸法と文言を使い、アクセシビリティ文字では1列にする。
- [x] **Step 4: 通ることを確認**
- [x] **Step 5: G2 → Codex がコミット** `feat(ui): fit onboarding on one landscape screen`

### Task 6: 設定（Claude）

**Files:**
- Modify: `CatRobot/App/ConversationSettingsView.swift`（2列のルート、`SettingsCategory`、アクセシビリティ文字での一覧→詳細、「はじめの説明をもう一度見る」のシート、既存の確認ダイアログと「完了」の制約）
- Create: `CatRobot/App/SettingsPanes.swift`（会話・記憶・利用量・このアプリについての右列）
- Create: `CatRobot/App/CameraTrackingSettingsPane.swift`（`CameraTrackingSettingsPane(camera: ConversationCamera?, faceTracking: FaceTrackingCoordinator?, preferences: RobotPreferences?)`。カメラの許可、顔追尾のトグル・状態、左右補正のステッパーと「8.5°に戻す」。識別子 `faceTrackingEnabled`, `faceTrackingStatus`, `faceTrackingYawCorrectionStepper` を移す）
- Modify: `CatRobot/RobotLink/RobotConnectionView.swift`（右列の中身にする。自前の ScrollView・ナビゲーションタイトル・顔追尾欄を外し、接続先選択シートと校正への `navigationDestination` は残す）
- Modify: `CatRobot/RobotLink/RobotCalibrationView.swift`（「顔追尾の向き」の欄と、確認文の「顔追尾の補正はiPhoneに自動保存されます。」を削除）
- Test: `CatRobotTests/Face/FaceConversationPresentationTests.swift`（`testCameraPermissionSettingsRenderAndRemainScrollable` を `testSettingsCategoriesRender` と `testCameraPaneAuthorizationStatesRender` に置き換え）、`CatRobotTests/RobotLink/RobotPresentationTests.swift`（`RobotConnectionView(model:)`、校正 fixture）
- 新規ファイルの追加後に Codex が `ruby scripts/generate_project.rb` を実行

**Interfaces:**
- Consumes: Task 5 の `OnboardingView(onStart:isReview:)`
- Produces: `SettingsCategory`、`ConversationSettingsView(..., initialCategory:)`、`RobotConnectionView(model:)`、`CameraTrackingSettingsPane`

- [x] **Step 1: fixture を書く。**
  - `testSettingsCategoriesRender`: 6カテゴリを `.large`、会話とロボットを `.accessibility5`（一覧→詳細）で描画し、右列が末尾までスクロールできること
  - `testCameraPaneAuthorizationStatesRender`: 未確認・拒否・許可済み
  - `RobotPresentationTests` の connection と calibration（顔追尾の欄がないこと）
  - `settings-calibration`: 校正画面がシート全体を覆うこと
  - 設定の操作は実際の `UIWindowScene` に接続したウィンドウと実測 safe area を使う。`Info.plist` はカメラ左の横向き固定であり、設定の逆向き表示は対象外。会話画面の模擬左右比較は残す。
- [x] **Step 2: G2 の事前連絡 → Codex が実行（シグネチャ変更のためビルドが失敗することを確認）**
- [x] **Step 3: 実装する。** 各カテゴリの中身と注記の文言は spec の「カテゴリと中身」どおり。
- [x] **Step 4: Codex が fixture と既存の `ConversationAccessibilityTests`（識別子の固定）を実行し、Review Focus の5項目目を確認**
- [x] **Step 5: G2 → Codex がコミット** `feat(ui): rebuild settings as categories with a detail pane`

### Task 7: 設計書・README・全体確認（Codex）

**Files:**
- Modify: `docs/superpowers/specs/2026-10-24-face-expression-design.md`（会話画面とアクセシビリティ）、`docs/superpowers/specs/2026-10-26-look-design.md`（「見ています」をチップへ）、`docs/superpowers/specs/2026-10-26-idle-sleeping-design.md`（待機中の表示をチップへ、居眠り欄を「会話」カテゴリへ）、`README.md`（操作手順・表示の説明）
- Create: `docs/validation/2026-10-27-ui-reorganization.md`（全テスト結果、fixture の保存先、実機の確認・未実施項目）

- [x] **Step 1: 文書を改訂する**
- [x] **Step 2: G3 の全体レビュー（双方。指摘は receiving-code-review で採否を記録）**
- [x] **Step 3: 全テストを実行し、失敗0件を確認（実機専用の skip は件数を記録）**
- [x] **Step 4: 実機の併用確認は未実施として検証記録に明記**（今回の作業はコード・Simulator検証まで。端末への更新インストールは行っていない）
- [x] **Step 5: Codex がコミット** `docs: revise specs and README for the reorganized UI`

## 完了記録

実装コード `2431a29`。全体830件中828件成功、実機専用2件スキップ、失敗0件。独立レビューと追加の配置・入力欄維持の指摘を修正した。詳細と109点の最終画像は [検証記録](../../validation/2026-10-27-ui-reorganization.md) を参照。
