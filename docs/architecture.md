# アーキテクチャ

この文書は、現在の main の構成と、コンポーネントの間の約束事をまとめたものです。2026-10-28 の文単位再生への一本化と ViewModel の責務整理を反映しています。手順は [README](../README.md)、仕様の一覧は [文書の索引](README.md) を見てください。

```
iPhone アプリ（SwiftUI、iOS 27、Swift 6 の strict concurrency）
  聞き取り → 宛先の判定 → 返答の生成（Claude、失敗時は端末内モデル） → 文ごとの読み上げ（Supertonic）
  顔の描画・表情・視線（前面カメラは画面の左に固定） ─┐
  首の動作の調停（MotionCoordinator） ───────────┼→ RobotLink ⇄ BLE（protocol v1） ⇄ XIAO ESP32C3 の
  顔追尾（FaceTrackingCoordinator） ──────────────┘                                    ファームウェア（2 軸サーボ）
```

## 組み立て

- **`ConversationComposition.live`**（App）: 本番の依存関係を 1 か所で組み立てる。組み立ての時点では、通信・マイクの起動・モデルの生成・記憶の読み書きをしない。
- **`ConversationAppCoordinator`**（App）: アプリ全体の状態を受け持つ。
  - scene の状態、画面遷移、設定画面の開閉、無操作時の待機（inactivity）、画面の wake lock、会話の開始意図。
  - 首の制御モードと、カメラ・表情・視線の表示状態を各コンポーネントへ配る。
- **`ConversationDependencies`**: ViewModel が外部とつながる境界。認識、分類、返答、話者、audio session、記憶、首、表情、視線、計測、時計、テスト用の checkpoint がすべてここを通る。

## 会話

- **`ConversationViewModel`**: 会話の状態機械。次のものを受け持つ。
  - ライフサイクル（開始・一時停止・shutdown）
  - 聞き取りと発話の区切り（`UtteranceSegmenter`）
  - 宛先の判定（`AddresseePolicy`、`EngagementWindow`、聞き返し）
  - 返答の再生の起動と、定型句（「なあに？」「今の、ぼくに言った？」）の発話
  - 失敗の後始末と、記憶の操作
- **`ConversationViewState`**: 表示状態を表す値型。
  - `enter(_:caption:)` は phase ごとの口の形と状態文言の表で、この表はここにしかない。
  - 失敗の表示は `presentFailure` が持つ。
- **`VoiceTurnLatencyRecorder`**: 音声ターン 1 回分の latency token と `ReplyTrace` を持つ。記録と終了は、所有者（世代・ターン・キャプチャ）が一致したときだけ行う。
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
- **聞き取り**: `AppleSpeechRecognizer`（Speech framework）、`SpeechAssetPreparer`、`AppleAudioSessionController`（割り込みと route の変更を知らせる）。

## 返答のモデルと記憶

- **`ClaudeConversationService`**: Claude API とのやり取りの中心。
  - ClaudeForFoundationModels 0.2.3 のセッション。
  - 短期記憶（会話の要約と直近の往復）。
  - tools: `move_head`、`express`、`look`、`remember`。
- **`OnDeviceFallbackReplyGenerator`**: Claude が失敗したら端末内の Foundation Models に切り替える。返答の途中では切り替えない。
- **`MotionReplyGenerator`**: 生成が終わったことを首に知らせる。
- **`RoutedAddressClassifier`**: 宛先を、端末内の分類と Claude の分類で振り分けて判定する。
- **`LongTermMemoryManager`**: 長期メモを扱う。
- **保存先**: Application Support の下（`ConversationMemoryLocation`）。
  - 短期記憶は `current.json`、長期メモは `facts.json`。
  - 保存先が使えないとき、短期記憶はエラーを表示する。長期メモはメモリ上だけで保持する。
