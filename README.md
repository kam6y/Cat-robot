# Cat Robot

Cat Robot は、Claude Opus 5.5（ClaudeForFoundationModels）で日本語の会話をする iPhone 向け SwiftUI アプリです。聞き取りと読み上げは端末内、返答は Claude で処理し、通信障害時は利用可能な Apple の端末内モデルへ切り替えます。

公開リポジトリ: [kam6y/Cat-robot](https://github.com/kam6y/Cat-robot)

## 主な機能

- 初回は「会話を始める」を押した後にマイク権限を求め、次回からは会話画面で自動開始します。会話画面が前面にある間だけ聞き取ります。エコー除去が使える音声経路では、返答を考えている間や話している間も聞き取り、「待って」などの発話で返答を止めて続きを聞きます。エコー除去を有効にできない経路では、返答後に聞き取りを再開します。
- `ねこ`、`猫ちゃん`、`Cat Robot`、`キャットロボット` から始まる発話や、直前から続いている会話は高速経路で処理します。
- 呼びかけがない発話は「猫への発話・曖昧・別の相手への発話」に分類します。端末内モデルが使える場合は Apple Foundation Models、それ以外は Claude Haiku 5.5 を使い、曖昧な場合は一度だけ聞き返します。
- 返答は Claude Opus 5.5 が既定です。Supertonic 3 で読み上げます。モデル・考える深さ・声は「…」→「設定」→「会話」で選べます。
- 返答本文をまだ出していないターンで通信到達不能、タイムアウト、レート制限などが起きた場合は、利用可能な端末内モデルへ切り替えます。原因を断定せず、簡単な返答に切り替えたことを冒頭で伝えます。既知の認証失敗・拒否・取消などは切り替えの対象外です。
- 日本語の聞き取りは `SpeechAnalyzer` / `SpeechTranscriber`、読み上げは Supertonic 3 で端末内処理します。マイクが使えない場合も「…」→「文字で話しかける」で会話できます。一時停止中の文字入力では、マイクを使わずに返答を再生します。
- BLEでハードに接続し、中立と反転を校正できます。`move_head`の予約は発話開始で解放し、待機微動と静止時のPWM停止を調停します。実機確認の結果と残項目は検証記録にまとめています。
- 会話の要約と直近の往復、短い長期メモを端末内に保存します。「新しい会話を始める」は長期メモを残し、「設定」→「記憶」→「すべて削除」は両方を削除します。
- 「見て」「これ何？」など、目の前の情報が必要なときに `look` で前面カメラの画像を1枚Claudeへ渡し、同じ返答で説明します。取得前に「見ています」の状態チップとcuriousの表情を表示します。ハードを接続しなくても使えます。
- 前面カメラが画面の左に来る横向き固定で、黒背景に耳のないベクターの顔を表示します。聞き取り中は `neutral` を表示します。会話状態と `express` に連動する8種類の表情に、待機用の `sleeping` を加え、Supertonic の文の実再生開始/終了に合わせて口を開閉します。通常は顔を大きく表示し、聞き取り中・一時停止・撮影中・自動待機・再接続・熱による追尾停止を左上の状態チップで知らせます。字幕と聞き取り途中の文字は画面に表示しません。最後の返答はVoiceOverで猫のボタンの「その他のコンテンツ」（猫の返事）から読め、会話の記憶にも保持します。文字入力・大きい文字・復旧操作ではスクロールできます。Liquid Glass、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOver に対応します。
- 会話画面が前面にある間は、自動待機に入るまで聞き取り続けます。バックグラウンド移行では停止し、前面に戻ると自動で再開します。音声割り込みとオーディオ経路変更では一時停止し、「一時停止中・猫をタップで再開」を表示します。猫をタップすると一時停止し、もう一度タップすると再開します。自動待機で寝た場合は、前面復帰や設定の開閉では起きず、猫のタップだけで再開します。
- OSLog のレイテンシ signpost と診断ログに、区間、結果コード、正規化したエラー種別、切り替えの事象と回数を記録します。区間ごとの経過秒と結果コードは、`log collect` で後から回収できるよう default レベルのログにも 1 行残します。発話・返答・API エラー本文は記録しません。

## 返答開始の待ち時間

一文が確定したら生成途中から読み上げ、再生中に次の一文だけを先に合成します。安全な区切りがない場合は全文を待ちます。ネイティブ合成は同時に 1 件、保持する音声は再生中と次の最大 2 文分です。利用者向けの方式切り替え設定はありません。

Claude 構成の実機遅延は 2026-10-12 に簡易版（20 ターン、iPhone 16 Pro・Wi-Fi）を測定し、高速経路の最初の字幕が中央値 2.21 秒（目標 1.5 秒）、読み上げ開始が中央値 3.19 秒（目標 2.5 秒）で目標未達でした。詳細と手順は [Claude 会話エンジンの検証記録](docs/validation/2026-10-11-claude-conversation-engine.md) にあり、条件は要件の前提どおり（既定の Opus 5.5・effort low）で、要件の 50 ターン受入は別に記録します。過去の[Supertonic 一文先読みの測定](docs/validation/2026-09-26-supertonic-voice-integration.md)は音声側の参考で、Claude 構成の実測値ではありません。

声で割り込むと、古い返答の再生・未再生キュー・生成を取り消し、その発話の先頭を残したまま聞き取りを続けます。記憶には読み上げ終わった文と中断したことだけを残し、途中の文や未再生の続きは伝達済みとして扱いません。画面を離れるなどの通常の停止では、従来どおり全文確定前の返答を保存せず、確定後は全文を保存します。通常の発話区切りは1.2秒のままで、通信、認証、認識の準備、要約による待ち時間は残ります。割り込みの検証条件と制限は[検証記録](docs/validation/2026-10-30-voice-barge-in.md)を参照してください。

## iPhoneからハードを接続・調整する

BLEプロトコル版1のロボットを使います。ハードが未接続でも会話を続けられます。接続先が未選択なら検索を押すまでBluetoothを起動せず、保存済みの接続先があれば会話画面を開いた時と前面復帰時に接続します。

1. 「会話を始める」から会話画面へ進み、「…」→「設定」→「ロボット」を開きます。会話の認証・マイクのエラーがあっても設定を開けます。手動の接続・校正にClaudeの返答生成は不要です。
2. 「接続先を変更」で近くの`CatRobot-XXXX`を選び、Bluetoothの許可と初回のペアリングに応じます。初回ペアリングはロボット起動後60秒以内です。接続準備中はハードの操作を待ちます。許可・ペアリングの一時的なinactiveでは接続準備を維持します。
3. 接続後、「動きの強さ」と「待機中も少し動く」を選べます。強さは静止後に速度上限だけを変更し、読み戻した値を表示します。標準は左右120°/秒・上下100°/秒、控えめ60/50、活発180/120です。未反映の選択はその旨を表示します。
4. 「中立と回転方向を調整」を開きます。現在の動作が終わり、調整値とリミットを新しく読めるまで待ちます。左の「中立の調整」「回転方向」「動作確認」から項目を選びます。大きい文字では項目一覧から詳細へ進みます。左右・上下のずれは±20°、0.5°刻み、反転は軸別です。変更は最大10Hzでその場に反映します。
5. 「動作確認」で「正面を向かせる」「左端へ／右端へ／上端へ／下端へ」で低速の方向確認をします。左右はロボットと向かい合って見た方向です。端は新しく読んだFWリミット以内、最大左右60°・上下30°です。未確認の方向は利用者がハードを見ながら1方向ずつ確認します。上部の「停止」は待機中・調整中にも使えます。表示角は指令値で、実測角ではありません。
6. 「ロボットに保存」はACKとCalibrationの読み戻しが一致してから「保存済み」と表示します。確認できなかった場合は変更を保ったまま再試行できます。「変更を戻す」は画面を開いた時の適用値へ戻し、不揮発保存は行いません。戻る際も、保存・戻す・編集を続ける、を選べます。

切断した校正は操作を無効にします。戻せなかった変更を表示し、再接続で古いドラフトや保存要求を再送しません。一度校正を閉じて開き直し、ロボットの実際の値を読み直してください。保存を確認できなかった場合も、不揮発メモリの結果は読み直して確認します。

接続できない場合はBluetoothの許可・電源・距離を確認します。初回やペアリングエラーはロボットを再起動し、60秒以内に再試行します。ボンドはアプリから自動削除しません。接続中・準備中・再接続中は「接続をキャンセル」で待機と再試行を中断できます。「接続を切る」または「接続をキャンセル」の後、その起動中は自動再接続せず、「このロボットに接続」か接続先の選択で明示的に再開します。

`move_head`は発話に合わせる動作の予約を返します。最初の読み上げ開始で一度だけ解放し、1サイクルずつ直列に実行します。4秒は追加予約・開始の目安で、最初の1サイクルと開始済みの動作は完走します。音声が先に終わっても途中で切りません。声の認識確定時の小さい頷きは、予約ジェスチャとは独立した短いMOVE列です。現在の`look_at_user`は正面を向きます。

`express(expression, hold_seconds)` は表情を予約します。`neutral` / `happy` / `curious` / `thinking` / `speaking` / `sleepy` / `surprised` / `sorry` の8種類を使えます。保持は1〜10秒（既定3秒）、最初の実再生開始を起点とし、複数文で延長しません。保持後はその時の会話状態へ戻り、停止・設定・背景・新しい会話・失敗時は取消します。ハードやカメラが使えなくても表情は表示でき、`sleepy` 自体はマイクやハードを操作しません。瞳のカメラ追従は別課題です。 表情と文口同期の自動試験、採用画像との比較、実機の未確認項目は[顔・表情・発話同期の検証記録](docs/validation/2026-10-24-face-expression.md)にまとめています。


最後に話しかけてから5分で `sleepy`、合計10分で自動待機に入り `sleeping` を表示します。「…」→「設定」→「会話」の「居眠り」でそれぞれ分単位に変更でき、設定は端末に保存します（待機は眠そうになる時間より後、最大24時間）。猫への呼びかけとして受け付けた音声、文字の送信、猫のタップで時間をリセットし、周囲の雑談では延長しません。返事や聞き取り判定の途中は処理を終えてから待機し、未確定の認識は発話開始から最大20秒で区切ります。音声認識の終了処理は既存の完了待ちを使い、別のタイムアウトは設けていません。

自動待機中は寝顔を表示したまま、マイク・カメラ・ハードの自動動作を止めます。ハードの姿勢保持と接続は維持します。背景・端末ロック・設定中の時間も数え、戻った時点で期限を過ぎていれば寝たままになります。猫をタップすると再開し、入力途中だった文字は残ります。`sleeping` は `express` から選べません。[下書きとベクターの比較](docs/design/sleeping-2026-10-26/visual-comparison.md)と[検証記録](docs/validation/2026-10-26-idle-sleeping.md)に詳細をまとめています。

`look(purpose)` は要求されたときだけ現在の静止画像を1枚返します。カメラ許可は「…」→「設定」→「カメラと顔追尾」から設定でき、顔追尾をオンにする必要はありません。未許可や取得失敗でも会話は続けられます。画像取得は同時に1件まで、3秒で時間切れとなり、設定・背景移行・高温・返答取消で中断します。画像はアプリに保存せず、画像付きのモデルセッションは返答後に破棄します。次の返答は文字の記憶を引き継ぎます。[lookの検証記録](docs/validation/2026-10-26-look.md)に自動試験と実機の未確認項目をまとめています。

顔追尾は、保存済みの「左右補正」で調整した正面方向から左右30°以内、上下はカメラ正面から25°以内を向いているときだけ行います。左右補正を変えると、追尾先と顔の向き判定の中心が一緒に変わります。角度が不明な顔は追尾せず、こちら向きの顔を最後に捉えてから約10秒で一度だけ正面へ戻ります。その後は「待機中も少し動く」の設定に従います。これは顔の向きによる近似で、目の視線を判定する機能ではありません。[設計](docs/superpowers/specs/2026-10-28-face-facing-gate-design.md)と[検証記録](docs/validation/2026-10-28-face-facing-gate.md)に判定条件と確認範囲を記載します。

設定では会話と新しい自動動作を止め、開始済みの波形を完走させます。バックグラウンドではPINGと接続を止め、FWの切断復帰に任せます。「待機中も少し動く」がオンの間はPWMを維持し、停止・再開による跳ねを避けます。オフの場合は、接続中にACTIVEのまま2秒静止すると低優先度の`TORQUE 0`でPWMを停止し、次の動作は通常のコマンドで再開します。これは電源断を意味しません。このアプリ制御下での実機の保持状態と電流は未確認です。

ホスト検証と、iPhone・ロボットの実機確認結果・未実施項目は[ハードの接続・動作・校正の検証記録](docs/validation/2026-10-23-ios-robot-link.md)に分けています。

7動作×3強度の実機確認は、ロボットを見られる状態で次の専用runnerを使います。iPhoneに保存済みの接続先名を指定し、`small` → `medium` → `large` を1段階ずつ実行して見た目を確認します。全体の「動きの強さ」は保存済み設定を使用します。通常テストとSimulatorではスキップし、実機でも明示の実行条件がなければBLEを起動しません。

```bash
scripts/run_robot_motion_device_test.sh --attended '<iPhone UDID>' small '<保存済みのロボット名>'
```

実行中はiPhoneを前面に保ち、「会話を始める」を押さずに待ちます。動作順は `nod` / `shake` / `tilt` / `look_up` / `look_down` / `look_at_user` / `center`。最後の2つは小さく横を向かせてから戻します。結果JSONとxcresultは出力先に保存し、実行成功は動作サイクルの完了を示します。方向・振幅はSTATUS軌跡、滑らかさは観察で確認します。音声入力・実際の読み上げとの同期は別の試験です。`ROBOT_BUILD_ONLY=1` ならビルドだけを行います。


## ロボット側ファームウェア（`firmware/`）

ハード（XIAO ESP32C3 + 2 軸サーボ）のファームウェアは `firmware/` にあり、iPhone アプリとは別にビルド・書き込みする（PlatformIO、Arduino-ESP32 3.3.12、NimBLE）。BLE のプロトコル版 1（要件 §7.5.2）、安全状態機械、ホスト単体テスト、Mac 用の試験ツール（`firmware/tools/ble_client.py`、`firmware/tools/serial_cli.py`）を含む。導入・書き込み・校正の手順は [firmware/README.md](firmware/README.md)、設計は [設計書](docs/superpowers/specs/2026-10-23-xiao-firmware-ble-design.md)、実測は [検証記録](docs/validation/2026-10-23-xiao-firmware.md)。

## 動作要件

実機:

- iOS 27.0 以上の iPhone。受入確認の基準端末は iPhone 16 Pro で、Claude 構成の実機確認は 2026-10-11 に Debug ビルドで実施しました（[検証記録](docs/validation/2026-10-11-claude-conversation-engine.md)）。
- Claude を利用するための通信と認証設定。
- 日本語の音声認識アセットと、同梱する Supertonic 音声資産。
- 音声入力にはマイク使用の許可。

Claude 会話、宛先判定、通信断時の切り替えは Apple Intelligence 対応機（iPhone 16 Pro）で検証済みです。Apple Intelligence 非対応機は未検証です（T-DEV-1 / T-DEV-2 は未実施）。端末内モデルが利用できない場合、通信断や日次上限時の代替返答は使えず、会話不可の案内になります。

開発環境:

- Xcode 27.1（build 27A9275、2026-10-23のハード接続ホスト検証環境）と同梱 iOS SDK。
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

「…」→「設定」で変更します。「会話」「記憶」「カメラと顔追尾」「ロボット」「利用量」「このアプリについて」の6カテゴリから選びます。開くと会話を停止し、閉じると自動で聞き取りを再開します（自動待機中は猫のタップが必要です）。初回の説明は「このアプリについて」で見直せます。

| 項目 | 内容 |
|---|---|
| モデル | Claude Opus 5.5（既定）/ Sonnet 5.5 / Haiku 5.5 |
| 考える深さ | low（速さ優先、既定）/ medium（少し考える） |
| 声 | Supertonic F1〜F5・M1〜M5、既定 F1 |
| 居眠り | 「会話」内で眠そうになるまで・待機に入るまでを分単位で設定 |
| カメラと顔追尾 | カメラ許可、顔追尾のオン/オフと状態、左右補正（0〜20°、0.5°刻み、既定の8.5°に戻せます） |
| ロボット | 接続先、動きの強さ、待機微動、中立・反転・方向確認・保存 |
| 記憶 | 長期メモの一覧、個別削除、すべて削除（会話の要約も消えます） |
| 1 日の上限 | 既定 300 回、10〜2,000 回を 10 回刻みで設定 |
| 利用量 | 今日・今月の回数、概算トークン数、今月の概算 USD |
| このアプリについて | 送るもの・保存するもの、はじめの説明の見直し、ライセンス |

モデルと考える深さは次に Claude セッションを作るときに反映し、進行中のセッションでは切り替えません。「新しい会話を始める」か次回起動で新しい設定を使えます。長期メモは保持します。記憶を個別に消した場合は、次の返答の前にセッションを作り直して反映します。要約と直近の往復は残ります。日次上限は次のターンで確認し、上限に達していれば Claude に送らず、利用可能な端末内モデルで簡単に答えます。

利用量は Claude で正常に完了した返答をもとにしたアプリ内の概算です。宛先判定・要約・メモ整理を含む実際の請求額とは異なるため、請求は Claude Console で確認します。ワークスペースの月間支出上限は Console で別途設定します。

## 日本語の読み変換の準備

jpreprocess 0.15.0と固定した日本語辞書を使い、YouTube等の既知のLatin語と`+`だけを音声向けに補正します。日本語・数字・助詞は原表記を保ち、全文カナ化はしません。数字を含むLatin語（25cm・iPhone15等）は語単位で読みます。URL・メール・コード・未知語・アクセントや他scriptが混ざる識別子は原文を保持します。従来のiPhone/Bluetoothだけを置き換える処理は廃止し、辞書や変換の失敗時は既存の音声エラーとして扱います。表示用・記憶用の返答は書き換えません。

Rust 1.90.0とXcodeを用意し、最初に次を実行します。通常のXcodeビルドではネットワーク取得やRustのビルドを行いません。

```bash
rustup toolchain install 1.90.0 --profile minimal
rustup target add --toolchain 1.90.0 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
python3 scripts/prepare_jpreprocess_assets.py --root CatRobot/LocalAssets/JPreprocess --manifest CatRobot/Resources/jpreprocess-manifest.json
scripts/build_jpreprocess.sh
```

ネイティブソースを変更したら`build_jpreprocess.sh`を再実行します。辞書は`LocalAssets/JPreprocess/dictionary`、静的ライブラリは同じ親フォルダのXCFrameworkに置き、Gitには追加しません。欠損・改変・ソースとライブラリの不一致はビルド時に検出します。[出典とライセンス](CatRobot/Vendor/JPreprocess/PROVENANCE.md)も参照してください。

実機で新旧の入力から音声サンプルを生成するには、専用の試験コマンドを使います。実行すると短い確認音声が流れます。結果と未確認事項は [検証記録](docs/validation/2026-10-28-jpreprocess-pronunciation.md) を参照してください。

```bash
scripts/run_supertonic_integration_device_test.sh <UDID> pronunciation
```

実機試験はアプリが前面にある状態で実行します。`test.log`に専用テストの開始が出た後、前面へ出す操作が必要な場合は別ターミナルで次を実行します。

```bash
xcrun devicectl device process launch --device <UDID> --activate com.kamby.CatRobot
```


## Supertonic音声の準備と設定

通常アプリは Supertonic 3 を使用します。「…」→「設定」→「会話」の「声」で F1〜F5・M1〜M5 を選び、初期値は F1 です。選択は再起動後も保持します。設定を開くと会話を一時停止し、閉じると自動で再開します（自動待機で寝ている場合は猫のタップが必要です）。再開後は選んだ声を使い、会話の記憶は変更しません。

開発時に以下を実行して、固定 revision の資産約 401 MB を取得します。資産は Git へ追加しません。ビルド前にサイズと SHA-256 を照合し、欠損や破損があればビルドを失敗させます。実行時のモデルダウンロードはありません。

```bash
python3 scripts/prepare_supertonic_assets.py \
  --output CatRobot/LocalAssets/Supertonic \
  --manifest CatRobot/Resources/supertonic-manifest.json
```

合成条件は日本語、8 steps、CPU 2 threads、speed 1.05。モデルと MIT / OpenRAIL-M のライセンスを同梱します。固定版と移植元は[出典](CatRobot/Vendor/Supertonic/PROVENANCE.md)に記録しています。読み上げは Supertonic に統一し、エンジン選択や読み上げ失敗時の自動切り替えはありません。

音声へ渡す直前だけ、`iPhone` を「アイフォーン」、`Bluetooth` を「ブルートゥース」に補正します。VoiceOverへ渡す返答と保存する会話は原文のままです。URL・メール・バッククォート内のコード・`iPhone16` など識別子の一部は置換しません。

実機の音声確認は `SupertonicIntegrationDeviceTests` scheme を使います。通常テストでは実行しません。利用者の記憶とは独立した試験文章を使い、結果にはその試験文章が含まれます。

```bash
scripts/run_supertonic_integration_device_test.sh '<iPhone UDID>' voices
# fixed / lifecycle も個別に実行可能
```

## 会話の記憶

返答の生成が正常に完了するたび、会話要約と直近の確定した往復を保存します。端末内モデルで完了した往復も次の Claude セッションへ引き継ぎます。空の返答、生成途中の返答、音声、宛先判定に使った発話は保存しません。過去に要約で省いた全文を保存する機能や、履歴一覧画面はありません。

記憶は 2 層で、保存先はアプリ内の `Library/Application Support/CatRobot/ConversationMemory/` です。

- `current.json`: 会話要約と直近の往復。互換 ID は `claude-memory-v1`。
- `facts.json`: 人物・好み・出来事・約束などの短い長期メモ。`remember` ツールで登録し、「設定」→「記憶」で一覧、個別削除、すべて削除を扱います。

完全ファイル保護を適用し、端末バックアップやクラウド同期には含めません。再インストールや別端末への移行では引き継げません。Claude に送るのは、受け付けた発話の文字、会話要約、直近の往復、長期メモ、および `look` が取得した静止画像1枚です。要約・メモの整理や、端末内モデルが使えない場合の宛先判定にも Claude を使います。音声や連続したカメラ映像は送信せず、カメラ画像は保存しません。取得画像は同じ返答の中だけで使い、次の返答へ再送しません。

保存できなかった場合は、会話を続けながら保存を再試行できます。そのまま終了すると、最後に保存できた時点までの記憶に戻る場合があります。読み込み失敗時は会話を止め、再試行または削除を案内します。壊れた記憶を空の会話で自動上書きしません。

「…」→「新しい会話を始める」は短期の要約と往復を捨て、長期メモを残して聞き取りを再開します。「設定」→「記憶」→「すべて削除」→「削除する」は両方を削除します。削除に失敗した場合は、再試行が成功するまで会話を再開しません。

## 顔サイズの調整

iPhone用の別アプリ「顔サイズ調整」で、通常会話画面の顔の大きさを見ながら選べます。[使い方とビルド手順](tools/face-size-tuner/README.md)。選んだ値をコピーしてCodexへ伝え、本体への反映を依頼してください。

## プロジェクト生成

`CatRobot.xcodeproj/project.pbxproj`と共有schemeは直接編集しません。`CatRobot/`または`CatRobotTests/`のSwiftファイルを変更したら、次を実行します。

```bash
ruby -e 'require "xcodeproj"; abort unless Xcodeproj::VERSION == "1.27.0"'
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

ソース変更と再生成した`CatRobot.xcodeproj`は一緒に管理します。生成をもう一度実行してもプロジェクト差分が増えないことが決定性の基準です。

生成するアプリターゲットには 3 つのスクリプト段階があります。「Validate jpreprocess assets」は辞書とネイティブライブラリを、「Validate Supertonic assets」は同梱する音声資産をコンパイル前に検証します。最後の「Remove codeless onnxruntime framework」は、静的リンク済みの `onnxruntime.framework` に Xcode が埋め込む中身のないスタブを取り除きます。スタブは App Store Connect の検証で ITMS-90208（Info.plist の最小 OS と不一致）になるためです。取り除くのは記号を公開しないスタブだけで、本物の dylib なら残します。検査や削除に失敗したらビルドを止めます。スクリプトの sandbox（`ENABLE_USER_SCRIPT_SANDBOXING`）は成果物の削除を許さず、削除対象を出力に宣言すると埋め込み段階と衝突するため、アプリターゲットだけ sandbox を切っています（プロジェクト既定とテストターゲットは有効のまま）。

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

1. 前面カメラを画面の左にした横向きで起動し、「会話を始める」からマイクを許可する。
2. 「猫ちゃん、短く自己紹介して」と話し、表情、口の動き、読み上げ、聞き取り再開を確認する。VoiceOverでは猫のボタンの「その他のコンテンツ」から返答の全文を確認する。
3. 続けて名前を呼ばずに話し、会話継続中の高速経路を確認する。
4. 別の人への発話と曖昧な発話で、無応答または聞き返しになることを確認する。
5. バックグラウンドへ移動して戻ると自動で聞き取りが再開すること、猫をタップすると一時停止し、もう一度タップで再開することを確認する。
6. 「…」→「文字で話しかける」で文字でも返答でき、送信後も入力欄が残ることを確認する。

## 制約

- 会話は画面がアクティブな間だけです。バックグラウンド録音、ロック画面の StandBy 拡張、常駐ウェイクワード検出は実装していません。
- 宛先判定には誤検知や見逃しがあり、生成モデルの返答も事実とは限りません。二重判定や返答の事実検証は行いません。
- アプリ独自のバックエンド、全文の会話ログ保存、分析基盤はありません。返答などの文字処理は Anthropic の Claude API、聞き取りと読み上げは端末内で行います。音声認識アセットは OS が事前に取得する場合があります。
- ClaudeForFoundationModels 0.2.3 では一部の API エラーを細かく区別できず、通信以外の汎用生成失敗も端末内モデルへの切り替え対象に含まれます。返答の途中では代替返答を重ねません。
- 医療、法律、金融など、正確性が必須の用途を保証する製品ではありません。
- アプリアイコン（`Assets.xcassets/AppIcon.appiconset`）は白背景に黒猫の横顔シルエットの 1 枚絵で、2026-10-12 に画像生成で作って採用したものです。猫の顔と UI の計画で見直す可能性があります。

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
- `docs/`: [文書の入口](docs/README.md)、[現行アーキテクチャ](docs/architecture.md)、仕様と検証記録。

deployment target は iOS 27.0、iPhone 専用、Swift 6 strict concurrency（complete）、前面カメラが画面の左・充電端子が右の横向き固定です。

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

統合と検証が済んだブランチは整理します。squashで本流から到達できない履歴を残す場合は、削除前に参照一覧と検証済みGit bundleを保存します。未コミット変更やローカル専用の音声資産・認証設定を含むworktreeは残し、強制削除しません。関係のない変更を同じbranchへ混ぜず、source、test、再生成したprojectを同じ粒度でまとめます。
