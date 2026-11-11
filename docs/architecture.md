# アーキテクチャ

この文書は、アプリの構成と、コンポーネントの間の約束事をまとめたものです。2026-10-28 の文単位再生への一本化と ViewModel の責務整理に加え、2026-11-07 の[挙動を変えない整理](superpowers/specs/2026-11-07-behavior-preserving-refactor-design.md)、2026-11-09 の[端末内モデルの削除と Haiku への一本化](superpowers/specs/2026-11-09-haiku-only-design.md)、2026-11-10 の返事の Hermes への移行（[検証記録](validation/2026-11-10-hermes-conversation.md)）を反映しています。手順は [README](../README.md)、仕様の一覧は [文書の索引](README.md) を見てください。

```
iPhone アプリ（SwiftUI、iOS 27、Swift 6 の strict concurrency）
  聞き取り → 宛先の判定（Claude Haiku、直近の会話つき。補助の経路） → 返事（利用者の Hermes の run API、最終出力を poll） → 文ごとの読み上げ（Supertonic）
  失敗したときは、種類ごとの定型文を声で案内してから表示する（別のモデルへの切り替えはない）
  顔の描画・表情・視線（前面カメラは画面の左に固定） ─┐
  首の動作の調停（MotionCoordinator） ───────────┼→ RobotLink ⇄ BLE（protocol v1） ⇄ XIAO ESP32C3 の
  顔追尾（FaceTrackingCoordinator） ──────────────┘                                    ファームウェア（2 軸サーボ）
```

## 組み立て

- **`ConversationComposition.live`**（App）: 本番の依存関係を 1 か所で組み立てる。組み立ての時点では、通信・マイクの起動・モデルの生成・記憶の読み書き・Keychain の読み出しをしない。返事・可否・記憶・宛先判定の履歴・設定の履歴に同じ `HermesConversationService` を 1 つ渡す。
- **`AppRootView(composition:onboardingSettings:)`**（App）: composition の全 field を、そのまま既存の init へ渡す。
- **`ConversationAppCoordinator`**（App）: アプリ全体の状態を受け持つ。
  - scene の状態、画面遷移、設定画面の開閉、無操作時の待機（inactivity）、画面の wake lock、会話の開始意図。
  - 首の制御モードと、カメラ・表情・視線の表示状態を各コンポーネントへ配る。
    - scene ごとの制御モード（`sceneControlMode`）は、設定画面のモードを設定した後に読む。
    - 設定画面からの復帰（`resumeAfterSettings`）は、settingsDidClose → 制御の更新 → wake lock → 聞き取りの再開、の順。
    - 操作を始めてよいかの判定（`permitsAction`）は、Task の中でも cancel の確認の後、scene の世代の確認の前に行う。
- **`ConversationDependencies`**: ViewModel が外部とつながる境界。認識、分類、返答、話者、audio session、記憶、首、表情、視線、計測、時計、テスト用の checkpoint がすべてここを通る。

## 会話

- **`ConversationViewModel`**: 会話の状態機械。次のものを受け持つ。
  - ライフサイクル（開始・一時停止・shutdown）
  - 聞き取りと発話の区切り（`UtteranceSegmenter`）
  - 宛先の判定（`AddresseePolicy`、`EngagementWindow`、聞き返し）
  - 返答の再生の起動と、聞き返しの定型句「今の、ぼくに言った？」の発話（`askForClarification`）。字幕と発話は固定の質問で、話し終えたときだけ、trim した元の発言と質問を記憶に残す
  - 失敗の後始末（定型文の読み上げを含む）と、記憶の操作
- **`ConversationViewState`**: 表示状態を表す値型。
  - `enter(_:caption:)` は phase ごとの口の形と状態文言の表で、この表はここにしかない。
  - 失敗の表示は `presentFailure` が持つ。定型文の読み上げ中は `isSpeakingFailureGuidance` が立ち、phase が speaking のまま文字入力だけを受け付ける（`allowsTypedSubmission`）。
  - 記憶の表示値は `memoryPresentation`（計算 property で、cache しない）から読む。
- **`VoiceTurnLatencyRecorder`**: 音声ターン 1 回分の latency token と `ReplyTrace` を持つ。記録と終了は、所有者（世代・ターン・キャプチャ）が一致したときだけ行う。
  - 所有者（`ConversationTurnOwner`）による取り消しと ViewModel の失敗処理は、同じ `isOwned` の判定を使う。shutdown 中かどうかの確認は ViewModel 側に残す。milestone の記録は、従来どおり世代とターンを直接照合する。
