# main リファクタリングの検証（2026-10-28）

基点: `69c2a229ac10f410d3101de468e198ad2fa60944`。製品コードの整理完了: `6c6249e`。利用者は動作を保つ段階的な整理、不要なコード・文書・ブランチの削除、agmsg 経由の Claude との協働を依頼した。

## 変更

- 読み上げは現役の `SentenceReplyPlayback` に統一。`SentenceSpeechSpeaking` を依存境界にし、旧比較用 mode と produce/play、テスト専用の旧 Supertonic 実装、未使用の Apple 読み上げ実装を削除した。
- `ConversationViewState.enter(_:caption:)` に phase の表示、`VoiceTurnLatencyRecorder` に所有者付きの計測、ViewModel の内部ヘルパーに失敗時の後始末と操作意図の待ち合わせを集約した。
- テストだけが使う短期記憶 store をテスト側へ移し、未使用の表示名・認証ファイル名定数、旧プレビュー画像、末尾取得関数を削除した。
- 719ファイル、135,741,533 bytes の過去文書・途中画像・完了済み作業記録を整理した。[削除一覧](../maintenance/2026-10-28-removed-files.json)。採用原画3枚、最終iOS描画、現行仕様と実機の未確認項目は残した。[文書の入口](../README.md)と[アーキテクチャ](../architecture.md)を追加した。

顔の形・80%の倍率・設定の保存キー・記憶形式・首の安全制御は変更していない。

## テストの移行と発見した不具合

旧テストの多くは fake 話者の型によって旧全文再生へ進んでいた。先に fake を本番と同じ文再生へ移し、その状態で停止・再開・記憶・首・表情の試験を通してから旧経路を削除した。文間の期待値は「考え中へ戻る」から、本番の「発話中のまま口を閉じる」に変更した。生成完了前と後の保存境界、取消の join、遅れて届くイベントの無視は保持した。

移行により、生成の失敗直後に未確定の末尾を再生へ渡す競合が顕在化した。snapshot の終了が正常終了として伝わっていたため、`AsyncThrowingStream` で元の失敗を伝えるよう修正した（`ed7bd24`）。修正前は繰り返し試験の2回目で再現。修正後は coordinator と実 Supertonic 経路の回帰試験を各20回、計40回実行して失敗0件。`modelGenerationFailed` と2000字制限の `inputTooLong` を確認した。

基点の839テストから825テストへ減少した内訳は、未使用Apple読み上げ専用17件の削除、旧Supertonic4件を現役の3件と既存の停止試験へ集約、所有権の計測試験2件・表示状態の保持試験1件と生成失敗の回帰試験1件の追加（差し引き14件減）。失敗・不正PCM・前処理の検査は現役の `SupertonicSentenceSpeakerTests` へ移した。停止の試験は推論完了待ち・古いPCMの破棄・古いcallbackの無視に加え、streamが取消で終わることも確認する。

## 実行結果

実行場所: `/Users/goodapple/.codex/worktrees/b200/Cat_robot`。iOS Simulator: `40C29D25-C8EC-42C7-8145-65AB37A2BB7D`。ログとxcresultの保管先: `/Users/goodapple/Archives/Cat_robot/2026-10-28/evidence/`（各ファイルのSHA-256一覧付き）。

| 確認 | 結果 | 証跡 |
|---|---|---|
| 統合直前の最終CatRobot全suite | 825件、823成功、実機専用2 skip、失敗0 | `final-full.log` / `.xcresult` |
| CatRobot全suite（旧経路削除後） | 825件、823成功、実機専用2 skip、失敗0 | `c2-full.log` / `.xcresult` |
| 未使用末尾関数削除・停止assert追加後の対象suite | 15件成功、失敗0 | `c2-review.log` / `.xcresult` |
| 生成失敗の繰り返し回帰 | 40実行成功、失敗0 | `c1-fix-repeat2.log` / `.xcresult` |
| CatRobotプロジェクト生成契約 | 成功 | `c2-review-generator.log` |
| 顔サイズ調整ツール | 5件成功、失敗0 | `tuner.log` / `.xcresult` |
| 顔サイズ調整プロジェクト | 2回の再生成で差分0 | `tuner-generator.log` |
| Pythonスクリプト | 9件成功 | `python.log` |
| ファームウェア native | 91件成功 | `firmware-native.log` |
| ServoDriver通常版・PWMなし版 | 両方成功 | `servo-driver.log` |
| 文書のローカルリンク | 202本、欠落0 | `docs-links.json` |
| 顔の幾何条件 | 10表情×4口形、成功 | `render-check.log` |
| 採用原画の読み込み・計測 | neutral-b / happy-b / sleeping-draftを確認 | `render-measure.log`、`render-sleeping.log` |

`xcodebuild test` は並列テストを無効にし、実行中は双方のソース編集を止めた。今回、iPhoneへの配布、Claude実API、実音声、実カメラ、実機の首・熱・VoiceOverは検証していない。従来の受入未完了項目は[索引](../README.md)から各日付の記録を参照する。

## レビューとブランチ整理

Claudeはagmsgで会話制御の抽出を担当し、Codexが処理順序とテストを確認した。ClaudeはCodexの削除・テスト移行・文書manifest・ブランチ保全手順を読み取り専用でレビューし、重大な問題なしと判定した。独立した全体レビューは `69c2a22..6b3dc2e` を読み、Critical / Important / Minor の指摘0件で統合可と判定した。Claudeの最終確認で、安全復帰の時間を記したアーキテクチャ文書に誤りが見つかり、`Config.h` と `Supervisor.cpp` に合わせて訂正した。計画時の表示メソッド名も実装の `enter(_:caption:)` へ揃えた。実機受入とGit整理の実行結果は独立コードレビューの対象外として扱い、この記録で別に確認する。

ブランチ削除の前に71参照のbundleを作成し、`git bundle verify`、mirror復元、全参照のOID一致、`git fsck --full`を確認した。作業記録のtarとともに次の2か所へ保存し、SHA-256を照合した。

- `/Users/goodapple/workspace/Cat_robot/.worktrees/archive-2026-10-28/`
- `/Users/goodapple/Archives/Cat_robot/2026-10-28/`

未コミット変更・ローカル専用資産を持つ作業場所と、未完了PR [#15](https://github.com/kam6y/Cat-robot/pull/15) / [#17](https://github.com/kam6y/Cat-robot/pull/17) のブランチは保全する。削除後、mainや保持した参照から到達しない207コミットは、上記2か所のアーカイブから復元する。整理結果は21 worktree・31ローカルブランチ・17リモートブランチを削除、14 worktreeを保持。通常のworktree削除の前にHEAD・未追跡を含むstatus・ignored集合・作業記録の内容を再照合し、参照は期待OID付きで削除した。リモートは最新PR/OIDを再確認し、全17参照を期待OID付きのatomic削除で処理、削除後も確認した。削除拒否・参照移動による保留は0件。`cleanup-result.json`と削除ログを両アーカイブに保存した。

復元例（元のブランチ名は `refs.txt` を参照）:

```bash
git fetch /Users/goodapple/Archives/Cat_robot/2026-10-28/before-cleanup.bundle \
  refs/heads/feature/look:refs/heads/restored/look
```

顔の製品3ファイルのGit blobは基点と一致している（`product-face-hashes.json`）。最終全suite後の変更は文書とGit参照だけである。
