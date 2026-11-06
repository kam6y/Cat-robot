# issue #28 相互受領（Claude）: native-code-review-first.md

- 受領対象: `native-code-review-first.md` sha256 `ccf7c4caece3146650c9e2d1e1cfb273e89b60bbdd4a874500ff591650738832`（56行）。Claude の初回報告5件を保存・固定した後に初めて読んだ。
- 検証対象: candidate `07363aaae506ebe153b7580c7efbae7610e5ef46`（checkout HEAD 一致、`git status --short` 空）。読み取りは `git show 07363aaa:<path>` のみ。編集・テスト・エージェント実行なし。
- 手順: superpowers:receiving-code-review（読む → 言い換え → 実コード照合 → 評価 → 採否）。Claude の初回報告は変更しない。

## 1. Native Minor 1（html:45「別の発話」行の旧条件）

**採用。Claude C1 と同一の不具合（重複）。** 修正は squash 前に行う。

照合結果:
- `docs/application-flow.html:45` の確認待ち mini-row は「別の発話 → 顔が1人・こちら向きなら返答。そうでなければ再判定し、曖昧でも再度は聞き返さない」のまま。
- `CatRobot/Conversation/Domain/AddresseePolicy.swift:50` は確認待ち中の別発話を `isFacingScreen ? .accept(trimmed) : .classify(utterance)` で扱う。`isFacingScreen` は今回広げた `ConversationCamera.hasFreshFacingFace`（`ConversationCamera.swift:57-62`、人数条件なし）の結果。したがって複数人中1人以上の有効なこちら向きでも返答する。行の記述は誤り。
- 同じ HTML の顔向き note と描画済み SVG ノードは「1人以上」。古い記述はこの mini-row の1箇所だけ（HTML 全体で「顔が1人」を含む箇所を列挙して確認）。
- この行は `diagram-definitions` JSON には含まれない（JSON に「別の発話」なし）。修正対象は HTML 本文だけ。

修正文: Native 案「有効でこちら向きの顔が1人以上なら返答。」を採る。後半の「そうでなければ再判定し、曖昧でも再度は聞き返さない」は残す。yes/no の優先は上の2行が表しており変更しない。

重大度の差: Native は Minor、Claude C1 は Important。どちらも「squash 前に修正」で処置は同じなので、差は扱いに影響しない。

### C1 の文言の補正（初回報告は変更せず、ここで補う）

Claude C1 は「validation :40/:42 が全文言の整合を主張している」と書いた。正確には次のとおり。
- validation :42 が整合を主張しているのは README・要件表 FR-CONV-2・新設計・#22 設計への追記で、これは事実。
- validation :40 が主張しているのは描画済み条件の「1人以上」のブラウザ確認で、これも事実。
- どちらも mini-row の整合を字義どおりには主張していない。validation 側の本当の不具合は、今回の HTML 修正後に :40 と `diagram-verification.json` が古くなる点である（3節の条件4）。

### Native の「生成元を残すなら更新」への回答

C2 を dated snapshot で受ける場合、コミット済み HTML を正本とし、task-private の生成元は保守対象にしない。この行は JSON 外なので、HTML だけ直せば足りる。

## 2. Native のその他の記載

- Strengths・検証証跡は照合した範囲で事実と一致した。HTML sha256 `40000a65…`、`diagram-verification.json` の `htmlSha256`、`ConversationCamera.swift:57` の1行変更、`AddresseePolicy.swift:50` の経路を確認した。
- Native は C1 以外の新規指摘を出していない。Claude の C3〜C12 は統合報告の処置（C3/C5/C7/C10 は記録して後回し可、C4/C8/C9/C12 は記録または後回し、C6 と C11 は1行修正）のまま変えない。
- 「Ready to merge from code review: Yes」「Ready to complete integration now: No」に同意する。残ゲートは5節。

## 3. Codex の C2 受領案（dated snapshot）の技術評価

**条件付きで採用。** Claude の統合報告は C2 の解決策として「生成元をコミットする」か「日付入り snapshot と宣言して索引もそう扱う」のどちらでもよいとしていた。Codex 案は後者で、利用者の要求が単体 HTML である点とも合う。現時点で継続的な generator を必須にしない判断に同意する。

