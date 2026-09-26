# Cat Robot

Cat Robot は、Gemma 4 E2B（LiteRT-LM）を使って日本語で会話する、iPhone向けのネイティブSwiftUIアプリです。会話画面を開いている間は、音声認識、発話の宛先判定、応答生成、読み上げ、聞き取り再開までを端末上で繰り返します。

公開リポジトリ: [kam6y/Cat-robot](https://github.com/kam6y/Cat-robot)

## MVPの機能

- 「会話を始める」を押した後だけマイク権限を求め、フォアグラウンドで継続的に会話します。AIが考えている間と話している間は聞き取りを止め、返答後に再開します。
- `ねこ`、`猫ちゃん`、`Cat Robot`、`キャットロボット` から始まる発話は高速経路で処理します。直前の会話が続いている間も、毎回名前を呼ぶ必要はありません。
- 呼びかけがない発話は、Gemmaで「猫への発話・曖昧・別の相手への発話」に分類します。曖昧な場合は「今の、ぼくに言った？」と一度だけ聞き返します。
- 応答生成にはオンデバイスのGemma 4 E2Bを使い、日本語の短い返答を逐次字幕へ反映します。
- 音声入力には日本語の`SpeechAnalyzer` / `SpeechTranscriber`、読み上げには端末内のSupertonic 3を使います。初期設定はF1で、「声」から全10種類を選択できます。選択は再起動後も保持します。
- 会話画面は横向き・黒背景です。猫はSwiftUIのベクター図形で描画し、状態に応じて目や口を動かします。操作部にはiOS 26のLiquid Glassを使い、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOverにも対応します。
- マイクや音声処理が使えない場合も、文字入力から会話できます。
- バックグラウンド移行、音声割り込み、オーディオ経路変更では会話を停止します。フォアグラウンド復帰時に勝手に聞き取りを再開せず、ユーザーの明示操作を待ちます。
- OSLogのレイテンシsignpostで、高速経路と分類経路の「最初の字幕」「読み上げ開始」を別々に測定します。認識文や返答文は記録せず、時刻、ターンID、結果コードだけを扱います。

## 返答開始の待ち時間

通常アプリは、一文が確定したら生成途中から読み上げ、再生中に次の一文だけを先に合成します。安全な区切りがない場合は全文を待ちます。ネイティブ合成は同時に1件、保持する音声は再生中と次の最大2文分です。利用者向けの方式切り替え設定はありません。

iPhone 16 Proで同じ文章を比較した54試行では、文間の待ちの中央値が約1.10秒から0.08秒へ短縮し、読み始めのp95の悪化は約7msでした。Gemma併用36試行、停止5ケース、通信OFFの再生2試行も成功し、2026-09-26の再試聴で利用者が「違和感なし」と確認したため、一文先読みを採用しました。短い五文では読み上げ方の変化で全体時間が約1.56秒長くなったため、返答全体が常に速く終わるわけではありません。[測定結果と制約](docs/validation/2026-09-26-supertonic-voice-integration.md)を参照してください。

Apple読み上げ時代の最初の一文の早期再生については、[以前の測定結果](docs/validation/2026-09-23-conversation-response-latency.md)に残しています。

生成・保存・読み上げが全て終わってから聞き取りを再開します。全文の確定前に中断した返答は保存せず、確定後は音声が失敗・停止しても全文を保存します。要約と履歴の再構築による待ち時間は残ります。

## 動作要件

実機:

- iPhone 16 Pro（Gemma実機検証の基準端末。他機種は未検証）
- iOS 26.0以上
- 固定版のGemmaモデルが配置済みであること（下記参照）。Apple Intelligenceの有効化は不要
- 日本語の音声認識アセットが利用可能で、Supertonic資産をアプリに同梱していること
- マイク使用の許可

開発環境:

- Xcode 27.0（build 27A266a、今回の検証環境）
- Xcodeに同梱されるiOS SDK
- Rubyと`xcodeproj` 1.27.0

今回の実機検証OSはiOS 27.2（24B5084k）です。deployment targetは26.0を維持しています。

アプリは公式LiteRT-LM 0.17.1とONNX Runtime 1.24.2に依存します。`xcodeproj` gemはXcodeプロジェクト生成時だけ使います。

## Supertonic音声の準備と設定

通常アプリはSupertonic 3を使用します。画面上部の「声」からF1〜F5・M1〜M5を選べます。設定を開くと会話を一時停止し、閉じても自動再開しません。次に会話を再開した際に選んだ声を使います。会話の記憶は変更しません。

開発時に以下を実行して、固定revisionの資産約401MBを取得します。資産はGitへ追加しません。ビルド前にサイズとSHA-256を照合し、欠損や破損があればビルドを失敗させます。実行時のモデルダウンロードはありません。

```bash
python3 scripts/prepare_supertonic_assets.py \
  --output CatRobot/LocalAssets/Supertonic \
  --manifest CatRobot/Resources/supertonic-manifest.json
```

合成条件は日本語、8 steps、CPU 2 threads、speed 1.05。モデルとMIT/OpenRAIL-Mのライセンスをアプリへ同梱します。固定版と移植元は[出典](CatRobot/Vendor/Supertonic/PROVENANCE.md)に記録しています。Apple読み上げの実装は保全していますが、エンジン選択画面や失敗時の自動切り替えはありません。

音声に渡す直前だけ、`iPhone`を「アイフォーン」、`Bluetooth`を「ブルートゥース」に補正します。字幕と保存する会話は原文のままです。URL・メール・バッククォート内のコード・`iPhone16`など識別子の一部は置換しません。未知の英単語の発音改善はこの辞書の対象外です。

実機比較は`SupertonicIntegrationDeviceTests` schemeを使います。通常テストでは実行しません。利用者の記憶とは独立した試験文章を使い、結果にはその試験文章が含まれます。

```bash
scripts/run_supertonic_integration_device_test.sh '<iPhone UDID>' voices
# fixed / gemma / lifecycle / offline も個別に実行可能
```

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

推論はGPU・12,288トークン、返答上限160トークン、thinking無効です。会話本文が8,192トークンに達すると、次の返答の前に古い会話と前回の要約を512トークン以内の記憶へまとめ、直近2,048トークン以上の会話と合わせて再開します。発言の途中では切らず、利用者とAIの一往復単位で残すため、実際の保持量は2Kより多くなる場合があります。要約後は再び8K付近まで会話を蓄積します。

本文の量はモデルのtokenizerで数えます。システム指示・要約・役割の区切り・再読み込みする履歴・新しい入力・返答用の余裕を含め、推論前に12K以内か確認します。短い発言が多く区切りの割合が高い場合は8Kより早く要約します。要約文を字幕や読み上げには出しません。要約の失敗や中断では確定済みの履歴を保ち、会話セッションのリセットでは要約も消去します。単一の大きすぎる入力など、圧縮しても収まらない場合は履歴を保ったまま入力を短くする案内になります。

要約と履歴の再読み込みには待ち時間があり、今回の通常アプリで合成会話を連続実行した実機テストでは約34〜48秒かかりました。要約は情報を取りこぼす場合があり、要約後に最新の返答形式の指定へ従わないケースも確認しています。空の返答で終了した場合だけ、保存した履歴から会話を作り直して一度再試行します。返答・要約・宛先判定は同じエンジンを順に使い、宛先判定の後は保存した記憶から返答用の会話を再構築します。初回はファイル検証とモデル初期化の待ち時間もあります。

通常の `CatRobot` schemeでは実機推論テストをスキップし、`GemmaAppDeviceTests` schemeで明示実行します。テスト中は短い合成会話が実際に読み上げられます。通常サービスで2回以上の自動要約と、その後の宛先判定・会話再開も検証します。Simulatorではモデルの実推論を行いません。

## 会話の記憶

Gemmaとの会話は、返答の生成が正常に完了するたびに「現在の要約＋保持中の確定した往復」をこのiPhone内へ保存します。アプリを終了して開き直しても、会話開始時に前回の記憶を読み込みます。過去に要約で省いた全文を保存する機能や、履歴一覧画面はありません。音声・生成途中の返答・宛先判定に使った発話は保存しません。

保存先はアプリ内の `Library/Application Support/CatRobot/ConversationMemory/current.json`。ロック中のファイル保護を適用し、端末バックアップやクラウド同期には含めません。再インストールや別端末への移行では引き継げません。起動・復帰だけでマイクは再開せず、従来どおり明示操作が必要です。

保存できなかった場合は、会話を続けながら「保存を再試行」できます。その状態でアプリが終了すると、最後に保存できた時点までの記憶に戻ります。生成・保存途中に終了した最新の往復も失われる場合があります。保存ファイルを読み込めない場合は会話開始を止め、再試行または記憶の削除を案内します。壊れた記憶を空の会話で自動上書きしません。

会話画面の「…」→「会話を忘れる」→「削除する」で、端末に保存した記憶も消します。完了後は一時停止状態になり、次の会話は空の記憶から始まります。削除に失敗した場合は、再試行が成功するまで会話を再開しません。

開発時の実機検証では、DebugビルドにUUIDの `CATROBOT_MEMORY_TEST_ID` を渡すと `CatRobot/DeviceMemoryTests/<UUID>` を利用します。Releaseビルドにはこの切り替えを含めません。再起動テストはDebugの実機だけで実行し、さらに保存先がテスト専用ディレクトリであることを検査してから書き込み・削除します。

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
- アプリ独自のクラウドAPI、バックエンド、全文の会話ログ保存、分析基盤はありません。会話の継続に使う要約と保持中の確定会話は端末内に保存します。会話処理は端末上で行います。ただし、必要な音声アセットはOSが事前に取得する場合があります。Gemmaモデルは開発時に手動転送します。
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
