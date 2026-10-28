# Claude（claude_ui_polish）ペア作業のまとめ — 2026-10-27

基点は 1d9e1d0（feature/ui-reorganization）、コミットは f85f74e（Codex）。Claude の役割は Task 2（校正画面の項目分割）。

## 担当

- Claude が編集したのは `CatRobot/RobotLink/RobotCalibrationView.swift` と `CatRobotTests/RobotLink/RobotPresentationTests.swift` の2ファイルだけ。このタスクでは実機へのインストールも実機の操作も行っていない。ビルド・試験・git は Codex だけが直列で行った。
- 製品
  - `RobotCalibrationCategory`（offsets・direction・movement／中立の調整・回転方向・動作確認、識別子は `calibrationCategory.*`）を追加した。
  - 標準文字: 左 220pt の項目列（行の寸法は設定と同じ）と右の Form。右列の下に、保存状態・変更を戻す・ロボットに保存を固定した。
  - 大きい文字: 一覧から詳細へ進む（`navigationDestination(item:)`）。詳細のバーには停止と「調整項目へ戻る」だけを置き、システムの戻るは隠した。
  - 「首」を「ハード」に置き換えた。停止・確認ダイアログ・各操作の押せる条件は変えていない。
- 試験
  - 実行前の状態で落ちる試験を先に書いた。文字列の識別子とラベルだけで書いたので、未実装でもコンパイルが通る。
  - 共有の準備 `openCalibrationInSettings(textSize:)` と `calibrationDepth`、途中で throw したときの後片付けを入れた。
  - 新しい試験は5件: 項目の切替と draft の保持、文字サイズの往復、大きい文字の詳細と確認付きの終了、xxxLarge で切断した状態の画面内配置、最初から AX5 で開く経路。

## 相互レビューの採否

Codex から Claude へ（すべて採用）:
- 用語は「ハード」。ナビゲーションバーは残す。行の寸法は複製し、共通の抽象は作らない。
- 大きい文字の詳細ではシステムの戻るを出さず、「調整項目へ戻る」にする。システムの戻るは長押しの履歴で、確認を飛ばして抜けられるため。
- `XCTUnwrap` の autoclosure の中に await を入れない。
- Slider のラベルが重複していたので、ラベルなしの初期化子にした。
- 一覧の行を押したときに selection を合わせる。
- AX5 で開く経路の試験を足す。後片付けを入れる。項目探索に scrollingIn を補う（Codex が修正）。

Claude から Codex へ:
- 文字入力中に聞き取りチップが毎ターン出入りして、顔の高さが変わる（Important として指摘）
  - 不採用。理由: 入力欄は動かず、通常の 85% の顔も一定。チップの領域を常に確保すると、チップの無いときの顔も縮む。
- typed-face の assert が弱い
  - 採用。Codex は画面の高さを 100pt 増やしたときに顔も 100pt 増えることを測る形にした。
- README に「首」が残っている
  - 採用。現在の説明は「ハード」へ統一した。

## 判明した点

- 文字サイズを large→AX5→large と変えても、校正画面の `topViewController` は同じ（ObjectIdentifier の診断）。校正の destination を親へ移す必要はない。
- Slider の「左右のずれ、左右のずれ」という重複読み上げは、変更前のコードからあった。今回直した。
- 最終確認: 対象 f85f74e の全体試験は 839 件で、837 件が通過、2 件がスキップ、失敗 0（full-final.log、TEST SUCCEEDED）。途中では、校正の8件と typed-face の試験を合わせた9件（calibration-fixed.log）と、AX5 で開く経路（calibration-large-start.log）も通過していた。

## 因果を保留した点

- 既存 CoversWhole の dialog=nil（文字サイズ変更から約300ms後に戻るを押したときの失敗）
  - Claude が出した「Group が修飾子を分岐ごとに付け直すため」という説明は、ダイアログについては撤回した。変更前の製品（GeometryReader）でも RED で同じ失敗が出ていたから。
  - Group から VStack への変更は、修飾子の親を安定させる修正として扱う。
  - 選択が戻らない件の因果も確定していない。単独で再現して確かめておらず、Group→VStack と、一覧の行を押したときに selection を合わせる変更を一緒に入れたため。
  - これら複数の修正を入れた後、ダイアログと選択の試験はどちらも同じ300msの待ちで通過した。待ち時間は増やしていない。
- 試験の順番による持ち越し（直前の新しい試験が throw して、session が残る）は仮説のまま。単独での実行はしていない。後片付けは根因とは別に、途中で throw したときの片付けとして入れた。
