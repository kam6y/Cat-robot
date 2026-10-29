# jpreprocess 相互レビューと整理

2026-10-29 JST。対象 `feature/jpreprocess-pronunciation`、初回レビュー範囲 `def7573..eb41f9c`。この記録の整理は `eb41f9c` に対する未コミット差分で、最終ソースは [source-hashes.json](data/2026-10-29-jpreprocess-cross-review/source-hashes.json) に固定した。以前の [初回統合の検証](2026-10-28-jpreprocess-pronunciation.md) の数値・音声・PID・source hashは上書きしていない。

## 実施した相互レビュー

1. Claudeで実際の `/simplify` を実行し、内蔵の4席（reuse、simplification、efficiency、altitude）が読み取りで確認した。
2. Codexは `requesting-code-review` の新しいsubagentへ、同じ確定版を独立レビューとして渡した。
3. 両方の初回レポートが揃ってから互いへ渡し、双方が `receiving-code-review` を使って根拠と採否を検証した。
4. Rootが全指摘を統合し、採用範囲を決定した後だけ編集した。最後に同じCodex席が変更差分だけを確認し、重要な残件なしと判断した。

[Claude /simplify](data/2026-10-29-jpreprocess-cross-review/claude-simplify.md)、[Codex初回](data/2026-10-29-jpreprocess-cross-review/codex-review.md)、[Claudeの受領評価](data/2026-10-29-jpreprocess-cross-review/claude-reception.md)、[Codexの受領評価](data/2026-10-29-jpreprocess-cross-review/codex-reception.md)、[Rootの全採否](data/2026-10-29-jpreprocess-cross-review/root-reception.md)、[最終の差分確認](data/2026-10-29-jpreprocess-cross-review/final-delta-review.md) を保存した。初回レポートの行番号・判断は初回の確定版に対する記録である。

## 修正と整理

- **R1/S2/S7:** 半角 `｡､｢｣`、全角括弧・引用符・ダッシュなど15種の表記揺れが、区間全体の補正を無効にしていた。元の記号を保持する境界へ加え、一覧を定数にまとめた。具体的な8文と、独立した24文字の幅/引用符の系列で実辞書の回帰テストを固定した。
- **R2/S1:** Cargoの生成物 `target/**/out/*.rs` がsource receiptに入り、案内どおりのホストテスト後にXcodeが誤って古いソースと判定する問題を修正した。実入力を明示し、生成物は除外した。新しい未追跡の実ソースは引き続き検出する。出力先をREADMEへ明示し、crateのtargetをGit対象から外した。
- **S3:** 同じ固定辞書を、公開APIによる読み取り専用mmapで読む。1インスタンスを保持する契約は同じ。利用中の辞書ファイルを書き換えない前提をREADME・Cヘッダーに明記した。署名アプリでは元から不変のbundle資源を使う。
- **S4/S5/S6/S10:** 一語の既知語判定を公開型NJDのhelperへまとめ、aliasは同じ4語の単一表から正規表現を作る。想定外のcaptureをBluetoothへ変えるcatchallをなくした。既存エラーマッパーを再利用し、生成した無声化記号だけをretainで除く。
- **S13一部:** 取消テストの専用gateを既存のConversationTestGateへ統一した。変換は解除するまで取消に協力せず、post-awaitの取消確認を検査する全assertionを保っている。

原文保護、未知語保持、結合文字・絵文字、入力/展開後上限、初期化失敗の固定、旧処理へ戻さない方針、取消の位置を維持した。型を名前付けするための新しい依存、汎用Unicode分類による分割、文法解析、余分なconcurrencyは追加していない。任意案S8以降やN1〜N8の採否は上の [Rootの全採否](data/2026-10-29-jpreprocess-cross-review/root-reception.md) を参照。

S19は、Bundle資源ルートの式が3か所にある点は事実だが、辞書URLは2か所で、CompositionはSupertonicを作るために使う。用途の差と独立したテストoracleを優先し、共通化は採らなかった。

## 検証

| 対象 | 結果 |
|---|---|
| 半角句読点・引用符の回帰 | 修正前に意図した失敗を確認し、修正後に成功 |
| 生成targetのreceipt誤検出 | 修正前に意図した失敗を確認し、修正後に成功。新しい実ソース/変更バイナリの拒否は維持 |
| native・実辞書/C ABI | 17件合格（読み13、FFI 4） |
| Python資産検査 | 8件合格 |
| native package | arm64 iPhone、arm64/x86_64 Simulatorを再生成、hash/receipt検査成功 |
| プロジェクト | xcodeproj 1.27.0の生成・決定性/契約検査成功 |
| Swift全体 | 847件中845件合格、実機専用2件skip、失敗0 |
| iPhone 16 Pro / iOS 27.2 | 専用試験1件合格、8組16WAV生成、本番speaker再生完了 |
| 通常起動 | 同じ署名アプリを通常環境へ戻し、process PID 3499確認 |

最終29ソースhashは全体テスト・実機実行の前後で一致。通常のモデル・F1既定・8推論steps・1件の推論/1文先読みは同じ。実機の本番再生に `｢+ボタン｣でYouTubeを開くよ。` を使い、`｢プラスボタン｣デユーチューブヲヒラクヨ。` が合成へ渡って再生完了した。前面化は既存テストプロセスを終了せず `devicectl --activate` で行った。

## mmapの測定（単回のDebug観測）

同じ端末、同じ固定辞書と8文、モデル準備前の段階で比較した。ファイルキャッシュ状態は固定していない。

| 項目 | 初回統合版・heap | 今回・mmap |
|---|---:|---:|
| 初回辞書準備 | 60.0 ms | 47.8 ms |
| 準備前後のprocess footprint差 | 151,601,296 bytes（144.6 MiB） | 74,350,712 bytes（70.9 MiB） |
| 8文の最初の変換 | 0.12〜2.61 ms | 0.49〜5.30 ms |

この観測では準備時の増分が77,250,584 bytes（73.7 MiB）小さくなった。一方、初回の各変換時間は増えている。常に高速になる、アプリ全体のメモリが半減する、Releaseや全端末でも同じ値になるという保証ではない。公開APIとsource probeでmmap対象のstorageを確認したが、mapped bytesとprocess footprint差は同じ指標ではない。

[実測値](data/2026-10-29-jpreprocess-cross-review/metrics.json)、[入力/出力とイベント](data/2026-10-29-jpreprocess-cross-review/results.json)、[音声hash](data/2026-10-29-jpreprocess-cross-review/audio-hashes.json) を保存した。音声本体と比較一覧は、この端末の `/private/tmp/cat-jpreprocess-cross-review-20261029/comparison.md` と `device-pronunciation/data/` にある。16ファイルの非空・有限PCMを確認した。音声バイナリはGitへ加えていない。

## 残る制約と証跡

発音・自然さの聴取評価は未確認。辞書の曖昧な読み（例: 辛いカレー→ツライカレー）、時刻、未知語を含む区間の原文保持、URL直後の日本語までの保護は以前の制約のまま。新しい文法・万能な読み推定は追加していない。これらを伏せず、同じ比較文を保持した。

ログ・xcresult・凍結した初回差分・修正差分・probeは `/private/tmp/cat-jpreprocess-cross-review-20261029/` に保存した。ソースと文書の変更は、この記録作成時点で未コミット。push/mergeは行っていない。
