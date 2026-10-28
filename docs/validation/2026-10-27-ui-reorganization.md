# 画面整理の検証（2026-10-27）

基準は居眠り機能を含む `9ee8dac`、作業ブランチは `feature/ui-reorganization`。利用者が承認した[設計](../superpowers/specs/2026-10-27-ui-reorganization-design.md)を、Claude と Codex のペアプログラミングで実装した。Claude が画面と描画・遷移試験を担当し、Codex が状態・起動処理の統合、ビルド、検証と文書を担当した。

## 変更

- 通常の会話画面は顔を大きく表示する。字幕と聞き取り途中の文字は画面から外し、返答の全文は会話の記憶に保持し、完了・停止後は VoiceOver の猫ボタンの「その他のコンテンツ」（猫の返事）から読める。
- 一時停止・撮影中・待機中・首の再接続・熱による顔追尾停止をチップで知らせる。タップで再開できる一時停止中だけ顔の不透明度を 0.5 にする。
- 初回説明は標準文字で2列に収め、開始ボタンで完了を保存する。次回から会話画面で開始し、設定から説明を見直せる。
- 設定は6カテゴリと詳細の2列にする。アクセシビリティ用の文字サイズでは一覧から詳細へ進む。顔追尾の補正は「カメラと顔追尾」、中立・回転方向の校正は「ロボット」にまとめる。

`CatFaceView` の形状・表情、BLE・首の動作・look・音声エンジンの挙動は変更対象に含めない。

## 相互レビューで確定した条件

- 音声の割り込みと出力先変更は、既存実装では割り込み終了だけで再開しない。猫のタップによる停止と同じ「タップで再開」の案内を出す。停止・再開の動作そのものは変えない。
- 首の再接続チップは、その起動中に同じ機器へ一度接続できた後の切断にだけ出す。起動時から電源オフの首への接続再試行には出さない。再試行の connecting/preparing 中も表示を保ち、別の機器への変更・未選択で接続済みの記録を消す。
- 待機中は一時停止・撮影中のチップを隠す。BLE接続を維持しているため、再接続と熱の警告は残す。
- 初回説明を省略した起動も既存の前面復帰経路を使う。マイク許可の表示中は開始を重ねず、通常のバックグラウンド復帰では聞き取りを再開する。
- 音声・文字返答は speaking → thinking → listening/paused を通る。既存の自動通知だけでは全文にアクセスできないため、猫ボタンに必要なときに読める返答全文を追加する。
- 大きい標準文字・一時停止/首/熱の3チップ・高さ240ptの文字入力を組み合わせると、熱のチップが入力カードの見出しに重なった。入力欄だけの位置確認では見逃すため、見出しと閉じるボタンも含めた回帰試験を加えた。チップを入力画面の縦配置に含め、収まらない場合は上側だけをスクロールさせる。入力欄は切り替えの外に置く。
- 初稿の両方向という指定は、カメラ左固定にした既存変更 `7aef684` より前の記述が残っていたものだった。製品の向きは変えない。設定の操作は実際の scene に接続したウィンドウで確認し、会話画面では模擬左右比較も行う。
- 配置を切り替える候補に入力欄を重複して置くと、表示中の入力欄が作り直されカーソルが2文字目から末尾へ移ることを再現した。候補の測定時に顔が大きすぎるため通常の入力画面までスクロール配置になり、顔が120ptへ縮む問題も確認した。入力欄を固定し、非スクロール候補の顔に最小・理想44ptを与えて、表示時には残りの高さを使う。回帰試験は実際に画面内でヒットする入力欄とカーソル位置を比較する。

## 自動検証

