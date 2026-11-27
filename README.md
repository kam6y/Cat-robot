# CaRot

CaRot（キャロット）は、利用者の Hermes（Windows の Hermes API server）で返事をつくり、日本語で会話する iPhone 向け SwiftUI アプリです。返事・会話の続き・履歴の正本は Hermes にあり、聞き取りと読み上げ、カメラ、顔追尾、BLE、すぐに止める安全の処理は端末で行います。声が猫に向けられたかは、呼びかけの言葉と顔の向きで端末の中だけで決め、そのための通信はしません。別のモデルへの切り替えはなく、つながらないときなどは短い定型文を声で案内してから失敗を表示します。

普段使いできる常設の HTTPS 接続先（OS 標準の証明書の確認を通る Hermes）はまだ用意されていません。接続先と API キーを設定しないと通常の返事は使えません（設定の案内が出るだけで、ほかのモデルが代わりに答えることはありません）。[Hermes で返事をつくる構成の検証記録](docs/validation/2026-11-10-hermes-conversation.md)を参照してください。

[CaRot のソースコード（GitHub）](https://github.com/kam6y/Cat-robot)

## 主な機能

- 初回は「会話を始める」を押した後にマイク権限を求め、次回からは会話画面で自動開始します。会話画面が前面にある間だけ聞き取ります。AI が考えている間と話している間は聞き取りを止め、返答後に再開します。
- 聞き取り中、新しい映像でこちらを向いた有効な顔が1人以上あれば、複数人が映っていても、呼びかけの言葉がなくても猫への発話として返答します。瞳の視線ではなく顔の向きを使い、ハード未接続・顔追尾オフでも動きます。顔と発声者は対応付けないため、誰かがこちらを向いている間は別の人の声にも応答する場合があります。一度会話を始めると、返答後30秒間は顔の向きや呼びかけを問わず続けて話せます。返答のたびに30秒を数え直すので、会話全体の長さに上限はありません。カメラ未許可・高温・こちら向きの顔なし・古い情報では顔による受理を使いません。顔の判定に画像の保存・送信は行いません。[アプリ全体の分岐図（2026-11-09時点の静的スナップショット。AI による宛先の判定と聞き返しは 2026-11-26 に撤去）](docs/application-flow.html)と[複数人対応の設計](docs/superpowers/specs/2026-11-07-multiple-facing-addressing-design.md)を参照してください。
- 顔が向いておらず会話の続きでもないときは、呼びかけの言葉（初期値「キャロット」）を含む発話だけを猫への発話として扱います。文の頭・途中・最後のどこで言ってもよく、発話の全文を Hermes に送って返事をつくります。照合は読みで行うので「きゃろっと」と書き起こされても一致し、単語の途中に含まれるだけでは一致しません。呼びかけの言葉だけのときは Hermes に送らず「なあに？」と答え、会話継続窓を始めます。それ以外の発話は何も送らずに捨て、聞き取りを続けます（聞き返しはしません）。その言葉を話題にした場合も応答します。呼びかけの言葉は「…」→「設定」→「声と待機時間」の「呼びかけ」で、文字で入力するか、入力欄の右端のマイクをタップして話し、内容を確かめてから保存します。声で入力するときは会話の聞き取りを止めた設定の中で一回だけ聞き取り、設定を閉じるとマイクを手放してから会話の聞き取りに戻ります。
- 返事は「…」→「設定」→「Hermes 接続」で設定した Hermes がつくり、Supertonic 3 で読み上げます。声は設定の「声と待機時間」で選べます。「返答モデル」では、接続中の Hermes が返事に使うモデルと推論の深さ（effort）を選べます。どちらも初期値は Hermes の既定です。
- 通信できない、生成に失敗した、接続設定が必要な、入力が長すぎる、聞き取りに失敗した、といったときは、種類ごとに決めた短い定型文（例:「ごめんね、いまはうまくつながらないみたい。少し待ってから、また話しかけてね。」）を声で案内してから失敗を表示します。端末内モデルへの切り替えや代替の返答はありません。読み上げ自体の失敗、マイク許可の拒否、取り消しは声で案内しません。案内の途中で一時停止・新しい会話・文字入力をすると案内を止め、文字入力はそのまま返答へ進みます。[設計](docs/superpowers/specs/2026-11-09-haiku-only-design.md)を参照してください。
- 日本語の聞き取りは `SpeechAnalyzer` / `SpeechTranscriber`、読み上げは Supertonic 3 で端末内処理します。マイクが使えない場合も「…」→「文字で話しかける」で会話できます。
- BLEでハードに接続し、中立と反転を校正できます。`move_head`の予約は発話開始で解放し、待機微動と静止時のPWM停止を調停します。実機確認の結果と残項目は検証記録にまとめています。
- 会話の本文は端末に保存しません。端末に残すのは Hermes の session などの識別子だけで、履歴は「…」→「会話の履歴」で表示のたびに Hermes から読みます。メニューの「新しい会話を始める…」で確認すると、新しい Hermes の session に切り替わります。Hermes 側の履歴の削除・忘却や、前の返事の停止を意味しません。
- Hermes は返事に合わせて首の動きと表情を選びます。「これを見て」と頼むと、iPhone は前面カメラの写真を1枚送り、Hermes が同じ会話で答えます。利用中の Windows の Hermes に追加設定は不要です。
- 前面カメラが画面の左に来る横向き固定で、黒背景に耳のないベクターの顔を表示します。聞き取り中は `neutral` を表示します。会話状態と `express` に連動する8種類の表情に、待機用の `sleeping` を加え、Supertonic の文の実再生開始/終了に合わせて口を開閉します。通常は顔を大きく表示し、聞き取り中・一時停止・撮影中・自動待機・再接続・熱による追尾停止・音量0を左上の状態チップで知らせます。字幕と聞き取り途中の文字は画面に表示しません。最後の返答はVoiceOverで猫のボタンの「その他のコンテンツ」（猫の返事）から読め、会話の記録は Hermes に残ります。文字入力・大きい文字・復旧操作ではスクロールできます。Liquid Glass、Reduce Motion、Reduce Transparency、Dynamic Type、VoiceOver に対応します。
- 会話画面が前面にある間は、自動待機に入るまで聞き取り続けます。バックグラウンド移行では停止し、前面に戻ると自動で再開します。音声割り込みとオーディオ経路変更では一時停止し、「一時停止中・猫をタップで再開」を表示します。猫をタップすると一時停止し、もう一度タップすると再開します。自動待機で寝た場合は、前面復帰や設定の開閉では起きず、猫のタップだけで再開します。
- OSLog のレイテンシ signpost と診断ログに、区間、結果コード、正規化したエラー種別、切り替えの事象と回数を記録します。区間ごとの経過秒と結果コードは、`log collect` で後から回収できるよう default レベルのログにも 1 行残します。発話・返答・API エラー本文は記録しません。

## 返答開始の待ち時間

Hermes の返事は、run が終わって最終出力を受け取ってから読み上げます（生成途中の文は届きません。読み上げは 2,000 文字までの最後の文末で切ります）。読み上げは一文ずつ合成し、再生中に次の一文だけを先に合成します。ネイティブ合成は同時に 1 件、保持する音声は再生中と次の最大 2 文分です。利用者向けの方式切り替え設定はありません。

Hermes 構成の待ち時間は未測定です。以前の Claude 構成の実機遅延は 2026-10-12 に簡易版（20 ターン、iPhone 16 Pro・Wi-Fi）を測定し、高速経路の最初の字幕が中央値 2.21 秒（目標 1.5 秒）、読み上げ開始が中央値 3.19 秒（目標 2.5 秒）で目標未達でした。詳細と手順は [Claude 会話エンジンの検証記録](docs/validation/2026-10-11-claude-conversation-engine.md) にあり、条件は要件の前提どおり（既定の Opus 5.5・effort low）で、要件の 50 ターン受入は別に記録します。過去の[Supertonic 一文先読みの測定](docs/validation/2026-09-26-supertonic-voice-integration.md)は音声側の参考で、Claude 構成の実測値ではありません。

返事の受け取りと読み上げが終わってから聞き取りを再開します。取り消した返事は、あとから届いても採用しません（Hermes 側では終わった run の返事が履歴に残ることがあります）。通信と Hermes の処理による待ち時間は残ります。

## iPhoneからハードを接続・調整する

BLEプロトコル版1のロボットを使います。ハードが未接続でも会話を続けられます。接続先が未選択なら検索を押すまでBluetoothを起動せず、保存済みの接続先があれば会話画面を開いた時と前面復帰時に接続します。

1. 「会話を始める」から会話画面へ進み、「…」→「設定」→「ロボット」を開きます。会話の接続・マイクのエラーがあっても設定を開けます。手動の接続・校正に Hermes の返事は不要です。
2. 「接続先を変更」で近くの`CaRot-XXXX`を選び、Bluetoothの許可と初回のペアリングに応じます。初回ペアリングはロボット起動後60秒以内です。接続準備中はハードの操作を待ちます。許可・ペアリングの一時的なinactiveでは接続準備を維持します。
3. 接続後、「動きの強さ」と「待機中も少し動く」を選べます。強さは静止後に速度上限だけを変更し、読み戻した値を表示します。標準は左右120°/秒・上下100°/秒、控えめ60/50、活発180/120です。未反映の選択はその旨を表示します。
4. 「中立と回転方向を調整」を開きます。現在の動作が終わり、調整値とリミットを新しく読めるまで待ちます。左の「中立の調整」「回転方向」「動作確認」から項目を選びます。大きい文字では項目一覧から詳細へ進みます。左右・上下のずれは±20°、0.5°刻み、反転は軸別です。変更は最大10Hzでその場に反映します。
5. 「動作確認」で「正面を向かせる」「左端へ／右端へ／上端へ／下端へ」で低速の方向確認をします。左右はロボットと向かい合って見た方向です。端は新しく読んだFWリミット以内、最大左右60°・上下30°です。未確認の方向は利用者がハードを見ながら1方向ずつ確認します。上部の「停止」は待機中・調整中にも使えます。表示角は指令値で、実測角ではありません。
6. 「ロボットに保存」はACKとCalibrationの読み戻しが一致してから「保存済み」と表示します。確認できなかった場合は変更を保ったまま再試行できます。「変更を戻す」は画面を開いた時の適用値へ戻し、不揮発保存は行いません。戻る際も、保存・戻す・編集を続ける、を選べます。

切断した校正は操作を無効にします。戻せなかった変更を表示し、再接続で古いドラフトや保存要求を再送しません。一度校正を閉じて開き直し、ロボットの実際の値を読み直してください。保存を確認できなかった場合も、不揮発メモリの結果は読み直して確認します。

接続できない場合はBluetoothの許可・電源・距離を確認します。初回やペアリングエラーはロボットを再起動し、60秒以内に再試行します。ボンドはアプリから自動削除しません。接続中・準備中・再接続中は「接続をキャンセル」で待機と再試行を中断できます。「接続を切る」または「接続をキャンセル」の後、その起動中は自動再接続せず、「このロボットに接続」か接続先の選択で明示的に再開します。

音声でも文字入力でも、Hermes が会話に合わせて `move_head`・`express`・`look` を選び、iPhone が実行します。首と表情は最初の返事で予約し、読み上げに合わせて動きます。首や表情を動かせないときも、そのまま返事を続けます。写真を求められたときだけ、取得結果を同じ Hermes セッションに返して答えを受け取ります。

`move_head`は発話に合わせる動作の予約を返します。最初の読み上げ開始で一度だけ解放し、1サイクルずつ直列に実行します。4秒は追加予約・開始の目安で、最初の1サイクルと開始済みの動作は完走します。音声が先に終わっても途中で切りません。声の認識確定時の小さい頷きは、予約ジェスチャとは独立した短いMOVE列です。現在の`look_at_user`は正面を向きます。

`express(expression, hold_seconds)` は表情を予約します。`neutral` / `happy` / `curious` / `thinking` / `speaking` / `sleepy` / `surprised` / `sorry` の8種類を使えます。保持は1〜10秒（既定3秒）、最初の実再生開始を起点とし、複数文で延長しません。保持後はその時の会話状態へ戻り、停止・設定・背景・新しい会話・失敗時は取消します。ハードやカメラが使えなくても表情は表示でき、`sleepy` 自体はマイクやハードを操作しません。瞳のカメラ追従は別課題です。 表情と文口同期の自動試験、採用画像との比較、実機の未確認項目は[顔・表情・発話同期の検証記録](docs/validation/2026-10-24-face-expression.md)にまとめています。


最後に話しかけてから5分で `sleepy`、合計10分で自動待機に入り `sleeping` を表示します。「…」→「設定」→「声と待機時間」の「居眠り」でそれぞれ分単位に変更でき、設定は端末に保存します（待機は眠そうになる時間より後、最大24時間）。猫への呼びかけとして受け付けた音声、文字の送信、猫のタップで時間をリセットし、周囲の雑談では延長しません。返事の途中は処理を終えてから待機し、未確定の認識は発話開始から最大20秒で区切ります。音声認識の終了処理は既存の完了待ちを使い、別のタイムアウトは設けていません。

自動待機中は寝顔を表示したまま、マイク・カメラ・ハードの自動動作を止めます。ハードの姿勢保持と接続は維持します。背景・端末ロック・設定中の時間も数え、戻った時点で期限を過ぎていれば寝たままになります。猫をタップすると再開し、入力途中だった文字は残ります。`sleeping` は `express` から選べません。[下書きとベクターの比較](docs/design/sleeping-2026-10-26/visual-comparison.md)と[検証記録](docs/validation/2026-10-26-idle-sleeping.md)に詳細をまとめています。

Hermes が返事の先頭で `"look":true` を指定すると、iPhone が前面カメラの写真を1枚取得します。カメラ許可は「…」→「設定」→「カメラと顔追尾」から設定でき、顔追尾をオンにする必要はありません。未許可や取得失敗でも会話は続けられます。画像取得は同時に1件まで、3秒で時間切れとなり、設定・背景移行・高温・返答取消で中断します。取得した写真はメモリ上でJPEGに変換してHermesに送ります。写真はHermes側の会話データに残り、iPhoneには保存しません。アプリの履歴には利用者の発言と猫の返事を文字で表示します。[lookの検証記録](docs/validation/2026-10-26-look.md)に自動試験と実機の未確認項目をまとめています。

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
- 返事に使う Hermes の HTTPS 接続先（https の root）と API キー。普段使いできる常設の接続先はまだありません。
- 日本語の音声認識アセットと、同梱する Supertonic 音声資産。
- 音声入力にはマイク使用の許可。

Hermes で返事をつくる構成の確認は[検証記録](docs/validation/2026-11-10-hermes-conversation.md)に記録します。以前の Claude 会話と宛先判定の実機確認は iPhone 16 Pro で行っています（2026-10-11 の Debug ビルドでの会話、2026-11-09 の文脈つき宛先判定の受入試験 69 回は専用の XCTest host）。端末内モデルは 2026-11-09 に外したので、Apple Intelligence の対応・非対応で振る舞いは変わらず、非対応機の確認（T-DEV-1 / T-DEV-2）は対象外になりました。通信断のときは定型文を声で案内してから失敗を表示します。通常署名版での人による確認（オンラインの会話、機内モードの案内）は未実施です（[検証記録](docs/validation/2026-11-09-haiku-only.md)）。

開発環境:

- Xcode 27.1（build 27A9275、2026-10-23のハード接続ホスト検証環境）と同梱 iOS SDK。
- Ruby と `xcodeproj` 1.27.0（プロジェクト生成用）。
- ONNX Runtime 1.24.2。版数と revision は `Package.resolved` で固定します。

## Hermes の接続

返事・会話の続き・履歴の正本は、利用者の Windows にある Hermes の API server です。「…」→「設定」→「Hermes 接続」で次を保存します。

- 接続先: `https://host[:port]` の root だけです（path・query・fragment・userinfo・IPv6 リテラルは受け付けません。scheme と host は小文字にし、443 は省きます）。UserDefaults に保存します。
- API キー: 接続先の origin ごとに Keychain（service `com.kamby.CatRobot.hermes`、account = origin）へ保存します。画面には保存済みかどうかだけを出し、キーそのものは表示しません。接続先を変えると前の接続先のキーは送りません。キーを保存できなければ前の設定を残します。

接続先とキーはターンごとに読むので、保存した次のターンから使います。通信は OS 標準の証明書の確認で行い、redirect を追わず、cookie と cache を使いません。普段使いできる常設の HTTPS 接続先はまだ用意されていません。開発中の実機確認は Debug 専用の試験経路（Mac の LAN relay と承認済みの短期証明書）で行い、この経路は Release に入りません。

- 未設定のときは会話画面に「接続を設定」と「もう一度確認」を出します。ほかのモデルが代わりに答えることはありません。
- Hermes がキーを受け付けない（401）ときは、返事・前の返事の後始末・履歴のどの要求で受けても同じ接続の拒否として覚え、自動では送り直しません（拒否のあいだは「会話の履歴」も読みません）。キーを替えた後に前のキーへ届いた拒否は、新しいキーの状態を変えません。別のキーを保存すれば次のターンから使います。Hermes 側を直して同じキーを使い続けるときは、会話画面の「もう一度確認」を押すと、同じ接続先とキーで認証付きの確認（`GET /v1/capabilities`）を 1 回だけ送り、通れば同じ会話を続けます。設定で同じキーを保存し直すだけ、マイクのボタン、設定を閉じたときの再開では確かめ直しません。
- 返事が届かないまま期限を過ぎたとき（installed Hermes で終わらない run が同じ session の後続を止める場合を含む）は「新しい会話を始める」を出します。端末は終わらない run を自動で解決しません。
- Hermes から前の会話を読めない（session が無い）ときは会話を止め、「再試行」か「新しい会話を始める」を出します。
- 「新しい会話を始める」は新しい Hermes の session id へ切り替えるだけです。Hermes 側の履歴の削除・忘却や、前の run の停止の成功を意味しません。
- 「…」→「会話の履歴」で現在の会話を開くと、最新のやり取りが見えます。上にスクロールして前の発言も読めます。開くたびに Hermes から履歴を読み、端末には保存しません。履歴を開くと会話を一時停止し、閉じると聞き取りを再開します（自動待機中は猫をタップしてください）。

## 設定

「…」→「設定」で変更します。一覧から変更したい項目を選びます。開くと会話を停止し、閉じると自動で聞き取りを再開します（自動待機中は猫のタップが必要です）。初回の説明は「このアプリについて」で見直せます。

| 項目 | 内容 |
|---|---|
| 声と待機時間 | 声（Supertonic F1〜F5・M1〜M5、既定 F1）、眠そうになるまで・待機に入るまでの時間（分） |
| 返答モデル | 返事に使うモデル、推論の深さ（effort）、候補の再取得。選択は Hermes の接続先ごとに保存 |
| Hermes 接続 | 接続先（https の root）、API キーの保存と削除（Keychain、接続先ごと） |
| カメラと顔追尾 | カメラ許可、顔追尾のオン/オフと状態、左右補正（0〜20°、0.5°刻み、既定の8.5°に戻せます） |
| ロボット | 接続先、動きの強さ、待機微動、中立・反転・方向確認・保存 |
| このアプリについて | 送るもの・保存するもの、はじめの説明の見直し、ライセンス |

接続先や API キーが未設定なら、「返答モデル」にある「Hermes 接続を設定」から登録できます。

- 「返答モデル」を開くと、その Hermes の `GET /api/model/options?include_unconfigured=false`（Hermes の cache）から読みます。「モデルの候補を再取得」だけが `refresh=true` で provider を確かめ直させます。未認証の provider と使えないモデルは出しません。この一覧に対応しない Hermes では候補を出さず、読めなかったことを表示します。
- effort は Hermes の段階（minimal・low・medium・high・xhigh・max・ultra）とオフです。推論に対応しないモデルでは出さず、推論を止められないモデルではオフを出しません。モデルを変えると、そのモデルで使えない effort は既定に戻します。
- 選択は接続先の origin ごとに UserDefaults に保存し、別の接続先には送りません。通常の読み込みでモデルが見つからなければ、候補の準備が終わるまで選択を保持します。手動の再取得でも見つからなければ既定に戻して知らせます。通信エラーや 401 のときも選択を保持します。401 を受けたキーでは自動で読み直さず、手動で再取得するか、別のキーを保存すると確かめ直せます。
- 選んだモデルと effort は次の返事（`POST /v1/runs`）に `model`・`provider`・`model_options.reasoning` として送ります（既定のときは何も足しません）。Hermes 側でその会話のモデルを固定している場合（`/model`）は Hermes がその会話の返事で固定モデルを優先します。モデルを変えても新しい会話には切り替えません。

アプリ内では利用量・トークン数・利用料を計測・保存せず、日次上限による返答の抑止も行いません。記憶管理画面と合わせた撤去範囲は[Hermes 移行②の検証記録](docs/validation/2026-11-10-remove-memory-ui-and-usage.md)にまとめています。

## 日本語の読み変換の準備

jpreprocess 0.15.0と固定した日本語辞書で、既知のLatin語・`+`・数値表記を音声向けに補正します。`1,500,000円`は`百五十万円`、`３億５０００万`は`三億五千万`へ変換します。IDは各桁を別区間で合成し、聞き取りやすさを優先するため待ち時間と再生時間が長くなります。数詞の分解や読み表は自前で持たず、日本語の全文カナ化も行いません。表示・記憶用の原文は保持します。対象となる表記・保護範囲・制限は[native frontendの仕様](native/japanese-pronunciation/README.md)、実機での確認と選択は[issue #24の検証記録](docs/validation/2026-11-06-number-speech.md)を参照してください。

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

通常アプリは Supertonic 3 を使用します。「…」→「設定」→「声と待機時間」の「声」で F1〜F5・M1〜M5 を選び、初期値は F1 です。選択は再起動後も保持します。設定を開くと会話を一時停止し、閉じると自動で再開します（自動待機で寝ている場合は猫のタップが必要です）。再開後は選んだ声を使い、会話の記憶は変更しません。

再生音量が0のときは、左上に「音量が0です」と表示します。音量を上げると消え、警告だけで会話を停止することはありません。iPhoneの消音モードでも声を再生する設定なので、消音モード自体では警告しません。

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

## Hermes接続診断（開発専用）

Debugビルドを `HERMES_PROBE=1` で起動する専用のXCTest hostで、Windows上の隔離したHermes環境との文字・認証・取消・模擬端末ツールの往復を検証します。端末ツールは文字列を返す `echo` だけです。このhostは会話用のcomposition、マイク、カメラ、BLE、音声出力を生成しません。

ローカルネットワークの用途は、同じネットワーク上のMacにある検証用relayへのHTTPS接続です。用途説明は共有Info.plistに置くためReleaseにも宣言されます。診断実装はDebug限定で、開発用診断だけがこの接続を使います。専用APIキーはKeychainへ保存し、取込用ファイルは保存後に削除します。キーをリポジトリ、アプリのリソース、ログへ含めません。

Mac側relayとMCP serverの運用は`tools/hermes-probe-relay/README.md`、検証記録は`docs/validation/2026-11-10-hermes-connection-probe.md`を参照してください。

通常の会話の受入試験（Debug 専用。Hermes の隔離した profile と、Mac の LAN relay の文字だけの会話 mode を使う）は `scripts/hermes-conversation-live-test.md` と `scripts/run_hermes_conversation_live_test.py` にあります。普段の composition の返事・履歴・取消・再接続を、偽の radio とカメラで確かめます。

## 会話の記録（Hermes）

返事・会話の続き・履歴の正本は Hermes にあります。端末は会話の本文を保存せず、次の識別子だけを UserDefaults に残します（`HermesSessionRecord`）: 接続先の origin、Hermes の session id、受け付けられたターンの有無、受付が分からない送信の有無、終わりを確かめていない run id。

- 返事をつくるときに Hermes に送るのは、発話の文字（聞き取った文、または文字入力）、session id、その run で使う指示（猫としての話し方と端末操作の形式）、「返答モデル」で選んだモデルと effort（選んだときだけ）です。写真を要求したターンに限り、端末での操作結果と、取得できた写真1枚を同じ session に送ります。
- 声の宛先の判定は端末の中だけで行い、Hermes には何も送りません。猫への発話と決めなかった発話は、どこにも送らず捨てます。
- 以前の版の聞き返し（「今の、ぼくに言った？」）は 2026-11-26 に撤去しました。その版が Hermes の履歴に残した記録は展開せず、届いた文字のまま表示します。
- CaRot への改名より前の版で保存した呼びかけの言葉は使いません。呼びかけは「キャロット」から始まり、設定で保存し直した言葉を使います。
- 同じターンの再送は同じ Idempotency-Key と同じ body を使い、Hermes の重複排除に任せます。取り消した返事やあとから届いた返事は採用しません。
- 以前の版が端末に保存した会話の記憶（`Library/Application Support/CatRobot/ConversationMemory/` の `current.json`・`facts.json`）は、この版では読み書きも削除もしません。
- 「…」→「新しい会話を始める…」で切り替えを確定すると、新しい Hermes の session で聞き取りを再開します。キャンセルすると今の会話を続けられます。Hermes 側の履歴の削除・忘却や、前の run の停止の成功を意味しません。

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

生成するアプリターゲットには 4 つのスクリプト段階があります。「Validate jpreprocess assets」は辞書とネイティブライブラリを、「Validate Supertonic assets」は同梱する音声資産をコンパイル前に検証します。「Validate Smart Turn assets」は発話終了判定モデルを検証します。最後の「Remove codeless onnxruntime framework」は、静的リンク済みの `onnxruntime.framework` に Xcode が埋め込む中身のないスタブを取り除きます。スタブは App Store Connect の検証で ITMS-90208（Info.plist の最小 OS と不一致）になるためです。取り除くのは記号を公開しないスタブだけで、本物の dylib なら残します。検査や削除に失敗したらビルドを止めます。スクリプトの sandbox（`ENABLE_USER_SCRIPT_SANDBOXING`）は成果物の削除を許さず、削除対象を出力に宣言すると埋め込み段階と衝突するため、アプリターゲットだけ sandbox を切っています（プロジェクト既定とテストターゲットは有効のまま）。

## Simulatorでビルド・テスト

以前の Claude SDK を含む版をビルドした環境では、更新後に一度 Xcode の「Product → Clean Build Folder」を実行してからビルドしてください。以前のビルド先を再利用すると、古いフレームワークや Debug 用キーのコピーがアプリ内に残ることがあります。クリーンビルドしたアプリを実機への導入に使います。

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

単体テストは 実際の Hermes に接続せず、偽の HTTP（`FakeHermesServer`）と、必要な Apple サービスのテスト用実装を使います。実際の Hermes との往復は Debug 専用の受入試験（`scripts/run_hermes_conversation_live_test.py`）で別に行います。結果は[検証記録](docs/validation/2026-11-10-hermes-conversation.md)を参照してください。

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

最初の実機確認では、「…」→「設定」→「Hermes 接続」で接続先と API キーを保存してから（普段使いできる常設の接続先はまだありません）、次を順に試します。

1. 前面カメラを画面の左にした横向きで起動し、「会話を始める」からマイクとカメラを許可する。
2. 猫へ顔を向けたまま、呼びかけの言葉なしで「短く自己紹介して」と話し、表情、口の動き、読み上げ、聞き取り再開を確認する。VoiceOverでは猫のボタンの「その他のコンテンツ」から返答の全文を確認する。
3. 返答後30秒以内に顔をそらして続きを話し、会話継続中も返答できることを確認する。
4. 最後の返答から30秒以上空け、顔をそらして呼びかけの言葉を含まない発話を試し、無応答のまま聞き取りが続くことを確認する。
5. 最後の返答から30秒以上空け、顔をそらしたまま「キャロット」だけと話して「なあに？」と答えることを、続けて「ねえキャロット、天気は？」「天気教えて、キャロット」のように文の途中や最後に呼びかけを入れて返答することを確認する。「…」→「設定」→「声と待機時間」で入力欄の右端のマイクから呼びかけの言葉を入力し、確かめて保存した後、新しい言葉で同じように応答することも確認する。
6. バックグラウンドへ移動して戻ると自動で聞き取りが再開すること、猫をタップすると一時停止し、もう一度タップで再開することを確認する。
7. 「…」→「文字で話しかける」から送信し、入力欄に続けて書けることを確認する。入力欄の左の「×」で戻り、「…」→「会話の履歴」を開いて、いまの発言と猫の返事を確認する。

## 制約

- 会話は画面がアクティブな間だけです。バックグラウンド録音、ロック画面の StandBy 拡張、常駐ウェイクワード検出は実装していません。
- 宛先の判定は呼びかけの言葉の書き起こしと顔の向きに頼るので、聞き違いや、こちらを向いた別の人の声への応答があります。生成モデルの返答も事実とは限らず、返答の事実検証は行いません。
- アプリ独自のバックエンドと分析基盤はありません。返事・会話の履歴は利用者の Hermes、聞き取り・読み上げ・声の宛先の判定は端末内で行います。
- 普段使いできる常設の HTTPS 接続先は未整備です。この版を merge・install しても、接続先を用意するまで通常の返事は使えません。
- Release ビルドの実通信（OS 標準の証明書で接続する Hermes）は未検証です。
- Hermes で終わらない run は同じ session の後続を止め、端末は自動で解決しません（「新しい会話を始める」で抜けます）。音声認識アセットは OS が事前に取得する場合があります。
- Hermes の run が completed 以外で終わったときや出力が空のときは、「うまく答えられなかった」の定型文と失敗の表示になります。代替の返答はありません。
- 医療、法律、金融など、正確性が必須の用途を保証する製品ではありません。
- アプリアイコン（`Assets.xcassets/AppIcon.appiconset`）は白背景に黒猫の横顔シルエットの 1 枚絵で、2026-10-12 に画像生成で作って採用したものです。猫の顔と UI の計画で見直す可能性があります。

## 構成

- `CatRobot/App/`: アプリ全体の依存関係を組み立てる `ConversationComposition`、SwiftUI エントリポイント、画面遷移、設定。
- `CatRobot/Conversation/Domain/`: 発話区切り、宛先、会話継続のロジック。
- `CatRobot/Conversation/Services/Hermes/`: 返事・会話の続き・履歴の adapter（`HermesConversationService`）、接続設定（`HermesConnectionSettings`）、session の記録。
- `CatRobot/Hermes/`: Hermes の Runs API client、OS trust の HTTPS transport、Keychain、Debug 専用の接続診断と試験用 transport。
- `CatRobot/Conversation/Tools/`: Hermes が選んだ首・表情・静止画の操作を、その返答のターンで実行するツール。
- `CatRobot/Conversation/Services/`: Speech、AVFAudio、Supertonic の実装（Apple Foundation Models による端末内推論は 2026-11-09 に撤去）。
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

### Smart Turnによる発話終了判定

通常起動では Smart Turn v3.2 と Silero VAD を使用します。音声だけで終了確率が 0.5 を超えたときに認識を閉じ、確定した末尾を取り込んで返答します。返答中は録音しません。

モデルの無音待ちは 224 ms（7 × 32 ms）です。ASR の固定1.2秒無音終了を主経路とし、Smart Turn の終了判定で早めに閉じることもできます。端数の音声はVADの継続状態を変えずに評価し、発話再開を示す場合や判定から300 msを過ぎた場合は早期終了しません。モデル準備が成功してから録音を始め、初期化・音声変換・VAD・推論・queue の失敗は「発話の終了判定に失敗しました」と表示して停止します。準備中でもユーザーの停止操作はモデル処理の完了を待ちません。

資産は `python3 scripts/prepare_smart_turn_assets.py --download` で取得します。固定版・SHA-256・ライセンスは [manifest](CatRobot/Resources/smart-turn-manifest.json) に記録し、8 ファイルをビルド時に検証します。資産本体は `CatRobot/LocalAssets/SmartTurn` に置き、Git には追加しません。

実装履歴は[初回検証記録](docs/validation/2026-11-05-smart-turn-clean.md)、相互レビューと修正は[レビュー記録](docs/validation/2026-11-06-smart-turn-cross-review.md)を参照してください。合成音声のテストや旧構成の測定値から、人の発話精度・雑音耐性・実音響遅延は保証しません。
