# 待機中の仕草とあくび（2026-10-30）

実装・検証完了。feature/idle-cat-life、基点 6aa4050ab7b699a68ab2a7dc8e28f76ccbaaf48c。
利用者は細部を Codex と Claude に任せて実装・検証まで進めることと、実機の使用を承認した。

## 見た目と動作
- 通常の聞き取り待機でも瞬く。従来は ConversationView が phase == idle のときだけ瞬きを許可し、listening では止まっていた。
- 不規則な瞬き、二度瞬き、ゆっくり瞬き、控えめな視線移動と片側のひげ。常時描き直すタイマーは使わず、仕草のキーフレーム間は休む。
- 視線移動の約4割で、0.3〜0.8秒遅れて同方向の首の微動を既存 MotionCoordinator に依頼する。yaw ±3°、pitch ±2°、speed 10。条件が合わない依頼は保存しない。
- 表示中の neutral から sleepy への変化で約4.5秒のあくびを一度だけ。活動世代は受け付けた活動と明示の起床だけで進む。画面復帰、設定復帰、最初から sleepy の表示では再演しない。
- 発話・考え中・視覚確認・保持中の表情・文字入力・エラー／ブロック中・非表示・非active・Reduce Motion・sleeping では装飾を止める。

## 分担と参考画像
Codex が built-in image_gen で生成し、Claude（agmsg coding / claude_sleep_zzz_1028）が創作案、ベクター化、参照との比較を担当。
利用者の修正「もっと大きい口、目を閉じる」「目の外側の短い突起線は不要」を採用。
最終参考: ../design/idle-cat-life-2026-10-30/yawn-reference.png。
プロンプト／生成手段: ../design/idle-cat-life-2026-10-30/yawn-reference.prompt.txt。
既存37枚の比較基準は変更前の scripts/render_face.sh preview で取得した。

## 現時点の検証
証跡の作業領域は /private/tmp/cat-idle-life-20261030。
- policy-red: 待機許可の未実装を確認。
- life-red: planner/runner の未実装を確認。
- life-green-motion-red: life 6件と表示状態18件が通過。首・活動世代の未実装3件が7 assertionsで期待通り失敗。
- motion-green-timing-red: 首42件と無活動7件が通過。レビュー指摘の瞬き左右差と首の遅延の加算を2件5 assertionsで再現。
- behavior-green: 77件通過。瞬きの開始だけ30msずらして両目のclose/open時間を揃え、首の開始までの合計時間を0.3〜0.8秒へ修正。画面離脱とキャンセルを無視する時計からの遅延復帰も確認。
- tracking-takeover-red: 追尾が古いidle所有権を引き継いで送信待ちのとき、仕草の取り消しが追尾まで取り消す不具合を2 assertionsで再現。
- tracking-and-app-green: 修正後115件通過。MotionCoordinator 43、FaceTrackingMotion 30、FaceTrackingAppIntegration 9、ConversationAutoResume 13、VoiceSettingsIntegration 4、AppComposition 16。
- live-face-red-2: 未実装のあくび描画を実ConversationViewの画素で検出。統合後の ios-round1-ui は Geometry16・表示3・Life10 の計29件が通過。
- ios-scene-ui: UIWindowScene 上の実画面で表示・発話中断・設定復帰の3件が通過。最初の scene なしウィンドウの録画にはホスト画面しか映っていなかったため、既存の scene 付き試験方式に修正。新しい録画で一連の動きを確認した。
- iphone-first-pass: 接続済み iPhone 16 Pro / iOS27.2 上の29件が通過。実機が生成したあくびとsleepyの添付画像も確認。
- simulator-final-full（レビュー修正前）: 889件中886成功、端末専用2件skip、1件失敗。旧タイマーで微動開始を待つ統合テストを、実アプリの idleFaceMotion アクションから始める方式へ更新した。追尾・書き込み待ちの検証は維持し、lifecycle-face-cue-green は17件通過。
- yawn-tween-red: あくびの途中でひげが露出した虹彩を横切る問題を、実機のパス演算で52 assertionsとして再現。
- yawn-staged-interruption-red: 閉眼→あくび→閉眼のまま下降→開眼へ段階分けし、4.5秒と首の開始1.8秒を維持。12件中11件通過、任意表情への途中キャンセル1件は288 assertionsで失敗を再現。
- yawn-dense-green: 描画と幾何検査に共通する実効目パラメータで、ひげが目に到達する前（yawn 0.15）に閉眼を完了させる制約を追加。通常のyawn0は元の値をそのまま返す。全9表情への遷移と実キーフレームを各100分割して12件通過。高コントラストの太いひげも同じ検査に追加。
- Xcode project生成の契約テストが通過。

