# iOS 首の接続・動作・校正 検証記録

- 日付: 2026-10-23（JST）
- 対象実装SHA: `818044e521ca47e0469a3ead9be800477db9282f`。以後の文書更新とレビュー修正は末尾へ追記する。
- 承認済み設計: [iOSロボット接続設計](../superpowers/specs/2026-10-23-ios-robot-link-design.md)
- 実装計画: [10タスクの計画](../superpowers/plans/2026-10-23-ios-robot-link.md)
- 環境: macOS 26.6.2、Xcode 27.1（27A9275）、iPhoneOS/iPhoneSimulator SDK 27.1、iOS 27.0 Simulator（iPhone 17 Pro）、Swift 6、Ruby `xcodeproj` 1.27.0。SPMは`Package.resolved`の固定版を使用。
- 実機操作・実API生成は行っていない。BLEはFakeTransport、音声・生成はテスト実装。CoreBluetoothテストは遅延生成・利用理由・エラー分類を確認し、本物のcentralを起動していない。

## ホストで確認したこと

| 設計の節 | 実装・観測 | 自動試験・確認 |
|---|---|---|
| 3 / 4: 値型境界とプロトコル | 9コマンド、4種のRead、deci整数、LE、長さ・版数・不正値の拒否 | `RobotProtocolTests`、FWの既存golden bytesとの照合 |
| 4: 接続と世代 | 既知UUID取得、サービス限定検索、Info→暗号化Status→Notify→Calibration→Limits、取消終端待ち・manager破棄後の再試行 | `RobotLinkTests`、`CoreBluetoothRobotTransportTests` |
| 4: PING・フロー制御 | 1Hz、古いStatusと新しいPING echoの回復確認、期限付き送信、最新1件、STOP/PING優先、inactive未送信動作破棄 | `RobotLinkTests`、`RobotLifecycleIntegrationTests` |
| 5.1: ターンスコープ | 同じSDKセッションを使った2ターン、スコープなし、取消後の古いTool.call、固定IDの生成終了通知 | `MotionTurnContextTests`、`MoveHeadToolTests`、`MotionReplyGeneratorTests` |
| 5.1: 発話同期と切り替え | voice/typed共通run、3文先読み、最初のspeechStartedだけ解放、失敗したprimaryの予約をsecondaryより前に失効 | `MotionPlaybackIntegrationTests`、`OnDeviceFallbackReplyGeneratorTests` |
| 5.2 / 5.3: 予算と波形 | 1サイクルずつ送信、初回完走、次の予測合計≤4秒、実測超過後の残り破棄、寄せ時間、左右交互tilt、Read確認した速度欄だけ更新 | `GestureTimingTests`、`MotionCoordinatorTests` |
| 5.4: 自動動作 | 4〜10秒間隔、±3°/±2°、1.2〜1.6秒のC²目標列、20Hz以下、0→−5°→0の約0.6秒MOVE列、古い列を再生しない | 偽時計で送信目標・時刻・優先順位を確認。実機の追従時間は未実施 |
| 5.5 / 5.6: 所有権と停止 | settings/inactiveでは波形完走、明示停止・新会話・真の合成失敗は停止、backgroundはSTOPを送らず切断、ACTIVE静止2秒の低優先度PWM停止と古いticket失効 | `RobotLifecycleIntegrationTests`、`MotionCoordinatorTests` |
| 6: 校正 | 静止待ち、新しいRead、10Hzプレビュー、保存ACK・saved・意図値照合、req折り返し、同req3回、全体2回、dirtyなentry復元、旧応答と切断後ドラフトの失効 | `RobotCalibrationSessionTests`、`RobotSettingsModelTests` |
| 7 / 8: 画面と記録 | 同じLink/Motionの注入、未接続でも会話継続、3種の接続表示だけを投影、角度通知で再アナウンスしない、本文・引数全文を記録しない | `RobotStatusPresentationTests`、既存会話・アクセシビリティ試験、ログ呼び出しの確認 |
| 7: レイアウト | Fakeのみの接続・校正画面の上下、会話ヘッダーを横向きの通常文字/最大Dynamic Typeで画像化。最大文字は1列。停止は上部に固定 | XCTest添付PNGを目視。スライダーの度数、反転、方向、停止、戻る、保存のラベルを確認。実機VoiceOverの操作受入は未実施 |

