# Haiku-only validation（端末内モデルの削除と Haiku への一本化、issue #30）

対象は [issue #30](https://github.com/kam6y/Cat-robot/issues/30)、設計は [2026-11-09 の spec](../superpowers/specs/2026-11-09-haiku-only-design.md)、手順は [実装計画](../superpowers/plans/2026-11-09-haiku-only.md)。main `7913e157a0a310b5064b3779620e006f11e87159` から `codex/issue-30-haiku-only` を作り、Codex と Claude が Driver／Navigator を交代しながら進めた。Task 4 の実モデル受入は 2026-11-09 の候補 `080e760025edb37b4a86e0c82e07c89717cb10ea`（文書を除く compiled 入力 296 ファイルの digest `50790fe8a4e67b9b465d0468ff4669be7f521c5c41bea52c79fe02a706fbc22f`、文書込み 298 ファイルの digest `118e22d278bed054c019fb765917f06457c1bf325f37bea88a0d1dfa30b5a82a`）に対するもの。証跡は `/private/tmp/cat-issue30-haiku-20261109/` の Task 別の記録・receipt・検証 JSON にある。

## 確認済みの実装

| 対象 | commit | 検証 |
| --- | --- | --- |
| spec r6 | `356c868e` | 文書のみ |
| 端末内モデル・fallback の撤去、日次上限の decorator 化 | `ad8e5ca4585dd8493cc0ad81b55630213da84c7b` | 計画 Task 1 Step 6 の 10 クラス 122 件成功 |
| 直近の会話つきの Haiku 宛先判定（`ContextualAddressClassifier`、JSON 入力、設定の説明文） | `b119f2a8` | 対象 7 クラス 111 件成功、全 suite 1,024 件成功 |
| 失敗の定型文の読み上げ（`ConversationFailureGuidance`、`finishFailure`） | `74653165e744e82ca1eef555fffad63e81c4f404` | 対象クラス 162 件成功、全 suite 1,045 件成功。初回（r1）は 152 成功／10 失敗で、本番の回帰 1 件（音声から引き継いだ audio session を早期失敗で解除しない。G3-1）と試験側の修正 4 件（G3-2〜G3-5）の後に r2 で全件成功 |
| 通常の宛先判定の指示文（話題の連続性の境界） | `0b44d7373f1e0a5076fb030562b7d6d60b2da9f2` | 8 クラス 112 件成功・1 skip（Simulator では受入試験を skip） |
| Haiku 受入試験の fixture と runner | `080e760025edb37b4a86e0c82e07c89717cb10ea` | 実モデル r1 66/69（不合格）→ 指示文修正 → r2 69/69（下記） |
| 案内の読み上げ開始の取り消し（I1） | `a72e769a14d486893ebf32603e1ee0cb0fa5fc5b` | 対象 12 クラス 176 件成功、全 suite 1,047 件成功。同レビュアーの限定確認で解消と関連 Critical／Important 0 件を確認 |

各 commit は Codex が行い、commit 前に全 source 入力が GREEN の入力と一致することを双方の digest で照合した。Simulator と fake による検証で、実モデルの意味判断・実請求額・実機での利用者の受入は代替しない。

静的な受入（計画 Task 1 Step 5。HEAD `080e7600` で再確認）: `grep -rn SystemLanguageModel CatRobot CatRobotTests` は 0 件。`^import (FoundationModels|ClaudeForFoundationModels)` を `CatRobot/` で持つファイルのうち `Conversation/Services/Claude/` と `Conversation/Tools/` の外にあるものは 0 件（Domain の port は SDK を知らない）。

### 試験数の内訳

基準（main `7913e157`）の通常 suite 1,048 件に対し、Task 3 後の全 suite は 1,045 件。`1048 − 43 + 10 + 9 + 21 + 0 = 1045`。その後、独立レビュー I1 の回帰試験を 2 件追加し、最終の通常 suite は `1048 − 43 + 10 + 9 + 21 + 2 = 1047` になった。

| Task | 削除 | 新設 | 名前を変えて移植（net 0） |
| --- | --- | --- | --- |
| 1 | 43（削除した 6 試験ファイル: OnDeviceFallback 23、Routed 7、FMAddress 3、FMAvailability 1、FMError 2、FMReply 7） | 10（DailyLimitedReplyGenerator 4、ClaudeAddressClassifier 6） | 12 |
| 2 | 0 | 9（ContextualAddressClassifier 6、routing 1、memory integration 1、service snapshot 1） | 3 |
| 3 | 0 | 21（guidance domain 1、FailureGuidance 19、playback ownership 1） | 5 |
| 4 | 0 | 2（`HaikuAddressingModelTests` の inventory と acceptance。有料・実機の 4 クラスとともに通常 suite から除外するので full では 0） | 0 |
| 5（I1 修正） | 0 | 2（開始前の取消と文字入力置き換え。通常 suite に含む） | 0 |

計算の方法は `test-counts-through-task4.json`（path＋test 関数名の集合差。名前を変えずに中身を変えた試験は net 0）。

## 固定した実モデル受入（Task 4）

fixture 版 `issue30-v1`、23 fixture × 3 回 = 69 回の Haiku 呼び出し（Opus 0）。合否は全 fixture で 3 回とも expected の集合に入ること。SDK は ClaudeForFoundationModels 0.2.3、revision `0262e1a766c461a4268dcec656eca95dd74cebf8`。モデルは本番と同じ `ClaudeAddressModelClient`（Haiku 5.5、effort low、timeout 15 秒、fallback なし）を `ClaudeAuthConfiguration.live()` で直接呼ぶ。実機は iPhone 16 Pro（iOS 27.3、「Not so bad」）、runner は `scripts/run_haiku_addressing_model_tests.sh`。結果は `/private/tmp/cat-issue30-haiku-20261109/model-runs/<runID>/`。実行の承認は 2026-11-09 に利用者から得た（再実行を含む）。

文脈は A = [(今日の天気はどう？, 晴れだよ)]、B = [(お姉ちゃんが来るんだ, 楽しみだね)]、C = [(ねこ、おはよう, おはよう！今日も元気だね)]。

| id | recentTurns | 発話 | expected |
| --- | --- | --- | --- |
| ctx-followup-tomorrow / ctx-followup-repeat / ctx-followup-umbrella | A | それで、あしたは？ / もう一回言って / 傘はいる？ | addressed |
| ctx-other-addressee-same-topic | A | ママ、あしたの天気どうだった？ | notAddressed |
| ctx-addressee-from-history / ctx-self-talk | B | お姉ちゃん、傘どこ？ / これは独り言。疲れたな。 | notAddressed |
| ctx-unrelated | A | 明日の予定は？ | ambiguous |
| plain-cat / plain-papa / plain-rain | なし | ねこ、元気？ / パパ、鍵はどこ？ / 明日は雨かな。 | addressed / notAddressed / ambiguous |
| clar-〜（13 件。#29 と同じ発話、元の発言「今日の天気はどう？」） | C | はい、うん、いいえ、ううん、言ったよ、そうそう、天気の、いいえ、あなたには言ってない、違うよ、ママに言ったの、猫ちゃん、5たす4はいくつ？ → addressed。明日の予定は？ → ambiguous。ママ、鍵はどこ？ / これは独り言。疲れたな。 → notAddressed。部長に電話しておいて。 → notAddressed または ambiguous |

### 結果

- **r1**（runID `C168788B-6479-4303-BC7D-7F1C96CE40AB`、HEAD `74653165`）: 69 回完了、66 成功、3 失敗。失敗は ctx-unrelated だけで、天気の文脈の後の「明日の予定は？」を 3 回とも addressed と判定した（期待は ambiguous）。API エラー 0、runtime warning 0。結果 `data/results.json` の SHA-256 `474984e4f8ba2f16f8888216bdd633bda9693ae29090683c643fe815d7263c96`。
- **原因と修正**: 通常の指示文の規則 3「会話の続き・同じ話題への追加の質問と読める: addressed」に話題の境界が無く、文脈つきの例「それで、あしたは？ → addressed」が「天気の後に明日を尋ねれば続き」と読めた。修正（`0b44d737`）は、規則 3 を「直前の話題と同じ事柄を扱うときだけ」（指示語・接続詞・聞き返し・言い直し・話題から自然に続く事柄。例: 天気の後に傘がいるか尋ねる）に限り、規則 4 に「別の事柄を新しく尋ねる発話は、今日・明日などの時間の言葉や疑問文の形が共通しても続きとは扱わず、手がかりがなければ ambiguous。直近の会話があるだけでは猫宛ての根拠にしない」を足し、対照の例として文脈 A＋「明日の宿題は何？ → ambiguous」を加えた。fixture の発話「明日の予定は？」は例に入れていない。確認待ち用の指示文、fixture、runner、他の本番コードは変えていない。試験側は `ClaudeAddressClassifierTests.testOrdinaryInputIsJSONWithRecentTurns` を続き／話題変更／猫呼びの 3 発話の表にし、履歴と発話が別の値で同じ通常指示とともに送られることを確認する（新しい文言の部分一致は固定しない。意味の回帰は凍結した fixture で判定する）。
- **r2**（runID `BFFB70BC-9B32-40A5-BAD0-5A0E17C8AAD9`、同じ 23 fixture、HEAD `74653165` ＋ 指示文修正の候補）: 69 回完了、69 成功、0 失敗。ctx-unrelated は 3 回とも ambiguous。API エラー 0、runtime warning 0、実行前後の source manifest 一致。r1 と r2 の fixture の prompt・期待・構成は一致し、違いは指示文だけ。結果の SHA-256 `37b9b0c9bb392f335445cc91d03c036d352d06d0385208884f3e4c4a6eaccf0e`、検証 `execution-verification.json` `1b9a5848b7d2dac9c89d18496e0548d8e4789c22824bb57ca505b4e05d069e4f`。
- 2 run の合計は top-level 138 回の Haiku 呼び出し。r1 の不合格も記録として保持する。

### 限界

- model と effort は本番の宣言値（`claude-haiku-5-5`、low）で、通信や server の応答から観測した値ではない。prompt のハッシュは論理的な JSON の正規形で、usage・請求額は SDK が返さないため記録していない。
- fixture は承認済みの回帰用の例で、held-out の benchmark ではない。指示文の例と同じ文の fixture が複数あり（「それで、あしたは？」「パパ、鍵はどこ？」など）、それらは例の再現を確かめている。ctx-unrelated の対照例は fixture と別の文にした。
- 指示文を変えるときは、この受入（69 回）を同じ構成で再実行する。

## 文書（Task 5 Step 1）

- `README.md`（Navigator の同意で対象に追加）: 概要・会話の節の「通信障害時は端末内モデルへ切り替え」「端末内モデルが使える場合は Apple Foundation Models」を、宛先判定はいつも直近の会話つきの Claude Haiku、失敗は種類ごとの定型文を声で案内してから表示する、に直した。日次上限の案内文、送るもの（判定のための発話と直近の会話）、Services の構成説明、Apple Intelligence 対応・非対応の記述（非対応機の確認 T-DEV-1 / T-DEV-2 は対象外）を更新し、通常署名版での人による確認が未実施であることを書いた。Navigator の所見 D4 で、分岐図リンクの日付と、日次上限は返答の生成だけを止めて宛先判定の Haiku は呼ぶことを直した。
- `docs/README.md`: #30 の spec と計画を索引へ加え、#29 の行に「確認待ちでないときは端末内モデルが使えれば端末内」の振り分けが #30 で廃止された旨を注記した。分岐図の時点を「2026-11-09 / issue #30 対応時点」にし、検証記録の表へこの記録を加えた。
- `docs/architecture.md`: 図を「宛先の判定（Claude Haiku、直近の会話つき） → 返答の生成（Claude）」にし、失敗は定型文を声で案内してから表示すると書いた。「返答のモデルと記憶」を `DailyLimitedReplyGenerator`・`ContextualAddressClassifier`・`ConversationFailureGuidance` に置き換え、所有権の約束事に失敗の終了の手順 (1)〜(6) と、一時停止が後始末中に定型文を止めることを書いた。テストの入口に `FailureGuidanceTests` と有料の runner を足した。Navigator の所見 D1・D2（所有者が変わっても (5) の停止・解除・reset は行うこと、通常指示と確認待ち指示の契約の区別）を `performFailureOperation` と照合して反映した。
- `docs/superpowers/specs/2026-11-07-clarification-history-design.md`: 冒頭に、#30 で端末内モデルを外し、確認待ちでない判定も文脈つきの Haiku で行う後継注記を 1 行入れた。本文は当時の記録として残す。
- `docs/application-flow.html`: #28・#29 で使った作業用の生成器（Mermaid 12.3.0 の描画済み SVG、headless Chrome）を複製し、まず HEAD の HTML（SHA-256 `63c462ca2cd4b069ec995deeb3503c5bd03c53ad2ad902bc8f6541f40eb2c820`）を byte 単位で再現できることを確かめてから入力を直した。「03 返答と記憶」は題を「返答はいつもClaude。失敗したら、定型文を声で案内する。」にし、端末内モデルの分岐（「端末内モデルを使える？」「案内を添えて、端末内で簡単に答える」）を外して「種類に応じた定型文を声で案内 → 理由を示して停止」と「文字入力が来たら案内を止める」を足した。Navigator の所見 D3 で、案内へ入る条件を「通信・生成・拒否・長さ超過などの失敗。本文が途中まで出ていても同じ」に直し（旧 fallback の「本文が確定する前」の条件を外した。`FailureGuidanceTests.testReplyFailureAfterPartialTextStillSpeaksGuidance` が根拠）、読み上げ自体の失敗は声の案内なしで停止、自動保存の失敗は「未保存と表示して再試行を案内。会話は続く」の箱へ分けた。「02 応答する条件」は判定の箱を「猫への発話かを、直近の会話つきでClaude Haikuが判定」にし、聞き返した後の「向いていない」「判定に失敗」の行と「モデルによる宛先判定」の注記（埋め込み定義と表示の 2 か所）を直した。「01 全体」は開始前の失敗の箱に声の案内を足した。参照は `DailyLimitedReplyGenerator.swift`、`ConversationFailureGuidance.swift`、`ContextualAddressClassifier.swift`、#30 の設計を加えて 36 件（`OnDeviceFallbackReplyGenerator.swift` は外した）。meta の入力 digest は `50790fe8…`。定義を変えた 3 図（全体・応答する条件・返答と記憶）だけを再描画し、他の 3 図は既存の SVG をそのまま使った（同じ定義でも始端・終端の箱の手描き風の path に乱数が入り byte が変わるため）。
  - オフラインの Chrome による確認: 6 図の切替、宛先の例の強調、詳細の図への移動、キーボード操作、拡大と全体表示、印刷時の 6 図表示、幅 390px で横にはみ出さないこと、直接リンク、JavaScript エラー 0、外部要求 0、参照 36 件、判定の箱・案内の箱の文言、端末内モデルの旧文言が残っていないこと。旧 HTML に同じ確認をかけると「向いていない」の行で失敗する。図の大きさ: 全体 716×1001.8（10 箱）、応答する条件 936.9×1160（11 箱）、返答と記憶 1178.0×809.4（9 箱）、待機・顔と首・読み上げは前回と同一。証跡は `/private/tmp/cat-issue30-haiku-20261109/task5-docs/`。生成器は作業用の複製で、リポジトリの依存にはしない。アプリの build・XCTest・実機はこの手順では実行していない。

## 全体検証（Task 5 Step 2）

Codex が実行した。文書候補 r3（compiled 入力は Task 4 の有料 r2 と同一）を固定し、プロジェクトの再生成 → generator の契約試験 → 再生成の byte 一致（生成 3 ファイル不変）→ `issue30_test` を引数なし（有料・実機の 4 クラス `SupertonicIntegrationDeviceTests` `RobotMotionIntegrationDeviceTests` `ClarificationHistoryModelTests` `HaikuAddressingModelTests` は skip のまま）の順。通常 suite は 1,045 件成功、失敗 0、skip 0、runtime warning 0（`task5-verification/full-1`、receipt SHA-256 `5f61f2eaf96a5637707a1d87ac24ebfcc133fc71c5d48e9cd1feaa21f322a785`、summary `f56f6c5ac4ada572ff9ac9cc353c5f612704f20792b37f04dc5f1cf561aa009b`）。実行前後で 304 入力（6 文書込み）の digest `ac6c1fee3cd64f2a8c74bdc9349035121f3adc6999e9b33818881570289cce4a` が一致し、件数は差分式 `1048 − 43 + 10 + 9 + 21 = 1045` と一致した。静的確認は `SystemLanguageModel` 0 件、許可外の SDK import 0 件、Markdown の相対リンク 120 件と HTML の参照リンク 36 件にリンク切れ 0（`static-and-links.json` SHA-256 `b239fca1c3a8ae2e2aa116237a039d5b2eb3f9b481a0f41b23401d6cb6dfe856`）。記録は `task5-verification/verification-r3.json`。この後の D3・D4 と結果欄の追記は文書だけの変更で compiled 入力を変えないため、Swift の全体試験は繰り返さず、入力の不変を照合する。

## 独立レビュー（Task 5 Step 3）

候補 HEAD `8ff85a32`、base `7913e157`、全差分 SHA-256 `a340f91e463604107b57f4d44544c6723ae38c2c7cb60625bfe277e71948c091` を固定し、互いの初回を見ずに保存してから交換した。

- Claude: `/simplify` を report-only（修正は適用しない）で 4 観点（reuse / simplification / efficiency / altitude）。各観点は履歴のない read-only の opus エージェント 1 つ。原本 4 本と統合版（SHA-256 `39034067c535f282ce5f2c33f2e4a5eec643f00aad3d089e1992a4d8636d7c31`）を `/private/tmp/cat-issue30-haiku-20261109/task5-review/claude/` に保存し、hash を `first-review-sha256.json` に記録した。統合版の所見は C1〜C19（Important 0。エージェントが Important とした A-1・A-2 は、実害の条件が示されていないため統合時に Minor へ下げ、その判断を統合版に明記した）。
- Codex: 履歴のない独立レビュアー 1 名（読み取りのみ、委譲なし）。原本 `task5-reviews/codex-first.md`（SHA-256 `7b1352b635282403f5ab6e7af4e9eebefa5b1b2a1908095500f5e70ca4964e14`）。所見は Important 1 件（I1）、Strengths 5 件、判断しない項目 3 件（実機の受入、通信上のモデル・effort・請求額・一般化、backend 中立化と記憶 adapter の分離）。

受領（双方 `superpowers:receiving-code-review`。要求を言い直し、HEAD の実装と照合してから採否を決めた）:

- Claude（`claude-reception.md`、SHA-256 `9b3915377b6f1cdc0c5f35edd6bf60a91a3926c02cd6fb8b924cfaf62f727641`）: I1 を採用（`SupertonicSentenceSpeaker` 36–62・60–90・216–227、`PCMPlayer` 38–44、`ConversationViewModel` 236–262・1333–1353・1405–1432 で機構を確認）。C3・C8・C11a・C16 の整理は 1 回の修正 pass を I1 だけに絞るという Codex の意見を採って延期。C17 は未計測の遅延として本記録に明記。
- Codex（`codex-reception.json`）: I1 を採用（RED で再現してから修正）。C1〜C19 はいずれも「現在の不具合を示していない整理」として延期（C17 は文書化）。理由は項目ごとに記録。
- 不採用: なし。延期分の行き先: 挙動を変えない整理の後続 issue。

I1 の内容: 手順 (4) の読み上げは、本番の話者では `speak` が 2 回の actor hop（文の送信と finish）を経てから `active` を登録する。その窓で一時停止・文字入力の置き換え・scene の inactive・shutdown が `speaker.stop()` を呼んでも、`preparation == nil && active == nil` で何もせず、`failureCleanupTask` は cancel されないので、合成と再生が遅れて始まり得た。窓は短いが実在し、spec の場面表「定型文の途中で一時停止・新しい会話・全削除・文字入力 → 止める」に反する。Claude の 4 観点は品質の読みで、この所有の取り消しと話者の開始窓の組み合わせは見落とした。

修正（Driver Codex、Navigator Claude。形 A: 読み上げだけを取り消せる子 Task にし、後始末の Task は取り消さない）:

- RED: `FakeSpeechSpeaker` に読み上げ開始の gate（`setSpeechStartGate`）と `speakStartCount` / `stopCompletedCount` を足し、`FailureGuidanceTests` に `testLifecycleEventsWhileGuidanceStartsNeverStartSpeechLate`（3 起点 × 5 の lifecycle 事象）と `testTypedReplacementWhileGuidanceStartsPreventsOldSpeech` を追加。修正前の VM（`8ff85a32` と同一 bytes）で 2 件とも失敗し、16 の assertion はすべて「遅れた speak の記録」だけだった（`task5-fix/red-1`、入力 SHA-256 `6b9c3ca4be57bd9a1eba55d8f06dc32ade3838eb6ced7451b75e1ecba2eee808`）。
- GREEN: `ConversationViewModel` に `failureSpeechTask` を追加。手順 (4) の `speak` と event ループを `@MainActor` の子 Task（`speakFailureGuidance`）へ移し、最初の await の前に登録する。一時停止の失敗分岐と文字入力の置き換えは `speaker.stop()` の前に子だけを cancel する。`failureCleanupTask` は cancel せず、子を待ってから手順 (5) の停止・解除・reset へ進む。子は開始前と各 event で所有と `Task.isCancelled` を確認し、エラーは握りつぶして元の結果を保つ。本番の話者では `speakSentences` の `Task.checkCancellation()`（62 行）から `active` の登録（90 行）まで suspension が無いので、cancel → stop の順を守れば窓は残らない。`docs/architecture.md` の「失敗の終了」(4) に追記した。
- 検証: 対象 12 クラス（計画の 11 と `SupertonicSentenceSpeakerTests`）176 件成功・失敗 0（`task5-fix/green-targeted-1`、入力 SHA-256 `04fd4d7dde5ae391cd9cfb9b0b49a988125b88128fe3395339c196e163769c89`、patch SHA-256 `30f882c0d37f7131ac40fb4377f1243de234875bfede3da625a74f5c4577186d`）。全 suite 1,047 件成功・失敗 0・skip 0・runtime warning 0（`task5-fix/green-full-1`、304 入力 `04fd4d7dde5ae391cd9cfb9b0b49a988125b88128fe3395339c196e163769c89` 前後一致、receipt SHA-256 `32c3a7fda89227372aaf61dd013e334f846da5b8bdd8ec4062b9f84db75d7908`、summary `f48c302f4269276221da4a50a3020b751eca127f2c0f5d2a50c3a9e53ac35b57`）。RED の試験と fake は bytes 不変。指示文・fixture・runner・保存形式は変えていないので、有料の受入（r2 69/69）は再実行していない。
- 同じ独立レビュアーによる I1 限定の確認: 修正候補 `a72e769a14d486893ebf32603e1ee0cb0fa5fc5b` で I1 の解消と、関連する Critical／Important が 0 件であることを確認した。確認原本は `task5-reviews/codex-I1-confirmation.md`、SHA-256 `02dd15d11199208a5b0f27f16ff5a59d23be2acf49a93ab7ab9a0c5625656f97`。元の初回は変更していない。コード・保存済み回帰試験の証拠に基づく確認で、実機の音声を観察した結果ではない。

C17（未計測の遅延）: 開始前の失敗では、案内のために話者の準備（TTS の初回読み込み）と audio session の有効化・解除が入るので、失敗の表示までの時間が延びる。承認済みの決定 (b)（開始前の失敗も声で案内する）から直接生じるもので、計測していない。実機の確認で体感を見る。

## 実機と統合（Task 5 Step 4）

利用者の原文「実装が完了した実機に入れてください。こちらでも確認します。」を受け、通常署名 Debug 版を登録済みの iPhone へ導入・起動した。今回の承認は導入と起動が対象で、main への squash と push は含まない。

- 導入したソースは HEAD `5b7413b4283be308463c98088da078264a380384`。通常署名 Debug build は成功し、`codesign --verify --deep --strict` も成功（`normal-device-build-final/receipt.json`、SHA-256 `e0def49bf33d2bc5d87dd7e5648d95bffb6ea8200b3dc510f6634996d17b64c1`）。sourceTag は `5b7413b4283be308463c98088da078264a380384-bd65267f0391330d` で、built Info と一致。304 入力の digest `bd65267f0391330dced08039856233b8e85a5165daf8c28439ace00d754aacb0` は build と導入・起動の前後で不変だった。
- 実機は Not so bad（iPhone 16 Pro、iOS 27.3、UDID `00008140-000610311A90801C`）。`devicectl` の install と通常 launch はともに成功し、bundle id は `com.kamby.CatRobot`、PID は 14625。直後のプロセス照会でも同じ PID が稼働し、executable が今回 install した app の場所と一致した。テスト host 用の環境変数は無い。
- 証跡は `normal-device-install/receipt.json`（SHA-256 `3693cdf357e8afa6f55ca9329d74c95bbbd819413e69d23cd1f24e6ee29c349d`）と `install.json`・`launch-2.json`・`processes.json`。最初の launch は開発ツールが空の環境変数辞書を受け付けず実行前に exit 64 となったが、子プロセスの環境上書きを除去した通常 launch 2 で成功した。両方の log を残す。

オンラインの会話、機内モードの案内（開始前と会話中、音声と文字入力）、案内中の一時停止と文字入力で遅れた声が出ないこと、日次上限の案内、設定の説明文という確認観点を利用者へ伝えた後、2026-11-09 に原文「問題なかったのでsquash と push の承認をします」を受領した。利用者は実機の受入に問題なしと回答し、main への squash と `origin main` への non-force push を承認済み（この記録時点では未実行）。個々の発話・操作の詳細ログは採取していない。feature branch の push と branch・worktree の削除は承認に含めず、行わない。

この導入記録の追記は文書だけの変更で、導入した app の compiled 入力は変えない。
