# issue #25: エフォート設定の検証

## 変更

- main `f206a1e` から `codex/issue-25-effort-settings` を作成。
- 設定「会話」の名称を「エフォート」に統一し、`low / medium / high / xhigh` の順で表示する。
- 保存済みの値と既定のlowを維持し、新しい2値も保存・復元して次のClaudeセッションへ渡す。
- 固定SDK 0.2.3（revision `0262e1a`）の全選択モデルが4値に対応することを確認。

## 確認

| 対象 | 結果 |
|---|---|
| 実際の設定コードをMac上で直接実行 | 実装前 `unsupported effort high` で失敗、実装後は4値の順序・保存・復元が成功 |
| Xcodeプロジェクト生成 | 成功、生成ファイルの差分なし |
| `ruby scripts/test_generate_project.rb` | `PASS: deterministic CatRobot project contract` |
| Simulator向けアプリ・テストのビルド | xcresultのbuild-resultsで `status: succeeded`、`errorCount: 0` を確認 |
| Simulator関連テスト | Xcode 27.2・27.0ともテスト起動待ちで中断。XCTestの実行結果は未取得 |
| Simulator全体テスト | 関連テストが起動しないため未実行 |
| `git diff --check` | 成功 |

関連テストは4値の保存・復元、SDKへの写像、3モデルの対応、進行中の設定維持とセッション再作成後の適用、既定値と不正な保存値を確認する。

変更前のSimulator実行はアプリとテストのコンパイル後に起動待ちで停止したため、中断した。専用Simulatorも `launchd_sim` の応答待ちで起動できず、ユーザーのCoreSimulatorServiceを再起動した。その後は専用デバイスを起動できたが、テスト本体は開始しなかった。Xcode 27.2の実装後ビルドと、iOS 27.0に合わせたXcode 27.0の `test-without-building` の両方で同じ状態となった。これはXCTestのアサーション失敗ではなく、テスト成功とも扱わない。

ログとxcresultは `/tmp/cat-issue25-effort-20261106/` に保存する。実装後ビルドの結果は `green-build-summary.json`、Xcode 27.2の中断結果は `green-summary.json`、27.0での試行は `green-beta.log` / `green-beta.xcresult`。27.0の中断結果には `CatRobot (74026) encountered an error` / `Testing was canceled` が1件記録されている。アサーション実行の失敗ではなく、成功したXCTestは0件。全体テストの成功件数はない。

## ペア作業

ユーザー指定のtmux 8:2にいるClaudeと、agmsgのcodingチームで作業した（`codex` と `claude_issue25`）。ClaudeはSDK互換性・実装方針、テスト差分、最終差分を確認し、Critical・Importantの指摘はなし。

任意の指摘については、英字のみの4選択肢は今回の仕様どおりとし、既定のlowはREADMEで説明する。過去の設計書は当時の記録として保持する。lowを含むテストの反復も4値の契約の確認として維持する。この採否をClaudeにも共有し、異論なしと回答を得た。プロジェクト生成契約の実行済み証跡も共有した。未対応の不具合指摘はない。

実APIでの応答時間や生成品質の測定は行っていない。

## ユーザー追記

初回実装後の指示により、表示を `low(推奨)` と `Claude Opus 5.5(推奨)` に変更する。括弧は半角。上記の「英字のみ」の判断を上書きする表示変更で、保存値・API指定値・既定値には変更を加えない。
