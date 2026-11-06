# issue #22 — docs-only fixes delta check (Claude, read-only)

作成: claude_issue25 2026-11-06 12:2xZ。対象: 作業ツリーの未コミット修正（codex root が 12:20Z に適用）。HEAD は凍結 e6cbe28ce2f44648fd6856d9ea030eeda11c54ff のまま。

## 結果

| 確認 | 値 | 判定 |
|---|---|---|
| 変更ファイル | README.md（10 行、5±）、docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md（2 行、1±） | Markdown のみ。`git diff --name-only` に非 .md なし |
| docs 差分 sha256 | `git diff -- README.md <requirements>` = f96ead1eb41d75d2da6ef82b983f5e70f5a452fa5106337911285e93b48b1ffd | 記録 |
| S1 行 | 作業ツリー :35 == base 04c3de85 :35（`diff` 空）、HEAD :35 とは異なる | 原文へ**完全復元** |
| README :11 | 「呼びかけがない発話は…」→「それ以外の発話は…」 | C3/S9 採用どおり |
| README :278-281 手動確認 | 1 マイクとカメラを許可 / 2 顔を向け呼び名なしで質問、返答だけでは省略を証明できないと明記 / 3 返答後 30 秒以内に顔をそらして続き / 4 30 秒以上空け顔をそらして別の相手・曖昧、本人宛て分類には返答 | native reception の指定（顔あり名前無し、30 秒内の横向き継続、期限後、trace の区別）を満たす |
| code/test/project パッチ | `git diff 04c3de85 -- CatRobot CatRobotTests CatRobot.xcodeproj`（作業ツリー）= 7b47dddc45e7a5907d60a0b66026c284bc333d8b51894b6773e1a6c1f0660c72 = HEAD の同パッチ = freeze.testedPatchSha256 | **不変**。全件再実行は不要 |
| 未追跡 `docs/validation/facing-addressing-review-2026-11-06/` | native-code-review.md, native-reception.md, claude-simplify{,-reuse,-simplification,-efficiency,-altitude}.md, project-semantic-check.json, user-device-check.json, build-receipt.json, full-receipt.json | 下記ハッシュ比較のとおり /tmp 原本と一致。claude-reception.md はまだ未収録（12:21Z 保存のため） |

## /tmp 原本との一致（sha256 先頭 16）

- same: native-code-review.md (a2ebd5dd794c9c9f)
- same: native-reception.md (1bbfb9198fd6944f)
- same: claude-simplify.md (a1e66e197c19b9dd)
- same: claude-simplify-reuse.md (4726e84e554e4c83)
- same: claude-simplify-simplification.md (c44f394f0783f058)
- same: claude-simplify-efficiency.md (47cd10531ff51ae9)
- same: claude-simplify-altitude.md (c331c3797d72798a)
- same: project-semantic-check.json (78c110e03c61a23d)
- same: user-device-check.json (32002ebeb83a9314)
- same: final2/build-receipt.json (6a763c8f32f2b45c)
- same: final2/full-receipt.json (82fb84d55fbdb688)

## 未対応の要望（ブロッカーではない）

- validation `docs/validation/2026-11-06-facing-addressing.md:15` は「追尾オフでは返答ごとに再起動する場合がある」のまま。再起動は宛先判定に進んだ発話ごと（返答しない却下発話も含む）。一文の精度修正を要望（claude-reception.md §5-1）。
- 最終記録での 2 つの digest 定義の明記（e9f1628f… = app+test+project 入力 digest、7fc67a24… = normal build sourceDigest、同一 commit e6cbe28c）。
- README :56 は既に「左右補正を変えると、追尾先と顔の向き判定の中心が一緒に変わります」と記しており、C4 の不足は設定画面の文言（production ソース）側のみ。defer に同意。

## 判定

docs-only 修正は採否どおりで、試験済みパッチと normal build に影響しない。squash → main の統合後に、#26 と同じ統合確認（main tree == feature tree 相当、code/test/project パッチ、push 後の remote hash、issue close）を行う。
