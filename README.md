# Cat Robot

Cat Robot は、Gemma 4 E2B（LiteRT-LM）を使って日本語で会話する、iPhone向けのネイティブSwiftUIアプリです。会話画面を開いている間は、音声認識、発話の宛先判定、応答生成、読み上げ、聞き取り再開までを端末上で繰り返します。

公開リポジトリ: [kam6y/Cat-robot](https://github.com/kam6y/Cat-robot)

## MVPの機能

- 「会話を始める」を押した後だけマイク権限を求め、フォアグラウンドで継続的に会話します。AIが考えている間と話している間は聞き取りを止め、返答後に再開します。
- `ねこ`、`猫ちゃん`、`Cat Robot`、`キャットロボット` から始まる発話は高速経路で処理します。直前の会話が続いている間も、毎回名前を呼ぶ必要はありません。
- 呼びかけがない発話は、Gemmaで「猫への発話・曖昧・別の相手への発話」に分類します。曖昧な場合は「今の、ぼくに言った？」と一度だけ聞き返します。
- 応答生成にはオンデバイスのGemma 4 E2Bを使い、日本語の短い返答を逐次字幕へ反映します。
- 音声入力には日本語の`SpeechAnalyzer` / `SpeechTranscriber`、読み上げには`AVSpeechSynthesizer`を使います。
- 会話画面は横向き・黒背景です。猫はSwiftUIのベクター図形で描画し、状態に応じて目や口を動かします。操作部にはiOS 26のLiquid Glassを使い、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOverにも対応します。
- マイクや音声処理が使えない場合も、文字入力から会話できます。
- バックグラウンド移行、音声割り込み、オーディオ経路変更では会話を停止します。フォアグラウンド復帰時に勝手に聞き取りを再開せず、ユーザーの明示操作を待ちます。
- OSLogのレイテンシsignpostで、高速経路と分類経路の「最初の字幕」「読み上げ開始」を別々に測定します。認識文や返答文は記録せず、時刻、ターンID、結果コードだけを扱います。

## 動作要件

実機:

- iPhone 16 Pro（Gemma実機検証の基準端末。他機種は未検証）
- iOS 26.0以上
- 固定版のGemmaモデルが配置済みであること（下記参照）。Apple Intelligenceの有効化は不要
- 日本語の音声認識アセットと読み上げ音声が利用可能なこと
- マイク使用の許可

開発環境:

- Xcode 27.0（build 27A266a、今回の検証環境）
- Xcodeに同梱されるiOS SDK
- Rubyと`xcodeproj` 1.27.0

今回の実機検証OSはiOS 27.2（24B5084k）です。deployment targetは26.0を維持しています。

アプリは公式LiteRT-LM 0.17.1に依存します。`xcodeproj` gemはXcodeプロジェクト生成時だけ使います。

## Gemmaモデルの準備

このfeatureではGemmaが標準です。AFMの実装・テストは残していますが、起動時の構成はGemmaのみで、モデル選択画面や自動フォールバックはありません。返答と宛先判定は同じエンジンを共有し、会話履歴は分離します。

固定モデルは約2.59 GB。以下のURLから取得し、ロック解除した実機へ転送して結合テストを実行します。モデルをリポジトリに追加しないでください。

```text
https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm
```

```bash
scripts/run_gemma_app_test.sh '<iPhone UDID>' '/absolute/path/gemma-4-E2B-it.litertlm'
# 配置済みなら第2引数は不要
scripts/run_gemma_app_test.sh '<iPhone UDID>'
```

SHA-256は `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`。スクリプトで転送前、アプリで初回ロード前に検証します。配置先はアプリコンテナの `Library/Application Support/CatRobot/LanguageModels/Gemma4E2B/gemma-4-E2B-it.litertlm`。未配置・破損は画面に表示されます。この開発版にはモデルの自動ダウンロードや選択UIはありません。

推論はGPU・8,192トークン、返答上限160トークン、thinking無効です。履歴の実トークン数と入力UTF-8バイト数による保守的な予算チェックを行い、超過時は既存の短期会話リセットと再入力案内を使います。入力や日本語の比率によっては8Kに達する前に上限になります。初回はファイル検証とモデル初期化の待ち時間があります。

通常の `CatRobot` schemeでは実機推論テストをスキップし、`GemmaAppDeviceTests` schemeで明示実行します。テスト中は短い合成会話が実際に読み上げられます。Simulatorではモデルの実推論を行いません。

## プロジェクト生成

`CatRobot.xcodeproj/project.pbxproj`と共有schemeは直接編集しません。`CatRobot/`または`CatRobotTests/`のSwiftファイルを変更したら、次を実行します。

```bash
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

ソース変更と再生成した`CatRobot.xcodeproj`は一緒に管理します。生成をもう一度実行してもプロジェクト差分が増えないことが決定性の基準です。

## Simulatorでビルド・テスト

固定のSimulator IDには依存しません。利用可能なiOS 26 Simulatorを確認し、そのUDIDを設定します。

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

SimulatorのテストはAppleサービスをテスト用実装へ差し替えて実行します。Gemma、実際のマイク、音声認識、読み上げを含む一連の確認は実機で行います。

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
5. バックグラウンドへ移動して戻り、自動再開せず「聞き取りを再開」が必要なことを確認する。
6. 文字入力でも返答できることを確認する。

## MVPの制約

- 常時会話は会話画面がアクティブな間だけです。バックグラウンド録音、ロック画面のStandBy拡張、常駐ウェイクワード検出は実装していません。
- 宛先判定には誤検知や見逃しがあり、生成モデルの返答も事実とは限りません。応答速度と自然な会話を優先し、二重判定や返答検証は行いません。誤りは次の発話で人が自然に訂正する前提です。
- アプリ独自のクラウドAPI、バックエンド、会話ログ保存、分析基盤はありません。会話処理は端末上で行います。ただし、必要な音声アセットはOSが事前に取得する場合があります。Gemmaモデルは開発時に手動転送します。
- 医療、法律、金融など、正確性が必須の用途を保証する製品ではありません。

## 構成

- `CatRobot/App/`: SwiftUIエントリポイント、画面遷移、ライフサイクル連携
- `CatRobot/Conversation/Domain/`: 発話区切り、宛先、会話継続の純粋ロジック
- `CatRobot/Conversation/Services/`: Gemma、保全したFoundation Models、Speech、AVFAudioの実装
- `CatRobot/Conversation/Integration/`: 会話オーケストレーション、依存関係、エラー、レイテンシ計測
- `CatRobot/Conversation/UI/`: 横向き会話画面、SwiftUIベクター猫、文字入力、アクセシビリティ
- `CatRobotTests/`: production構成に対応する単体テスト
- `scripts/`: 決定的なXcodeプロジェクト生成と契約テスト
- `docs/`: 設計、実装計画、猫の生成画像とベクタートレース用資料

deployment targetはiOS 26.0、iPhone専用、Swift 6 strict concurrency、横向き両方向対応です。

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