## レビュー
requesting-code-review の独立レビュー idle_life_behavior_review を実施し、receiving-code-review の手順でコードと再現試験に照合した。
左右の瞬き速度が不揃い、首の遅延の上限超過、画面離脱／非協調clockの検証不足を修正／追加した。
完成差分の独立レビュー idle_life_final_review では、途中フレームの目とひげの交差をImportantと判定した。実機で再現してから、通常シーケンスと任意表情への割り込みの双方を修正した。首の優先順位・追尾引き継ぎ・プロジェクト構成もレビュー対象に含めた。

参照照合では mouth全体の上移動が舌・牙までずらす点を指摘して上唇だけの修正へ戻した。さらにCodexが重ね合わせで、比較コードが白に近いひげの画素を除外していたことを発見した。Claudeが trace / compare のひげmaskをcream|whiteへ修正し再計測したところ、参考のひげはほぼ左右対称と確認できた。最終round4はこの測定に基づく対称形で、ひげの外接差≤1.1px、中心線差最大1.6px（1280×720）。以前の「短い／左右の長さが違う」という数値は誤ったmaskによるもので採用しない。既存の全9表情・全mouth poseのdrawingPointsは変更前と小数9桁で一致（389745バイトのdump一致）。curiousだけの410画素・最大1/255のハーネス差は、単独の製品CatFaceViewでは再現せず基準と一致。これを形状差や37枚すべてのbyte一致とは表現しない。

独立した完成差分レビューの最終判定は、Critical / Important / Minorいずれも未解決0件。レビューが対象外とした実画像忠実度はCodexが比較と実機画像で確認し、実際のサーボの滑らかさは実測していないため未確認として扱う。モデル・音声は今回変更していない。

## 最終検証

| 対象 | 結果 |
| --- | --- |
| 全シミュレータテスト | 891件: 889成功、端末専用2件skip、失敗0 |
| iPhone16Pro / iOS27.2 | Geometry16・表示3・Life12、計31件成功 |
| 最終録画の実画面表示試験 | 3件成功 |
| 既存macOS描画ハーネス | check成功、lineScale1と1.35 |
| Xcode project生成契約 | 成功 |
| 既存FaceSizeTuner | iOS Simulator向けbuild成功 |
| 完成差分レビュー | Critical / Important / Minorの未解決0件 |
| 検証中のソース253ファイル | 前後のSHA-256一致 |

最終実行名は verified-final-full / verified-final-iphone / verified-final-ui。結果の要約、ソース識別子、独立レビューは [検証資料](2026-10-30-idle-cat-life/results.json) と同じフォルダに保存。
実機テスト後に、修正版CatRobotをXCTest引数なしで通常起動し直した。

## 確認資料と範囲

- [あくびの動画](../design/idle-cat-life-2026-10-30/ios/yawn-preview.mp4): 実ConversationViewのシミュレータ画面。約6秒、音なし。
- [iPhoneのあくび](../design/idle-cat-life-2026-10-30/ios/iphone-yawn.png) / [sleepyへの復帰](../design/idle-cat-life-2026-10-30/ios/iphone-sleepy.png)。
- [参考との重ね合わせ](../design/idle-cat-life-2026-10-30/renders/round-4/overlay-yawning.png) / [測定値と残差](../design/idle-cat-life-2026-10-30/visual-comparison.md)。輪郭の位置は確認済みだが、生成画像の塗りの質感や唇の薄さまでの画素単位の同一性は主張しない。

実機で確認したのはiPhone上の描画と制御ロジック。首の物理的な滑らかさは未実測。サーボ操作の有人試験は実行していない。
初回完成時点ではfeature/idle-cat-lifeに保存し、mainへのマージやpushは行わなかった。後述の追加依頼でmainへのスカッシュマージとpushが承認された。


## あくび時の首の動きの追加調整（2026-10-30）

利用者の「5どくらいにして」に合わせ、あくびの pitch 目標を -1.5°から -5°へ変更した。あくびの依頼種別を顔からアプリ・首制御まで伝え、あくびだけ pitch 上限を5°にする。通常微動は yaw ±3° / pitch ±2°のまま。既存の3秒・speed10・追尾優先・キャンセル条件を利用する。首と視線の連動を外す案は利用者が取り下げたため変更していない。

