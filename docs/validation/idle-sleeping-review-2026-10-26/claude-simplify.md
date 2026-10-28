# /simplify 所見（claude）— 居眠り・待機と sleeping 表情の未コミット差分

- 対象: /Users/goodapple/.codex/worktrees/b200/Cat_robot（feature/look、base = HEAD = f6eeedad）の作業ツリー差分 + 未追跡の CatRobot/Conversation/Inactivity/ 実装 2 ファイルと CatRobotTests/Conversation/Inactivity/ テスト 3 ファイル。固定 diff scope.diff（SHA-256 155914ef…、scope.json と一致、作業ツリーとも一致）。行番号はすべて現行作業ツリーのもの。
- 方法: /simplify の 4 観点（再利用 R、簡潔さ S、効率 E、修正の深さ A）をそれぞれ独立した read-only subagent（opus）に読ませ、本書で重複を統合した。各観点の全文（根拠、確認して指摘しなかった点）は claude-simplify-details/findings-{reuse,simplification,efficiency,altitude}.md。統合時に私が現行コードで再確認した項目は「確認」欄に書いた。
- 立場: 品質（再利用・簡潔さ・効率・修正の深さ）だけを見た。正しさのバグは Codex の R1–R4 と claude-reception.md で扱う。コードは一切編集していない。
- 守る前提: 仕様の決定（sleeping はタップまで sticky、待機中も首の保持と画面点灯を維持、express ツールは sleeping を予約できない）、利用者承認済みの顔の意匠（round-8 の 36 ファイル画素一致 + sleeping round-2）、カメラ前面を画面左固定。画素に触れ得る C11 は `scripts/render_face.sh check` と preview の画素一致を採用条件にする。
- 範囲外として退けたもの: sleeping を ConversationPhase の case にする案、coordinator 全体のモード enum 化、FaceExpression の分割、render を `--design DIR` に統合する案（いずれも既レビュー済み基盤の書き換えになる。理由は findings-altitude.md の headline と verdict）。

## 件数

- 元の所見: 再利用 8（R1–R8）、簡潔さ 13（S1–S13）、効率 5（E1–E5）、修正の深さ 7（A1–A7）。
- 統合後: C1–C12（高 1 / 中 6 / 低 5）。

## 重複対応表

| 統合ID | 元の所見 | 重大度 | 要約 |
|---|---|---|---|
| C1 | R4 = S1 ⊂ A1 | 高 | enterSleeping が forwardPauseIfNeeded の一時停止手順を逐語で複製 |
| C2 | S6 ≈ E1 = A2 | 中（高寄り） | onPhaseChange が「phase 変化」と「保留音声の変化」の 2 つの意味を運び、ASR の部分結果ごとに顔環境を更新、else 分岐で二重通知 |
| C3 | R5 = S9 = A3 | 中 | 無活動として数える phase の一覧が 2 層に重複 |
| C4 | R6 = S10 ⊂ A5 | 中 | 分の範囲 1…1439 / 2…1440 と既定値がモデル 3 か所 + Stepper 2 か所に手書き、設定オブジェクトの二重所有の逃げ道 |
| C5 | S5 ⊂ A5 | 低 | settingsDidChange() は製品から呼ばれない |
| C6 | R7 = S8 ≈ A4、S7 | 中 | sleeping の表示規則が ViewState の displayed* と View のインライン判定に分散、allowsTypedSubmission の !isSleeping は無効、待機文言の二重定義、Accessibility の private 旗 |
| C7 | A1 ⊃ S2、R8、E3、E4 | 中 | coordinator の !isSleeping 条件が約 10 か所に散在、ロボットモード規則が 2 通り、二重 guard |
| C8 | S3、S4、E2 | 低 | ConversationInactivity 内部: recordActivity/wake の共通本体、clock 3 回読み、generation トークン、期限不変でもタイマー再生成 |
| C9 | R1、R2、R3、S12、S13、A7 | 中（claude_sleep 所有・オフライン工具） | face-render の鼻・口・ひげ検出と round 出力の足場の複製、下書きの二重読込・二重採点 |
| C10 | S11、A（test smell） | 低 | テストの重複断言・重複準備 |
| C11 | A6、E5 | 低（任意） | highlightDrop の lid == 1 端点ガードは幾何条件の代用、closedLid を毎フレーム構築 |
| C12 | R/A 備考 | 低 | ExpressTool の 9 表情名の手書き一覧と expressible の二重真実（差分前から。テストで固定する案） |

