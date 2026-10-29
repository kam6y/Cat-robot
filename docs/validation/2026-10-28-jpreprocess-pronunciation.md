# jpreprocessによる読み変換の検証

作業開始2026-10-28、実機確認2026-10-29 JST。これは初回統合版の履歴で、その後の整理・修正・mmap計測は [相互レビューの記録](2026-10-29-jpreprocess-cross-review.md) にある。branch `feature/jpreprocess-pronunciation`、基点 `def7573`、コード確定 `184aee7`。表示・記憶用の原文を保持し、音声用の読みをjpreprocessへ完全に置き換えた。旧2語置換とそれへ戻す経路を削除した。

## 初回統合時の結果（184aee7）

| 検証 | 結果 |
|---|---|
| Rust・実辞書/C ABI | 16件合格（読み変換12、FFI 4） |
| Swiftアプリ全体 | 847件中845件合格、実機専用2件skip、失敗0 |
| Python資産検査 | 7件合格、実資産のhash/receipt検査成功 |
| プロジェクト生成 | xcodeproj 1.27.0、決定性・契約検査成功 |
| iPhone 16 Pro / iOS 27.2 | 専用試験1件合格、失敗0。8組16本のWAV生成と本番speakerの再生完了 |
| 通常起動 | 同じ署名アプリを試験終了後に通常環境で再起動し、process PID 3477確認 |
| 聴取による発音・自然さ | 未確認 |

初回検証版の29ファイルは、当時 [source-hashes.json](data/2026-10-28-jpreprocess-pronunciation/source-hashes.json) と照合した。ビルド内のrevision表示は `17810a1-working` だが、そのソース内容が後の `184aee7` と同じであることをhashで照合した。モデル、声、8推論ステップ、先読み1文、同時推論1件、PCM 60秒上限を維持した。

## ペアレビューと修正

独立Codexレビューは `def7573..17810a1` にコード指摘なし。ユーザーの依頼によりagmsgでClaudeとペアレビューを行い、Important 2件を採用した。

1. `Disney+`、`A+`、`x+1`などの`+`が「タス」になる。`+`を含む英字語を辞書で引き、一語の既知語（`C++`など）だけ字句として保持し、それ以外の`+`は「プラス」にした。
2. `+ボタンを押してね♪`、`YouTubeを見よう…`などで、記号を理由に区間全体が原文へ戻る。一般的な記号17種を保持する境界にし、前後の既知区間の補正を継続した。

両方とも修正前の失敗を実辞書テストで確認し、修正後に16件のnativeテストとSwift全体テストを通した。既存の未知語・URL・メール・コード・結合文字・`C++`のassertionは維持した。一般の未知絵文字を無理に分割する処理や、新しい数式・時刻の構文解析は追加していない。

[Codexレビュー](data/2026-10-28-jpreprocess-pronunciation/codex-review.md)、[Claudeレビューと限定差分の確認](data/2026-10-28-jpreprocess-pronunciation/claude-pair-review.md)、[採否と最終結果](data/2026-10-28-jpreprocess-pronunciation/review-reception.md) に根拠を保存した。

## 実機で得た入力と制約

F1・8 stepsで原文と変換文を合成した。乱数状態の同一性は固定していない。元の比較文に旧iPhone/Bluetooth置換は作用しないため、元の入力は旧方式のモデル入力に相当する。

| 元の文 | 新しい音声用入力 |
|---|---|
| `+ボタンを押してね。` | `プラスボタンヲオシテネ。` |
| `YouTubeを見よう。` | `ユーチューブヲミヨー。` |
| `3人で25個を分けるよ。` | `サンニンデニジューゴコヲワケルヨ。` |
| `こんにちは。今日も一緒に遊ぼうね。` | `コンニチワ。キョーモイッショニアソボーネ。` |
| `Disney+を見よう。` | `ディズニープラスヲミヨー。` |
| `辛いカレーが好きだよ。` | `ツライカレーガスキダヨ。`（適切な「カライ」を選べていない） |
| `今日は25℃だよ。` | `キョーワニジューゴドシーダヨ。` |
| `7:30に起こしてね。` | `ナナ:サンジューニオコシテネ。`（時・分への変換はされていない） |