実際のあくびプランからアプリのアクションを通して送信コマンドを調べる回帰テストで、修正前は -2°で制限される失敗を確認。修正後の `yawn-five-degrees-green` は106件成功（Life12、実画面3、Motion43、追尾30、アプリ連携18）。通常微動の上限検査と、あくびも設定画面・追尾・無効設定等で拒否される検査を含む。独立レビューで未解決の指摘なし。証跡は `/private/tmp/cat-idle-life-20261030/yawn-five-degrees-{red,green}.xcresult`。

この追加調整とsleepy瞬き修正を含む最新版をiPhone16Proへインストールし、テスト引数なしの通常起動まで成功した。署名付きbuild成功、製品Swift112ファイルのビルド前後ハッシュ一致。反映記録は `/private/tmp/cat-yawn-neck-20261030/{device-build-result,iphone-install,iphone-launch}.json`。サーボの実動作確認は未実施。


### あくび10°への変更と実機反映（2026-10-30）

利用者の追加指定に従い、あくびのpitch目標と専用上限を -10° / ±10°へ変更。通常微動のpitch上限2°は維持。実アプリ経路の回帰テストは修正前に -5°で止まる失敗を確認し、修正後 `yawn-ten-degrees-green` の関連73件が成功した。署名付きビルド成功、製品Swift112ファイルのビルド前後ハッシュ一致。iPhone16Proへのインストールと通常起動も成功。反映記録は `/private/tmp/cat-yawn-neck-10deg-20261030/{device-build-result,iphone-install,iphone-launch}.json`。サーボの実動作の観察は行っていない。


### あくび中の追尾一時停止と復帰（2026-10-30）

追尾中に首が動かなかった原因は、あくびが通常微動と同じ追尾優先ゲートに入っていたこと。利用者の承認に従い、首のあくび3秒間だけ追尾の送信を止める。カメラの観測は継続し、実際のyawを保ってpitch目標-10°へ動いたあと、最新かつ有効期限内の追尾先へ戻る。顔を見失っていれば古い座標へ戻らず、正面復帰が中断されていれば再発行する。通常微動は引き続き追尾より低優先。

新規の実アプリ→RobotLinkテストで動作中の追尾からの引き継ぎを検証。中断、顔の見失い、期限切れ、通信待ち、正面復帰も検査した。独立レビューの2指摘（最初のあくび送信前の所有権消失、正面復帰済みフラグの残留）は、回帰テストで3 assertionsの失敗として再現して修正。`yawn-tracking-final-full` は899件中897成功・端末専用2件skip・失敗0。署名付きbuildと製品Swift112ファイルの同一性を確認し、iPhone16Proへのインストールとテスト引数なしの通常起動が成功した。

反映証跡: `/private/tmp/cat-yawn-tracking-20261030/{device-build-result,deployment-source,iphone-install,iphone-launch}.json`。テスト結果: `/private/tmp/cat-idle-life-20261030/yawn-tracking-final-full.xcresult`。サーボの実動作の目視は行っていない。


## 簡素化・相互レビューとmain統合の検証（2026-10-30）

利用者の追加依頼に従い、Claudeが `/simplify` を実行し、Codexは `requesting-code-review` で独立サブエージェントによる全差分レビューを行った。双方が `receiving-code-review` で指摘と採否を実コードに照合し、簡素化後の再レビューも含めてCritical / Important / Minorの未解決は0件。不要な周期まばたき状態の削除、首制御の上限・キャンセル処理の共通化、描画・検証helperの重複削減を採用し、動作や幾何に影響する構造変更は見送った。詳細は[簡素化と相互評価](2026-10-30-idle-cat-life/simplify-review.md)。

レビュー対象のfeature最終コミットは `1c11416`。mainへのスカッシュ適用後の内容がこのコミットと同一であることを確認し、最終検証を実行した。

- 全シミュレータテスト: 899件中897成功、端末専用2件skip、失敗0。
- 簡素化前後の描画: 通常37枚・あくび16枚、合計53枚すべてPNGファイル単位で一致。
- 描画ハーネスの幾何検査（線倍率1と1.35）、Xcode project生成契約、FaceSizeTuner build、iPhone向け署名付きbuild: 成功。
- 検証対象253ファイル: 開始前後のSHA-256一致。

[結果と証跡](2026-10-30-idle-cat-life/merge-results.json)。今回の簡素化後は実機への再インストール・サーボ操作は行っていない。