## 所見

### C1（高）enterSleeping が forwardPauseIfNeeded の末尾を複製
- 場所: CatRobot/App/ConversationAppCoordinator.swift:95-106（enterSleeping）と :396-404（forwardPauseIfNeeded）。
- 内容: `activeStartIntentID = nil`、`startTask?.cancel()`、`viewModel.invalidateForSceneInactivity()`、`sceneBecameInactive()` を待つ `pauseTask` の生成、の 4 手順が両方に逐語で並ぶ。
- コスト: 仕様は「既存の取消経路を再利用する」と明記しているが、一時停止の手順が 2 か所になり、片方だけ直す事故の口になる（例: pauseTask の後始末や順序を変えるとき）。
- 提案: `private func pauseConversationForScene()`（名前は任意）に 4 手順を抽出。`forwardPauseIfNeeded` は guard と 2 つの旗（didForwardPauseSinceActive / deferredPermissionPrompt）を保ったまま呼び、`enterSleeping` は `invalidateActionTasksForSceneInactivity()` → 抽出関数 → `updateRobotScene(scenePhase)` にする。`enterSleeping` から `forwardPauseIfNeeded()` を直接呼ぶのは不可（旗が立ち、deferredPermissionPrompt が消えて挙動が変わる）。
- 動作保持: 手順と順序は同一。`updateRobotScene` を Task 生成の後に置いても、Task は同期区間が終わるまで走らないので差はない。
- テスト影響: なし。
- 確認: 両箇所を読んで一致を確認した。
- 干渉: Codex R2（failed からの休眠入り）・R4（caption 消去を enterSleeping に追加）は同じ関数を触る。R 修正を先に入れてから抽出するか、抽出した関数に R4 の 1 行を足す形で同時に行う。

### C2（中・高寄り）onPhaseChange が 2 つの意味を運び、部分結果ごとに顔環境を更新
- 場所: CatRobot/Conversation/Integration/ConversationViewModel.swift:97（宣言）、:808（receiveRecognition 末尾）、:816（synchronizeCaptureTimingWithSegmenter）、:828（presentUnrecognizedSpeechWhileListening）、:1609（transition）、:1629（publish）。受け側 CatRobot/App/ConversationAppCoordinator.swift:76, 84-93。
- 内容: phase の書き手は `transition` と `publish` の 2 つだけで、そこでの通知は正しい。808/816/828 の 3 か所は phase ではなく `hasPendingSpeech` の変化を伝えるための呼び出しだが、coordinator は全部を phase 変化として `updateFaceEnvironment` + `updateInactivity` に流す。さらに receiveRecognition の else 分岐では synchronize 内の通知（816）と末尾の通知（808）で同じ値が 2 回届く。
- コスト: 部分認識結果ごと（周囲の会話でも数回/秒）に `expressions.setVisible`、`look.setVisible`、`ConversationCamera.setEnvironment`（認可状態の再読込 + reconcile）、`FaceTrackingCoordinator.setEnvironment`（reconcile）が主アクターで同期実行される。差分前は AppRootView の onChange で phase が実際に変わったときだけだった。量は数〜数十 µs/回で視覚への影響はないが、名前が読者を誤らせ、受け側で phase 変化と誤解した処理を足す口になる。
- 提案（どちらも動作同一）:
  1. 信号を分ける: `onPendingSpeechChange: @MainActor () -> Void` を追加し 808/816/828 をそれに替え、coordinator では `updateInactivity()` だけに配線。`onPhaseChange` は transition/publish の 2 か所に戻す。else 分岐の二重呼びは、末尾の通知を「segmenter が処理した 2 分岐」側に限定して解消。
  2. 最小案: coordinator に `lastForwardedPhase` を持ち、phase が変わったときだけ `updateFaceEnvironment(phase:)` を呼び、`updateInactivity(phase:)` は毎回呼ぶ（差分前の onChange の重複排除を再現）。
