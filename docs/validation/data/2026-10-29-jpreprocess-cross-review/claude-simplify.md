# claude /simplify レポート: jpreprocess 読み変換（READ-ONLY）

## 実施内容
- 対象
  - `feature/jpreprocess-pronunciation`、`def7573..eb41f9c`、作業ツリーは clean。
  - `git diff def7573..eb41f9c` の sha256 先頭は `25179dc57883` で、`baseline.diff` と一致した。
- 実行した手順
  - 実際に `/simplify` を実行し、内蔵の 4 席（reuse、simplification、efficiency、altitude）を同時に動かした。すべて model opus、読み取り専用。
  - 4 席には、ライセンス本文・Cargo.lock・pbxproj を除いた差分（3763 行）と、現 HEAD のファイルを読ませた。過去のレポートは読ませていない。
  - 統合の段階で、指摘を claude が自分で確かめた。根拠は次の 3 種類。
    - git・grep・ソースの読み取り
    - 既存の probe（前回作った 17810a1 版。`convert_run` の判定は HEAD と同じで、違うのは区切りの一覧だけ）
    - cargo レジストリのソース
- してないこと
  - 編集、commit、Xcode、cargo build・test は一切していない。
  - `/simplify` の Phase 2（修正の適用）は、指示に従って行っていない。以下の指摘はすべて提案である。
- 「動作変更」の欄の意味: 製品の出力・契約が変わるかどうか。守る契約は、原文保護、取消、上限、旧処理へ戻さないこと、辞書を 1 回だけ読むことである。

## 優先度の高いもの

### S1（High、運用。ビルドが壊れるおそれ）: native の receipt が crate 内の `target/` まで数える
- 場所
  - `scripts/validate_jpreprocess_assets.py:44-50`: `native_sources()` が `native/japanese-pronunciation` の下を `rglob("*")` で全部たどり、拡張子 `.rs/.toml/.lock/.h/.modulemap` のファイルを集める。
  - `native/japanese-pronunciation/README.md:18`: ホスト用テストのコマンドが `CARGO_TARGET_DIR` を指定していない。
- 根拠
  - 上のコマンドをそのまま実行すると、crate の中に `target/` ができる。
  - `.gitignore` に target はない。`git check-ignore -v native/japanese-pronunciation/target/debug/x.rs` の exit は 1 だった。
  - build.rs は `target/debug/build/*/out/private.rs` を作る。codex の target に `serde_core`・`serde`・`thiserror` の実物があるのを確認した。
- 影響（推論。ビルドは実行していない）
  - 開発者が README どおりにテストを走らせると、`sourceFiles` が receipt と一致しなくなる。
  - その結果、通常の Xcode ビルドが「jpreprocess source changed」で止まる。
  - さらに、未追跡の巨大な `target/` が `git add -A` に入るおそれがある。
- 修正案（どれも小さい）
  - (a) `native_sources()` を `git ls-files native/japanese-pronunciation` の集合にするか、`target` を除外する。
  - (b) README のコマンドに `CARGO_TARGET_DIR=.build/jpreprocess-host` を付ける（`.build/` は無視される）。
  - (c) `.gitignore` に `native/japanese-pronunciation/target/` を追加する。
- 動作変更: なし（ビルドの検査だけ）。
- 指摘した席: efficiency。claude が確認した。correctness の性格が強いので、codex のレビュー席にも共有済み。

### S2（Medium）: 区切り文字の一覧が足りず、全角や引用符の表記揺れで P2 と同じ「区間全体が原文に戻る」が残る
- 場所: `native/japanese-pronunciation/src/lib.rs:215-268`（`is_separator`）。
- 根拠: 既存の probe で確認した。これらの文字は HEAD の一覧にも入っていない。
  - `“YouTube”を見よう` → 原文のまま。NJD は `“` と `”` を pron `、`、mora 0 にする。
  - `［YouTube］を見よう` → 原文のまま。
  - `YouTube—見よう` → 原文のまま。`—` は mora 0。
  - 一覧には ASCII の `[ ] { } "` があるのに、全角の `［ ］ ｛ ｝ ＂`、`“ ” ‘ ’`、`— ―` がない。
- 影響
  - Claude の返答は `“…”` や `—` をよく使う。そういう文では YouTube・`+`・数の変換がまた効かなくなる。
  - 以前より悪くなる（退行）わけではないが、P2 の修正が不完全である。
