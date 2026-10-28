# 顔の向きによる追尾条件の検証

## 対象

既存の低頻度AVCapture/Vision処理に顔のyaw/pitchを通し、保存済みの左右補正を中心に左右30度以内、上下25度以内の有限な角度を持つ顔だけを追尾候補にする。端末内の顔の向きによる近似であり、視線の推定精度は主張しない。現在の条件の全体は[設計](../superpowers/specs/2026-10-28-face-facing-gate-design.md)を参照。以下は日付順の記録で、各節の判定幅・テスト数・PIDはその時点の版のもの。

## 確認済み（最初の版: 補正中心なしの左右±30度・上下±25度）

- 変更前のFaceTrackingGeometryTests / FaceTrackingCoordinatorTests / FaceTrackingMotionTests: 67 tests, 0 failures, xcodebuild exit 0。
- 最初の回帰テストを追加して現状の不具合を再現: 角度情報のない顔が選択され、追尾姿勢も生成された。1 test, 2 expected assertion failures, xcodebuild exit 65。ビルド失敗による赤ではない。

証跡: `/private/tmp/cat-facing-tracking-20261028/baseline.log`, `baseline.xcresult`, `red-missing.log`, `red-missing.xcresult`。

- メタデータを渡し、まだ角度条件を入れない段階でGeometry / Coordinatorを実行: 44 tests, 35 expected assertion failures, exit 65。角度範囲外・角度不明の選択、中央の横顔による候補遮断、復帰期限の更新、姿勢待ち画像の上書きを再現した。
- 角度条件を入れた後の追尾・Motion・Preferences・AppIntegration・CapturePolicy・ConversationCamera・CameraFrameCache・Look関連の12クラス: 143 tests, 0 failures, xcodebuild exit 0。
- `ruby scripts/generate_project.rb` / `ruby scripts/test_generate_project.rb`: deterministic CatRobot project contract PASS。生成projectに差分なし。
- `git diff --check`: PASS。

追加証跡: `/private/tmp/cat-facing-tracking-20261028/red-angles.log`, `red-angles.xcresult`, `green-related.log`, `green-related.xcresult`, `project-generation.log`。実際に失敗を確認したテストを同じ入力で成功させた。既存Xcode/Simulatorの警告は残っているが、実行失敗はない。

## レビュー・ビルド・実機反映（最初の版）

- agmsgのClaudeによる本体の相互レビュー、CodexによるClaudeのテストのレビュー、別コンテキストの独立レビューを実施。Critical / Importantの指摘なし。復帰時刻・姿勢待ちの説明とDebug角度の確認項目を明確化した。
- 指定iPhone向けビルドは接続先を発見できずexit 70。`devicectl list devices`でもiPhone 16 Pro「Not so bad」はunavailable。ソースのコンパイル失敗ではない。
- generic iOS向けDebug署名付きビルド: BUILD SUCCEEDED, exit 0。アプリは `/private/tmp/CatRobotIdleSleepDerived/Build/Products/Debug-iphoneos/CatRobot.app`。
- 初回確認では端末がunavailableで反映を保留。その後、利用者がiPhoneを再接続したため、検証済みSwiftソースの6ファイルのハッシュが不変であることを確認してインストール・起動した。いずれもexit 0。
- 新しいインストール先 `8BBBD806-EB6D-436E-9DEA-B024AC0F49BE/CatRobot.app` からPID 2234で実行中であることを `devicectl device info processes` で確認した。実際の顔角度・サーボ挙動の観察は下記の確認項目として残る。

レビュー記録: `/private/tmp/cat-facing-tracking-20261028/claude-review.md`, `fresh-review.md`。端末状態の証跡: `device-build.log`, `devices.json`, `devices-final.json`, `device-generic-build.log`, `devices-reconnected.json`, `device-install.json`, `device-launch.json`, `device-processes.json`。

## 実際の人の顔で確認する項目