- やってはいけないこと（findings-altitude.md A2 で根拠付き）: VM 側で「hasPendingSpeech が反転したときだけ送る」重複排除、`viewState` の didSet で phase 変化だけ通知、`segmenter`/`captureIsClosing` の didSet から通知。`.ignore` / `.dismissPending` 経路では phase が listening のまま同相 transition でしか保留が解除されないため、取りこぼすと発話途中で寝る。重複排除するなら受け側（ConversationInactivity が保持値と比較）だけ。
- テスト影響: なし。改善を固定するなら「部分結果 1 回あたりの setEnvironment 呼び出し回数」を数えるテストを追加できる。`.ignore` 経路の idle テストが無いので、C2 に触るなら回帰を 1 本足す。
- 確認: 805-816 の二重呼びと 3 か所の通知地点を読んで確認した。
- 干渉: Codex R1/R2 は coordinator 側の監視条件と evaluate を触るが、この通知経路とは独立。

### C3（中）無活動として数える phase の一覧が 2 層に重複
- 場所: CatRobot/Conversation/Inactivity/ConversationInactivity.swift:77-82（`case .idle, .listening, .paused: break; default: setState(.awake); return`）と CatRobot/Conversation/UI/ConversationViewState.swift:48（`phase == .listening || phase == .idle || phase == .paused`）。
- コスト: 2 つの一覧は一致している必要があるが結び付きがない。phase を足す・数える phase を変えるときに 2 か所の同期編集が要る。
- 提案: `ConversationPhase` に網羅 switch の算出プロパティ（例 `countsTowardInactivity`）を、既存の `allowsTypedSubmission`（ConversationViewState.swift:78）・`permitsFaceTracking`（FaceTrackingTypes.swift:59）の隣に置き、両方で使う。evaluate は `guard phase.countsTowardInactivity else { setState(.awake); return }`、faceExpression は `inactivity == .sleepy && phase.countsTowardInactivity`。
- 動作保持: 一覧は同じ（.paused を含む）。
- テスト影響: なし。
- 確認: 両箇所を読んで確認した。
- 干渉と相乗: Codex R2 は evaluate の一覧に `.failed` を足す。先に C3 を入れると R2 は 1 か所の編集で済む。ただし表示側（sleepy の顔を failed で出すか）は仕様「sleepy は idle/listening のみ」に照らして Codex と決める必要があり、1 つのプロパティで両方を縛るかは R2 の採否と一緒に判断する（findings-altitude.md A3 の注記）。