- 修正案（上から順に推奨）
  - (a) 一覧を `const SEPARATORS: &str` にし（S7 と統合）、`“”‘’［］｛｝＂—―` を足す。
  - (b) 一覧が今後また足りなくなるのを防ぐため、辞書を使うテストを足す。Unicode の P*・S* の 1 文字を単独で NJD にかけ、mora 0 の記号の 1 ノードになるものは、一覧か明示した除外表のどちらかに必ず入っていることを確かめる。絵文字は除外する。
  - (c) 負債として記録する: NJD の mora 0 の記号ノードの位置で区間を分ける。NFC・alias・`+`・正規化を経た位置を原文の位置へ戻す必要があり、費用が高い。
  - 採らない案: Unicode の分類だけで区切ること。ZWJ でつながった絵文字や、読めている `%`・`-`・`/` まで分割してしまう。
- 動作変更: あり。該当する入力の出力が変わる（改善の方向）。
- 指摘した席: altitude。claude が probe で確認した。

### S3（Medium、効率）: 辞書は mmap されず、ヒープにコピーされる
- 場所: `lib.rs:35-38`。
- 根拠
  - `SystemDictionaryConfig::File(..).load()` → lindera-dictionary 3.0.7 の `Dictionary::load_from_path` → `load_from_path_with_options(path, false)`（`dictionary.rs:83-84`）。
  - `jpreprocess` 0.15.0 の `lib.rs:164` が `Dictionary` を再 export しており、`load_from_path_with_options` は `dictionary.rs:88` にある。mmap feature は `cargo tree` で有効と確認済み。
- 影響
  - 実測: モデル準備前の footprint の差は +144.6 MiB（codex が Debug で 1 回計測）。
  - 推定（efficiency 席）: `dict.words`、`dict.vals`、`dict.wordsidx` の約 41 MiB が、アプリが動いている間ずっと dirty heap に乗る。
  - `dict.da` と `matrix.mtx` は、upstream が自分の Vec へコピーするので、mmap にしても減らない。
- 修正案: `jpreprocess::Dictionary::load_from_path_with_options(path, true)` で辞書を読み、`JPreprocess::with_dictionaries(d, None)` に渡す。新しい依存は要らない。変更後に実機で footprint を測り直す。
- 動作変更: なし（同じバイト列で、読むのは 1 回のまま）。
- 指摘した席: efficiency。claude が API の存在を確認した。

## 中〜低（構造の簡素化）

### S4（Low-Medium）: 「1 語の既知語かどうか」の照会が 2 か所に書かれている
- 場所: `lib.rs:98-108`（`verbalize_plus`）と `:156-168`（Latin 語の再照会）。
- 中身: どちらも `text_to_njd` → `nodes.len()==1` → 表層の一致 → `mora_size()>0` の順に確かめる。約 15 行が重複している。
- 修正案: `fn known_single_word(&self, text, expected_surface) -> Result<Option<Node>, Error>` を作る。比較の形が違うので、表層は引数で渡す（一方は `normalize_text_for_naist_jdic(word)`、他方は `node.get_string()`）。
- 動作変更: なし。
- 指摘した席: simplification、reuse、altitude。

### S5（Low-Medium）: alias の名前が、正規表現と match の 2 か所にある
- 場所: `lib.rs:25-27` と `:133-140`。
- 危険: match の最後が `_ => "Bluetooth"` なので、5 つ目の alias を正規表現にだけ足すと、その語が黙って「Bluetooth」として読まれる。
- 修正案: `const ALIASES = ["YouTuber","YouTube","iPhone","Bluetooth"]` から正規表現を作り、置換は `eq_ignore_ascii_case` で探す。
- 動作変更: なし。
- 指摘した席: simplification。

### S6（Low）: speaker の `normalize` closure が、エラーを手で `speechSynthesisFailed` に変えている
- 場所: `SupertonicSentenceSpeaker.swift:29-32`。
- 中身: 2 行上の `prepare` は、同じサービスのエラーを `SupertonicErrorMapper.map` で変えている。`map` は SupertonicError 以外を `speechSynthesisFailed` にするので、結果は同じである。
- 修正案: `catch { throw SupertonicErrorMapper.map(error) }` にそろえる。あるいは、取消とその他を振り分ける共通の wrapper を、prepare・normalize・synthesize の 3 か所で使う。
- 動作変更: なし。旧処理へは戻らないまま。
- 指摘した席: reuse、simplification。

### S7（Low）: `is_separator` が 55 行の `matches!`
- 場所: `lib.rs:215-269`。
- 修正案: `const SEPARATORS: &str = "…";` と `c.is_whitespace() || SEPARATORS.contains(c)`。S2 の追加と同時に行う。テスト側の独立した一覧（`tests/pronunciation.rs`）は残す。独立しているからこそ、誤って消した記号を検出できる。
- 動作変更: なし。

