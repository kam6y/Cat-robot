# 挙動を保つリファクタリング（2026-11-07）

2026-11-07。基点 `3699ef13`（main、#29 統合後）、作業ブランチ `codex/refactor-20261107`。

## ユーザーの指示と判断の区別

- ユーザーの依頼（agmsg 経由で受信 11:54:18Z、正確な発言時刻は未確定）:「かなり実装を進めたのでここでリファクタリングを行ってください。もう寝るので自律的に進めておいてください。実機検証は後でしてください。」
- ユーザーの追加判断（Claude のセッションで 12:08:58Z 以降に受信、正確な発言時刻は不明）:「待機中の動きの古い仕組みは本番で使ってないなら消していいよ」。対象は T1 に記載する。
- ユーザーは途中の質問を不要とした。以下の対象・順序・除外・検証方法は Codex と Claude の判断であり、個別にユーザーの承認を得たものではない。
- 今回の完了範囲は、ブランチへの commit、自動検証、独立レビューと受領判断、引継ぎ記録まで。main への統合と push は対象外（#29 の承認はこのタスクへ流用しない）。有料のモデル試行と端末操作は行わない。人による実機確認は後日。

## 目的と方針

#22〜#29 で会話経路・要約・首の待機動作に機能が積み重なった。現役の責務を読みやすくするため、根拠のある小さな単位だけを整理する。小さな清掃案をすべて実施することは目的にしない。4 領域の読取監査（`/private/tmp/cat-refactor-20261107/claude-audit/`）から、効果があり既存の試験で固定できるものを選んだ。

- 各 task は単独で commit でき、どの task の後で止めてもブランチは一貫して動作する。
- 既存の試験が期待する挙動とオラクルを弱めない。例外は次の 2 つだけとし、計画と記録で個別に示す。
  - compile のためだけの引数の適応（例: T3 の `previousSummary:` の明示、T1 の `random:` の削除）。
  - T1 で旧経路に固有の試験を分類し、移植または削除すること。
- 試験側の整理は、それに固定される本番の整理より後の task で行う。
- 既存の試験で固定されていない挙動に触れる場合は、先に現行コードで通る特性試験を追加する。新しい API が無いことによる compile error は、意味のある RED と扱わない。
- 非同期処理の actor / await / cancel / join の順序は変えない。

## 維持する契約

- UI の文言と表示、VoiceOver、保存形式・保存先・互換 ID、依存パッケージの版。
- モデル入力。保証する範囲を次のように区別する。
  - 固定の指示、生成した返答指示、要約 prompt は、UTF-8 の byte 列を変えない。
  - 分類の JSON は、key を整列した論理 payload を変えない（#29 で知られた `JSONEncoder` の key 順は wire 上の保証に含めない）。
  - SDK による包装と HTTP の wire bytes は観測していないので、保証の対象外とする。
- `@Generable` の型名、`@Guide` の字面、schema の field 名と case 名。
- 首・追尾・電源の安全条件と判定順、校正・リミット・停止・heartbeat・再接続。
- `project.pbxproj` は `ruby scripts/generate_project.rb` でのみ変更する。
- 実機ランナー（`scripts/run_*_device_test.sh`）は、後日の実機検証まで現状のまま残す。

## 対象（優先順）

T1〜T7 はすべて計画に含める。延期は、計画や実装の途中で新しい根拠のあるリスクが見つかったものに限り、理由を記録する。順序は、試験の書換えがそれに固定される整理より後になるよう決めた（T5 は T2・T3 の固定試験に触れ、T7 は T1 と同じ `ConversationAppCoordinator.swift` に触れる）。

### T1 内蔵の待機動作スケジューラの撤去（ユーザー判断）

これは挙動を保つ整理ではない。本番では到達しない経路を、ユーザーの条件付きの判断に基づいて撤去する。試験と実機用試験からは到達できるため、その契約は移植するか削除する。

