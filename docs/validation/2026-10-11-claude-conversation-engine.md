# Claude 会話エンジンの検証記録

2026-10-11、Task 9 の自動検証を実施した。実 API の Simulator スモークは利用者の指定により実行していない。App Attest、Apple Intelligence 非対応機、実機遅延、VoiceOver / Dynamic Type の受入も未実施で、Task 10 で結果を追記する。

鍵、認証トークン、client ID の実値、会話本文はこの記録に含めない。

## 対象と環境

- ブランチ: `feature/claude-conversation-engine`。
- Task 9 の BASE: `6d8d05f301121e176a43d91275b971ca85dce3c7`。検証対象はその上の Task 9 の変更。
- Xcode 27.0（27A266a）、Swift 6 strict concurrency（complete）、deployment target iOS 27.0。
- Simulator: iPhone 17 Pro / iOS 27.0、UDID `80F1BF36-5242-4067-A1D9-99399B852120`。
- `xcodeproj` 1.27.0、ClaudeForFoundationModels 0.2.3、ONNX Runtime 1.24.2。依存は `Package.resolved` の固定版。
- Supertonic 3 の資産は既存の Git 管理外ディレクトリを使用。認証キーのファイルは空のままで、統合の client ID も未設定のまま。

## Task 9 Step 4: 自動検証

新規テストは `AppCompositionTests.testLiveCompositionIsLazyAndWiresClaudeRoles` の 1 件。製品変更より前に追加し、RED を確認してから実装した。実 API には接続していない。

| 検証 | 結果 | ログ |
|---|---|---|
| テスト追加後の project 生成・契約 | PASS | `task9-generate-red.log` |
| RED: AppCompositionTests | `ConversationComposition` 未定義と、それに伴う型推論エラー。exit 65、TEST FAILED | `task9-red.log` |
| 実装後の project 生成・契約 | PASS | `task9-generate-green.log` |
| AppCompositionTests + VoiceSettingsIntegrationTests | 18 件、失敗 0。exit 0、TEST SUCCEEDED | `task9-green.log` |
| Python スクリプトの unittest | 3 ファイルの 9 件、失敗 0。exit 0 | `task9-python.log` |
| 全回帰 | 418 件、既存 skip 1、失敗 0。exit 0、TEST SUCCEEDED | `task9-full.log` |

ログは作業環境の `/private/tmp/cat-claude-engine/` に保存した。全回帰の xcresult は `simulator/Logs/Test/Test-CatRobot-2026.10.11_20-14-57-+0900.xcresult`。skip は既存の `SupertonicIntegrationDeviceTests.testSelectedStage` で、明示的な iPhone 実行を必要とする。

最終確認では、staged index から取り出した project・2 つの scheme・`Package.resolved` が再生成結果とバイト一致し、生成契約も PASS（`task9-generate-final.log`）。`git diff --cached --check` は通過し、未ステージの差分はない。Task 9 の GREEN / 全回帰ログの Swift 警告は既存の 8 種類で、新規 0。AppIntents の metadata extraction 通知を含む警告メッセージ全体にも新規差分はない（`task9-warnings.txt`）。README の旧エンジン・旧テスト用環境変数の記述は 0 件で、保持するよう指定された 3 節とローカルリンクも確認した。

実行したコマンド:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
python3 -m unittest discover -s scripts -p 'test_*.py'

xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -derivedDataPath /private/tmp/cat-claude-engine/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-claude-engine/packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

対象テストの GREEN では同じコマンドに `-only-testing:CatRobotTests/AppCompositionTests -only-testing:CatRobotTests/VoiceSettingsIntegrationTests` を付けた。RED は AppCompositionTests だけを指定した。

## 配線と遅延性

`ConversationComposition` が声・モデル設定・長期メモ・利用量を保持し、`CatRobotApp` が同じインスタンスを `AppRootView` に渡す。返答と可用性確認は同じ `OnDeviceFallbackReplyGenerator`、記憶管理はその primary である `ClaudeConversationService`、宛先判定は `RoutedAddressClassifier` に接続する。利用量計と設定の取得クロージャは Claude と代替返答の両方で共有する。

構築時にはネットワーク、マイク・音声の稼働、端末内モデルの生成・availability 照会、記憶データの読み書きを行わない。既存の `FileConversationMemoryStore.defaultDirectory()` は `create: true` で Application Support のルートだけを作る可能性がある。これは冪等で会話データを伴わない既存挙動として、navigator の確認を受けて維持した。会話ディレクトリ、`current.json`、`facts.json` は保存時まで作らない。モデルの記述子とファイルの URL を保持する処理は構築時に行う。

新規テストは役割の型、`.sentencePrefetch`、認証未設定時の `.claudeCredentialMissing` を確認する。既存の root 構築テストはマイク要求・可用性確認・音声準備・認識開始・音声セッション有効化・wake lock が始まらないことを確認する。ディレクトリ作成の有無を固定するテストは追加していない。

## Task 9 Step 5: 利用者による Simulator スモーク

**未実施（利用者が実施）**。今回の自動検証で以下が通ったとは扱わない。キーの設定・実 API 呼び出し・ネットワーク状態の変更も行っていない。

1. 利用者が開発用 API キーを用意し、[README の認証手順](../../README.md#claude-の認証)に従って Debug 実行の環境変数か Git 管理外のキーのファイルに設定する。キーをこの記録やログへ貼り付けない。
2. [Simulator のビルド手順](../../README.md#simulatorでビルドテスト)で Debug アプリをビルドし、対象 Simulator にインストールして起動する。
3. 下表を確認し、結果・日時・構成・失敗の種別だけを追記する。会話本文や鍵・トークンは記録しない。
4. 日次上限などの試験用設定を元に戻す。共有環境へ置いた開発用キーは利用者が片付ける。

| 手動確認 | 状態 |
|---|---|
| 文字入力への Claude の返答と逐次字幕 | 未実施 |
| remember による長期メモ登録と設定画面への表示 | 未実施 |
| 通信断で端末内モデルへ切り替え、使えなければ会話不可を表示 | 未実施 |
| モデル変更後も現在のセッションを維持し、新しい会話で変更が反映 | 未実施 |
| 日次上限到達後の代替返答または会話不可（T-COST-1） | 未実施 |

## Task 10: 実機受入の残項目

| 項目 | 状態・追記する内容 |
|---|---|
| App integration 登録・ワークスペース支出上限 | 未実施。利用者が登録して client ID を設定する |
| App Attest の Debug 予備確認 | 未実施。キーを使わず実機で確認し、使用した App Attest 環境と結果を記録する |
| T-AUTH-1: TestFlight の認証 | 未実施。Release 構成・キーなしでの認証と会話成立を確認する |
| T-AUTH-2: 統合の取り消し | 未実施。取り消しは恒久なので、検証用の別統合で失効時の案内を確認する |
| T-DEV-1 / T-DEV-2 | 未実施。Apple Intelligence 非対応の iPhone で Claude 会話、宛先判定、通信断を確認し、README の端末要件へ反映する |
| T-LAT-1 | 未実施。高速経路と分類経路を分けて字幕・音声開始の signpost を集計する。Task 10 の 20 ターン簡易測定と、要件の 50 ターン受入は区別して記録する |
| VoiceOver / Dynamic Type | 未実施。設定画面の操作、長期メモの個別削除、新しい会話の操作と表示を実機で確認する |

App Attest と取り消しの仕様は [Anthropic の公式手順](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models#app-attest)を参照する。