### S8（Low）: `convert_plain` で、隣が数字かどうかを 2 種類の書き方で調べている
- 場所: `lib.rs:72-79`。
- 中身: `Vec<(usize,char)>`（1 文字 16B）と添字の計算を使う箇所と、`grouped` のスライスを使う箇所がある。
- 修正案: `char_indices()` で 1 つ前の文字を持ち、次の文字はスライスで覗く形にそろえる。
- 動作変更: なし。

### S9（Low）: `verbalize_plus` が同じ置換を 3 回書き、常に新しい文字列を作る
- 場所: `lib.rs:90-117`。
- 修正案: 置換を局所の closure にまとめる。`+`・`＋` を含まない区間は `Cow::Borrowed` ですぐ返す（ほとんどの区間に `+` はない）。
- 動作変更: なし。

### S10（Low）: `’` を取り除くために 2 回 collect している
- 場所: `lib.rs:183-190`。
- 修正案: `result.retain(|c| c != '’')` にする。
- より深い案: `preprocess()` の後に `get_pron_mut().moras_mut()` で `is_voiced = true` にし、無声化の印を出所で消す。`Mora.is_voiced` が pub で、`moras_mut` があることは確認した。ただし、`to_pure_string` がこの値を見るかどうかは未確認である。
- 出力の許可文字の検査（`:191-197`）は、失敗を表に出すための guard なので残す。
- 動作変更: なし。

### S11（Low、任意）: 到達しない guard が 2 つある
- 場所
  - `JapanesePronunciationService.swift:43-44` の `guard case let .ready … else throw`。`prepare()` は、throw するか `.ready` にするかのどちらかである。
  - `lib.rs:56-58` の `!text.is_empty() && result.is_empty()`。区切りと保護区間はそのまま出力し、区間は kana か原文を返すので、成り立たない。
- 修正案: 前者は `pronouncer() throws -> NativePronouncer` にまとめる。取消を確かめる位置はそのままにする。後者は「消さない」ことを明示する guard として残してもよい。
- 動作変更: なし。

### S12（Low）: 上限の数値がいくつもの場所に書かれている
- 中身: `32_768` は Swift の `:41`、`ffi.rs:59`、`lib.rs:9`、ヘッダのコメントにある。`2_000` は Swift の 2 か所と `SupertonicEngine.swift:57` にある。
- 修正案: 名前付きの定数にする。ヘッダに `#define` を置いて Swift から読めるかどうかは未確認。
- Swift 側の検査は消さない。
  - `NativePronouncer` は、0 以外の status をすべて `.conversionFailed` にしている。
  - テストの `:63-65` は `.invalidInput` を確かめている。
  - Swift で先に検査するので、辞書を読む前に不正な入力を拒否できる。
  - altitude 席は「status 1 を `.invalidInput` に変え、Swift の検査を消す」案を出した。しかしそうすると、拒否より先に辞書を読むようになるので、採らない。
- 動作変更: 定数にするだけならなし。

## 低（テスト・スクリプト・試験ホスト）

### S13（Low、テストのみ）: テストの雛形が重複している
- 中身
  - `prepare: {}, normalize: { $0 }` が 15 か所ある（grep で 15 を確認）。
  - `ControlledPronunciation`（`SupertonicSentenceSpeakerTests.swift:270-283`）は、既存の `ConversationTestGate`（`ConversationFakes.swift:182`）と同じことをしている。
  - Rust のテストで、表を回すループが約 7 回ある。
  - `JapanesePronunciationServiceTests` は辞書を 3 回フルに読む（推定で 1 回 60ms、約 80MB）。
- 修正案
  - テスト target の中だけで使う convenience init を作る。製品の init に既定値を足すと、黙って恒等変換に戻る経路ができるので、それはしない。
  - Gate を使い回す。
  - `assert_reads` という helper を作る。
  - 正常系のテストでは、1 つのインスタンスを共有する。
- 動作変更: なし。

### S14（Low）: `generate_project.rb:141-146` が Supertonic の検査 phase と同じ形をしている
- 中身: 新しい phase の `input_paths` には `prepare_supertonic_assets.py` がない。この file は `validate_jpreprocess_assets.py:9` が import しているのに、Supertonic の `:125` には入っている。
- 修正案: `add_asset_validation_phase(name, script, inputs)` という helper を作り、入力を正しく並べる。
- 効率の補足: 毎回のビルドで約 192MiB をハッシュし直す。Mac の warm 状態で 0.16〜0.30 秒（efficiency 席の実測）。Supertonic と同じ方針なので、このままでよい。
- 動作変更: なし（`always_out_of_date` のため）。