- **互換性**: 次の値は変えない。変えると保存済みの記憶や設定が読めなくなる。
  - 互換 ID の `claude-memory-v1`、snapshot の `schemaVersion` 1、ファイル名
  - enum の raw 値（記憶のカテゴリ、声、モデル、effort）
  - UserDefaults の key（声、使用量、首、オンボーディング、待機）

## 顔・視線・首

- **顔の描画**: `CatFaceView`、`CatFaceShapes`、`CatFaceAppearance` の 3 ファイル。
  - `scripts/render_face.sh` と `tools/face-size-tuner` も、この 3 ファイルを直接コンパイルしている。
  - そのため `MouthPose` と `FaceExpression` のケースの名前と順序は、`scripts/face-render/Stubs.swift` と揃えておく必要がある。
- **`FaceExpressionCoordinator`**: phase と `express` tool から表情を決める。
- **カメラと視線**:
  - `ConversationCamera` と `AppleFaceCaptureSource` が前面カメラを扱う（画面の左に固定）。
  - `LookCoordinator` は `look` tool の撮影と、画像を保持する期間を受け持つ。
- **`FaceTrackingCoordinator`**: 顔の位置から追尾の指令を作る。
- **`MotionCoordinator`**: 首の動作の調停。
  - 返答のジェスチャの予約（1 ターンあたりの予算は 4 秒）、待機時の微動、追尾との調停、STOP の規則、強度（SET_LIMITS）を扱う。
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
  - **返答の失敗**: `stopTurnAudio` が、再生の join → 話者の停止 → 認識の停止 → audio session の解除 →（`contextExceeded` のときだけ）返答 session の reset、の順で行う。
  - **一時停止**: まず世代を進めて paused を表示し、その後で実行中の作業を切り離す。そこから先は状況で二通り。
    - 通常: 再生の join → 話者の停止 → 認識の停止 → キャプチャ・区切り・ターンの join → audio session の解除。
    - 失敗の後始末の最中: 音声の停止は後始末に任せる。キャプチャと区切りの確定作業は cancel してから join する。
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
| iOS の単体・統合テスト | README「Simulatorでビルド・テスト」（`xcodebuild … -scheme CatRobot test`）。Claude API には接続しない |
| 会話の状態機械 | `ConversationViewModelTests`、`ConversationRecoveryTests`、`ConversationAutoResumeTests`、`ConversationNewSessionTests`、`ConversationMemoryIntegrationTests`、`ConversationIdleIntegrationTests` |
| 再生と計測 | `SentenceReplyPlaybackTests`、`ReplyPlaybackCoordinatorTests`、`ReplyPlaybackIntegrationTests`、`ConversationLatencyTests`、`ReplyTraceTests`、`VoiceTurnLatencyRecorderTests` |
| 表示と VoiceOver | `ConversationViewStateTests`、`ConversationAccessibilityTests`、`FaceConversationPresentationTests` |
| 首と追尾 | `MotionCoordinatorTests`、`FaceTrackingMotionTests`、`RobotLinkTests`、`RobotLifecycleIntegrationTests`、`RobotProtocolTests` |
| 実機専用（通常のテストではスキップ） | `SupertonicIntegrationDeviceTests` scheme と `scripts/run_supertonic_integration_device_test.sh`、`scripts/run_robot_motion_device_test.sh`（7 動作×3 強度。首が見える状態で実行する） |
| プロジェクト生成の契約 | `ruby scripts/generate_project.rb && ruby scripts/test_generate_project.rb`（pbxproj と共有 scheme は直接編集しない） |
| 顔の描画計測 | `scripts/render_face.sh check` と `scripts/render_face.sh measure`。新しい round は顔が 9 から、寝顔が 3 から |
| Python のスクリプト | `scripts/test_*.py`（音声資産の準備・検証、実機結果の集計） |
| ファームウェア | `cd firmware && pio test -e native`（ホストでの単体テスト、実機は不要） |
| 顔サイズ調整ツール | `tools/face-size-tuner`（README を参照） |