- **対象:** `MotionCoordinator` の内蔵スケジューラ（待機中に 4〜10 秒ごとに乱数で yaw ±3°・pitch ±2° の列を始める処理、`serviceAutonomous` 末尾）と、`idleFaceDriven` flag、`setIdleFaceDriven(_:)`、`nextIdleAt`。2026-10-30 の待機中の猫の生活（顔の計画から首へ要求する方式）以降、本番の待機動作はこの要求経路だけで動いている。
- **本番で到達しない根拠（読取による。T1 の特性試験で現行コードについて確かめる）:**
  - 本番の `MotionCoordinator` は `ConversationComposition.swift:30-31` の 1 個だけ。motion の phase を変えるのは `ConversationViewModel.swift:112`（`announcePhase`）だけである。
  - `AppRootView.init`（`AppRootView.swift:52-61`）は VM を作り、続けて同期的に `ConversationAppCoordinator` を作る。このとき VM の init（`:107`）が `announcePhase(.idle)` を呼ぶ。`.idle` は `isWaiting`（`MotionCoordinator.swift:422`）に含まれる。
  - それでもスケジューラは arm されない。arm には `atRest`（`:421`、接続済みで準備完了かつ STATUS が静止）が必要である。この時点の `RobotLink` は作られたばかりである。init（`RobotLink.swift:70-76`）は既定の snapshot に device だけを設定し、transport と monitor は start / resume まで起動しない。その開始は後の `updateRobotScene` の `link?.resume()`（`ConversationAppCoordinator.swift:254`）である。STATUS が無いので `serviceAutonomous` は `:758` で `nextIdleAt = nil` とする。
  - 仮に arm されたとしても発火はしない。続く Coordinator の init の最後（`:99`）が、同じ MainActor の同期処理の中で `setIdleFaceDriven(true)` を呼び、`nextIdleAt = nil` にするためである。発火させる `tick` の timer は接続中にだけ存在し、ここには suspension point がない。
  - flag は本番では false から true へ一度だけ変わり、false へ戻す呼出しはない。そのため、後で `AppRootView.init` が再評価されて新しい VM が `.idle` を通知しても、スケジューラの guard（`!idleFaceDriven`）は成り立たない。同じ理由で、`requestIdleFaceMotion`、`requestYawnMotion`、`cancelIdleFaceMotion` の `idleFaceDriven` guard は、本番では常に成り立つ。
  - スケジューラに到達するのは、試験の `MotionHarness`（既定値 false）と、実機用の `RobotMotionIntegrationDeviceTests.swift:52-57` だけである。
- **残すもの:**
  - `RobotPreferences.idleEnabled`（「待機中も少し動く」）。顔の要求を受け付ける条件として使う。
  - 顔からの待機動作とあくび、追尾優先、上下限と速度。
  - `RobotRandomSource`。顔の計画（`CatFaceLife`）が使う。
- **進め方:**
  1. 撤去の前に、本番と同じ配線の特性試験を追加する。現行コードで通ること。
     - 実際の VM → Coordinator を構築する。motion は接続済み・準備完了・静止とし、`idleEnabled = true`、`trackingEnabled = false` を明示する。
     - 顔の cue が出ない条件のまま 12 秒以上進め、MOVE と idle 優先度の自動書込みが無いことを観測する。
     - 時間は `MotionHarness.advanceFresh(by:)` と同様に STATUS を新しく保ちながら進める。clock だけを進めると、link が stale になって動かないだけの偽の成功になる。
     - 検出力を示すため、同じ手法で、face-driven を有効にしない対照（Coordinator を通さず motion だけで同じ phase にする）では旧スケジューラの MOVE が出ることも確かめる。この対照は旧経路に固有なので、撤去時に削除する。
  2. 依存する試験を推測でなく実測で特定する。計画段階の新しい HANDOFF の下で、既定値を true にした一時的な変更（commit しない）で Motion・FaceTracking・RobotLifecycle の suite を実行する。失敗した試験を全件一覧にし、1 件ずつ「旧スケジューラに固有なので削除」か「現行の契約なので移植」かを理由付きで記録する。
  3. 撤去の前に、まだ有効な契約を顔の要求の API で書いた試験へ移植する。既知の候補:
     - holding で抑止され searching で許可される
     - 熱による停止中は動かない
     - 顔の取得が、queue 済みの次の sample を含めて待機動作に優先する
     - 発話が送信待ちの待機動作を無効にする
     - 列の上下限・速度 10・50ms 間隔

     MotionHarness の単体でも「顔の要求なしで 12 秒待っても待機動作を送らない」固定試験を追加する。これらは現行コードで通ること。
  4. 撤去する。試験の変更は `setIdleFaceDriven(true)` の削除と `random:` 引数の削除だけにとどめる。スケジューラ固有の主張（4〜10 秒の間隔、3〜4 秒の乱数の長さ）を持つ試験は削除する。
- **影響を受ける file:**
  - 本番: `MotionCoordinator.swift`、`RobotMotionControlling.swift`（要件と既定実装）、`ConversationAppCoordinator.swift`、`ConversationComposition.swift`
  - 文書: `docs/architecture.md`（待機時の微動は顔の計画からの要求だけで動くこと。必要なら文書索引も）
  - 試験: `MotionTestDoubles.swift`、`MotionCoordinatorTests.swift`、`FaceTrackingMotionTests.swift`、`RobotLifecycleIntegrationTests.swift`
  - `RobotMotionIntegrationDeviceTests.swift`: compile のための引数変更だけで、実行しない
- **後日の実機確認:** 待機中の首の視線追従・あくび・追尾への引継ぎ。

### T2 聞き返し発話経路の整理（VM）

