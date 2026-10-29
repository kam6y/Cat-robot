# claude による受領評価: fresh-code-review.md（superpowers:receiving-code-review）

claude_sleep_zzz_1028、2026-10-29。

- **前提**: 対象 HEAD は 3472b95（feature/response-latency）。READ-ONLY で、編集・build・test・ブランチ操作はしていない。
- **方法**: 実際に `superpowers:receiving-code-review` を起動して評価した。各指摘は `git show 3472b95:<path>` の source で確かめた。
- **独立性**: claude-simplify.md は、この review を読む前に保存し、その後は変えていない。
- **判定の種類**: 採用 / 一部採用 / 反論 / 延期。

## Strengths
- **採用**（4 点。根拠の行を確かめた）
  - 確定文を再正規化し、trim の前に検査してから完全一致を比べる。voice は 1 回だけ取得し、監査は再生の直前に行う（Speaker:74-77、:123-145、:150-161）。
  - 不一致・取消・失敗のどの出口でも、先行合成を cancel してから join し、その後で置き換えの合成を始める（:124-125、:136-139、:142-143）。
  - channel の確定キュー（容量 2）・候補の一回性・failure 優先（SpeechSentenceChannel）。
  - 協調しない推論を使った不一致/stop の試験（SentenceReplyPlaybackTests:68-155）。
- **一部反論**: 「summary は推論設定の変化を拒否する」は不正確。
  - **証拠**: benchmark は行に `"steps": 8, "threads": 2, "speed": 1.05` を定数で書いている（ResponseLatencyDeviceBenchmark.swift:160@HEAD）。summarizer はそれを同じ定数と比べている（summarize_supertonic_integration.py:40）。
  - 実際の値は別の場所で決まる（Speaker:34 の `steps: 8`、Helper:820 の threads、Helper:705 の speed 既定値）。だから本番の設定を変えても、この検査は通る。
  - voice は実際の `voice.rawValue` を記録しているので、voice の検査は実際に効いている。
  - 対処は claude-simplify.md の CS1（steps を本番定数と共有し、threads/speed は宣言値と明記）。

## Important 1: 今の正規化で、実機の受入 gate をまだ満たしていない
**判定: 採用。squash merge と push の前に解消すべき条件とする。**

### 確認したこと
- **境界 fixture**: 明示的な最大長の境界 fixture は、カタカナ 16 字 `アイウエオカキクケコサシスセソ。` と `XCTAssertEqual(boundaryPronunciation.count, 16, …)` だけ（ResponseLatencyDeviceBenchmark.swift:63-64@HEAD）。
- **guard**: guard は正規化後の書記素数で数えている（Speaker:116 `spoken.count <= 16`）。
- **正規化の変化**: main の修復で、正規化後の文字列は漢字と数字を保持するようになった。
  - 同じ 16 字でも、音声の長さと合成量の分布が変わる。この点は、私が 10-29 13:2x の相談回答の別件欄で指摘したとおり。
  - review-context.md も「旧 54 試行は新入力の証明ではない」と明記している。
- **記録の内容が古い**: validation の記述が、すでに事実と合わない。
  - `docs/validation/2026-10-29-response-latency.md:3` は、実装・実機の版を 91ceca4 としている。
  - `:94` は「後続の変更は検証文書だけで、main にはマージしていない」としている。
  - 3472b95 は main の natural-speech 修復を取り込んでおり、正規化（native）の挙動が変わっている。

### 対処
review の提案に同意し、次を加える。
- **fixture**: root が作業ツリーで追加中の `changed-kanji-boundary`（不一致経路）と `delayed-mixed`（hit 経路）でよい。
  - 正規化後の文字数は、現行の normalizer で 16 になることを assert する（CS5 の名前付き定数を参照）。
  - 先行合成の試行数の期待値（境界 = 1、長文 = 0）も固定する。
- **再測定の条件**: 新しい runID で、同じ build の paired 比較を行い、gate は 100ms のまま緩めない。現モデルでの smoke も新しく取る。
  - 各条件 3 回なので p95 は事実上の最大値になる。境界ケースは揺れやすいことを注記する。