- 通常の会話距離で猫の画面を向いたとき、yaw/pitchが取得され、追尾を開始・維持できるか。Debugログは従来の初回・25フレーム間隔で先頭3件までの角度を度数で出す。新しいループや画像記録は追加していない。ログのpitchは正が顔を下へ向ける方向。
- 横を向く、上下を大きく向くと追尾が止まり、約10秒後に一度だけ正面へ戻るか。
- 正面に戻る前にこちらを向き直したとき追尾が再開するか。
- 画面端の人、カメラ位置と画面中心のずれ、眼鏡・照明の違いで判定が過剰に厳しくならないか。
- 閾値近くの小さな動きで追尾と保持が頻繁に切り替わらないか。必要性が観察されてから閾値や継続判定を調整する。

自動試験は合成された角度と状態遷移を検証する。実際のVision推定値、物理的なサーボの挙動、消費電力・発熱は別の実機観察であり、ビルド成功・インストール成功だけでは確認済みとしない。

補足: 10秒は、追尾目標を生成できた最後の適格な顔の撮影時刻から数える。こちら向きの新鮮な画像が姿勢補間を待つ間は、基準時刻を更新せずに復帰判断を一時保留するため、正面へ戻るのがちょうど10秒後とは限らない。保留の解除を含む詳しい規則は[設計](../superpowers/specs/2026-10-28-face-facing-gate-design.md)の「方式」にある。

## 実機試用後の判定範囲の調整（過去の版: 左右±20度・上下±15度）

この幅は、後の「補正した中心を維持して判定幅を戻す」で左右±30度・上下±25度へ戻した。以下は当時の記録。

利用者の「もうちょっと判定狭くてもいいかも」に従い、左右30°→20°、上下25°→15°に変更した。上記143テストと初回インストールの記録は調整前のものとして保存する。既存の境界テストを先に更新し、旧実装で20 tests / 8 expected assertion failuresを確認した。調整後のGeometry / Coordinator / Motionは74 tests, 0 failures, exit 0。project生成の決定性チェック、差分チェック、署名付き実機ビルドも成功した。Claudeの差分レビューで問題なし。iPhoneへ再インストール・起動し、新しいインストール先 `9C00D984-1979-445A-98B2-81BEEDC75FA3/CatRobot.app` からPID 2260で実行中と確認した。

調整後の証跡は `/private/tmp/cat-facing-tracking-20261028/tighter/` 内の `red.log`, `green.log`, `project-generation.log`, `device-build.log`, `device-install.json`, `device-launch.json`, `device-processes.json`。閾値変更後の実際の追尾の体感は利用者の再試用で確認する。

## 左右判定の中心を補正値へ連動（中心の連動は現行、判定幅±20度は過去の版）

利用者の追加指定により、左右補正 c 度を使ってVision yawの受入範囲を当時の幅で `[-c - 20, -c + 20]` 度へ変更した。8.5度なら `[-28.5, 11.5]` 度だった。設定値の変更は、既存の撮影停止・世代切替を通して次の会話画像から反映する形にした。