- **聞き返し専用の発話関数:** `speakAndResume` を、聞き返し専用の `askForClarification(candidate:generation:turnID:)` に置き換える。
  - 呼出し元は #22 以降 1 か所だけで、`.clarifying` と `.none` を渡している。
  - 関数内の trace と latency の呼出しはすべて効果がない。直前の `VM:1010` で、このターンの計測を `.ambiguous` で終えているためである（`VoiceTurnLatencyRecorder.cancel` で `active = nil`）。新しい計測が始まるのは次の capture 境界（`VM:890`）だけである。
  - 次の点は変えない:
    - 記憶へ渡す prompt。渡された candidate を trim した値を関数の中で保持する。期限 task が発話中に消し得る `pendingClarification` から読み戻さない。
    - `setPendingClarification` を発話より前に呼ぶ順序
    - 失敗時の `finishVoiceFailure`
- **`EngagementUpdate`:** `.arm` と `.refresh` だけにする。`generateReply` の呼出しは `.arm` と `.refresh` だけを渡している。
- **`classifyAndRespond` の抽出:** `performTurn` の分類分岐を抜き出す。`do` の中で throw するのは `classifier.classify` だけなので、`switch target` を `do` の外へ出す。await の順序は変えない。分類の trace に `ReplyTraceContext.withTool` は使わない（取消しの記録が `.cancelled` に変わるため）。
- **`ConversationTurnOwner.isOwned`:** `VoiceTurnLatencyRecorder` と VM にある同じ owner 判定を共用する。
- **文書:** `docs/architecture.md:27` の古い定型句「なあに？」を直す。
- **固定する試験:**
  - `ConversationLatencyTests`
  - `ConversationRecoveryTests`（聞き返しの表示と失敗）
  - `ConversationMemoryIntegrationTests`（聞き返しの保存と中断）
  - `ClarificationRoutingTests`
  - `AddresseePolicyTests`
  - `FacingAddressingTests`
  - `VoiceTurnLatencyRecorderTests`

### T3 要約の入力と結果の整理

- **先に固定試験を足す:** `referenceTurns` を含む `ConversationSummaryRequest.prompt` を、byte 単位で比べる試験を `ConversationInstructionsTests` へ追加する。比較は Swift `String` の正規化等価ではなく、`Array(actual.utf8) == Array(expected.utf8)` で行う。参照部の見出しは、現在 byte 単位では固定されていない。
- **既定値の除去:** `ConversationSummaryResult` の `previousSummary: = ""` の既定値を除く。既定値があると `.noContent` が空文字へ戻せてしまう。呼出し元の試験（`ClaudeSessionFactoryTests`）は引数を明示する。
- **共通化:** 文字数検証を `validatedSummary(_:characterLimit:)` にまとめる。factory と service の 2 層の検証は、別の契約なので両方残す。
- **今回はやらない:** 返答指示と要約 prompt の transcript 生成の共通化。モデル入力に触れる割に利益が小さい。

### T4 Supertonic のエラー変換

`SupertonicSentenceSpeaker` の convenience init にある 3 つの closure（prepare / normalize / synthesize）は、同じ do/catch を持つ。`CancellationError` だけを `.cancelled` にし、それ以外を `SupertonicErrorMapper.map` に渡す。この変換を 1 つにまとめる。

1. 既存の `map` の意味を、`SupertonicErrorMapperTests` で先に固定する。現状の差はそのまま固定する:
   - `missingAssets` / `invalidAssets` / `unsupportedVoice` → `.speechVoiceUnavailable`
   - `JapanesePronunciationError.dictionaryUnavailable` を含むその他 → `.speechSynthesisFailed`
2. 旧 do/catch と同じ処理を `SupertonicErrorMapper.mapping` として機械的に抜き出す。境界の試験を足して GREEN にする:
   - `CancellationError` → `.cancelled`
   - その他のエラー → `map` と同じ結果
   - 成功値はそのまま通る

   API が無い状態の compile error は RED と呼ばない。
3. 3 つの呼出し元を `mapping` へつなぎ替える。

### T5 分類器の未使用 adapter と試験用 double

- **未使用の adapter:**
  - 呼出しのない `AddressModelClient.classify(String)` を削除する。
  - 本番では呼ばれない `AddressClassifying.classify(String)` は、試験の support へ移す。
- **試験用 double:**
  - fake の `calls`、`prompts`、`requestCount` を、`requests` から計算する値にする。
  - `waitForSummaryCondition` は、`ConversationHarness.waitUntil` と同じ時間制限付きの待機である。これを共通の helper（例: `pollUntil`）にまとめ、harness もそれへ委ねる。timeout・間隔・失敗時の message は保つ。名前を `waitUntil` にはしない（XCTestCase extension と衝突するため）。
  - 時間制限のない `gate.waitUntilEntered()` へは置き換えない。regression 時に失敗ではなくハングになるためである。
  - `makeClaudeService` に引数を足し、試験内の builder の重複をなくす。