- **`ReplyPlaybackCoordinator`**: 1 回の返答の生成と再生を、1 つの所有タスクとしてまとめて待つ（join）。
  - 同時に動かせる返答は 1 つだけで、2 つ目は `modelBusy` になる。
  - `ReplyTurnObserving`（首・表情・視線を 1 つにまとめたもの）へ、beginTurn → speechStarted（1 回だけ）→ speechFinished／cancelTurn の順に知らせる。
  - 初期化は `init(reply:speaker:motion:)`。話者は `SentenceSpeechSpeaking` が必須で、旧来の再生 mode はない。
- **`SentenceReplyPlayback`**: 返答の文字列を文に分けて読み上げに回す。
  - 流れ: 生成の snapshot → `ReplySentenceStreamBuffer` → `SpeechSentenceChannel` → `speakSentences(prefetch: true)`
  - 文が確定するのは、安定した prefix の後ろに次の文字が来たときだけ。最後の文は生成の完了を待つ。
  - 文ごとに `sentenceStarted` と `sentenceFinished` を出す。全体の `speechFinished` は、生成が終わり、すべての文を読み終えた後に 1 回だけ出す。
- **Supertonic**: 端末内の読み上げ。
  - `SupertonicSentenceSpeaker` は 1 返答につき推論を 1 本だけ走らせ、先読みは次の 1 文だけ。定型句の単発の `speak` は先読みしない（`prefetch: false`）。
  - 読み上げ直前だけ `iPhone` →「アイフォーン」、`Bluetooth` →「ブルートゥース」に補正する。URL・メール・コード・識別子の一部と、保存・表示用の原文は変更しない。
  - `SupertonicEngine` は ONNX を動かす。`PCMPlayer` は `started` と `finished` だけを出す（`willSpeak` は出さない）。
  - native の各段階（準備・読み変換・合成）は `SupertonicErrorMapper.mapping` を通す。`CancellationError` は `.cancelled` にし、それ以外のエラーは `map` で会話のエラーに変換する（`map` に直接渡した `CancellationError` は `.speechSynthesisFailed` になる）。
- **聞き取り**: `AppleSpeechRecognizer`（Speech framework）、`SpeechAssetPreparer`、`AppleAudioSessionController`（割り込みと route の変更を知らせる）。

## 返答と会話の記録（Hermes）

- **`HermesConversationService`**: 通常の返事・会話の続き・履歴の正本を Hermes に置く adapter。返事（`MotionReplyGenerator` の内側）・可否・記憶・宛先判定に添える直近の往復・設定の履歴を 1 つのインスタンスが受け持つ（別々に作ると「新しい会話」が記憶の失敗を消せない）。
  - ターンごとに `HermesConnectionSettings.connection()` を読む。未設定は `.hermesNotConfigured`、401 は `.hermesUnauthorized`。返事・後始末・stop・履歴のどの要求の 401 でも同じ接続の拒否として覚え、その接続では明示の確認のほかは何も送らない（返事・記憶の準備・設定の履歴は送らずに `.hermesUnauthorized`）。拒否は接続ごとに覚えるので、キーを替えた後に前のキーへ遅れて届いた 401 は前のキーだけを拒否にし、今のキーの記録を変えない（そのターンはそれ以上送らずに終える）。どの要求も出す直前にその要求の接続の拒否を確かめるので、「新しい会話」の後に前の worker へ届いた 401 のあとは、並行する新しい worker も再送・照会・後始末・stop・履歴を送らない（run id と受付の分からない送信の記録は残す）。別のキーを保存すれば次のターンから使う。同じキーは、会話画面の「もう一度確認」（`retryRecovery` → 開始の preflight の最初、同じ世代の中）でだけ `recheckAvailability()` が認証付きの `GET /v1/capabilities` を 1 回送って確かめ直す。確かな 401 と取り消された確認は拒否のまま、届かなかった確認は拒否を外して次のターンの答えに任せる。session・端末の記録・履歴は変えない。
  - `POST /v1/runs`（明示 session、ターンごとに固定した Idempotency-Key と同じ body で再送）→ `GET /v1/runs/{id}` の poll。最終出力だけを読み上げへ渡す（2,000 文字までの最後の文末で切る。入力は 4,000 文字まで）。
  - 取消は端末の世代を先に無効化し、run id が分かれば `POST /v1/runs/{id}/stop`。遅れて届いた結果は採用しない。stop の応答や切断を終了とみなさず、終端を確かめるまで run id を記録に残し、次のターンの前に stop と 1 回の照会で確かめる（ターンは待たせない）。
  - 端末に残すのは識別子だけ（`HermesSessionRecord`: origin、session id、受付済みの有無、受付が分からない送信、終端未確認の run id）。会話の本文は保存しない。
  - 「新しい会話を始める」は新しい session id へ切り替えるだけ。Hermes 側の削除・忘却や、前の run の停止の成功を意味しない。
  - installed Hermes で終わらない（unknown の）run は、同じ session の後続を止める。端末は自動で resolve しない。返事の期限切れ（`.replyTimedOut`: 受付の分からない送信のまま、または受け付けられた run が終わらないまま期限を過ぎた）の表示から「新しい会話を始める」で抜ける。宛先判定（Haiku）の通信断や Hermes の 429・503（`.modelUnreachable`）では続けられる会話を捨てさせないので、この出口を出さない。
  - 体の操作（首・表情・見る・覚える）の tool は Hermes の返事からは使えない（robot の実行 bridge は繋いでいない）。