Swift側の予算用予測は、標準上限・中立でnod large 1.52秒、shake large 2.08秒、tilt large 2.48秒、look large 4.06秒（±20ms）を既存FWのホスト基準と照合した。これは実機の運動時間の再測定ではない。サーボのPlannerをSwiftに複製せず、完了はStatusで判定する。

## 自動検証の結果

| 項目 | 結果 |
|---|---|
| 全Simulator試験（実装SHA `818044e`） | 556件実行、1件skip、失敗0（20.773秒。Xcode起動・ビルド時間を除く） |
| skip | `SupertonicIntegrationDeviceTests`。Simulator条件で`Explicit iPhone integration test required`により明示的skip。専用iPhone runnerを使う既存の音声受入試験 |
| プロジェクト生成と契約試験 | PASS。再生成でproject/schemeの追加差分なし |
| generic iOS unsigned build | BUILD SUCCEEDED（実装SHA `818044e`、iPhoneOS SDK 27.1、署名・インストール・起動なし） |
| `git diff --check` | PASS |
| 新しい担当によるブランチレビュー | 実行後に追記。ホストPASSを実機受入として扱わない |

実行は`xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO`（only-testingなし、専用DerivedDataと固定SPMキャッシュを指定）。ビルドは`xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination 'generic/platform=iOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO`。生成は`ruby scripts/generate_project.rb`と`ruby scripts/test_generate_project.rb`。

## NFR-PERF-3の計測境界

Tool.callは即時に予約を返し、発話開始が実行の最早時刻になる。300msの目標は、発話開始済みで前サイクルの完走・静止・必要な速度設定の確認を終え、実行可能になった時刻から、Statusで開始を観測するまでとする。

`RobotMotion`ログの`eligible`→`startObserved`を測り、`speechStarted`→`startObserved`の発話からの実測値と、`previousCycleWait`の前サイクル待ちを別記する。`sent`の`speechToSend`は発話から送信までで、実際の運動開始時間の代用にはしない。予約/発話開始/実行可能/送信/開始観測/完了はターンID・サイクルID・単調時刻・enum結果で結ぶ。本文・引数全文はログに出さない。

この300ms目標、FWの追従込み1〜2秒の待機微動、約0.6秒の確認頷きはすべて**実機未実施**。偽時計の送信時刻が合うことを、実機の性能達成として扱わない。

## 利用者在席で残る実機受入

| 項目 | 状態 | 実施時に残す条件・観測 |
|---|---|---|
| iPhone初回検索・ペアリング・暗号化Read | 未実施 | iPhone/OS/FW/ビルドSHA、起動後60秒窓、許可ダイアログ、初回操作 |
| 既知UUIDの再接続 | 未実施 | 通常5秒目標。権限・ペアリング待ちは別記し、重複centralを起動しない |
| 2台目centralの60秒窓外拒否 | 未実施 | 既存T-FW-9の残り。iPhoneとMac BLE toolsを同時接続で競合させない |
| 校正保存と電源再投入後の保持 | 未実施 | ACK、Calibration Read、saved、意図値、再起動後の実際の値 |
| 7動作×3強さ、方向・振幅・上限 | 未実施 | 低速の1方向確認から開始。tool intensityと全体の強さを区別 |
| 発話同期・前サイクル待ち | 未実施 | 上記3区間、送信とStatus開始の時刻、必要に応じ動画 |
| 動作中の切断からFW安全復帰 | 未実施 | 先にSTOPを送らない。FW RETURNING/RELAX_WAITと中立への復帰 |
| 再接続時に旧予約・MOVE・校正を再送しない | 未実施 | 新接続epoch、古いコマンド不在、Readしてから明示操作 |
| 校正専有と停止・離脱 | 未実施 | 動作終了待ち、自動動作不在、停止、保存/戻す/編集継続 |
| ACTIVE静止2秒でPWM停止、次の動作で復帰 | 未実施 | PING継続、TORQUE0一度、古い停止ticket不在、保持状態。電源断や保持電流低下を保証しない |
| 横向き・最大文字・実機VoiceOver | 未実施 | 操作ラベル・値・保存状態・接続失敗を色だけに依存せず確認 |
| 実API生成からのmove_head | 未実施 | 実API利用は別途利用者の指示の下で実施。今回のホスト検証に課金テストを含めない |

利用者が首を見られる状態を確認してから実施する。今回は書き込み、リセット、実BLE scan/接続、マイク・実音声、実API生成を行っていない。

## レビューと追記

最終レビューの指摘・修正SHA・再検証をここへ追記する。マージ・push・配布はこの記録とは別の統合操作として扱う。
