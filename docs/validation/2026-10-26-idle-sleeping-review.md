# 居眠り・待機機能の相互レビュー（2026-10-26）

Claude の `/simplify` と Codex subagent の独立レビューを実施し、双方の所見を相手側で `receiving-code-review` に沿って検証した。採用した不具合 3 件と整理 9 項目（部分採用を含む）を反映し、最終差分を双方で再確認した。追加の Critical / Important / Minor 指摘はない。修正後の全体テストは **797 件、795 成功、実機専用 2 スキップ、0 失敗**。

対象は `feature/look`、基準 `f6eeedad` からの居眠り・待機・sleeping 表情の未コミット変更と、その関連経路。着手時の [固定差分](idle-sleeping-review-2026-10-26/scope.diff)・[ハッシュ](idle-sleeping-review-2026-10-26/scope.json)、採用修正だけの [最終差分](idle-sleeping-review-2026-10-26/review-fixes.diff) を保存した。既存機能全体や未変更の firmware を新たに全監査したものではない。

## 相互レビュー

| 作業 | 記録 |
|---|---|
| Claude `/simplify`（再利用・簡潔さ・効率・責務の深さの 4 独立観点） | [C1–C12](idle-sleeping-review-2026-10-26/claude-simplify.md) |
| Codex subagent `requesting-code-review` | [R1–R4](idle-sleeping-review-2026-10-26/codex-review.md) |
| Codex による Claude 所見の受入評価 | [C1–C12 の採否と理由](idle-sleeping-review-2026-10-26/codex-reception.md) |
| Claude による Codex 所見の受入評価 | [R1–R4 の裏取りと修正案評価](idle-sleeping-review-2026-10-26/claude-reception.md) |
| 最終差分の照合 | [Codex](idle-sleeping-review-2026-10-26/codex-final-review.md) / [Claude](idle-sleeping-review-2026-10-26/claude-final-review.md) |

各レビューは書かれた時点の記録として保存した。最終レビュー中の「全体テスト実行中」という条件は、その後完了した下記の成功結果で満たした。

## 正しさの指摘

| ID | 結果 | 内容 |
|---|---|---|
| R1 Important | 修正 | マイク拒否後の文字専用会話でも待機を監視する。会話開始の明示操作を計時起点とし、音声・カメラの開始成功旗から監視を切り離した。拒否直後に未入力のままの場合も期限で寝る。 |
| R2 Important | 修正 | 終端の `.failed` も待機へ進む対象とした。エラー表示は待機まで維持し、失敗処理の終了と期限到達が重なっても一度だけ寝て、タップで一度だけ再開する。 |
| R3 当初 Important | 主張の訂正・文書修正、既存課題を別途記録 | 20 秒は未確定発話を区切る上限であり、音声認識の終了処理全体の上限ではない。reviewer もその保証違反という表現を撤回した。README・設計・検証文書を訂正。既存の graceful finalization に独立したタイムアウトがない点は未修正。 |
| R4 Minor | 修正 | 待機入り時に保存された字幕を消し、起床後に古い返事が再表示されないようにした。入力下書きと会話記憶は維持する。 |

R3 の残存制約: 音声認識の終了処理が完了しなければ待機も遅れる。将来の期限付き停止は `AppleSpeechRecognizer.stopCapture` 内で、元の停止処理と取消処理の完了まで所有権を保持する形で扱う。今回の修正で解消したとはしていない。

## 整理の採否

12 項目中、全採用 3・部分採用 6・見送り 3。詳細な理由は受入評価に記載した。

| ID | 判定 | 反映した範囲・見送った理由 |
|---|---|---|
| C1 | 採用 | 共通の一時停止手順を抽出。字幕消去は待機入りだけに残した。 |
| C2 | 採用 | 保留音声の通知を phase 通知から分離し、部分認識ごとの不要な顔環境更新と二重通知を除去。 |
| C3 | 見送り | 待機対象 phase と眠そうな顔を出す phase は、エラー表示優先のため意図的に異なる。 |
| C4 | 部分採用 | 分数範囲を共有し設定を必須注入に。編集側を優先する非対称な正規化は維持。 |
| C5 | 採用 | 製品から未使用の設定変更 API を削除し、テストも製品と同じ反映経路を使用。 |
| C6 | 部分採用 | 待機中の表示値を ViewState に集め、起床のアクセシビリティ動作を明示。入力可否・字幕非表示の契約は維持。 |
| C7 | 部分採用 | 前面会話・実行可能状態の共通条件を命名。不要な状態通知を縮小。非同期前後のガードとモード遷移順は維持。 |
| C8 | 部分採用 | 評価中の時計読みを 1 回に。取消世代や既存タイマー所有権は維持し、追加のキャッシュ状態は導入しない。 |
| C9 | 部分採用 | Claude がオフライン描画・計測ツールの重複を共通化。別 CLI の統合やキャッシュは追加しない。 |
| C10 | 部分採用 | テストの専用 UserDefaults を後始末し、条件付きの主要断言を明示。異なる経路を確認する断言は維持。 |
| C11 | 見送り | 未検証の幾何置換と微小な高速化のために、承認済みの顔の描画へ変更を広げない。 |
| C12 | 見送り | ソース文字列を解析するテストは追加せず、既存の express 受理・拒否の動作検証を維持。 |

## 検証

- R1・R2・R4 を覆う 5 ケースを失敗する統合テストで確認し、順に修正した。別途追加した ignore 経路の 1 ケースは、初回のテスト待ち条件に問題があり訂正した。これは製品の不具合として数えない。
- 修正ごとの実行は 2 件、9 件、19 件が成功。その後、整理も含めた最終ソースで全体を実行した。[実行サマリー](idle-sleeping-review-2026-10-26/test-executions.json)
- 全体: 21:48–21:52 JST、**797 件中 795 成功・2 スキップ・0 失敗**。[xcresult の JSON](idle-sleeping-review-2026-10-26/full-test-summary.json)。スキップは `RobotMotionIntegrationDeviceTests.testSelectedStage` と `SupertonicIntegrationDeviceTests.testSelectedStage`。xcresult: `/tmp/CatRobotIdleSleepDerived/Logs/Test/Test-CatRobot-2026.10.26_21-48-31-+0900.xcresult`。
- `ruby scripts/test_generate_project.rb` 成功。生成された project / scheme は全体テスト時点から不変。[記録](idle-sleeping-review-2026-10-26/project-contract-hashes.json)
- 全 225 ソースの SHA-256 が全体テスト開始前の固定値と一致。[固定値](idle-sleeping-review-2026-10-26/final-source.json) / [照合結果](idle-sleeping-review-2026-10-26/verification.json)
- 製品の顔の 3 ファイルはレビュー着手時から不変。C9 の前後で PNG **48/48 が byte 一致**、check と 3 種の measure 出力も一致。Codex が出力ファイルを独立に比較した。[比較結果](idle-sleeping-review-2026-10-26/render-comparison.json) / [Claude の作業記録](idle-sleeping-review-2026-10-26/claude-simplify-fixes.md)
- `git diff --check` 成功。

全体テストのコマンドは [初回の検証記録](2026-10-26-idle-sleeping.md#自動テスト) と同じ。レビュー後に実機への再配布や操作は行っていない。

## 実機・作業ツリーの状態

利用者から初回配布版について「いい感じ」との感想があった。これは一般的な使用感として記録し、個別の時間境界や資源停止を測定した証拠には広げない。今回のレビュー修正は **未コミット・実機未反映**。iPhone 16 Pro はレビュー前の `f6eeedad-idle-sleeping-working` のまま。firmware の変更なし。
