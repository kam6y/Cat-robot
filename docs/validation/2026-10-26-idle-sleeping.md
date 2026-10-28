# 居眠り・待機と sleeping 表情の検証（2026-10-26）

`feature/look`、基準コミット `f6eeedad` に対する変更。Codex がタイマー・会話/lifecycle 統合・設定・検証、Claude が下書きからのベクター実装と独立レビューを担当した。今回の変更は未コミット。

## 実装した動作
- 最後に受け付けた呼びかけから既定 5 分で `sleepy`、合計 10 分で自動待機して `sleeping`。設定の「居眠り」で分単位に変更・保存できる。待機は sleepy より後、上限 24 時間。
- 受理した呼びかけ・文字送信・明示タップで時計をリセット。周囲の会話・曖昧な呼びかけ・設定の開閉・前面復帰では延長しない。背景や端末スリープの経過時間も含む。
- 応答や分類の処理中は終わるまで待つ。期限到達時に認識途中の声がある場合は区切りまで保留し、確定しない認識も発話開始から最大 20 秒で区切る。この上限は segmentation / provisional-only の処理に限り、音声認識の終了処理全体を 20 秒以内に完了させる保証ではない。
- 自動待機はマイク、カメラ、顔追尾、首の自動動作を停止。寝顔と画面の点灯を維持し、猫のタップだけで会話に戻る。首の保持・BLE 接続は維持する。
- 背景復帰・設定終了・新しい会話・会話の復旧から勝手に起きない。記憶保存の再試行は待機のまま可能。入力途中の文字は隠して保持する。
- sleeping はアプリの状態専用で、LLM の `express` 選択肢には加えない。既存 9 表情の描画は維持。

## 自動テスト
```sh
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=40C29D25-C8EC-42C7-8145-65AB37A2BB7D' \
  -derivedDataPath /tmp/CatRobotIdleSleepDerived \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO test
```

プロジェクト生成の整合性チェックは通過。初回配布前の全体テストは **791 件、789 成功、2 スキップ、0 失敗**（20:23–20:28 JST）。
[結果 JSON](idle-sleeping-2026-10-26/full-test-summary.json)。xcresult は `/tmp/CatRobotIdleSleepDerived/Logs/Test/Test-CatRobot-2026.10.26_20-23-22-+0900.xcresult`。
スキップは明示的な実機実行が必要な `RobotMotionIntegrationDeviceTests.testSelectedStage` と `SupertonicIntegrationDeviceTests.testSelectedStage`。

境界 299/300/599/600 秒、設定値の正規化・永続化、呼びかけの分類別リセット、処理中の保留、背景/設定で期限をまたぐ場合、停止中のタップ、foreground と停止の競合、カメラ/自動動作の停止・再開、待機表示を検証した。

実装前の欠落、保存再試行の拒否、認識途中の声が待機で中断される問題、未確定認識のタイマー再予約不足をそれぞれ失敗する回帰で確認して修正した。初回の全体実行で Accessibility テストの設定コントロール期待一覧の更新漏れが 1 件あり、2 つの stepper を追加してから全体を再実行した。

## 画像とレビュー
[image_gen 下書き](../design/sleeping-2026-10-26/sleeping-draft.png) → Claude の SwiftUI ベクター → Mac / iOS 描画比較の順に確認した。
[上下比較](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/design/sleeping-2026-10-26/renders/round-2/compare-sleeping.png)と[詳細な視覚比較](../design/sleeping-2026-10-26/visual-comparison.md)に測定結果を残した。下書きの目の曲線との差は中央部で約 1px（1280×720）。先端の丸みと、画像生成による鼻・口・ひげの小差は記録済みで、画素完全一致とはしていない。

最終 iOS キャプチャと Mac の寝顔は、弧・鼻・口/ひげの分類 IoU が各 1.0、配置・主要色も一致。root が待機画面、文字入力からの待機、最大文字サイズ、設定画面を目視確認した。補間は製品の描画を使った Mac 診断で 5 コマを確認し、顔の消失や鼻・口・ひげの移動はない。

[Claude による状態遷移レビュー](idle-sleeping-2026-10-26/claude-review.md)と[独立した画像レビュー](idle-sleeping-2026-10-26/claude-review-ios-face-png.md)を保存した。重要な未解消指摘はない。

上記のキャプチャ・791 件のテスト・実機配布は、初回実装時点の記録。[provenance](../design/sleeping-2026-10-26/ios/final/provenance.json) はその時点のまま保存している。後続の相互レビューで、文字専用・失敗後の待機と字幕消去を修正し、コードを整理した。修正後は **797 件、795 成功、2 スキップ、0 失敗**。顔の製品描画 3 ファイルは不変。採否と検証結果は [相互レビュー記録](2026-10-26-idle-sleeping-review.md) を参照。

## 未実施の範囲
利用者の実機確認の依頼により、iPhone 16 Pro へ署名付き実機ビルドを更新インストールし、通常起動とプロセスの継続を確認した。アプリ識別子は `com.kamby.CatRobot`、source revision は `f6eeedad-idle-sleeping-working`。ビルド前後で製品・テストのソースが Simulator 最終成功時と一致することを確認した。[配布記録](idle-sleeping-2026-10-26/device-deployment.json)。

初回配布後、利用者から「いい感じ」との感想を受けた。個別の時間境界・マイク/カメラ/首の停止・タップ復帰について測定済みとはしていない。短時間での確認手順として設定を 1 分・2 分に変更する方法を案内した。端末の時間設定は自動変更していない。上記の停止・再開の検証結果は現時点では Simulator の統合テストによるもの。ファームウェア変更なし。

相互レビュー後の修正は実機へ再配布していない。端末は上記の初回配布版のまま。