辞書が選ぶ漢字の読みには誤りが残る。全文をカナへ変換するため、その読みをSupertonic側が再解釈する余地はなくなる。これらを含む16本を聴き比べ用に残し、実際の発音が改善したとはまだ断言していない。未知語・保護区間の原文保持は変換層の契約であり、Supertonic内部の記号処理や発音の正しさを保証するものではない。

音声と一覧は、この端末の `/private/tmp/cat-jpreprocess-implementation-20261028/comparison.md` と `device-pronunciation-foreground/data/` にある。WAVの非空・有限PCMと16ファイルの存在を確認し、[音声hash](data/2026-10-28-jpreprocess-pronunciation/audio-hashes.json) を保存した。音声バイナリはGitに含めていない。[実測入力/出力](data/2026-10-28-jpreprocess-pronunciation/results.json) と [集計](data/2026-10-28-jpreprocess-pronunciation/metrics.json) はGitに保存した。

## 性能・サイズ（単回のDebug測定）

| 項目 | 実測 |
|---|---|
| プロセス内の初回辞書準備 | 60.0 ms |
| 初回の短文変換（`+ボタン`、regex初期化を含む） | 2.61 ms |
| 残る7文の変換 | 0.12〜0.47 ms |
| モデル準備前のprocess footprint | 29,230,800 → 180,832,096 bytes、差 +151,601,296 bytes（約144.6 MiB） |
| 同梱辞書ファイル | 80,055,769 bytes |
| 署名Debugアプリのバンドル | 567,155,586 bytes |
| この端末の以前のDebugビルドとの差 | +121,442,553 bytes |

ファイルキャッシュ状態は固定していない。process footprint差は辞書だけの厳密な占有量ではなく、初期化中のコード/allocator等も含む。バンドル値は非圧縮のDebug参考値であり、配信サイズやRelease性能の測定ではない。初回統合版では1つの辞書をヒープへロードして再利用していた。後のmmap変更は相互レビューの記録を参照。

## 途中の失敗と切り分け

- 最初の実機インストールは `IXRemoteErrorDomain code 6` の通信切断で停止した。再接続後は署名ビルドを再利用して起動できた。
- 通常画面が試験と同時に起動し、共有辞書を先に準備していた。最初の `coldPreparationSeconds=0.0001764` とfootprint差0は初回測定ではなく、採用しない。専用Debug実機試験だけlive compositionを作らないホストへ分離した。通常/Releaseは従来どおりlive compositionを使う。
- ホスト分離だけでは再生失敗は解消しなかった。さらにモデル準備直後はallocatorの解放が重なり、footprint差が負になったため、辞書測定をモデル準備より前へ移した。
- 後の失敗で `UIApplication` がバックグラウンド（state 2）、音声再有効化が `561015905` で拒否されていた。同じテストプロセスを `devicectl ... process launch --activate` で前面へ出すと、state 0で再生まで合格した。通常のPCMPlayerに変更は加えていない。
- 高温判定中は既存の冷却待ちを使い、待機時間を別記した。最終の前面実行は [results.json](data/2026-10-28-jpreprocess-pronunciation/results.json) に記録した。

古い失敗ログと音声は `/private/tmp/cat-jpreprocess-implementation-20261028/device-pronunciation{,-retry,-isolated,-pair}/` に残した。成功した最終runは `device-pronunciation-foreground/`。モデル推論前後の音声セッションを試験が所有し、試験終了時の自動ロック設定は元へ戻す。

## 実装判断

- ユーザーの「完全に置き換え」に従い、初期化/変換/展開上限エラーでは旧処理で再試行せず、音声エラーにする。辞書初期化失敗は再起動まで保持する。
- 未知文字を含む安全に対応づけられない連続区間を原文保持する。補正の取りこぼしは残るが、未知の内容を黙って消さない。
- XCFrameworkが公開するCモジュールを使い、重複する手動のSwift検索経路は削除した。実コンパイルとgenerator契約で確認した。
- 辞書の曖昧読み、URL直後の日本語までの保護、mmap最適化、旧仮名の対応などは [レビュー採否](data/2026-10-28-jpreprocess-pronunciation/review-reception.md) に記録した。

固定辞書archive SHA-256: `8a930bbc57bf4adcf521d53544c7dc9ab8ab3aa997a591b1b1608dc5539017b8`。固定ソース・依存ライセンス・再作成手順は [PROVENANCE](../../CatRobot/Vendor/JPreprocess/PROVENANCE.md) と [README](../../README.md#日本語の読み変換の準備) を参照。