- **前提:** T2・T3 の後に行う。

### T6 UI の小さな重複

- `memoryPresentation` を計算 property にし、8 か所で使う。
- 設定にある 3 つの識別子文字列を、`ConversationSettingsIdentifier` へ移す。値は同じにする。あわせて `ConversationAccessibilityTests` の宣言一覧に加える。

### T7 Coordinator と追尾の小さな重複

- **`sceneControlMode`:**
  - scene から制御モードへの対応表を 1 つにまとめる。
  - `setApplicationMode` の後に読む。
  - `let` に持ち上げない。
  - `updateRobotScene` の引数を除く。
- **設定画面を閉じた後の再開:** `resumeAfterSettings()` と `permitsAction(allowWhileSleeping:)` を抽出する。`updateInactivity()` は含めない。
- **`AppRootView` の convenience init:** composition から作れるようにする。
- **`FaceTrackingCoordinator`:**
  - 鮮度判定を `isFresh(_:)` にまとめる。式はそのまま残し、`CameraSnapshot.isFresh` は使わない。
  - `faceLossTimeout` を定数にする。
- **前提:** T1 の後に行う。

## 今回は対象外とするもの

| 候補 | 理由 |
|---|---|
| VM の 3 組の counter・ID を共通の ownership 型へ | 寿命と取消しの意味が絡み、利益が小さい |
| `PendingClarification.isActive(at:)` を policy と VM で共用 | VM の `>=` を `!(<)` に変えると NaN などで同値でなくなる。比較境界の意味を動かす利益が小さいので、既存の記法を保つ |
| Coordinator の待機動作 guard を表示中の状態へ統合 | gate の特性試験が先に必要。停止中の `hasPendingSpeech` に未固定の挙動がある |
| 実機ランナーの snapshot・xctestrun 処理の共通化 | 後日の実機検証まで実行経路を変えない |
| `RobotMotionControlling` の既定実装を明示的な no-op に | idle-life 計画での判断。所有者の確認が必要 |
| `RobotCommand` 判定の共有、generator の phase helper、顔の `closeEyes()`、再生 event の payload 削除、試験配置の移動 | 利益が小さい。画素比較などの追加検証が必要 |
| 試験 support の大規模な重複整理（wake lock、camera harness、polling、BLE literal、count waiter） | 試験だけの整理。上の task で同じ file に触れる箇所に限って扱う |
| 首と追尾の安全経路の数値（epsilon、clamp）、capture の部分リセット、音声とセッションの停止順 | 安全条件と停止順を保つため |

## 検証

- **各 task:** 関係する suite を実行し、最後に全通常 XCTest を実行する（実機と有料の 3 class は除外）。実行は Codex の `/private/tmp/cat-refactor-20261107/run-tests.py` で行う。入力 digest を前後で照合し、選択した試験が 0 件になる誤りを検出する。
- **モデル入力の不変:**
  - T3・T5 の後と最終候補で、ネットワークなしの `testFixtureInventoryAndPromptSizes` を Simulator で単独実行する。
  - 結果を `model-inputs-before.json`（24 fixture の分類・返答・要約の実 instructions と prompt）、および `model-contracts-before.json` と照合する。
  - #29 の 72 試行を新しい source で再実行したとは記載しない。
- **最終候補:**
  - 生成の契約試験と pbxproj の差分の有無
  - Python の試験
  - 通常の署名付き generic iOS build（install と起動はしない）
  - T1 で実機用試験の引数を変えるため、実機専用の試験本体も compile まで確認する（generic iOS の build-for-testing など、Xcode が許す方法を Codex が確認する）。実行・install・課金は行わない。
- **レビュー:**
  - Claude の `/simplify` 4 観点（report-only）と、Codex の独立レビュアー 1 名。
  - それぞれ初回の結果を保存してから交換し、`receiving-code-review` で採否を記録する。
- **記録:** `docs/validation/2026-11-07-behavior-preserving-refactor.md` に、未確認の実機事項（T1 の首の待機動作）を明記する。

## 分担

- **計画:** この設計を両者で確定した後、Codex が Driver として `writing-plans` で計画を作る。
- **実装:** task ごとに Driver を交代する。HANDOFF では対象 file を上の task 単位で固定する。
- **Git と検証:** Git、build、test、commit は Codex が行う。Claude は担当 task の編集と、Navigator としてのレビューを行う。

## 旧記述の扱い

`2026-10-11` 要件の FR-MOV-6 と `2026-10-23` robot-link 設計の待機微動の節には、4〜10 秒の乱数動作が残っている。これらは歴史記録として本文を書き換えない。後継の方式（2026-10-30 の待機中の猫の生活）と今回の撤去は、この設計、検証記録、必要なら現行の `docs/architecture.md` と文書索引で示す。
