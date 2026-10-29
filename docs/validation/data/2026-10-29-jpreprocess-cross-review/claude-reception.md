# claude の受領評価: codex-review.md（superpowers:receiving-code-review）

## 前提
- 進め方
  - skill `superpowers:receiving-code-review` を実際に呼んで評価した。
  - 対象は HEAD `eb41f9c`。作業ツリーは clean で、repo の編集・build・Xcode はしていない。
  - claude-simplify.md（sha256 先頭 `ff862c346b60`）は送った後に凍結し、この評価では変えていない。
- 判定の種類: 採用、一部採用、却下、保留、追加の証拠が必要。
- 確認の方法: 各指摘を、現 HEAD のソースと手元の再現で確かめた。
- 再現に使った probe
  - repo の crate のコピーを build したもの。
  - 区切り文字の一覧（`is_separator`）は、HEAD と `diff` で完全一致を確認した。
  - `+` の扱いは HEAD と違う（コピーは案 (a)、HEAD は案 (b)）。ただし以下の入力の `+` はどれも単独なので、どちらの版でも「プラス」になる。

## Strengths
- 採用。すべて確認した。
  - 停止の確認が変換の前後にある（`SupertonicSentenceSpeaker.swift:96-100`）。
  - 失敗しても旧処理で合成しない。
  - 準備の失敗は、その状態を保持する（`JapanesePronunciationService.swift:26-36`）。
  - 展開後の上限は、1000 文字と 1001 文字の境界で実際に試している（`JapanesePronunciationServiceTests.swift:67-69`）。
  - 資産の receipt とハッシュによる検査がある。

## R1（Important）: 半角の `｡ ､ ｢ ｣` で、その区間の補正が丸ごと効かなくなる
- **判定: 採用。重要度も Important に同意する。私の S2 と統合して直すのがよい。**
- **確認（独自に再現）**
  - `+ボタンを押してね｡` → 原文のまま
  - `｢+ボタン｣` → 原文のまま
  - `YouTube､Bluetooth` → 原文のまま
  - 対照: `「+ボタン」` → `「プラスボタン」`
  - 原因: `lib.rs:215-268` の一覧には全角の `。、「」` しかなく、半角の `｡､｢｣` がない。その文字が NJD で mora 0 になり、`:170-178` で区間全体が原文に戻る。
- **重要度が妥当な理由**
  - 半角の句読点を LLM が出す頻度は高くない、と推測する。
  - ただし旧処理と比べた退行がはっきりある。旧処理は、正規表現の語の境界さえ合えば、隣の記号に関係なく置換した。
    - 例: `iPhone｡` → 旧処理は `アイフォーン｡`。現 HEAD は `iPhone｡` のまま（再現済み）。
  - 修正は小さいので、Important のままでよい。
  - 参考: `iPhone😊` も原文のまま残る（再現済み）。ただし絵文字を含む区間を丸ごと残すことは spec が許容しているので、今回の範囲外とする。
- **S2 との関係**
  - 同じ仕組み、つまり区切り文字の一覧が足りないことから起きる別の例である。
  - S2 で見つけたのは `“ ” ［ ］ —`。R1 で見つかったのは `｡ ､ ｢ ｣`。
  - 1 文字ずつ足していくと、また別の取りこぼしが出る。
- **推奨する修正範囲**
  - (1) 一覧に `｡ ､ ｢ ｣`（R1）と `“ ” ‘ ’ ［ ］ ｛ ｝ ＂ — ―`（S2）を足す。元の記号は、正規化せずそのまま残す。
  - (2) R1 の 3 例と S2 の 3 例を、実辞書の assertion として足す。
  - (3) 取りこぼしを防ぐ走査テストを足す（S2 の (b)）。Unicode の P*・S* の 1 文字を単独で NJD にかけ、mora 0 の記号になるものは、一覧か明示した除外表に必ず入っていることを確かめる。
    - 絵文字・変体記号は除外表に入れる。
    - これで今後の取りこぼしを、テストの失敗として検出できる。
    - 費用は小さい: 前回の走査では、約 16,000 文字が 1 秒未満で終わった。