照合した事実:
- HTML 冒頭に「2026.11.07 更新」「issue #28 対応版」がある。末尾に「issue #28対応時点のコードを要約した静的な図です。参照リンクはmainの最新コードです。変更時に図は自動更新されません。」がある。日付・静的・非自動更新の表示は既にある。
- `diagram-definitions` JSON は6図すべての Mermaid `source` と label・title・description・notes・refs を持つ。ページの操作スクリプトはこれを読まない（`blob`・`href`・`refs` を参照しない）。保管用の定義として残っている。確認待ち mini-row と例は JSON 外の手書き HTML である。
- `blob/main/...#L<n>` のリンクは31本、すべて HTML 本文にある。表示ラベルも31件が `path:N` 形式で行番号を見せている。設計文書へのリンクは無意味な `#L1`。
- JSON の `refs` も31件すべてが `[path, 行番号]` の組で、行番号を持つ。
- 索引は日付を持たない。`docs/README.md:51` は「アプリ全体の分岐図」、`README.md:10` も「アプリ全体の分岐図」。

C2 を閉じる条件:
1. **行番号を3箇所すべてで外す。** href の `#L<n>` 31本、表示ラベルの `:N` 31件（設計文書の `#L1` を含む）、JSON `refs` の行番号31件。JSON の行番号は削除を推奨する。残す場合は「図の時点の行番号で、現在の main とは一致しない」と明記する。操作スクリプトはリンクを解析しないので、外しても動作は変わらない。
2. **commit 固定リンクは採らない。** squash 後の SHA は文書修正を含むコミットができるまで存在しない。変更のないファイルだけ `b59f0b9d` に固定すると、リンクが2つの版に分かれる。ファイル単位の main リンクと日付表示の組み合わせが、最小で一貫した形である。
3. **末尾の文言を直す。** 「参照リンクはmainの最新コードです」を、図は 2026-11-07・issue #28 時点の内容であること、リンク先は最新 main のファイルで内容が変わっている場合があることを示す文に変える。`docs/README.md:51` と `README.md:10` のリンク文にも日付（または issue #28 版）を入れ、snapshot であることが索引から分かるようにする。
4. **検証記録を更新する。** HTML を直すと validation :40 の「図・CSS・操作スクリプトはその後変更していない」と `diagram-verification.json` の `htmlSha256` が古くなる。既存の項目 `browserCheckedHTMLSha256`・`postBrowserChanges`・`postBrowserAnchorOnlyProof` に合わせて次を記録する。
   - 新しい HTML sha256。
   - ブラウザ確認後の変更が、mini-row の文言・末尾の文言・href・表示ラベル・JSON refs だけであること。
   - 埋め込み SVG 6件の sha256 が `svg-node-manifest.json` と一致し、CSS とスクリプトのバイト列が変わっていないこと。
   - ブラウザ再確認をしたか。JS・CSS・SVG が変わらないなら「再確認なし」と書けば正直で十分。古い主張を残すのは不可。
   - validation :40 の文、必要なら :36 も新しい状態に合わせる。

C2 の小項目ごとの扱い:

| C2 の小項目 | Codex 案での扱い |
|---|---|
| 生成元が task-private | snapshot の判断として受け入れる残存リスク。validation :36 に Mermaid 12.3.0 と definitions の記録がある |
| ブラウザ確認後の編集 | 条件4で証跡を更新する |
| JSON が未使用・不完全 | 保管用の定義として受け入れる。mini-row と例が JSON 外であることは validation に1文あれば足りる（任意） |
| `#L` の行番号ずれ | 条件1で解消する |
| issue #28 表示なのに索引は現行扱い | 条件3で索引に日付を入れて解消する |

C2 の範囲外の注意: 利用者が今後も更新され続ける図を望む場合は、生成元をコミットする案が残る。今回はそれを要求しない。

## 4. 修正の分担と順序（HANDOFF 3 で Claude が Driver の場合）

1. html:45 の mini-row を修正する（C1／Native Minor 1）。
2. 行番号を外し、末尾の文言を直す（C2 条件1〜3）。`README.md:10` と `docs/README.md:51` のリンク文に日付を入れる。
3. validation :40（必要なら :36）と `diagram-verification.json` を更新する（C2 条件4）。新しい sha256 と SVG 6件の一致を記録する。
4. 任意: C11（30秒ルール note の重複文）と C6（UserDefaults の後始末）を同じ機会に直すかは Codex が決める。C6 はテストファイルの変更なので、実装入力 `4e99…` が変わり再テストが要る。文書だけで閉じるなら C6 は後回しにする。

C1 と C2 の修正は文書だけで、アプリの再ビルドと再テストは要らない（Native の判断と同じ）。実装入力 `4e99d6b4…` は変わらない。

## 5. 残ゲート

1. 2人での実機確認（人の QA、返答待ち）。
2. 上の文書修正と、その差分の確認。
3. 最新 main の確認、squash、通常署名版の実機確認、non-force push、issue のクローズ、文書の差分確認。

Native と Claude の両報告とも、これらのゲートを通過した証拠にはならない。