### C4（中）分の範囲・既定値の手書きと、設定オブジェクトの二重所有の逃げ道
- 場所: CatRobot/Conversation/Inactivity/ConversationIdleSettings.swift:15-16, 24-25, 32-35（1/1439、2/1440、sleeping ≥ sleepy + 1、既定 5/10）、CatRobot/App/ConversationSettingsView.swift:72, 74（Stepper の `in: 1...1439` / `2...1440`）、:33（`idleSettings ?? ConversationIdleSettings()`）、ConversationAppCoordinator.swift:60/74（`idleSettings ?? ConversationIdleSettings()`）。
- コスト: 境界を変えると 4〜5 か所の編集。SettingsView の `??` は `.standard` 上に 2 つ目の無関係なインスタンスを作れる逃げ道で、live の ConversationInactivity はその編集を見ない（現状この経路を通るのは FaceConversationPresentationTests.swift:31 のカメラ fixture だけ）。
- 提案: RobotPreferences の `defaultTrackingYawCorrection` / `trackingYawCorrectionRange`（RobotPreferences.swift:14-16、RobotCalibrationView が同じ範囲を使う）に倣い、`static let sleepyRange = 1...1439`、`sleepingRange = 2...1440`、既定値の static、`static func normalized(sleepy:sleeping:) -> (Int, Int)` を 1 つ置いて setter・init・Stepper で共有。SettingsView の `idleSettings` は voiceSettings / modelSettings と同じく必須引数にする（カメラ fixture は専用 UserDefaults suite のインスタンスを渡す）。coordinator の `??` はテストの RobotAppHarness が通るので任意。
- 動作保持: 製品では同一（正規化の式は同じ）。
- テスト影響: カメラ fixture 1 か所に引数追加。
- 確認: ConversationIdleSettings.swift 全文と SettingsView 72/74、RobotPreferences 14-16 を読んで確認した。

### C5（低）settingsDidChange() は製品から呼ばれない
- 場所: CatRobot/Conversation/Inactivity/ConversationInactivity.swift:64。呼び出しは CatRobotTests/Conversation/Inactivity/ConversationInactivityTests.swift:25, 80, 83 のみ。
- コスト: 製品の反映経路は closeVoiceSettings → updateInactivity → setMonitoring → evaluate（UI の脚注「変更は設定を閉じたときに反映します」と一致）。使われない公開 API が「設定変更で即時再評価する」経路があるように見せる。
- 提案: 削除し、3 つのテストは `setMonitoring(true, phase:)` で駆動する（製品経路と同じ）。
- 動作保持: 製品は無変更。
- テスト影響: 3 行。
- 確認: grep で製品呼び出し 0 件を確認した。

### C6（中）sleeping の表示規則の分散、無効な guard、待機文言の二重定義、Accessibility の private 旗
- 場所:
  - ConversationViewState.swift:91 の `!isSleeping &&`（allowsTypedSubmission）。読者は VM（ConversationViewModel.swift:221, 243。VM 自身の viewState の inactivity は常に .awake。inactivity を設定するのは AppRootView の合成コピーだけ）と ConversationView.swift:226（typedInput 内。211 で sleeping 中は描画されない）。どちらでも項は効かない。実際の門は coordinator の launchAction（:408, 417）。
  - ConversationView.swift:80（`showsTypedInput && !isSleeping`）、:117（`!isSleeping, !provisionalTranscript.isEmpty`）、:211（同 80）、:233（マイク記号）のインライン判定。一方 caption / activityStatus / microphoneStatus は ViewState の displayed* 経由。
  - 「待機中・タップで起こす」が ConversationViewState.swift:52 と ConversationAccessibility.swift:40 に二重定義。
  - ConversationAccessibility.swift:30-42: private `isSleeping` 旗と 2 つの三項演算子が、`.resume` と保存した listeningSemantic を上書き。
- コスト: 画面に出す VM 由来の値を増やすたびに View 側で sleeping 判定を思い出す必要がある。VM の guard は「VM が待機中の文字送信を止めている」と誤読させる。文言は 2 か所の同期編集。
- 提案: ViewState を唯一の表示射影にする。`displaysTypedInput`（showsTypedInput && !isSleeping）、`displayedProvisionalTranscript`、`microphoneSymbol` を displayedCaption の隣に追加し View はそれだけ読む。`allowsTypedSubmission` から `!isSleeping` を外し「phase と記憶状態が文字送信を許す」の意味に戻す。待機文言は 1 つの定数を ViewState と Accessibility で共有。Accessibility は `ConversationListeningSemantic` に `.wake` case を足し（actionLabel「猫を起こす」、hint「タップして会話を再開します」）、旗と三項を削除。射影は AppRootView の合成ではなく ViewState に置く（スナップショット fixture は `inactivity` を直接セットして描くため）。
- 動作保持: 描画・VoiceOver 文字列・文字下書きの保持は同一。
- テスト影響: ConversationIdlePresentationTests.swift:14 の `XCTAssertFalse(state.allowsTypedSubmission)` を `displaysTypedInput` の否定に差し替え。スナップショットは不変。
- 確認: 各行と allowsTypedSubmission の読者、Accessibility の構造を読んで確認した。
- 干渉: Codex R4（caption を enterSleeping で消す）を入れると `displayedCaption` の sleeping 分岐は二重の仕組みになる。R4 と同時に一本化してよい。