```sh
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=40C29D25-C8EC-42C7-8145-65AB37A2BB7D' \
  -derivedDataPath /tmp/CatRobotIdleSleepDerived \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

途中の全体試験は829件、実機専用2件スキップ、失敗0件だった。その後の画像比較と操作条件の追加で入力画面の2件を再現し、最終検証は修正後の `2431a29` に相当するコードで別途実施した。

途中の回帰試験では、音声の割り込み後の案内不足と、初回接続の失敗で警告が残る条件をそれぞれ失敗させてから修正した。初回説明の完了保存、許可拒否の回復、許可待ちの inactive/active、通常の背景復帰、繰り返す active 通知を検証した。基盤の関連44件と、一時停止表示の関連56件は通過した。

最終結果は **830件中828件成功・実機専用2件スキップ・失敗0件**。iPhone 18 Pro Simulator / iOS 27.0 で実施した。`RobotMotionIntegrationDeviceTests.testSelectedStage` と `SupertonicIntegrationDeviceTests.testSelectedStage` は実機での明示的な実行が必要なためスキップした。プロジェクト生成の再現性検証も通過した。

テスト対象のコードは `2431a29`。実行前後のソース・テスト・プロジェクト・依存関係・画面向きの設定223ファイルのハッシュが一致し、テスト後の変更がないことを確認した。[テスト概要](ui-reorganization-2026-10-27/full-test-summary.json)、[実行条件](ui-reorganization-2026-10-27/verification.json)、[対象ファイルのハッシュ](ui-reorganization-2026-10-27/final-source.json)、[修正前の失敗記録](ui-reorganization-2026-10-27/regression-failures.txt)を保存した。

独立した文脈での[レビュー結果](ui-reorganization-2026-10-27/independent-review.txt)は Critical 0件、Important 1件（VoiceOver の返答アクセス）、Minor 0件。VoiceOver の指摘は修正・検証済み。追加検証として求められた狭い入力画面では、見出しへの重なり、入力欄とカーソルの作り直し、通常の顔の縮小を再現して修正した。新しい3件の回帰試験と最終全体試験が通過した。相互レビューと実装時の[判断の記録](ui-reorganization-2026-10-27/rulings.json)も保存する。

## 描画の確認方法

比較用 viewport は 852×393 pt、模擬 safe area は左62・右40・下11 pt と、その左右を入れ替えたもの。実機で測った寸法とは呼ばない。UIKit と SwiftUI の両方が safe area を扱うため、模擬値を与えただけで済ませず、SwiftUIが測った値と最終描画の座標を照合する。左列の位置と幅、右列の余白も描画結果で確認する。

設定の描画と操作は iPhone 18 Pro Simulator の実際の scene（874×402pt、左右62・下20pt）で行う。会話と初回説明の寸法試験は前述の模擬値を使う。配置候補間の入力欄維持試験では高さ800→240→393ptを与え、同じ候補に留まるだけの偽陽性を防ぐ。

実際のボタンを操作する試験は、テストプロセスのアクセシビリティ環境を有効にして実施する。会話のチップ、文字入力・エラー・記憶復旧、標準/最大文字、設定の各カテゴリと校正への遷移を対象とする。

## 保存した画像

最終テストから109点の画像を保存した。[一覧とハッシュ](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/image-manifest.json)には、画像ごとのテスト名とピクセル寸法を記録した。会話・初回説明は1倍、UIKitの校正画像には端末スケールの画像が含まれるため、ピクセル数をそのままptとは扱わない。

| 画面 | 画像 |
|---|---|
| 通常の会話 | [顔とメニュー](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/normal.png) |
| 初回説明 | [標準文字](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/onboarding-standard.png) |
| 設定 | [会話カテゴリ](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/settings-conversation.png) |
| 説明の見直し | [閉じるボタンのあるシート](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/settings-onboarding-review.png) |
| 文字入力 | [通常の顔の大きさ](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/typed-face-size.png) |
| 狭い文字入力 | [警告3件と入力カード](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/typed-paused-chips-largest-standard-type-short-viewport.png) |
| 校正 | [設定全体を覆う校正画面](https://github.com/kam6y/Cat-robot/blob/69c2a229ac10f410d3101de468e198ad2fa60944/docs/validation/ui-reorganization-2026-10-27/images/settings-calibration.png) |

## 実機への更新インストール（2026-10-27）

利用者の依頼で、iPhone 16 Pro の既存 CatRobot を更新した。署名付き実機ビルド、`codesign --verify --deep --strict`、`devicectl` によるインストールが成功し、更新後のアプリの配置先がインストール結果と一致することも確認した。成果物の source revision は `0e3489edba477fe823c6119359ce43222cf2daf8`（実装コード `2431a29` を含む）。ビルド前後で検証済み223ファイルが一致した。既存アプリのアンインストールは行っていない。[配布記録](ui-reorganization-2026-10-27/device-deployment.json)。

今回の依頼はインストールまでのため、通常起動、実音声・カメラ・首を併用した操作、実機の VoiceOver 読み上げ、ソフトウェアキーボードを表示した配置は未確認。Simulator の描画・統合試験を実機の動作合格とは扱わない。端末設定・ロボットの校正値・ファームウェアは変更していない。

## 相互レビュー後の修正

この実装に対する Claude の `/simplify` と Codex の独立レビュー、および双方の `receiving-code-review` は、[相互レビューの検証記録](2026-10-27-ui-cross-review.md)にまとめた。エラー・記憶カードの切り替え時に入力欄が作り直される問題を修正し、未使用コードと重複処理を整理した。本ページのテストと実機配布記録は、修正前のコミットに対する記録として保持する。