符号は、[Apple WWDC21のVisionデモ](https://developer.apple.com/videos/play/wwdc2021/10040/?time=205)の画像を正立・非反転で実際にVision revision3へ入力して確認した。画像右向きの顔は+65.65度、画像左向きは-22.63度。デモ画面のプレビューは反転の可能性があるため、その表示値自体はアプリの符号の根拠にしていない。カメラが利用者から見て画面左にあることと合わせ、画面側へ向く顔は負のyawとして中心を移す。macOSでの符号確認であり、iPhone上の実際の顔の角度や距離ごとの補正精度を測定したものではない。

証跡: `/private/tmp/cat-facing-tracking-20261028/centered/yaw-demo.png`, `check-yaw.swift`, `check-yaw-native.log`。初回のサンドボックス内実行はVisionモデル起動制約で失敗し、通常環境で再実行して確認した。中心変更前のGeometry / Coordinatorは50 tests, 13 expected assertion failures, exit 65。変更後の追尾・カメラ共有・Look関連12クラスは149 tests, 0 failures, exit 0。project生成の決定性チェックと差分チェックも成功。Claudeの差分レビューで阻害要因なし。証跡は同じ `centered/` の `red.log`, `green.log`, `project-generation.log`。署名付きビルドはBUILD SUCCEEDED, exit 0。検証済みSwift 7ファイルのハッシュ不変を確認し、iPhoneへのインストール・起動はいずれもexit 0。新しいインストール先 `95F7F3D8-014B-4D01-9F81-B942CF1CECAA/CatRobot.app` からPID 2327で実行中と確認した。証跡: `centered/device-build.log`, `device-install.json`, `device-launch.json`, `device-processes.json`, `tested-source-hashes.json`。

実機での追加確認: カメラレンズを見る場合と猫の顔の中心を見る場合のyawを比較する。会話距離や画像内の位置を変え、猫の顔を見たときに判定中心の -c 度付近になるか確認する。顔への視線方向を基準とした角度か、カメラ光軸を基準とした角度かによる差は、この符号確認だけでは確定していない。

## 補正した中心を維持して判定幅を戻す（現在の版）

利用者の明示確認により、保存済み補正値と判定中心の連動は維持し、幅だけ左右±30度・上下±25度へ戻した。現在のyaw受入範囲は `[-c - 30, -c + 30]` 度、既定値8.5度なら `[-38.5, 21.5]` 度。上記の `tighter/` と `centered/` の記録は以前の狭い判定幅の証跡として保存する。設定値の書換えや初期化は行わない。既存の境界・複数顔・Coordinatorテストを先に更新し、旧20/15度版で50 tests, 17 expected assertion failures, exit 65を確認した。判定幅の変更後は関連12クラス149 tests, 0 failures, exit 0。project生成チェックと差分チェックは成功。Claudeの差分レビューでコードの阻害要因なし。計画書の古い判定幅の表記は修正した。証跡は `range-restore/red.log`, `green.log`, `project-generation.log`, `claude-review.md`。署名付きビルド・インストール・起動はいずれも成功。新しいインストール先 `265BB905-8945-4D5C-ADFF-3883DEE1F0AE/CatRobot.app` からPID 2340で実行中と確認した。`range-restore/device-build.log`, `device-install.json`, `device-launch.json`, `device-processes.json` に記録。検証済みSwift 7ファイルのハッシュは不変で、補正値の保存処理・設定UIは変更していない。

## 相互レビュー後の整理

Claudeの実際の `/simplify`（再利用・単純化・効率・高度の4観点）と独立したCodexレビューを実施し、結果を交換して双方で `receiving-code-review` に従って採否を検証した。Critical / Importantのコード指摘はなかった。閾値をファイル内の名前付きDouble定数にし、評価順・判定条件を維持したままコメントと文書を整理した。テストは削除せず、保存済みの補正値と既定値8.5度の取り違えを検出するよう、既存Coordinatorテストの起動時の入力を-39度、設定変更前を-35度、変更後を-40度にした。

修正後のGeometry / Coordinator / Motionは80 tests, 0 failures, xcodebuild exit 0。project生成の決定性チェックもPASS。前節の149テストと実機ビルド・配布は整理前の結果として保持する。今回の整理ではSimulatorでアプリをビルドして回帰確認し、実機への再配布は行っていない。左右補正に連動した中心、左右±30度・上下±25度、既存の追尾・復帰の動作は変えていない。

証跡は `/private/tmp/cat-facing-cross-review-20261028/` の `claude-simplify.md`, `codex-review.md`, `claude-reception.md`, `codex-reception.md`, `root-reception.md`, `root-fixes.diff`, `claude-docs.diff`, `verification.log`, `verification.xcresult`, `project-generation.log`, `tested-source-hashes.json`。合成角度の自動試験であり、実機での角度精度・発熱を新たに測定した記録ではない。