### C7（中）coordinator の !isSleeping 条件の散在、ロボットモード規則の二重記述、二重 guard
- 場所: ConversationAppCoordinator.swift:90-91（監視条件）、:123（activeControlMode）、:127（顔の可視）、:144-148（開始完了 guard）、:169（resumeListeningIfNeeded）と :175（launchStart）、:231（`setApplicationMode(isSleeping && isVoiceSettingsClosed ? .inactive : nil)`）、:252（openVoiceSettings の明示 `setApplicationMode(nil)`）、:318-321 と :345-347（showTypedInput の同じ guard 2 か所）、:77-81（onStateChange）、:438-439（wake lock）。
- 内容とコスト:
  - 基盤が既に `destination == .conversation && scenePhase == .active && isVoiceSettingsClosed` をインラインで 5 か所に書いており、差分はその一部に `!isSleeping` を足し、一部（wake lock、監視）には意図的に足していない。どの門に sleeping を含めるかが各呼び出し地点の暗黙の選択になり、次に門を足す人が規則を再構築することになる。
  - 「待機中は設定シートが所有しない限り .inactive」という規則が activeControlMode（123）と updateRobotScene（231）の 2 通りで書かれ、openVoiceSettings はそれを戻すための明示 nil（252）を必要としている。効率面の帰結（E3）: 待機中に設定を開閉すると `.inactive → .conversation → .settings`、閉じるとき `.settings → .conversation → .inactive` と 1 回余分なモード遷移（MotionCoordinator.setControlMode と追尾 reconcile）が走る。
  - resumeListeningIfNeeded（169）と launchStart（175）の `!isSleeping` は重なる。showTypedInput の guard は 2 か所に同文。
  - onStateChange（77-81）は awake↔sleepy でも updateFaceEnvironment を呼ぶが顔環境は sleepy に依存せず、起床時は wakeFromSleeping の updateRobotScene と二重（E4、微小）。
- 提案: 述語を 1 度だけ名付けて使い回す。
  ```swift
  private var conversationOwnsForeground: Bool { destination == .conversation && scenePhase == .active && isVoiceSettingsClosed }
  private var conversationMayRun: Bool { conversationOwnsForeground && !isSleeping }
  private var standbyApplicationMode: RobotControlMode? { isSleeping && isVoiceSettingsClosed ? .inactive : nil }
  ```
  監視（90-91）は `hasStartedConversation && conversationOwnsForeground`、wake lock（438-439）は `conversationOwnsForeground`（「待機中も点灯」が式に見える）、127 / 144-148 / 169 は `conversationMayRun`。launchStart の guard（175）は全開始が通る唯一の門なので残す。activeControlMode は `standbyApplicationMode ?? (…)`、updateRobotScene(.active) と openVoiceSettings はどちらも `setApplicationMode(standbyApplicationMode)`（open 時は isOpeningVoiceSettings が先に立つので nil に評価され、明示 nil と同値）。showTypedInput は `showTypedInputIfAwake()` 1 本。`launchAction(allowWhileSleeping:)` はタップ起床と記憶保存再試行のための意図的な例外なので残す。E3 の遷移順入れ替え（open: settingsDidOpen を先に、close: sleeping なら .inactive を先に）は最終状態は同じだが過渡状態が変わるので、正しさレビュー側で副作用の有無を確認してから。
