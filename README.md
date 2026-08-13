# Cat Robot

Cat Robot は、Apple Foundation Models を使って日本語で会話する、iPhone向けのネイティブSwiftUIアプリです。会話画面を開いている間は、音声認識、発話の宛先判定、応答生成、読み上げ、聞き取り再開までを端末上で繰り返します。

公開リポジトリ: [kam6y/Cat-robot](https://github.com/kam6y/Cat-robot)

## MVPの機能

- 「会話を始める」を押した後だけマイク権限を求め、フォアグラウンドで継続的に会話します。AIが考えている間と話している間は聞き取りを止め、返答後に再開します。
- `ねこ`、`猫ちゃん`、`Cat Robot`、`キャットロボット` から始まる発話は高速経路で処理します。直前の会話が続いている間も、毎回名前を呼ぶ必要はありません。
- 呼びかけがない発話は、Foundation Modelsで「猫への発話・曖昧・別の相手への発話」に分類します。曖昧な場合は「今の、ぼくに言った？」と一度だけ聞き返します。
- 応答生成にはオンデバイスのApple Foundation Modelsを使い、日本語の短い返答を逐次字幕へ反映します。
- 音声入力には日本語の`SpeechAnalyzer` / `SpeechTranscriber`、読み上げには`AVSpeechSynthesizer`を使います。
- 会話画面は横向き・黒背景です。猫はSwiftUIのベクター図形で描画し、状態に応じて目や口を動かします。操作部にはiOS 26のLiquid Glassを使い、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOverにも対応します。
- マイクや音声処理が使えない場合も、文字入力から会話できます。
- バックグラウンド移行、音声割り込み、オーディオ経路変更では会話を停止します。フォアグラウンド復帰時に勝手に聞き取りを再開せず、ユーザーの明示操作を待ちます。
- OSLogのレイテンシsignpostで、高速経路と分類経路の「最初の字幕」「読み上げ開始」を別々に測定します。認識文や返答文は記録せず、時刻、ターンID、結果コードだけを扱います。

## 動作要件

実機:

- Apple Intelligence対応端末（MVPの基準端末はiPhone 16 Pro）
- iOS 26.0以上
- Apple Intelligenceが有効で、日本語モデルが利用可能なこと
- 日本語の音声認識アセットと読み上げ音声が利用可能なこと
- マイク使用の許可

開発環境:

- Xcode 26.6（build 17F113）
- Xcode 26.6に同梱されるiOS 26.5 SDK
- Rubyと`xcodeproj` 1.27.0

Xcode 26.6の同梱SDKは26.5ですが、iOS 26.6の実機をビルド・実行対象にできます。iOS 26.6という別SDKを追加する必要はありません。

アプリにサードパーティのランタイム依存関係はありません。`xcodeproj` gemはXcodeプロジェクト生成時だけ使います。

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

SimulatorのテストはAppleサービスをテスト用実装へ差し替えて実行します。Foundation Models、実際のマイク、音声認識、読み上げを含む一連の確認は実機で行います。

## iPhoneでビルド・実行

基準実機は、USB-C接続したiPhone 16 Pro（iOS 26.6）です。端末をロック解除し、このMacを信頼してDeveloper Modeを有効にします。Xcode用のdestination IDと`devicectl`用のdevice IDを次で確認してください。

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
- アプリ独自のクラウドAPI、バックエンド、会話ログ保存、分析基盤はありません。会話処理は端末上で行います。ただし、必要なApple Intelligenceや音声アセットはOSが事前に取得する場合があります。
- 医療、法律、金融など、正確性が必須の用途を保証する製品ではありません。

## 構成

- `CatRobot/App/`: SwiftUIエントリポイント、画面遷移、ライフサイクル連携
- `CatRobot/Conversation/Domain/`: 発話区切り、宛先、会話継続の純粋ロジック
- `CatRobot/Conversation/Services/`: Foundation Models、Speech、AVFAudioの実装
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
