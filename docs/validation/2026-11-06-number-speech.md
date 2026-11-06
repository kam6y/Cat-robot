# issue #24: 数値表記の読み上げ

対象: [issue #24](https://github.com/kam6y/Cat-robot/issues/24)。main `b050575f88b6f14f520f3ee968c42c0ad6021e3c` から `codex/issue-24-japanese-number-speech` を作成した。最終検証は2026-11-07 JST。実装・テスト・レビューの記録は[artifacts](artifacts/2026-11-06-number-speech/)に保存した。初回レビューは当時の候補についての報告であり、そこにあるpendingや読点形式は最終仕様を意味しない。

## 結果と採用方針

固定jpreprocess0.15/NAIST辞書の標準NJD処理を使う。大きな数量は前処理後の漢数字表層、小数・%・電話は標準発音を採用した。IDは明示ラベルを一箇所で判定し、実際の1桁入力を辞書APIへ渡す。各桁を段落で分け、既存Supertonicの区間合成と通常の0.3秒の区間間無音を使う。読み表、数詞分解、小数の読み組み立て、偽の番号文脈、独自音声結合は実装していない。時刻は時・分の表記へ整え、数字の漢字化は同じライブラリへ任せる。

| 原文 | 実際の音声入力 |
|---|---|
| `1500000円だよ。` / `1,500,000円だよ。` | `百五十万円だよ。` |
| `３億５０００万だよ。` | `三億五千万だよ。` |
| `1500000人で分けるよ。` | `百五十万人で分けるよ。` |
| `3.14だよ。` | `サンテンイチヨンだよ。` |
| `25%だよ。` | `ニジューゴパーセントだよ。` |
| `7:30に起こしてね。` | `七時三十分に起こしてね。` |
| `090-1234-5678だよ。` | `ゼロキューゼロ、イチニーサンヨン、ゴーロクナナハチだよ。` |
| `IDは123456789だよ。` | `アイディーは`・各桁の辞書読み・`だよ。`の11区間 |

表示・記憶用の原文、対象区間外の日本語、声F1・8steps・速度1.05・CPU2threadsを維持する。URL・メール・コード・最大Latin語・未知Unicodeを保護する。小さい整数の助数詞・年・整数温度は従来表記を保つ。小数温度は小数の対象となる。負数・範囲を保護し、既存のプラスの読みは維持した。

独立した5桁以上、正しい3桁区切り、万/億/兆/京付きの数量が対象。数量の24桁上限は原表記内の数字の個数であり、単位を掛けた数学的値の上限ではない。次の単位`𥝱`は同梱文字表に無いため、25桁以上は原表記を保持する。実辞書で`一垓`と25桁の保持を検証した。任意の無標識の数字をIDと推測しない。明示バージョン、日付、無効な時刻、桁区切り付き小数やLatin末尾は保護する。境界と制限の正本は[native README](../../native/japanese-pronunciation/README.md)。

## ライブラリ選定とClaudeとの合意

利用者は最初の同声比較で **C＝数字部分の漢数字** を選び、小数・%・時刻・電話・IDの従来入力の問題を報告した。さらにライブラリを使って独自実装を最小限にする指示を受け、自前の読み表を削除した。

- [jpreprocess0.15公開API](https://docs.rs/jpreprocess/0.15.0/jpreprocess/)と実辞書: 数量のNJD表層、標準の小数・%・電話発音、本物の1桁入力の発音を直接確認した。
- [Foundation NumberFormatter.spellOut](https://developer.apple.com/documentation/foundation/numberformatter/style/spellout): 実測で1500000は百五十万、3.14は三・一四、20桁例は数字へのフォールバック。用途判別や保護を置き換えなかった。
- [NeMo Rust v0.3.1](https://github.com/FluidInference/text-processing-rs/tree/v0.3.1)、rev `46ebddcea5e1ff673c2cb5256a1b6b0e6c4ff527`: 隔離Cargoプログラムで通常APIと実際の`fst-engine`の日本語FSTを27例で実行した。**iPhoneで利用可能**であり、Python限定というClaudeの当初の判断は訂正した。却下理由は挙動である。FSTでは1,500,000が一,五百,零零零、電話が数量読み、IDが基数読み、%記号は保持だった。時刻には有効でも電話・ID・桁区切りの接続処理を減らせなかった。
- [Misaki](https://github.com/hexgrad/misaki)、[num2words](https://github.com/savoirfairelinux/num2words)、[Yosina Swift](https://github.com/yosina-lib/yosina-swift)、[Haqumei](https://github.com/o24s/haqumei)も一次資料を比較した。実行環境・文字正規化・全文G2Pなど用途が異なり、今回の保護と出力選択を削れる根拠は得られなかった。

Claudeとの[最終合意](artifacts/2026-11-06-number-speech/claude-nemo-c-assessment-final-agreement.md)は「読みは既存NJD、アプリは対象表記の受理・出力選択・時刻の表記整理のみ」。IDは一箇所のラベル規則と本物の各桁API入力を使う。NeMoの2つの実行ログ、実辞書のprobe、ID候補の由来も保存した。評価用依存は一時領域だけに置き、製品の依存バージョンを変えていない。会話履歴は使用していない。

## 実機聴取と最終ID形式

iPhone16Pro/iOS27.2で固定の公開例だけを合成した。設定は上記と同じで、固定seedではない。比較用PCM16は同じrate/monoでlocalhostだけへ配信した。

1. 初回run `290BDB59-27FE-495C-9ADC-AD057D131FCA`:42WAVと本番文再生。利用者は大きな数量の漢数字形式を選択し、従来の小数・%・時刻・電話・IDの不自然さを報告した。候補リテラルと実際のfrontend入力は区別した。
2. 修正後run `D3D1079B-6D75-443B-A570-91F862B7627B` と境界修正版 `889B4FA0-0630-457C-86AA-F885F29DA12C`:各47WAV・19記録、全件成功。原文`残高は1,500,000円だよ。`を保ち、speaker入力だけが`残高は百五十万円だよ。`となった。利用者はIDの速さと、一部の「百」の明瞭さを指摘した。
3. 読点によるID区切りrun `64A84462-60E6-4637-B74F-49BA1359744B`:各3回の実経路9WAVと本番ID文再生、全10記録成功。それでもIDは回によって1/7、5/8、2が欠けて聞こえた。入力文字の欠落ではなく、全桁ある入力からの合成音の問題だった。金額・人数の波形差については利用者が許容した。元のカンマ有無の2つの円の例も、音声入力・区間・再生1.995秒が同一でWAVだけが異なる。元のカンマに依存した速度・seed等の処理は加えていない。
4. ID候補run `ED8A7E1E-DA31-48D4-A04A-DACD768A2AEB`: A＝NJD漢数字表層、B＝NJD辞書読みをFoundationでひらがな化、C＝各桁を既存の段落区間として合成、各3回。利用者は **「C：各桁を別区間」** を選択した。Cの合成約5.4秒・再生約17.4秒を選択前に明示した。
5. 最終製品経路run `0FC49928-9DEC-4A0D-B4DD-7944F1965716`:数量・人数・ID各3回の9WAVと実際のID文再生、全10記録成功。3回とも実際の正規化文字列と11区間が受理済みCと完全一致した。原文`IDは123456789だよ。`は保持され、本番speakerへの入力も一致した。再生は各17.386秒、合成は5.128/5.377/5.524秒。[照合記録](artifacts/2026-11-06-number-speech/production-confirmation.json)参照。新たな波形自体を利用者が再聴取したとは主張しない。

**IDのこの9桁例は元のS1（2.5秒）を満たさない。** 聞き取りを優先する明示選択として採用し、READMEのS1定義は変更していない。非常に長いIDは既存60秒の合成音長上限に達し、`invalidPCM`で失敗し得る。約30桁前後が目安となり得るが、桁の発音・文脈によるため固定の桁数保証ではない。2000文字以内なら任意長のIDを再生できるとは保証しない。

## 最終検証

- 既存native22件PASS後、Swiftの2テストで7件の意図したREDを確認した。数量・桁区切り・プラス・未対応文字・意味種類・境界の修正にも実辞書のRED→GREENを使った。
- 独立レビューの重要3件はnativeで3件のREDを確認して修正した。最終ID段落形式も従来期待値でREDを確認後に採用した。30%の期待値は実辞書の`サンジュッパーセント`へ修正しており、自前の読み補正ではない。
- **最終native30件PASS（発音26＋C ABI4）**、Rust1.90.0 fmt PASS。iPhone arm64とSimulator arm64/x86_64を再構築し、辞書・全生成物・ソースのreceiptを検証した。
- **最終XCTest1003件PASS、失敗0・skip0**。実辞書を通る音声入力、IDの11区間、元の表示用文字列、900桁IDの展開後上限などを含む。有料API・実ハードウェア専用の2クラスは通常suiteから除外し、ローカル発音の実機試験は別途上記の通り実行した。
- Python assets8件PASS、project生成契約PASS（生成結果変更なし）。最終のasset検証と差分検査もPASS。

最終code/test/project/native/scripts入力digestは `c919e40823159289f385cf685b1f1e5f45400650904393706ca16f515f17d1cf`。候補HEAD `812bbbf010cf9178562df00ad3592dbb716b1726` 上の同範囲の作業差分SHA256は `d98079bc0f5b4623af9bf6cb45f4e22e6000ed685cc483a8c5616e0e0b2e8e45`、native receipt SHA256は `2ee2883ca23745dc8729e88a780264d32a270c3b1d3faa4de42e657fe555d0ca`。試験中のソース不変をcontrollerが確認した。最終検証commandは実結果と現在のdigestを再照合し、task-doneを記録した。同じテストの帳簿上だけの再実行はしない。

## レビューと残る制限

Claudeの実際の`/simplify --report-only`を同一固定差分に対する独立4観点（reuse/simplification/efficiency/altitude）で実行し、Codex側は1名の新規subagentで独立レビューした。双方の初回報告を保存してから相互に`receiving-code-review`し、rootが根拠を確認して採否を記録した。agmsgで実際のClaudeと方針・修正内容をすり合わせた。

重要な修正は、IDラベルを電話形状より優先すること、意味区間の末尾全体の境界確認と拒否区間の消費、明示バージョンの区切り・助詞の保護。共通幅変換、数値だけのNJD準備helper、文脈の重複計算削減、診断の最小整理を採用した。元のLatin未知語判定を壊す共通化、数量grammarの全面regex化、同じ入力の音声の使い回しは採用していない。

最終修正差分の限定確認は[独立レビュアー](artifacts/2026-11-06-number-speech/native-final-fix-reception.md)・[Claude](artifacts/2026-11-06-number-speech/claude-final-fix-reception.md)とも **未解決Critical0・Important0**。その時点で未確定だった最終suite・実機経路は上記の実結果で確認した。Claudeの文書指摘も段落形式への更新、probeの追跡追加、長いIDの60秒制限明記で解消した。

以下は既知のMinorとして保留した。一般的な数値文法を実装したとは主張しない。

- `1万万2`/`1万億円`など、隣接した不正な単位列を部分変換することがある。
- `1,500,000%`など、桁区切り付き百分率では%が標準発音にならず残る。

## main・通常実機版への反映手順

検証済み入力を保った最終feature commitを、最新mainが基点と一致することを確認して1コミットにsquashする。全tree一致と入力digestを証明し、**push前に通常署名のfinal-main版を実機へインストール・起動する**。XCTestなし・試験引数なし・モデル資産・ソースrevision・実プロセスを確認する。同一treeのため、音声確認済み診断版の後に通常feature-previewを重ねて入れる工程は省き、通常final-main版で検証する。

non-force push、remote hash、issueのCLOSED、実機PID、clean working treeの実結果はコミット後にのみ確定するため、task-private `integration.json`に記録し完了報告へ示す。このコミット内の記録を、まだ行っていない公開・通常起動の成功とは扱わない。feature branchと管理されたhost worktreeは残し、このplan所有の一時実行workspaceだけを保管して片付ける。