- 動作保持: 各述語はすべての呼び出し地点で同じ真偽値（wake lock と監視の意図的例外を含む）。
- テスト影響: なし（ConversationIdleIntegrationTests / RobotLifecycleIntegrationTests が経路を覆う）。
- 確認: 123 / 169 / 175 / 231 / 252 / 284-287 / 318-321 / 345-347 / 438-439 を読んで確認した。
- 干渉: Codex R1 は 144-148 の監視武装を変える。R1 の別旗と `conversationMayRun` を同時に設計するのがよい。

### C8（低）ConversationInactivity の内部整理
- 場所: ConversationInactivity.swift:50-62（recordActivity / wake）、:72-104（evaluate）、:33, 73, 98, 101（generation）。
- 内容: recordActivity と wake は guard 1 つを除いて同じ本体。evaluate は `clock.now` を 3 回読み（88, 91, 95）、sleepy/awake の判定を 2 分岐で重複計算。generation トークンは毎回 `timer?.cancel()` と同じ同期区間で増やされるため `!Task.isCancelled` で足りる（ただし FaceExpressionCoordinator にもトークン型の前例があるので、残す判断も妥当）。evaluate は期限が変わらなくてもタイマーを作り直す（scenePhaseDidChange → resumeListeningIfNeeded、closeVoiceSettings → resumeListeningIfNeeded、新しい会話の recordActivity → updateInactivity、開始完了 → transition(.listening) で 2〜4 回/イベント。部分結果ごとには作らない）。
- 提案: private `restart()` を 2 つの公開関数で共有。`let now = clock.now` を 1 度だけ読み、`finishingSpeech` を 1 度計算して各分岐で使う。期限が同じでタイマーが生きていれば早期 return（`armedDeadline` を保持。判定は generation 増加と cancel の前に置く。FaceTrackingCoordinator.scheduleWake と同じ型）。generation の削除は任意。
- 動作保持: 各分岐の終着状態は同じ。先頭の `updateInactivity()` 呼び出し順は testForegroundAndSettingsCloseEvaluateExpiredTimeBeforeStartingMicrophone が依存するので変えない。
- テスト影響: なし。
- 確認: ファイル全文を読んで確認した。
- 干渉: Codex R2 は evaluate の default 分岐を触る。R2 を先に入れてから整理する。

### C9（中・claude_sleep 所有・オフライン工具）face-render の複製
- 場所と内容:
  - scripts/face-render/Measure.swift:388-413（reportSleeping）が :147-181（report）の鼻・口・ひげ検出を複製: しきい値 200/150、isMouth（画面幅 ±10%）、口の結合、ひげの並べ替えと `index % 3 + 1` の命名。:285 のコメント「採用画像と同じ計測」は 2 つの写しが一致している間だけ真。
  - Render.swift の runSleeping（24-79）が run を複製: round 既存の guard と文言（27-31 vs 15-19）、save クロージャ（33-37 vs 88-92）、上下比較 + 区切り線（53-58 vs 125-130）、50% 重ね（59-62 vs 131-134）、縮小参照の compose（49-51 vs 135-137）、IoU 整形（73-74 vs 138-139、3 回）。
  - 下書きのパスが Measure.swift:213 と Render.swift:45 で別々に組み立てられ、縮小 + toneAgreement が両方にあるため `render_face.sh sleeping` は毎 round 同じ IoU を 2 回計算・2 回印字。
  - 小物: `@discardableResult`（Measure.swift:286、両呼び出しが戻り値を使う）、`arcBounds`（:300, 320）は `arcs.map(\.bounds)`、定数 0.2231（:221, 240）は `CatFaceGeometry.baseEyeRadii.height`（CatFaceShapes.swift:32）、GalleryView の列数 3 が 5 か所（Render.swift）、表示ラベル「|u| <= 0.9」に対し判定は 0.95（claude_sleep が deferred minor として記録済み）。
