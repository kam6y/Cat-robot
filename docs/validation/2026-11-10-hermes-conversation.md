# 返事を Hermes へ（2026-11-10）

## 範囲

- 通常の会話の返事・会話の続き・履歴の正本を、利用者の Windows にある Hermes（API server）へ移した。
- iPhone は次の処理を持ち続ける: 声（聞き取り・読み上げ）、カメラ、顔追尾、BLE、すぐに止める安全の処理。
- 利用経路:
  - 設定の「Hermes 接続」。接続先は https の root、API キーは接続先ごとに Keychain に置く。
  - 未設定・401 のときの案内（「接続を設定」「もう一度確認」）と、401 の後の明示的な再確認。
  - 返事の期限切れや、前の会話を読めないときの「新しい会話を始める」。
  - 会話の履歴の表示。表示のたびに Hermes から読む。
  - アプリを再起動した後も、同じ接続先・キー・session を使う。
- ほかのモデルへの fallback はない。補助の経路として、声の宛先判定は Claude Haiku 5.5 のまま。
- つないでいないもの（コードには残る）:
  - `ClaudeConversationService`、`ConversationModelSettings`、`LongTermMemoryManager`
  - 記憶の store（`current.json` / `facts.json`）
  - robot の tool provider（`move_head`・`express`・`look`・`remember`）
- 以前の版が保存した記憶のファイルは、読まず、消しもしない。

## 自動試験

- 最終候補 C4 は、HEAD `4abe4c7` からの未 commit 差分。入力 digest は `609ad7ca2a3d885c0c84401f0e57ef6030ee1f06677625b454bc14abf7efe82e`（966 files）。
- **全体試験**（iOS 27 Simulator、`xcodebuild test`）: 1,218 件中 1,212 通過・0 失敗・6 skip。
  - skip の 6 件は、次の 6 クラスに 1 件ずつある。
    - クラス: `ClarificationHistoryModelTests`、`HaikuAddressingModelTests`、`HermesConversationLiveTests`、`HermesProbeDeviceTests`、`RobotMotionIntegrationDeviceTests`、`SupertonicIntegrationDeviceTests`。
    - どれも、実機・専用の runner・明示の opt-in のいずれかが要る試験で、通常の実行では最初に止まる。
- **Release build**（iOS Simulator）: 成功。
- 全体試験と Release build のどちらも、実行の前後で入力（git の追跡・未追跡の全 file の hash）が変わらないことを確かめた。
- 変更は段階ごとに、意味のある失敗（RED）を先に確かめてから、最小の修正で通した（GREEN）。段階:
  - 401 の明示の再確認
  - 新しい会話の出口と画面の文言
  - Info.plist と生成 project
  - 設定の会話の履歴
- 独立レビュー（Claude の `/simplify` 4 観点、Codex 側の reviewer 1 名）で採用した指摘も、同じ手順で直した。
  - どの経路の 401 も、接続ごとの拒否として覚える。並行する worker を含め、その接続では送らない。
  - 受付の分からない送信の後でも、Hermes に会話があると読めたら、受付済みにする。
  - 「新しい会話を始める」を出すのは、返事の期限切れのときだけ。
  - poll の待ち中に取り消したら、次の照会を出さない。
- 同じ reviewer が、修正の差分だけを 2 回確かめた。
  - その修正に関係する Critical と Important は残っていない。
  - これは候補全体の再レビューではない。
  - 初回の指摘の一部は、理由を記録したうえで Minor へ評価を下げ、延期した。
- 試験で直接は確かめていないもの:
  - 履歴を読む直前の拒否の確認。入口の確認との間には端末の記録の読み込みしかなく、順序を固定した試験を作れない。確認自体は、ほかの経路と同じ helper を通る。
  - About と Onboarding の文言。描画の確認だけ。
- この文書は最終候補を固めた後に更新した。変わったのは文書だけなので、試験は再実行していない。

## 実機・live

