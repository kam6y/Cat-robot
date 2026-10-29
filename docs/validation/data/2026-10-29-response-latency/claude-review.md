# claude 差分レビュー: 7733e20..8574958（feature/response-latency）

- **担当と範囲**: claude_sleep_zzz_1028。2026-10-29、READ-ONLY で行った。
  - 編集・build・test 実行・subagent の起動はしていない。
- **対象**: 論理差分。
  - 製品: Domain、Integration、Speaker、Tools、Helper、PROVENANCE。
  - テスト: Swift テスト、デバイスベンチ。
  - スクリプト: runner、summarizer。
  - 生成 project の GUID 差分は対象外。
- **判断の根拠**: すべてコードを読んで判断した。実行時の挙動は、テスト実行や実機での確認をしていない。
- **作業ツリーとの差**: レビュー時点の作業ツリーには、HEAD に対して未コミットの変更が 3 ファイルある。
  - `scripts/summarize_supertonic_integration.py`
  - `scripts/test_summarize_supertonic_integration.py`
  - `ConversationRecoveryTests.swift`
  - 下の I1 は、このうちの summarizer の修正と関係する。

## 結論

Critical 0 / Important 1（作業ツリーで修正済み・未コミット）/ Minor 6。

製品コードについては、仕様（spec）の契約 1〜9 を満たしていると判断した。以下はすべてコードを読んで確かめた。

- **候補の範囲**: 候補になるのは ordinal 0 だけ。
- **安定判定と候補の一回性**:
  - 前後の空白を除いた原文で 75ms の安定を判定する。
  - 候補の通知は 1 回だけ（`SpeechSentenceChannel.offerPreparation` の one-shot、`!hasCommittedSentence`）。
- **再生と監査の時点**:
  - 確定前は再生しない。`nextPrepared` は、`channel.next()` で確定文を受け取ってからでないと Prepared を返さない。
  - onInput は確定文について、再生の直前に 1 回だけ呼ばれる。
- **キーの一致と取消**:
  - 正規化して trim したキーが一致したときだけ、先に作った PCM を再利用する。
  - 不一致・失敗・取消のときは、先行合成を cancel してから join する。経路は 4 つで、`SupertonicSentenceSpeaker.swift:115-140` にある。
- **合成の割り込み**: step 間で取消を確認する（Helper の 2 か所）。

## Important

### I1. summarizer で cooldown と hotEnds がモードごとに分かれず、全行の合計になる（8574958 時点）

- **箇所**: `scripts/summarize_supertonic_integration.py:126-127`（8574958）。
- **原因**: ループ変数を `rows` から `group_rows` に改名したとき、`cooldownSeconds` と `hotEnds` の 2 行だけ外側の `rows`（全行）を参照したまま残った。
- **影響**:
  - baseline と prepared の両方に、全試行の合計の冷却秒数と高温回数が同じ値で入る。
  - spec の「メモリ/発熱を記録」で、モード差が見えなくなる。
  - 既存の stage（voices/fixed など）を再集計した場合も、モードごとの値が壊れる。
  - 受入判定（`latency_acceptance`）はこの 2 つの値を使わないので、合否そのものには影響しない。
- **状況**: 作業ツリーに修正（`group_rows`）と回帰テスト `test_cooldown_and_heat_stay_with_their_own_mode` がある。
  - 内容は妥当と確認した。コミットして回帰テストが通ることを確かめれば解消する。

## Minor

### M1. `preparation` という名前が二重に使われている（読みやすさ）

- **箇所**: `SupertonicSentenceSpeaker.swift:114`。
- **内容**: `nextPrepared` の中のローカル変数 `preparation`（先行合成の Task）が、インスタンスの `preparation`（モデル準備の Task。`:13`、`:41-44`、`:65`、`:214` で使用）を隠している。
- **紛らわしい点**:
  - `stop()`（:214）は `preparation` を cancel するが、これはモデル準備の Task であり、先行合成の Task ではない。
  - 先行合成は、操作の Task への cancel 伝播と onCancel で止まる。読み手は `stop()` が先行合成を直接止めていると誤読しやすい。
  - `prepare(_:voice:)` と、プロトコルの `prepare()` の多重定義も同じ種類の紛らわしさがある。
- **案**: ローカル変数を `candidateSynthesis` などに改名する。

### M2. A/B の baseline は 7733e20 と同じではない