- 提案（出力は byte 同一のまま）: `noseMouthWhiskers(bitmap:tones:screen:excluding:)` を 1 つ切り出し report は eyeBounds、reportSleeping は arcBounds を渡す（印字は各呼び出し側に残す）。`roundDirectory(design:round:overwrite:)` と `saveComparison(reference:rendered:name:save:)`（compare / overlay / 任意の diff / IoU）を抽出し、run と runSleeping は「何を描くか・どの参照を読むか」だけ違う形に。`Measurement.sleepingDraftPath` 定数と縮小ヘルパを共有。別コマンドのまま維持（参照画像と出力が違うため `render --design DIR` への統合は非推奨）。
- 動作保持: stdout / measure.txt / PNG は同一。
- テスト影響: なし（harness のみ。採用後に `scripts/render_face.sh check` と preview の画素一致で確認）。
- 確認: 差分で複製を確認した。行番号は findings-reuse.md / findings-simplification.md のもの。

### C10（低）テストの重複断言・重複準備
- 場所: CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift:79-80 と :135-139（「まぶたが外形を覆う」を 2 テストで断言。Check.swift:76-77 / :156-160 も同様）、CatRobotTests/Face/FaceExpressionTests.swift:31-36（同じ事実を 4 通りで断言）、CatRobotTests/Conversation/Domain/UtteranceSegmenterTests.swift:49-50（既存 33-34 の再掲）、CatRobotTests/Conversation/Inactivity/ConversationIdleIntegrationTests.swift（同じ準備と後始末が 8 テストに、専用 UserDefaults suite の生成が 4 か所。suite は削除されない。ConversationUsageMeterTests は削除している）、同 :200（主要断言が `if h.sut.viewState.phase == .listening { … }` に包まれ、前提が崩れると黙って skip される）。
- 提案: 共有ヘルパ（準備・後始末・suite 生成と削除）、断言は 1 つに、:200 は `guard … else { XCTFail(); return }` か無条件に。
- 動作保持: 検証内容は同じ。
- 確認: 幾何テストと FaceExpressionTests は差分で確認した。他は findings-simplification.md / findings-altitude.md による。

### C11（低・任意）highlightDrop の端点ガードと closedLid の毎フレーム構築
- 場所: CatRobot/Conversation/UI/CatFaceShapes.swift:378（`guard lid > 0.000_1, lid < 1`）、:191（closedLid を全プリセットで毎フレーム構築）。
- 内容: ガードは「まぶたが外形を全部覆うなら白丸を動かしても見えない」という幾何条件の代用として端点 lid == 1 だけを特別扱いしている。補間中の lid ∈ [≈0.9, 1) では大きな drop を計算し、白丸の点はキャンバス外に出る（clip(to: outline) で見えないので画素には出ない。端点だけ見る「points in 0...1」の検査は通る）。closedLid は closed == 0 の表情でも毎フレーム作る（13 点の小パス、1 µs 未満、静止中はフレームなし）。
- 提案（任意）: ガードを幾何規則にする（白丸の u 範囲で lidEdgeV ≥ 1 なら 0 を返す、または needed を外形下端で clamp）。closedLid は EyeGeometry に EyeFrame を持たせた算出プロパティにしてもよい（all / mirroredShapes / テスト / harness はそのまま compile）。
- 動作保持: 画素同一（覆われた白丸は clip で隠れ、sleeping プリセットの drop は 0 のまま）。
- 採用条件: claude_sleep 所有。`scripts/render_face.sh check` と preview 36 ファイル + sleeping round の画素一致を必須にする。
- 確認: ガードと描画順（CatFaceView.swift:135 clip、159 lid、162 closedLid）は前回の顔差分レビューで読んだ。幾何規則への置換は未検証。