- 実機の受入は、署名した Debug の build・install・XCTest と、定義済みの 4 つの live の場面を 1 回行う計画だった。
- 実機の受入を 5 回試み、5 回目で合格した。install・XCTest・live の場面まで進んだのは 5 回目だけで、live の受入は全体で 1 回。
- 5 回目（2026-11-11）:
  - ユーザーが、iPhone の USB の接続・画面の点灯・ロックの解除を保つ準備ができたと伝え、再開を指示した後に行った。試験した入力は、アプリ・ソース・project・試験が C4 と同じで、違うのはこの文書の前の版だけ。
  - 実行直前の確認は全部通った: iPhone は Mac に有線で接続され、paired・DDI・developer mode 有効、ロックは解除。LAN の address と接続先も一致し、証明書の pin・対象 address・hostname・期限も合った。
  - 証明書と接続先は、4 回目に作ったものをそのまま使った。新しい証明書は作っていない。
  - 親 Hermes が試験用 profile を改めて起動し、認証の確認が通った（キーなしと誤ったキーは 401、正しいキーは 200）。
  - runner を 1 回だけ実行した。runner には前の build を使い回す方法がないので、新しく build した。4 回目の署名済みの build は残してある。
  - build・アプリと試験の署名の確認・install・XCTest・結果の取り出しが、どれも終了コード 0 で終わった。XCTest は 4 つの場面を順に行う 1 つの試験で、実行 1 件・失敗 0。
  - runner の基準で、4 つの場面が合格した:
    1. 文字の 2 ターン: 2 ターン目の返事が 1 ターン目の文脈に合い、Hermes の履歴は利用者 2・返事 2。
    2. consumer と store を作り直した後も、同じ session と Hermes の履歴を戻せた。
    3. 取消の後に遅れて届いた結果を採らなかった。Hermes 側の run の終わりも確かめた。終わり方は completed。
    4. 受け付けられた応答を 1 回落とした後、同じ key と body の再送が 1 つの run にまとまった。Hermes の履歴は利用者 4・返事 4。
  - 実行の前後で入力は変わらなかった。
  - iPhone に置いたのは、試験用の接続先・pin・relay 用のキーだけで、終わった後に消した。relay の先の Hermes のキーは iPhone に渡していない。試験専用の Keychain と defaults、Mac 側の試験用の file も消した。証拠に資格情報の値は入っていない。
  - この会話は Hermes の試験用 profile にだけ記録され、default の profile には無かった（この session の 1 件、利用者 4・返事 4）。これは memory や skill の隔離を示すものではない。
  - 終わった後、relay と試験用 profile を止めた。default の Hermes は同じ process のまま変えていない。
- 合格した範囲の限り:
  - 経路は Debug 専用の試験経路: Mac の LAN relay の文字だけの会話 mode、承認済みの短期証明書、隔離 profile `catrobot-conversation-test`。この経路で、アプリの通常の composition を実際の Hermes へつないだ。
  - 再起動の確認は、同じ process の中での作り直し（保存した session id と Hermes の履歴）。アプリの process の再起動と disk への書き出しは含まない。
  - 取消の場面の Hermes 側の終わり方は completed で、Hermes 側で run を途中で止められたことを示すものではない。
  - 切断は DEBUG transport で応答を落としたもので、実際の Wi-Fi の切断ではない。
  - 試験では radio と camera を偽物に置き換え、音声・camera・BLE・motor は動かしていない。
  - 上の Simulator の結果と足し合わせて、アプリ全体の成功とはみなさない（下の「制約と未実施」）。
- 1〜4 回目は合格していない。経過として残す。
  1. 2026-11-10: 最終候補 C4 で。実行直前の確認で止まった。
  2. 2026-11-11: ユーザーの指示（実機の受入試験の後に PR を作る）を受けて、親 Hermes が受入を再開したとき。候補のアプリ・ソース・project・試験は C4 と同じで、違うのはこの文書だけ（3 回目と 4 回目も同じ）。実行直前の確認で止まった。
  3. 2026-11-11: ユーザーが、iPhone を USB で接続してロックを解除したと伝え、試験に要るコマンドをコマンドごとの承認で実行することを許可した後。build の前の LAN と証明書の確認で止まった。
  4. 2026-11-11: ユーザーが、短期の試験用の証明書と接続先だけを更新して続けることを承認した後。署名した build までは進み、install の前で止まった。
- 1 回目と 2 回目の結果（同じ）:
  - 通った: 既存の短期証明書の pin・期限・hostname。
  - 通らなかった: 作業環境から LAN の address を照会できなかった（`ipconfig` の error 44c）。
  - 通らなかった: CoreDeviceService の初期化が timeout になった。このため、端末の pairing・DDI・developer mode・ロックを改めて確かめられなかった。
  - この 2 つの失敗だけでは、iPhone が offline だったとは言えない。
  - どちらの回も、自動の再試行・権限の追加・別の経路での実行はしていない。
- 2 回目の後の切り分け: ユーザーが許可した 2 つの読み取り（LAN の address と端末の情報）だけを、作業環境の通常の制限（sandbox）を外して 1 回ずつ実行した。
  - 2 つとも答えが返った。前の失敗は、作業環境の制限によるものと考えると矛盾しない。ただし同じ時に比べたわけではないので、それだけが原因とは言えない。答えが返ったことは、準備ができたことを意味しない。
  - Mac の今の LAN の address は、承認済みの relay の endpoint の address と違っていた。
  - 端末の情報は、Mac から iPhone に接続できない（unavailable）状態で返った部分的な値だった。DDI は使えなかった。paired・developer mode 有効という値もあったが、以前の値の可能性があり、その時点の状態を確かめたものではない。ロックは確かめていない。
