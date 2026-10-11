# Cat Robot

Cat Robot は、Claude Opus 5.5（ClaudeForFoundationModels）で日本語の会話をする iPhone 向け SwiftUI アプリです。聞き取りと読み上げは端末内、返答は Claude で処理し、通信障害時は利用可能な Apple の端末内モデルへ切り替えます。

公開リポジトリ: [kam6y/Cat-robot](https://github.com/kam6y/Cat-robot)

## MVPの機能

- 「会話を始める」を押した後にマイク権限を求め、会話画面が前面にある間だけ聞き取ります。AI が考えている間と話している間は聞き取りを止め、返答後に再開します。
- `ねこ`、`猫ちゃん`、`Cat Robot`、`キャットロボット` から始まる発話や、直前から続いている会話は高速経路で処理します。
- 呼びかけがない発話は「猫への発話・曖昧・別の相手への発話」に分類します。端末内モデルが使える場合は Apple Foundation Models、それ以外は Claude Haiku 5.5 を使い、曖昧な場合は一度だけ聞き返します。
- 返答は Claude Opus 5.5 が既定です。字幕を逐次更新し、Supertonic 3 で読み上げます。モデル・考える深さ・声は「…」→「設定」で選べます。
- 返答本文をまだ出していないターンで通信到達不能、タイムアウト、レート制限などが起きた場合は、利用可能な端末内モデルへ切り替えます。原因を断定せず、簡単な返答に切り替えたことを冒頭で伝えます。既知の認証失敗・拒否・取消などは切り替えの対象外です。
- 日本語の聞き取りは `SpeechAnalyzer` / `SpeechTranscriber`、読み上げは Supertonic 3 で端末内処理します。マイクが使えない場合も「…」→「文字で話しかける」で会話できます。
- 会話の要約と直近の往復、短い長期メモを端末内に保存します。「新しい会話を始める」は長期メモを残し、「設定」→「覚えていること」→「すべて削除」は両方を削除します。
- 横向き・黒背景の画面で、SwiftUI のベクター猫が状態に応じて目や口を動かします。Liquid Glass、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOver に対応します。
- 会話画面が前面にある間は聞き取り続けます。バックグラウンド移行、音声割り込み、オーディオ経路変更では停止し、前面に戻ると自動で再開します。猫をタップすると一時停止し、もう一度タップすると再開します。
- OSLog のレイテンシ signpost と診断ログに、区間、結果コード、正規化したエラー種別、切り替えの事象と回数を記録します。発話・返答・API エラー本文は記録しません。

## 返答開始の待ち時間

一文が確定したら生成途中から読み上げ、再生中に次の一文だけを先に合成します。安全な区切りがない場合は全文を待ちます。ネイティブ合成は同時に 1 件、保持する音声は再生中と次の最大 2 文分です。利用者向けの方式切り替え設定はありません。

Claude 構成の実機遅延はまだ測定していません。Task 10 で高速経路と宛先分類経路を分けて計測し、[Claude 会話エンジンの検証記録](docs/validation/2026-10-11-claude-conversation-engine.md)に結果を追記します。過去の[Supertonic 一文先読みの測定](docs/validation/2026-09-26-supertonic-voice-integration.md)は音声側の参考で、Claude 構成の実測値ではありません。

生成・保存・読み上げが終わってから聞き取りを再開します。全文確定前に中断した返答は保存せず、確定後は音声が失敗・停止しても全文を保存します。通信、認証、要約による待ち時間は残ります。

## 動作要件

実機:

- iOS 27.0 以上の iPhone。受入確認の基準端末は iPhone 16 Pro で、Claude 構成の実機確認は 2026-10-11 に Debug ビルドで実施しました（[検証記録](docs/validation/2026-10-11-claude-conversation-engine.md)）。
- Claude を利用するための通信と認証設定。
- 日本語の音声認識アセットと、同梱する Supertonic 音声資産。
- 音声入力にはマイク使用の許可。

Claude 会話、宛先判定、通信断時の切り替えは Apple Intelligence 対応機（iPhone 16 Pro）で検証済みです。Apple Intelligence 非対応機は未検証です（T-DEV-1 / T-DEV-2 は未実施）。端末内モデルが利用できない場合、通信断や日次上限時の代替返答は使えず、会話不可の案内になります。

開発環境:

- Xcode 27.0（build 27A266a、今回の検証環境）と同梱 iOS SDK。
- Ruby と `xcodeproj` 1.27.0（プロジェクト生成用）。
- ClaudeForFoundationModels 0.2.3 と ONNX Runtime 1.24.2。版数と revision は `Package.resolved` で固定します。

## Claude の認証

配布する Release ビルドは App Attest を使います。Claude Console のワークスペース設定「App integrations」で Team ID と Bundle ID を登録し、発行された client ID を `CatRobot/Resources/claude-integration.json` の `clientID` に設定してプロジェクトを再生成します。登録には組織の admin / owner 等の権限が必要です。現在の client ID は未設定で、Task 10 で利用者が設定します。

App Attest は実機で利用し、Simulator は開発用 API キーを使います。統合の取り消しは恒久で、発行済みトークンも失効します。取り消しの受入試験は本番用と別の統合で行います。詳しくは [Anthropic の App Attest 手順](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models#app-attest)を参照してください。

Debug ビルドの認証は次の順に解決します。

1. アプリの実行環境にある `ANTHROPIC_API_KEY`。
2. `CatRobot/LocalAssets/claude-api-key.txt`（Git 管理外、Debug ビルドだけ同梱）。
3. 設定済みの client ID による App Attest（実機）。

API キーは利用者が用意し、ソース・README・検証ログへ記載しません。Release では環境変数と同梱キーの経路を使わず、キーのファイルもビルド資源から除外します。会話開始前に認証を確認し、未設定や認証失敗は画面に表示します。

## モデルと設定

「…」→「設定」で変更します。開くと会話を停止し、閉じると自動で聞き取りを再開します。

| 項目 | 内容 |
|---|---|
| モデル | Claude Opus 5.5（既定）/ Sonnet 5.5 / Haiku 5.5 |
| 考える深さ | low（速さ優先、既定）/ medium（少し考える） |
| 声 | Supertonic F1〜F5・M1〜M5、既定 F1 |
| 覚えていること | 長期メモの一覧、個別削除、すべて削除（会話の要約も消えます） |
| 1 日の上限 | 既定 300 回、10〜2,000 回を 10 回刻みで設定 |
| 利用量 | 今日・今月の回数、概算トークン数、今月の概算 USD |

モデルと考える深さは次に Claude セッションを作るときに反映し、進行中のセッションでは切り替えません。「新しい会話を始める」か次回起動で新しい設定を使えます。長期メモは保持します。覚えていることを個別に消した場合は、次の返答の前にセッションを作り直して反映します。要約と直近の往復は残ります。日次上限は次のターンで確認し、上限に達していれば Claude に送らず、利用可能な端末内モデルで簡単に答えます。

利用量は Claude で正常に完了した返答をもとにしたアプリ内の概算です。宛先判定・要約・メモ整理を含む実際の請求額とは異なるため、請求は Claude Console で確認します。ワークスペースの月間支出上限は Console で別途設定します。

## Supertonic音声の準備と設定

通常アプリは Supertonic 3 を使用します。「…」→「設定」の「声」で F1〜F5・M1〜M5 を選び、初期値は F1 です。選択は再起動後も保持します。設定を開くと会話を一時停止し、閉じると自動で再開します。再開後は選んだ声を使い、会話の記憶は変更しません。

開発時に以下を実行して、固定 revision の資産約 401 MB を取得します。資産は Git へ追加しません。ビルド前にサイズと SHA-256 を照合し、欠損や破損があればビルドを失敗させます。実行時のモデルダウンロードはありません。

```bash
python3 scripts/prepare_supertonic_assets.py \
  --output CatRobot/LocalAssets/Supertonic \
  --manifest CatRobot/Resources/supertonic-manifest.json
```

合成条件は日本語、8 steps、CPU 2 threads、speed 1.05。モデルと MIT / OpenRAIL-M のライセンスを同梱します。固定版と移植元は[出典](CatRobot/Vendor/Supertonic/PROVENANCE.md)に記録しています。Apple 読み上げの実装は保全していますが、エンジン選択画面や失敗時の自動切り替えはありません。

音声へ渡す直前だけ、`iPhone` を「アイフォーン」、`Bluetooth` を「ブルートゥース」に補正します。字幕と保存する会話は原文のままです。URL・メール・バッククォート内のコード・`iPhone16` など識別子の一部は置換しません。

実機の音声確認は `SupertonicIntegrationDeviceTests` scheme を使います。通常テストでは実行しません。利用者の記憶とは独立した試験文章を使い、結果にはその試験文章が含まれます。

```bash
scripts/run_supertonic_integration_device_test.sh '<iPhone UDID>' voices
# fixed / lifecycle も個別に実行可能
```

## 会話の記憶

返答の生成が正常に完了するたび、会話要約と直近の確定した往復を保存します。端末内モデルで完了した往復も次の Claude セッションへ引き継ぎます。空の返答、生成途中の返答、音声、宛先判定に使った発話は保存しません。過去に要約で省いた全文を保存する機能や、履歴一覧画面はありません。

記憶は 2 層で、保存先はアプリ内の `Library/Application Support/CatRobot/ConversationMemory/` です。

- `current.json`: 会話要約と直近の往復。互換 ID は `claude-memory-v1`。
- `facts.json`: 人物・好み・出来事・約束などの短い長期メモ。`remember` ツールで登録し、「設定」→「覚えていること」で一覧、個別削除、すべて削除を扱います。

完全ファイル保護を適用し、端末バックアップやクラウド同期には含めません。再インストールや別端末への移行では引き継げません。Claude に送るのは、受け付けた発話の文字、会話要約、直近の往復、長期メモです。要約・メモの整理や、端末内モデルが使えない場合の宛先判定にも Claude を使います。音声は送信しません。

保存できなかった場合は、会話を続けながら保存を再試行できます。そのまま終了すると、最後に保存できた時点までの記憶に戻る場合があります。読み込み失敗時は会話を止め、再試行または削除を案内します。壊れた記憶を空の会話で自動上書きしません。

「…」→「新しい会話を始める」は短期の要約と往復を捨て、長期メモを残して聞き取りを再開します。「設定」→「覚えていること」→「すべて削除」→「削除する」は両方を削除します。削除に失敗した場合は、再試行が成功するまで会話を再開しません。

## プロジェクト生成

`CatRobot.xcodeproj/project.pbxproj`と共有schemeは直接編集しません。`CatRobot/`または`CatRobotTests/`のSwiftファイルを変更したら、次を実行します。

```bash
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

ソース変更と再生成した`CatRobot.xcodeproj`は一緒に管理します。生成をもう一度実行してもプロジェクト差分が増えないことが決定性の基準です。

## Simulatorでビルド・テスト

固定のSimulator IDには依存しません。利用可能なiOS 27 Simulatorを確認し、そのUDIDを設定します。

```bash
xcrun simctl list devices available
SIMULATOR_UDID='<利用するSimulatorのUDID>'

xcodebuild \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -derivedDataPath /tmp/CatRobotDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -derivedDataPath /tmp/CatRobotDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

単体テストは Claude API に接続せず、必要な Apple サービスをテスト用実装に差し替えます。実 API の Simulator スモークは利用者が開発用キーを用意して別途実施します。今回は未実施です。手順と残る実機確認は[検証記録](docs/validation/2026-10-11-claude-conversation-engine.md)を参照してください。

## iPhoneでビルド・実行

基準実機は、USB-C接続したiPhone 16 Proです。端末をロック解除し、このMacを信頼してDeveloper Modeを有効にします。Xcode用のdestination IDと`devicectl`用のdevice IDを次で確認してください。

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -showdestinations
xcrun devicectl list devices
```

表示されたIDを使い、Automatic Signingのままビルド、インストール、起動します。

```bash
XCODE_DEVICE_ID='<xcodebuildが表示したiPhoneのID>'
CORE_DEVICE_ID='<devicectlが表示したiPhoneのID>'

xcodebuild \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -configuration Debug \
  -destination "platform=iOS,id=${XCODE_DEVICE_ID}" \
  -derivedDataPath /tmp/CatRobotDeviceDerivedData \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

xcrun devicectl device install app \
  --device "${CORE_DEVICE_ID}" \
  /tmp/CatRobotDeviceDerivedData/Build/Products/Debug-iphoneos/CatRobot.app

xcrun devicectl device process launch \
  --device "${CORE_DEVICE_ID}" \
  com.kamby.CatRobot
```

プロジェクトはAutomatic Signing、team `VUB4VP6453`、bundle ID `com.kamby.CatRobot`です。Apple側で最新のProgram License Agreement（PLA）が未同意だと署名ビルドが停止するため、その場合はApple Developerアカウントで契約へ同意してから再実行します。これはSDKの不足とは別の署名要件です。

最初の実機確認では、次を順に試します。

1. 横向きで起動し、「会話を始める」からマイクを許可する。
2. 「猫ちゃん、短く自己紹介して」と話し、字幕、口の動き、読み上げ、聞き取り再開を確認する。
3. 続けて名前を呼ばずに話し、会話継続中の高速経路を確認する。
4. 別の人への発話と曖昧な発話で、無応答または聞き返しになることを確認する。
5. バックグラウンドへ移動して戻ると自動で聞き取りが再開すること、猫をタップすると一時停止し、もう一度タップで再開することを確認する。
6. 「…」→「文字で話しかける」で文字でも返答でき、送信後も入力欄が残ることを確認する。

## MVPの制約

- 会話は画面がアクティブな間だけです。バックグラウンド録音、ロック画面の StandBy 拡張、常駐ウェイクワード検出は実装していません。
- 宛先判定には誤検知や見逃しがあり、生成モデルの返答も事実とは限りません。二重判定や返答の事実検証は行いません。
- アプリ独自のバックエンド、全文の会話ログ保存、分析基盤はありません。返答などの文字処理は Anthropic の Claude API、聞き取りと読み上げは端末内で行います。音声認識アセットは OS が事前に取得する場合があります。
- ClaudeForFoundationModels 0.2.3 では一部の API エラーを細かく区別できず、通信以外の汎用生成失敗も端末内モデルへの切り替え対象に含まれます。返答の途中では代替返答を重ねません。
- 医療、法律、金融など、正確性が必須の用途を保証する製品ではありません。

## 構成

- `CatRobot/App/`: アプリ全体の依存関係を組み立てる `ConversationComposition`、SwiftUI エントリポイント、画面遷移、設定。
- `CatRobot/Conversation/Domain/`: 発話区切り、宛先、会話継続のロジック。
- `CatRobot/Conversation/Services/Claude/`: 認証、セッション、返答、端末内モデルへの切り替え、宛先分類、モデル設定、利用量。
- `CatRobot/Conversation/Services/Memory/`: 会話要約・直近往復と長期メモの保存・削除。
- `CatRobot/Conversation/Tools/`: `remember` とツール集合の提供。
- `CatRobot/Conversation/Services/`: Apple Foundation Models、Speech、AVFAudio、Supertonic の実装。
- `CatRobot/Conversation/Integration/`: 会話の進行、依存関係、エラー、レイテンシ計測。
- `CatRobot/Conversation/UI/`: 横向き会話画面、ベクター猫、文字入力、アクセシビリティ。
- `CatRobotTests/`: 各機能の単体・統合テスト。
- `scripts/`: Xcode プロジェクト生成、契約テスト、音声資産の準備と検証。
- `docs/`: 設計、実装計画、検証記録。

deployment target は iOS 27.0、iPhone 専用、Swift 6 strict concurrency（complete）、横向き両方向対応です。

## ブランチとworktreeの運用

開発作業は、1つの機能または境界の明確な修正ごとに`feature/<scope>`ブランチを作り、専用worktreeで行います。

```bash
git switch main
git worktree add ".worktrees/feature-<scope>" -b "feature/<scope>" main
```

実装・テスト・レビュー後はfeature branchをpushし、`main`側でsquash mergeします。

```bash
git switch main
git merge --squash "feature/<scope>"
git commit
git push origin main "feature/<scope>"
```

squash後も、履歴確認のためローカル・リモートのfeature branchを削除しません。関係のない変更を同じbranchへ混ぜず、source、test、再生成したprojectを同じ粒度でまとめます。