### C12（低）ExpressTool の 9 表情名の手書き一覧と expressible の二重真実
- 場所: CatRobot/Conversation/Tools/ExpressTool.swift:5（description）、:9（@Guide）、CatRobot/Conversation/Face/FaceExpression.swift:7（expressible）。
- 内容: 差分前からの手書き一覧（MoveHeadTool / RememberTool と同じ慣習）で、今回 `expressible` ができたことで真実が 2 つになった。`description` は `let` なので `expressible` から導出できるが、`@Guide(description:)` が非リテラルを受けるかは未確認（repo 内の使用はすべてリテラル）。
- 提案: 最小は、両文字列が `FaceExpression.expressible.map(\.rawValue)` とちょうど一致することを断言するテストを 1 本足す。description の導出は任意。
- 動作保持: 同一。

## 確認したが指摘しない点（要約）
- ConversationInactivity を phase や VM の関心にせず coordinator 隣の所有者にした設計は正しい高度（VM の phase 書き換え経路すべてで sleeping を守る必要がなくなる、資源の所有は coordinator、ConversationPhase の網羅 switch を増やさない）。
- `onAddressedActivity` の 4 か所（ConversationViewModel.swift:244, 966, 976, 1002）は routing の結果で phase から導出できないため適切。coordinator の `recordActivity()`（タップ :314、新しい会話 :355）も適切。
- coordinator の手置きの `updateInactivity()`（147, 168, 197, 251, 284, 356）: didSet に集約すると isOpeningVoiceSettings / showsVoiceSettings の受け渡し中に一瞬監視が入るので、明示呼び出しが正しい。
- `hasPendingSpeech` の `.listening` 限定は load-bearing（pause 経路は segmenter をリセットせず、transition(.paused) の通知は captureIsClosing 解除より前）。
- `UtteranceSegmenter.flushDelay` の修正は正しい場所（flushSegmentation 側の再アームは 1.2 秒ごとのポーリングになる）。
- `ConversationIdleClock` は RobotClock の新実装で並行機構ではない（ContinuousClock は端末スリープを含む）。置き場所を RobotClock.swift 隣にするかは任意。
- `Eye.closed` は blink と独立の層（lidAmount = lid + (1 − lid)·blink）なので lid から導出すると瞬きで金の弧が点滅する。別チャンネルが正しい。
- AppRootView の onChange 除去は仕様「SwiftUI の更新タイミングから独立」に沿う。C2 はその上に乗った余分な信号だけの話。
- Check.swift と XCTest の鏡写し（closedLidThickness を含む）は harness が XCTest を link できないための意図的な複製。
- テストの層分け（ConversationInactivity の単体で境界、coordinator で lifecycle の競合、RobotAppHarness で首と追尾）は適切。
- 閉包はすべて `[weak self]`、timer Task は clock だけ捕捉。UserDefaults の読込は init のみ。`setState` は等値 guard 付きで観測の空振りなし。

## 正しさレビュー（Codex）への申し送り（/simplify の指摘ではない）
- 仕様は「sleepy は idle/listening のみ」だが、ViewState:48 と evaluate:77-82 はどちらも `.paused` を含む。C3 の統合で 1 つの決定になるので、R2（failed）の扱いと合わせて意図を確定してほしい。
- `.ignore` 経路（同相 transition(.listening) だけで保留解除）の idle テストが無い。C2 に触るなら先に回帰を足す。
- E3 の過渡モード（待機中に設定を開閉すると一瞬 .conversation）の副作用の有無。

## 推奨する着手順（採否合意後）
1. Codex R1 / R2 / R4 の修正（coordinator・evaluate・enterSleeping）。
2. C3（phase 一覧の一本化。R2 の編集を 1 か所にする）→ C1（pause 手順の抽出。R4 の 1 行を含める）→ C7（述語の名付け。R1 の別旗と同時）。
3. C2（信号の分離 + `.ignore` 回帰）、C6（ViewState 射影。R4 と displayedCaption の一本化）、C4、C5、C8。
4. claude_sleep 所有: C9、C10（顔テスト分）、C11（任意、画素一致が条件）、C12。