- **`HermesConnectionSettings`**: 接続先は https の root だけ（userinfo・path・query・fragment・IPv6 リテラルは拒否、scheme と host は小文字、443 は省く）を UserDefaults、API キーは Keychain（service `com.kamby.CatRobot.hermes`、account = origin）に置く。保存は「確かめる → キーをその origin へ → URL」の順で、キーを保存できなければ前の設定を残す。別の origin へ前のキーを送らない。通信は `HermesURLSessionTransport`（OS 標準の証明書の確認、redirect を追わない、cookie と cache なし）。
- **`ContextualAddressClassifier`**（補助の経路）: 宛先の判定。`ConversationHistoryReading`（`HermesConversationService` が実装。準備前は空）から直近の往復を読み、確認待ちなら末尾の「元の発言 → 聞き返し」の往復を除き、新しい側から合計 4,000 文字（`ConversationBudget().retainedCharacters`）までを `recentTurns` として `ClaudeAddressModelClient`（Haiku 5.5、effort low、timeout 15 秒、fallback なし）へ JSON で渡す。端末内の分類はない。指示文は 2026-11-09 の Haiku 一本化のまま。声の会話には Claude の認証（Debug は開発用キー、Release は App Attest）が要る。文字の会話は Hermes だけで続けられ、宛先判定の失敗には「文字で話す」を出す。
- **`ConversationFailureGuidance`**: 失敗の種類ごとの定型文（9 文）。Claude を名指ししない中立の文で、声の宛先判定（Claude）が使えないときだけ「文字で話しかけてね」の文（`voiceAddressing`）にする。`ConversationServiceError.spokenGuidance` が対応を決め、読み上げ・audio session・マイクの許可・取り消し・聞き取れなかった場合（`speechUnrecognized`）は声で案内しない。
- **`MotionReplyGenerator`**: 返事（`HermesConversationService`）を直接受け、生成が終わったことを首に知らせる。アプリ独自の利用量集計・保存と日次上限はない。
- **木に残るが通常の経路では使わないもの**: `ClaudeConversationService`、`ConversationModelSettings`、記憶の store（`current.json` / `facts.json`）、`LongTermMemoryManager`、robot の tool provider。live の組み立てから外し、Claude で返事を代わりに作ることはしない。以前の版が保存した記憶のファイルは読まず、消しもしない。

## 顔・視線・首

- **顔の描画**: `CatFaceView`、`CatFaceShapes`、`CatFaceAppearance` の 3 ファイル。
  - `scripts/render_face.sh` と `tools/face-size-tuner` も、この 3 ファイルを直接コンパイルしている。
  - そのため `MouthPose` と `FaceExpression` のケースの名前と順序は、`scripts/face-render/Stubs.swift` と揃えておく必要がある。
- **`FaceExpressionCoordinator`**: phase と `express` tool から表情を決める（`express` は以前の Claude 構成の tool で、Hermes の返事からは呼ばれない）。
- **カメラと視線**:
  - `ConversationCamera` と `AppleFaceCaptureSource` が前面カメラを扱う（画面の左に固定）。
  - `LookCoordinator` は `look` tool の撮影と、画像を保持する期間を受け持つ（Hermes の返事からは呼ばれない）。
- **`FaceTrackingCoordinator`**: 顔の位置から追尾の指令を作る。
  - 画像の鮮度は `isFresh`（`now − capturedAt < 0.4 − 0.000001`）で判定する。
  - 顔を見失ったとみなす 10 秒（`faceLossTimeout`）は、温度による休止の 10 秒とは別の値。