- **source の固定**: 現行の source と native の版（receipt と hash）を記録する。
- **旧データの扱い**: 旧 54 試行は「全文カナ時代の履歴データ」として、現行の受入と分けて記載する。
- **gate に落ちたとき**: 上限か 75ms を狭めて再検証する。上限を新しい fixture に合わせて調整してはいけない。根拠は、実機の「正規化後の長さ」対「合成時間・取消の残差」に置く。

## Minor 1: 75ms の安定待ちが、候補の変化でやり直されることを直接試すテストが無い
**判定: 採用（blocking ではない）。**

### 確認したこと
- `testChangedCandidateCancelsAndDrainsBeforeSynthesisOfConfirmedText`（:68-99）は、候補の合成が始まった後に文を変えている（`await fulfillment(of: [started])` の後に yield）。
  - したがって試しているのは「合成開始後の取消」で、75ms 以内に key が変わったときの timer の再始動ではない。
- `testUnstableOrProtectedIncompletePrefixDoesNotStartPreparation`（:206-231）は、候補が出ない prefix について、150ms の間に準備が始まらないことを確かめているだけ。
- ReplySentenceStreamBufferTests は parser の試験で、timer は動かさない。
- 3472b95 の test 名一覧に、timer の再始動に当たるものは無い。

### 意義
`SentenceReplyPlayback.swift:101-111` の `key != candidateKey` → `pending` を cancel して join → 再び Task を作る、という処理が退行した場合、現状のテストでは捕まらない。その場合、1 回しか無い準備の機会を、古い候補で使い切る。

### 対処
- **テスト**: 句読点の伸長を使う。`"仮の文。"` を yield した直後に `"仮の文。！"` を yield し、次を確かめる。
  - 最初の候補は合成されないこと。
  - 準備は、伸びた候補について 1 回だけ起きること。
  - 確定前は再生しないこと。
- **遅延の注入口**: claude-simplify.md の CS5 で 75ms を名前付き定数にするのと合わせ、`SentenceReplyPlayback`（または Coordinator）の init に既定値 75ms の遅延引数を足す。
  - テストでは長め（例 300ms）を与え、「窓の中での変化」を、実行環境の stall に左右されない形で試す。
  - 本番の既定値は変わらないので、振る舞いは保たれる。
- この引数の追加が不釣り合いなら、即時の連続 yield だけで書いてよい（2 つの await の間が 75ms 以上 stall した場合に flaky になり得る、と注記する）。merge の前後は root の判断。

## Recommendations
- **(1) 現行 source での実機受入を merge/push の前に済ませる**: 採用（Important 1 と同じ）。
  - 「同じ build で準備を切り替えた比較」を、旧 main バイナリとの比較と書かない点にも同意する。
- **(2) simplify を適用するとき、cancel→drain と確定文の再検証を保つ**: 採用。私の simplify はこれと整合している。
  - E2（確定文の再正規化をやめる）は spec 4 に反するので不採用にした。
  - E3(b)（置き換えの合成を始めた後に join する）も不採用にした。
  - CS3(b) の `async let` 案では、置き換えの `makePCM` は do の scope の外にある。scope を出るときに投機分が cancel→await されてから、置き換えの合成が始まる。順序は変わらない。
- **(3) 再利用 0 件の cloud smoke を、実会話の高速化として一般化しない**: 採用。新しい smoke も、paired replay とは分けて記録する。

## Declined to judge
- 6 項目すべてに同意する（発音品質、音響上の発声開始・実会話、熱、ONNX の中での取消期限、範囲外の業務ロジック、build・test の認証）。
- ONNX の中で取消が効かない区間について、補足が 1 つある。
  - 不一致の経路では、`SupertonicEngine.synthesize` の `textProcessor.call`・`loadVoiceStyle`・duration/text encoder の推論が、取消の効かない区間になる。
  - 任意の小改善として、Engine:61-62 の間に取消確認を 1 行置く案を CS10 に記した。gate の対象ではない。

## Assessment
- **「With fixes」に同意する。**
- **merge の前に必須**: Important 1。漢字を含む現行入力で実機の paired gate と smoke を通し、validation の版と記述を更新する。
- **merge 前が望ましい**: CS1（証拠の検査が実際に効くようにする、または記述を正す）と Minor 1 のテスト。
- **その他**: simplify の CS2〜CS8 は振る舞いを変えない整理。適用するかと時期は root の判断。適用した場合は、既存の drain・trace のテストで確かめる。