- 3 回目の結果: build の前の LAN と証明書の確認だけで止まった。端末・DDI・ロックは確かめていない。
  - LAN の address は、コマンドごとの承認で読んだ。承認済みの relay の endpoint の address は、Mac のどの interface にもなかった。
  - 既存の証明書は、pin・期限・承認済みの host には合う。しかし証明書が対象にする address は承認済みの relay の address と loopback だけで、Mac の今の address を含まない。
  - そのため、今の address で relay を動かすには、その address を含む証明書と承認済みの endpoint が要る。どちらも承認されておらず、作っても変えてもいない。
  - USB の接続とロックの解除は、ユーザーの報告で、測った値ではない。
- 1〜3 回目は、relay と Hermes の試験用 profile の起動、資格情報の読み込み、bootstrap と DerivedData の作成はしていない。
- 4 回目の結果:
  - 承認の範囲で、短期の試験用の証明書を新しく作った（P-256、対象は Mac の今の LAN の address と loopback だけ、期限 48 時間）。更新したのは試験用の接続先と pin だけで、古い証明書は残した。
  - 実行直前の確認は全部通った: iPhone は Mac に有線で接続され、paired・DDI・developer mode 有効、ロックは解除。LAN の address と接続先も一致した。
  - 親 Hermes が試験用 profile を起動した。実際の LAN の経路で、relay の認証の確認が通った（キーなしと誤ったキーは 401、正しいキーは 200。証明書の pin・hostname・期限も確認）。この確認では推論を呼んでいない。
  - runner を 1 回だけ実行した。署名した Debug の実機向けの build と、アプリと試験の署名の確認が通った。
  - build の直後のロックの確認で、iPhone はパスコードが要る状態だった。runner の決まりどおり、install の前で止まった。会話の試験が失敗したのではなく、その前提の確認で止まった。原因（自動のロックなど）は確かめていない。
  - ここまでの成功は部品ごとのもので、受入全体・iOS からの実際の通信・記憶や skill が動くことを示すものではない。
  - 資格情報は relay と認証の確認のメモリの中だけで読んだ。bootstrap は作らず、iPhone に鍵を渡していない。relay は止めた。
  - 親 Hermes がユーザーにロックの解除を確かめたが、時間内に答えがなかった。答えがないことは、解除や再試行の承認ではない。親 Hermes は再試行せずに実機の作業を止め、試験用 profile を止めた。default の Hermes は変えていない。

## 制約と未実施

- **常設の HTTPS 接続先が未整備**（OS 標準の証明書の確認を通る Hermes）。
  - この branch を merge・install しても、接続先を用意するまで通常の返事は使えない（設定の案内が出るだけ）。
  - そのため PR は Draft のまま merge しない。
  - 常設の接続先を今回の範囲から分けたのは、この作業を指揮した親 Hermes の範囲の判断で、利用者が延期を指定したものではない。
- **PR は、実機の受入に合格した後に作る**（ユーザーの指示を受けた親 Hermes の決定）。5 回目で合格したので、親 Hermes が Draft の PR を作る。merge はしない。
- **Release ビルドの実通信は未検証**（OS trust の Hermes、App Attest の Haiku）。
- **実機の受入で確かめていないもの**（上の「合格した範囲の限り」）:
  - アプリの process の再起動と、disk への書き出し。
  - Hermes 側で run を途中で止めること。
  - 実際の Wi-Fi の切断。
  - Hermes の summary・長期記憶・skill。
  - 常設の HTTPS の接続先を通る通信（確かめたのは Debug 専用の試験経路だけ）。
- **401 の後に同じキーを確かめ直すのは、会話画面の「もう一度確認」だけ**（認証付きの `GET /v1/capabilities` を 1 回）。
  - 次の操作では確かめ直さない: 設定で同じキーを保存し直す、マイクのボタン、設定を閉じたときの再開。
- **installed Hermes で終わらない（unknown の）run は、同じ session の後続を止める。**
  - 端末は自動で解決せず、「新しい会話を始める」で抜ける。
  - 新しい会話は、Hermes 側の削除・忘却や、前の run の停止の成功を意味しない。
- Hermes の返事からは、体の操作の tool を使えない。
- 人による実機確認（通常署名版の会話・設定・履歴）は未実施。