- **`MotionCoordinator`**: 首の動作の調停。
  - 返答のジェスチャの予約（1 ターンあたりの予算は 4 秒。`move_head` tool からの予約で、Hermes の返事からは呼ばれない）、待機時の微動、追尾との調停、STOP の規則、強度（SET_LIMITS）を扱う。
  - 待機時の微動は、顔の計画からの要求（`requestIdleFaceMotion`）だけで動く。4〜10 秒ごとに乱数で動かす旧来の内蔵スケジューラは、2026-11-07 に撤去した。
- **`RobotLink`**: BLE の通信。
  - 接続、暗号化、handshake、heartbeat、STATUS の鮮度。
  - コマンドを受け付けるかの判定と queue（同じグループは置き換え、motion 系は 0.3 秒で期限切れ、token を無効にすると queue から除く）。
- **`RobotSettingsModel` と `RobotCalibrationSession`**: 接続先、強度、追尾の設定、校正（校正中は首を専有する）。

### 首の安全上の約束事（変えるときは仕様とファームウェアに合わせる）

- **STOP**:
  - link を失ったときと background に入ったときは、STOP を送らない（ファームウェアが自分で中立へ戻る）。
  - 利用者が停止したときと新しい会話を始めたときは、必ず STOP を送る。
  - 手動の STOP は暗号化が済んでいれば受け付け、最優先で送る。
- **アプリが inactive の間**: 送れるのは heartbeat・STOP・settlement だけ。
- **追尾の上限**: ±45°/±10°、速度 20、0.2 秒以上の間隔、2° の不感帯。
- **待機時の微動の上限**: ±3°/±2°、速度 10。
- **自動電源オフ**: 待機と追尾がどちらもオフのときだけ行う。

## ファームウェア（`firmware/`）

- **`lib/catneck`**: `Protocol`（v1）、`SerialParser`、`Planner`、`Gesture`、`Axis`、`Supervisor`（安全状態機械）。
  - ACTIVE で動作・保守の通信（PING を含む）が 3 秒途絶えると RETURNING に入り、安全復帰速度で中立へ戻る。中立に着くか 2 秒の期限（期限では止まれる位置で保持）で RELAX_WAIT、さらに 2 秒で IDLE。BLE が切断されたら ACTIVE から待たずに RETURNING に入る。
- **`src`**: `main`、`Console`、platform（`BleTransport`（NimBLE）、`NvsStorage`、`SerialTransport`、`ServoDriver`）。
- **ビルドの env**: `xiao`（実機用）、`xiao_bringup`（サーボを出力しない）、`native`（ホストでの単体テスト）。

## 非同期処理の所有権の約束事（ConversationViewModel）

- **`lifecycleGeneration`**: 開始、一時停止、文字入力、scene が inactive になったときに進む。古い世代から届いた非同期の結果は捨てる。
- **`turnID`**: 1 回の返答ターン。表示・計測・失敗処理は、`activeTurnID` と一致するときだけ行う。
- **`captureID`**: 1 本の認識ストリーム。区切りの確定後に届いた末尾は、同じキャプチャのものだけをつなぐ。
- **`ConversationTurnOwner`**（lifecycle / turn / capture）: 失敗の後始末と計測の取り消しは、所有者が一致したときだけ行う。古い所有者が新しいターンの計測や trace を終わらせることはない。
- **操作の意図**: 前の後始末を待っている間に、後から開始・文字入力・一時停止が来たら、先に来た操作は取りやめる（`awaitTaskKeepingIntent`）。
- **cancel と join の順序**:
  - **失敗の終了**: 返答・宛先判定・文字入力・開始前の確認・聞き取りのどの失敗も `finishFailure` を通る。(1) 同期部で聞き取りの意図と確認待ちを消し、`failureCleanupTask` を最初の await より前に登録する。その Task が (2) 再生の join と、起点が認識を使っていれば認識の停止 → (3) 定型文があり所有者が一致していて audio session が未起動なら、話者と audio session の準備 → (4) 所有者が一致していれば phase を speaking にし、開始前も取り消せる子 Task で定型文を読み上げる（所有を失うと話者の停止より前に子だけを取り消し、後始末の Task は子を待ってから続行する） → (5) 話者の停止、audio session を起動していれば（音声の会話から引き継いだ場合と、起動を試みて失敗した場合を含む）その解除、`contextExceeded` のときだけ返答 session の reset → (6) 所有者が一致していれば失敗の表示（記憶の失敗なら paused）、の順で行う。所有者が変わると (3)(4) の新しい案内と (6) の表示は行わないが、(5) の停止・解除・reset は必ず行う。後始末はこの Task だけが行うので、操作が重なっても `deactivate` は 1 回で、遅れて `activate` や読み上げが始まらない。
  - **一時停止**: まず世代を進めて paused を表示し、その後で実行中の作業を切り離す。そこから先は状況で二通り。
    - 通常: 再生の join → 話者の停止 → 認識の停止 → キャプチャ・区切り・ターンの join → audio session の解除。
    - 失敗の後始末の最中: 再生の join と話者の停止を行ってから `failureCleanupTask` を待つ（読み上げ中の定型文はここで止まり、その失敗の表示は出さない）。キャプチャと区切りの確定作業は cancel してから join する。
  - **shutdown**: 明示的な teardown の約束事として残している。今の本番 UI からは呼ばれていないが、テストの停止境界として使っている。