- 動作変更: 該当する入力の出力が変わる（改善の方向）。原文保護・未知語の原文保持・上限・取消の契約は変えない。

## R2（Minor）: source receipt が Cargo の生成物まで数える
- **判定: 採用。私の S1 と同じ問題である。重要度は codex の Minor に寄せ、私の S1 を High から Medium に下げる。**
- **確認**
  - `scripts/validate_jpreprocess_assets.py:44-50` の `rglob("*")` は、`target/` を除外していない。
  - `native/japanese-pronunciation/README.md:18` のコマンドは、`CARGO_TARGET_DIR` を指定していない。
  - `.gitignore` に target はない（`git check-ignore` の exit は 1）。
  - codex は、隔離した fixture で receipt の検査が失敗することまで再現した。私の S1 は推論止まりだったので、codex の証拠の方が強い。
- **重要度を見直した理由**
  - 検査は失敗した側に止まり（fail-closed）、出荷する音声には影響しない。この点は codex の評価が正しい。
  - 一方で、私が Medium（Minor より上）とする理由が 2 つある。
    - 案内どおりに `build_jpreprocess.sh` を再実行すると、そのときの `target/` の中身が新しい receipt に入る。その後また cargo を動かすと、また一致しなくなる。原因の分かりにくい繰り返しになる。
    - `target/` が無視されていないので、`git add -A` で巨大な生成物が混入する危険がある。
- **推奨する修正範囲**（codex の案と同じ）
  - (1) `native_sources()` が数えるのを、明示した入力（`src`、`tests`、`include`、`Cargo.toml`、`Cargo.lock`、`rust-toolchain.toml`、`build_jpreprocess.sh`）に限る。`git ls-files` の集合を使ってもよい。
  - (2) fixture の assertion を足す: `target/**/out/*.rs` を追加しても、source のハッシュが変わらないこと。
  - (3) README のコマンドに `CARGO_TARGET_DIR=…/.build/…` を付けるか、`.gitignore` に `native/japanese-pronunciation/target/` を加える。どちらも小さい変更である。
- 動作変更: なし（ビルド時の検査だけ）。

## Validation and coverage assessment
- 採用。49 ファイルのハッシュの一致と、29 ファイルの tested source の一致は、codex の照合による。
- 847・16・7 という件数は、以前の実行の記録を確認したものであり、今回テストを走らせたものではない。この区別も正しい。
- 私の側でも HEAD `eb41f9c` が clean であることを確認した。

## Recommendations
- 採用。R1 は小さな区切りの追加と回帰テストで直し、R2 は別に直す。新しい fallback・文法処理・辞書・エンジンを足さない、という方針にも同意する。
- 一点だけ足したい: R1 の修正には、S2 の (3) 走査テストを含めるのがよい。そうしないと、同じ種類の取りこぼしが残る。

## Declined to judge
- 次の 4 つは、どれも同意する。
  - 聴いての評価: 未聴取なので判断しない。
  - 時刻・同音異義: spec が保証の範囲外としている。
  - 未知語・絵文字を含む区間の扱い: 区間全体の原文保持を spec が許容している。
  - URL の後ろに続く日本語: 旧処理から引き継いだ制約である。
- mmap・性能保証: 同意する。
  - 私の S3 も、効果を断定していない。API の存在（jpreprocess 0.15.0 の `lib.rs:164` の再 export と、lindera-dictionary の `dictionary.rs:88`）を確かめ、効果は推定だと明記した。
  - 採るかどうかは、コード変更と実機での再計測で決めることに同意する。
- ライセンスの法的監査: 範囲外とすることに同意する。

## Assessment
- 「With fixes」に同意する。
  - 必須: R1 と S2 の区切り文字の修正、走査テスト。
  - 小さい修正: R2 と S1。
  - 任意: S3 以降は、root の統合判断に委ねる。
