# 2026-10-29 日本語の自然さを保つ読み上げ修復

利用者の指示でmain上に修正。実装・全体試験・実機の版は `f2367d5a2487dfa5fded96d0385d3d7a18fa1bc2`、基点は `7733e20`。[修正設計](../superpowers/specs/2026-10-29-natural-japanese-speech-repair-design.md)、[計画](../superpowers/plans/2026-10-29-natural-japanese-speech-repair.md)。高速化ブランチは取り込んでいない。

## 原因と採用した修正

前の改修は、日本語の既知区間も全文カタカナの発音表記にしていた。文字列が残ること、PCMが有限であること、再生完了イベントが来ることは、実際の全文の発音・自然さの保証ではない。前回はこの聴取確認が不足していた。

利用者はカタコト・漢字付近の読み飛ばしを報告。字幕が出ないため、明示承認後に端末の直近の返答をローカル診断用に取得した。固定の同じ文を、同じSupertonic/F1/8steps/CPU2threadsでA原文・B全文カナ・C英語名だけカナ化として生成。ブラウザの再生ページで本人が比較し「Cだけ自然だわ」と回答した。[比較の条件と回答](data/2026-10-29-natural-japanese-speech-repair/listener-comparison.json)。これは1例の聴取結果であり、全文章・全声の品質保証ではない。

修正後は日本語・数字・助詞・句読点を原表記で渡し、既知のASCII/全角Latin語と保護外の+だけを補正する。数字を含むLatin語（25cm/5G/iPhone15）は語全体で読む。未知語・アクセント・他script・互換文字が混ざる語は全体を保持し、既知の先頭だけを変えない。幅だけを畳み込み、URL・メール・コードは既存どおり保護する。Wi-Fiの辞書読み、C++、単独+、日本語の結合文字・半角濁点も保持した。

| 固定文 | 修正後の合成入力 |
|---|---|
| YouTubeを見よう。 | ユーチューブを見よう。 |
| +ボタンを押してね。 | プラスボタンを押してね。 |
| こんにちは。今日も一緒に遊ぼうね。 | 原文のまま |
| 辛いカレーが好きだよ。 | 原文のまま（辞書のツライ読みで固定しない） |
| 3人で25個を分けるよ。 | 原文のまま |

声・モデル・速度・steps・CPU並列数・文分割・先読み・再生順・記憶・利用者設定は変更していない。[最終native出力が利用者選択Cの入力と一致する確認](data/2026-10-29-natural-japanese-speech-repair/candidate-matches-selected-C.json)。私的な履歴・元の診断文・その比較音声はGitに入れていない。

## 検証

| 対象 | 結果 |
|---|---|
| Native実辞書/C ABI | 22成功（読み18/FFI4）、失敗0 |
| Swift実辞書/speakerの先行確認 | 17成功 |
| 最終Swift全体 | 848件、846成功、実機専用2skip、失敗0 |
| Python資産・検証スクリプト | 17成功 |
| nativeパッケージ | iPhone arm64、Simulator arm64/x86_64再生成、辞書/ソース/ライブラリreceipt検査成功 |
| project生成契約 | 以前のmainで成功したものを再利用。generator・契約試験・projectの3ファイルのhashが不変で、membership変更なし |
| 署名実機試験 | 1成功、skip/失敗0。固定8組16WAVと本番speaker、9記録すべて成功 |
| 通常起動 | テスト用SUPER環境変数なしで再起動、PID2273確認 |

nativeの新しい3ケースを追加して修正前に失敗を確認し、Swift→実辞書経路も1テスト4assertionの失敗を確認した。Claudeの半角濁点境界の指摘は専用テストで失敗を見てから修正。独立レビューのUnicode内部ハイフン/アポストロフィによる部分変換もRED→GREENにした。修正途中の全体試験は既知のレビュー修正前だったため中断し、合格に数えていない。最終版で全体試験を通した。

実機の受領入力は `｢プラスボタン｣でユーチューブを開くよ。`。前面state0で再生完了。原文は `｢+ボタン｣でYouTubeを開くよ。` のまま保持。[固定入力とイベント](data/2026-10-29-natural-japanese-speech-repair/device-results.json)、[実機結果](data/2026-10-29-natural-japanese-speech-repair/device-test-summary.json)、[音声hash](data/2026-10-29-natural-japanese-speech-repair/device-audio-hashes.json)。音声本体はローカル診断領域だけにある。

[262ソースhash](data/2026-10-29-natural-japanese-speech-repair/source-hashes.json)は全体試験から実機まで一致。[nativeビルドreceipt](data/2026-10-29-natural-japanese-speech-repair/native-build-receipt.json)、[全体試験結果](data/2026-10-29-natural-japanese-speech-repair/swift-full-summary.json)、[通常起動の確認](data/2026-10-29-natural-japanese-speech-repair/normal-launch-check.json)、[検証集約](data/2026-10-29-natural-japanese-speech-repair/verification.json)。以降の変更は文書だけなので、同じ全体試験を繰り返していない。

## agmsg pairとレビュー受領

agmsgのClaudeとLatin対象の範囲、数字だけの保持、語内数字の例外、変換前のホワイトリスト、幅だけのfold、結合文字・他script・半角濁点・Wi-Fi・上限検査を相談し、実装へ反映した。最終差分のpair確認でも新しいblockingは無し。[Claudeの相談/最終確認](data/2026-10-29-natural-japanese-speech-repair/claude-pair-review.md)。Rootが全編集・build・testを担当。

[独立レビュー](data/2026-10-29-natural-japanese-speech-repair/independent-review.md)はImportant1件（Unicode内部連結文字）を指摘。根拠を確認し、走査だけに連結文字を追加して変換許可文字は増やさず、引用符と+を巻き込まない開始条件を合わせて修正した。全22native/848Swift試験で検証。再レビューを重ねていない。

軽微な保留は、辞書語だけの展開を上限直前で試す追加ケース（共有する出力guardを実際の+展開で検証済み）と、未知のドット複合語を部分ごとに補正する追加fallback。後者は語全体保持の契約を優先して採らなかった。実辞書比較ではMr.Children/No.1は全体の辞書読みになり、Dr.STONE/Lv.5は原表記に戻り、YouTube’sは前後とも原表記だった。[比較](data/2026-10-29-natural-japanese-speech-repair/compound-word-comparison.txt)。すべての外来語の読みは保証しない。

[全受領評価・判断と代償](data/2026-10-29-natural-japanese-speech-repair/review-reception.md)、[実行記録](data/2026-10-29-natural-japanese-speech-repair/execution-ledger.md)。

## 残る制約

- モデルのunicode indexerに無い漢字を含む文は、既存の入力guardで合成失敗になる。全文カナ化時には読みへ置き換わっていた一部の漢字も、原文保持ではこの制約を受ける。未対応漢字だけを読む追加機能やモデルの交換は今回していない。
- 既存のSupertonic側のNFKD・絵文字除去・記号処理は同じ。frontendで原表記を保つことは、モデル前処理まで全文字が保たれる保証ではない。♪等の未対応記号や新しいURL/markup構文も別の制約として残る。
- 1例のC選択と実機の固定文再生以外の全文章/全声の聴取、音響遅延、長時間品質は未確認。
- 高速化ブランチは未マージ。将来この修正後mainへ載せ直すなら、正規化後16文字の意味が変わるため、候補上限と実機の性能基準を測り直す必要がある。