### S15（Low）: `build_jpreprocess.sh:39-47` の Python heredoc は `rm -rf "$target" && mv "$src" "$asset_root/"` で足りる
- PYARCH（`:27-34`）は、実際の `lipo` のスライスを検査している。`validate_framework` が見るのは Info.plist だけなので、PYARCH は残す。
- 動作変更: なし。

### S16（Low）: 実機テストの `writeWAV` が、PCMPlayer のバッファを埋める処理と重複している
- 場所: `SupertonicIntegrationDeviceTests.swift:177-183` と `PCMPlayer.swift:21-25`。
- 修正案: `SpeechPCM.makeBuffer()` という extension を作る。ただし製品の file にも触ることになり、価値は小さい（任意）。

### S17（Low、任意）: `CatRobotApp.swift:9-19` の DEBUG と環境変数の分岐
- 簡素化: `.live()` が 2 回書かれているので、`composition = isSpeechTrialHost ? nil : .live()` にまとめる。
- altitude の観点
  - 本当の原因は、計測対象が `JapanesePronunciationService.shared` であることである。
  - 試験の中で新しい `JapanesePronunciationService(root:)` を測るか、speaker にサービスを注入できるようにすれば、アプリの分岐は要らなくなる。
  - ただし、この分岐には音声を隔離する目的もあった。`review-reception.md:22` では、その仮説は証明されていない。
  - 今回は変えず、負債として記録するのがよい。
- 動作変更: 製品はなし。実機試験への影響は不明。

### S18（Low、任意）: 実機の記録が、冷えた状態の値を 3 回持っている
- 場所: `SupertonicIntegrationDeviceTests.swift:165-167`。
- 中身: 各 record に、冷えた状態の秒数・前・後の値が繰り返し入る。
- 修正案: 上位の `pronunciationPreparation` だけにする。ただし `results.json` の形が変わり、validation の文書が参照しているので、今回は見送ってよい。

### S19（Low）: 辞書の bundle の場所が 3 か所で計算されている
- 場所: `JapanesePronunciationService.swift:13-14`、`CatRobot/App/ConversationComposition.swift:69`、テストの `:6`。
- 修正案: `static let bundledDictionaryURL` を作って共有する。
- 動作変更: なし。

## 確認して採らなかったもの（理由）
- **N1: 辞書の prepare とモデルの prepare を並列にする**（efficiency の 4 番）
  - 1 プロセスにつき 60ms 縮む。
  - しかし ONNX と辞書の読み込みが重なり、メモリの山が高くなる。モデルが失敗しても辞書を読み終えてしまう。採らない。
- **N2: 未知の kana の語が mora 0 になり、区間全体が原文に戻る**（altitude の 1 番）
  - `ザズゾゾ` は 1 文字ずつ mora>0 で読まれ、`ぴよぴよりん` は既知語だった。再現しなかった。
  - RED が作れないかぎり変えない。
- **N3: Unicode の分類で区切る** → S2 の「採らない案」のとおり。
- **N4: alias をやめて大文字小文字を無視して照会する**
  - lindera に大文字小文字を無視する照会はない。
  - 大文字・小文字の組み合わせを試し直しても、すべて大文字の入力から `iPhone`・`YouTube` には戻せない。
  - 今の alias を残す。
- **N5: 濁点の前検査と、区間全体を原文に戻す仕組み** → spec 規則 5 と、upstream で文字が失われる唯一の経路への対策なので、残す。
- **N6: Swift の 32KiB と NUL の検査を消す** → S12 のとおり、エラーの種類と、辞書を読む前に拒否する順序が変わるので、残す。
- **N7: Latin の再照会を、早期に返す判定より前に省く**（efficiency の 5 番）→ μs 単位の差で、エラーの扱いがわずかに変わるので、見送り。
- **N8: `Array(original.utf8)` のコピーをやめて `withUTF8` にする**（efficiency の 8 番）→ 先読みで隠れる μs 単位の差なので、任意。

## まとめ（推奨順）
1. S1（receipt と target/）。小さく、確実に効く。
2. S2 と S7（区切り一覧の補完、一覧の定数化、取りこぼしを防ぐ走査テスト）。
3. S3（mmap にして実機で測り直す）。
4. S4・S5・S6（共通の helper と、取り違えを防ぐ形）。
5. それ以外（S8〜S19）は任意。今回の整理範囲に入れるかは、root の判断に委ねる。