- **共通の変更**: prepared を無効にしても、次の 4 点は両方のモードに入っている。
  - 合成入力の trim。
  - onInput の発火点（合成の前から、再生の直前へ移動）と、spoken の trim。
  - Helper の step 間取消。
  - trace の notice 化と、追加の trace 点。
- **記録への要望**: validation には次の 2 点を明記する。
  - baseline は「同じ build で事前準備だけを無効にしたもの」であること。
  - 上の共通変更による挙動の差、特に onInput の意味が「再生直前・trim 済み」に変わったこと。
- trim が合成入力として等価であること自体は確認済み。`chunkText`（Helper.swift:336）と `preprocessText`（`\s+`→1 つにまとめてから trim）で、同じ結果になる。

### M3. `firstSentence` の意味が変わった

- **箇所**: `SentenceReplyPlayback.swift:127`。
- **内容**: 最後の flush 経路でも `firstSentence` を記録するようになった。
  - 以前はストリーム中に確定した場合だけ記録していた。
  - そのため、旧 trace との比較で一文返答の扱いが変わる。
- **案**: 意図どおりなら、validation に注記する。

### M4. 75ms の安定待ちが、実際の効果の範囲を決める

- **一文返答で効かない場合**: 末尾に tool がない一文返答では、次の時間が 75ms 未満だと事前準備は一度も始まらない（`pending` が cancel される）。
  - 終端の到着から、usage/save を経てストリームが終わるまでの時間。
- **待ちを短くする余地**: step 間で取消できるようになったので、外れたときの損失はおおむね 1 step + 後処理で済む。待ちを短くする余地はある。
- **案**:
  - 実機の cloud smoke と実会話の trace から、`firstCandidate → speechEnqueued(first)` の分布を記録する。
  - 75ms が妥当かどうかを、数値付きで残す。

### M5. 固定 fixture の短縮量を、実会話の改善として書かない

- **根拠**: `delayed`/`quoted`/`whitespace` は、700〜900ms の末尾待ちを人工的に入れている。
- **実際の効果**: 実会話での効果は、次の 2 つで決まる。
  - 本物の Claude ターンでの `firstCandidate → speechEnqueued` の分布。
  - tool を後に置いたときの区間。
- **案**: cloud smoke（3 件）は配線の確認として扱い、分布の推定には使わない、と明記する。

### M6. tool trace は TaskLocal の伝播を前提にしている

- **前提**: `ReplyTraceContext.current` が FoundationModels の tool 呼び出しまで伝わることを前提にしている。これは `MotionTurnContext` と同じ前提。
- **解釈の注意**: 実機の cloud smoke で tool 予約が起きたのに toolStarted が出なければ、伝播が切れている。その場合「tool event が無い」を「tool を使っていない」と解釈してはいけない。
- **案**: smoke の記録で、tool の有無と toolStarted の数を突き合わせる。

## 確認した主な点（問題なし）

- **SentenceReplyPlayback.enqueue**:
  - 候補 key が変わると、`pending` を cancel して join してから send する（offer→send の順序が保証される）。
  - 終了、失敗、取消（catch）のどの経路でも join する。
- **SpeechSentenceChannel**:
  - 確定文は候補より優先する（`nextInput` で queue を先に見る）。
  - `send` で `candidate` を消し、`finish` でも消す。
  - 旧来の `next()` 利用者は候補を読み飛ばす。
- **Speaker の候補経路**:
  - 候補の正規化に失敗しても、確定文の処理は続く。
  - 不一致のとき、候補の合成失敗は無視して確定文を合成する。
  - 一致したとき、合成失敗は同じ入力についての失敗なので、そのまま失敗として扱う。
  - 確定文の上限・NUL・空を、trim 前に検査する（`:144-155`）。
  - stop も失敗経路も drain してから終わる。
- **Helper の取消**: 取消は呼び出し側の Task から見える。actor の同期メソッドは呼び出し側の Task で実行されるため。
  - CancellationError は `.cancelled` に写像される。
  - 通常の合成でも stop が早く終わるようになる（改善）。
- **trace と tool**:
  - trace は本文を含まない。tool は enum で記録する。ログは notice、privacy は public。
  - 区間の対応は ends で数え、並行する tool もカウントで扱える。
- **テストが表している契約**: 確定前に再生しない、一致時は再合成しない、変更時は drain、取消時は drain して次のターンへ漏らさない、上限、生成失敗時の破棄、未確定や保護中の prefix。
- **summarizer**: 対になる組の欠落・重複、revision と設定の固定、原文の連結一致、順序の検査、一致時に再合成していないことの検査は妥当。