- **表示と聞き取りの再開**:
  - 文と文の間は口を閉じ、phase は speaking のままにする。
  - 返答全体が終わるまで聞き取りを再開しない。
  - 首の解放は 1 回だけ。
- **生成が途中で失敗したとき**: 失敗（生成の失敗、2000 字を超えたときの `inputTooLong` を含む）の後で、未確定の末尾を合成も読み上げもしない。
  - 回帰テストは `SentenceReplyPlaybackTests` と `ReplyPlaybackCoordinatorTests`。修正後の各20回、計40回の繰り返し試験で失敗0件（[検証記録](validation/2026-10-28-main-refactor.md)）。

## テストの入口

| 対象 | 入口 |
|---|---|
| iOS の単体・統合テスト | README「Simulatorでビルド・テスト」（`xcodebuild … -scheme CatRobot test`）。Hermes と Claude API には接続しない（Hermes は `FakeHermesServer`） |
| Hermes の会話 | `HermesConversationServiceTests`、`HermesSubmissionUncertaintyTests`、`HermesConversationBoundaryTests`、`HermesConnectionSettingsTests`、`HermesAuthorizationRecheckTests`、`HermesConversationExitTests`、`ConversationHistoryModelTests`、`HermesConversationLiveSupportTests`（受入試験の fault fixture） |
| 会話の状態機械 | `ConversationViewModelTests`、`ConversationRecoveryTests`、`ConversationAutoResumeTests`、`ConversationNewSessionTests`、`ConversationMemoryIntegrationTests`、`ConversationIdleIntegrationTests`、`FailureGuidanceTests`（失敗の定型文と後始末） |
| 再生と計測 | `SentenceReplyPlaybackTests`、`ReplyPlaybackCoordinatorTests`、`ReplyPlaybackIntegrationTests`、`ConversationLatencyTests`、`ReplyTraceTests`、`VoiceTurnLatencyRecorderTests` |
| 表示と VoiceOver | `ConversationViewStateTests`、`ConversationAccessibilityTests`、`FaceConversationPresentationTests` |
| 首と追尾 | `MotionCoordinatorTests`、`FaceTrackingMotionTests`、`RobotLinkTests`、`RobotLifecycleIntegrationTests`、`RobotProtocolTests` |
| 実機専用（通常のテストではスキップ） | `scripts/run_hermes_conversation_live_test.py`（Debug 専用。Hermes の隔離 profile と Mac の LAN relay、偽の radio とカメラ。手順は `scripts/hermes-conversation-live-test.md`）、`SupertonicIntegrationDeviceTests` scheme と `scripts/run_supertonic_integration_device_test.sh`、`scripts/run_robot_motion_device_test.sh`（7 動作×3 強度。首が見える状態で実行する）、`scripts/run_haiku_addressing_model_tests.sh`（有料。`HaikuAddressingModelTests` の 23 fixture × 3 回を本番の Haiku で判定する） |
| プロジェクト生成の契約 | `ruby scripts/generate_project.rb && ruby scripts/test_generate_project.rb`（pbxproj と共有 scheme は直接編集しない） |
| 顔の描画計測 | `scripts/render_face.sh check` と `scripts/render_face.sh measure`。新しい round は顔が 9 から、寝顔が 3 から |
| Python のスクリプト | `scripts/test_*.py`（音声資産の準備・検証、実機結果の集計） |
| ファームウェア | `cd firmware && pio test -e native`（ホストでの単体テスト、実機は不要） |
| 顔サイズ調整ツール | `tools/face-size-tuner`（README を参照） |
