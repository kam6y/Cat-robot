# claude /simplify: feature/response-latency 2fa4ae7..3472b95（READ-ONLY）

claude_sleep_zzz_1028、2026-10-29。

## 前提
- **範囲**: review.diff のうち runtime・tests・scripts・project。project の GUID 差分と validation データは対象外。
- **体制**: 実際に /simplify を回し、4 観点（Reuse / Simplification / Efficiency / Altitude）を opus の subagent 4 体に並列で振った。
  - 結果は私が重複を除いて統合し、主要な行番号を `git show 3472b95:` で照合した。
  - 独立 review（fresh-code-review.md）は、この文書を保存するまで読んでいない。
- **しなかったこと**: 編集・build・test・ブランチ操作。skill の Phase 2（修正の適用）は、指示どおり実施していない。修正は root が判断する。
- **作業ツリーの状態**: 確認時点で `ResponseLatencyDeviceBenchmark.swift` に未コミット変更があった。root が足した漢字境界の fixture で、行番号はすべて HEAD 3472b95 基準。
- **総評**:
  - correctness の gate になる指摘はない。どれも品質面で、merge を止めない。
  - ホットパス（LLM 文字列 → 最初の音声）に、トークン単位の無駄は増えていない。候補が無い snapshot では、nil の代入 2 回と Optional の比較 1 回だけ。
  - 「振る舞い保持」は、本番の意味（投機再生なし・正規化後の完全一致での再利用・推論は常に 1 本・cancel→join・原文/記憶/usage 不変・8steps/1.05/2threads）と trace の順序を変えない、の意味で使う。

## 優先度順の指摘

### CS1【証拠の正しさ・推奨】推論設定の「不変」検査が、絶対に失敗しない
- **箇所と仕組み**:
  - benchmark は行に定数を直接書いている: `ResponseLatencyDeviceBenchmark.swift:160` の `"steps": 8, "threads": 2, "speed": 1.05`。
  - summarizer はそれを同じ定数と比べている: `summarize_supertonic_integration.py:40` の `!= (8, 2, 1.05)`。
  - 実際の値は別の場所で決まる: `SupertonicSentenceSpeaker.swift:34` の `steps: 8`、`Helper.swift:820` の threads 2、`Helper.swift:705` の speed の既定値。
  - 本番の steps を変えても、行には 8 と記録される。
- **コスト**: validation の「設定不変」という主張が、観測値ではなく記録側の定数を検証しているにすぎない。
- **案**:
  - steps を本番の定数にし（例 `static let inferenceSteps = 8`）、speaker と benchmark の両方で使う。
  - threads と speed は vendor の中にあるので、コードは変えない。
    - validation では「宣言値であって観測値ではない」と明記する。
    - または、行ごとの証拠から外す。
- 本番の挙動は変わらない。指摘元: Altitude A3、Reuse R9、Simplification の付記。確信度は高。

### CS2【推奨】tool の trace 定型句が 4 つの tool にあり、すでに 2 種類に分かれている
- **箇所**: `ExpressTool:19-21`、`MoveHeadTool:18-20`、`LookTool:30-33,37-40`、`RememberTool:17-23`。
  - Express と MoveHead は `.success` を直接書いている。
  - Look と Remember は `var outcome = .generationFailure` を置き、成功時に `outcome = .success` を手で書く方式。
  - そのために Remember の `switch try await ...` と Look の guard が、trace のためだけに書き換えられている。
- **案**: helper を 1 つ作る。
  ```swift
  extension ReplyTraceContext {
      static func tool<T>(_ tool: ReplyTraceTool, _ body: () async throws -> T) async rethrows -> T {
          let trace = current; trace?.mark(.toolStarted, tool: tool)
          var outcome = ReplyTraceOutcome.generationFailure
          defer { trace?.mark(.toolFinished, outcome: Task.isCancelled ? .cancelled : outcome, tool: tool) }
          let value = try await body(); outcome = .success; return value
      }
  }
  ```
  - 各 tool は `try await ReplyTraceContext.tool(.look) { 元の本体 }` とし、本体は base の形に戻す。
- **振る舞い**: 保持される。
  - Express と MoveHead の本体には `try` が無いので、失敗の既定値には到達しない。
  - closure は non-escaping なので、`MotionTurnContext.current` は同じ task のまま読まれる。
  - 3 種類の outcome は既存の ReplyTraceTests が押さえている。
- **採らない案**: `TracedTool<Base>` で包む汎用 wrapper。`as? MoveHeadTool` と `as? RememberTool` の型変換を使うテスト（MoveHeadToolTests:122、ClaudeConversationServiceTests:174,188）が壊れるため。
- **任意**: tool 名の一覧と `ReplyTraceTool` の rawValue が一致することを確かめる drift test を 1 本。
- 指摘元: S3、R2、A2（3 観点が一致）。確信度は高。

### CS3【推奨】`nextPrepared` の候補分岐で、手書きの経路が重複している
- **(a) 確定文へのフォールバックが同じコードで 2 回ある**（`SupertonicSentenceSpeaker.swift:111-112` と `:117-118`）。1 つにまとめる。
  ```swift
  let hint: String?
  do { hint = try await normalizedInput(candidate.original) }
  catch { try Task.checkCancellation(); hint = nil }   // a failed hint is not a confirmed failure
  guard let spoken = hint, spoken.count <= 16 else {
      guard let confirmed = try await channel.next() else { return nil }
      return try await prepare(confirmed, voice: voice)
  }
  ```
  - 取消の確認は、今と同じく失敗経路にだけ残る。`preparationDiscarded` を mark する defer の位置も変わらない。厳密に保持される。
  - 指摘元: S1、R7、A8。A8 の「`return try await nextPrepared(...)` で再帰する」案より、こちらが読みやすい。
- **(b) cancel→join の手書きが 3 か所あり、onCancel handler も別に要る**（`:124-125`、`:136-137`、`:142-143`、`:146`）。
  - 推奨: `async let` に置き換える。scope を出るとき、言語が cancel と await を保証する。
    ```swift
    let confirmed: SpeechSentence; let actual: String
    do {
        async let speculative = makePCM(spoken, ordinal: 0, voice: voice, speculative: true)
        guard let next = try await channel.next() else { return nil }
        let normalized = try await normalizedInput(next.original)
        if normalized == spoken {
            let pcm = try await speculative
            try Task.checkCancellation(); used = true
            trace?.mark(.preparationUsed, part: .first, sentenceOrdinal: 0)
            return Prepared(sentence: next, spoken: normalized, pcm: pcm)
        }
        confirmed = next; actual = normalized
    }
    let pcm = try await makePCM(actual, ordinal: confirmed.ordinal, voice: voice, speculative: false)
    return Prepared(sentence: confirmed, spoken: actual, pcm: pcm)
    ```
    - 意味は保持される。
      - 内側の scope は case 側の defer より先に巻き戻るので、trace の順序 `preparationFinished(cancelled)` →（不一致なら synthesis）→ `preparationDiscarded` は今と同じ。
      - await されなかった async let のエラーは捨てられる。これも今の `_ = await preparation.result` と同じ。
    - 「どの出口でも join を忘れない」が型で保証されるので、新しい出口を足したときに推論が重なる退行を防げる。
    - 確信度: 意味は高（SE-0317）。Swift 6.0 の strict concurrency でそのまま compile できるかは中なので、root の compile と既存の drain テストで確認する。
  - 不採用なら最低限、局所関数 `func drain() async { preparation.cancel(); _ = await preparation.result }` にまとめる。
  - `:138` の `try Task.checkCancellation()` は冗長。`makePCM` が最初に同じ確認をしていて、間に suspension が無い。
  - 指摘元: S2、R4。
- **(c) `makePCM` の `speculative` による三項演算 4 回と、`onSynthesis` の文字列リテラル**（`:173,176,179,183`）。
  - 一度だけ `let (begin, end): (ReplyTracePoint, ReplyTracePoint) = speculative ? (.preparationStarted, .preparationFinished) : (.synthesisStarted, .synthesisFinished)` を作る。
  - `onSynthesis` には `begin.rawValue` と `end.rawValue` を渡す。文字列は今と同一なので、厳密に保持される。
  - 指摘元: S6、R5、A5。
- **(d) `normalizedInput` が trim を 2 回計算している**（`:157`、`:160`）。
  - 一度だけ束縛する。2000 文字の検査は trim 前の文字列のまま残す（spec 5）。
  - 指摘元: E4、S8。

### CS4【推奨】`enqueue` の送信ループが完全に同一で 2 つ、drain が 3 か所
- **箇所**:
  - `SentenceReplyPlayback.swift:116-120` と `:126-130` は、この差分で最後のループにも `firstSentence` を足した結果、バイト単位で同一になった。2 つの copy がずれた実例でもある。
  - `pending?.cancel(); await pending?.value` が `:102-104`、`:123-124`、`:133-134` の 3 か所。
- **案**:
  - `private func commit(_ sentences:to:trace:) async throws` にまとめる。
  - drain は局所関数 `func settle() async { pending?.cancel(); await pending?.value; pending = nil }` にする。
- 厳密に保持される。指摘元: S5、R3、R4。確信度は高。

### CS5【推奨】方針値 16 と 75ms に名前が無く、テストと benchmark に同じ数が直書きされている
- **`<= 16`**（`SupertonicSentenceSpeaker.swift:116`）:
  - benchmark の `XCTAssertEqual(boundaryPronunciation.count, 16, …)`（HEAD:64）が同じ数を持っている。root が作業ツリーで足した漢字境界の assert も同様。
  - 本番値を変えると、境界 fixture は黙って境界を試さなくなる。
  - さらに単位が変わっている。正規化後の書記素数なので、全文カナから漢字保持への変更で、同じ 16 が表す音声の長さが変わった。
  - 案: `static let maximumPreparedPronunciationCharacters = 16` に doc comment（単位は正規化後の書記素で、natural-speech 修復以後は漢字を含む）を付け、benchmark は `@testable` 経由でこの定数を参照する。
- **75ms**（`SentenceReplyPlayback.swift:109`）:
  - `SentenceReplyPlaybackTests.swift:222` は、150ms 待ってから「準備が始まっていない」ことを確かめる否定の assert。遅延を 150ms 以上に調整すると、何も検証しないまま通るようになる。
  - Python テストの `0.125` も 0.05+0.075 を手で計算した値。
  - 案: `static let preparationStableDelay: Duration = .milliseconds(75)` とし、テストの待ちをこの値から導く（例: ×2）。
- **benchmark の fixture 判定**: `fixture.id == "changed-boundary"` などの文字列比較の連鎖（HEAD:80-82、作業ツリーでさらに延長中）をやめ、`Fixture` に `expectedPreparationAttempts: Int?` を持たせる。
- すべて振る舞いを変えない。指摘元: A1、A4、S8、A7。確信度は高。

### CS6【任意】`SpeechSentenceChannel` が、1 回きりの hint に状態を 3 つ使っている
- **箇所**: `candidate`、`offeredPreparation`、`hasCommittedSentence`（`:12-14`）は常にまとめて変わる。
- **案**: `enum Hint { case open, pending(SpeechSentence), spent }` に置き換えられる。全遷移が同値であることは確認済み。
- **同じファイルの小さい点**:
  - offerPreparation の guard（`:22`）の `failure == nil` は冗長。failure が設定されるのは `closed = true` の直後だけ。
  - `finish` の `candidate = nil`（`:92`）は観測されない。nextInput は candidate より先に closed を見るので、解放の意味しかない。
  - `cancelSend`/`cancelReceive` が `guard let waiting = …, waiting.0 == id` から `sender!`/`receiver!` に書き換えられている。commit に理由が書かれていない。compiler の診断で強いられたのでなければ、元の形に戻すことを勧める（root の compile で確認）。
- actor の状態に触れるので、merge 前にやるかは root の判断。指摘元: S4。確信度: enum は高、force unwrap を戻す件は中。

### CS7【推奨・offline】Python summarizer の重複した走査
- **箇所と案**:
  - `latency_acceptance:76-78` は同じ形の `sum(sum(e['point'] == X …))` が 3 回ある → `Counter(e['point'] for r in prepared for e in r.get('events', []))` 1 回にする。
  - `:83-84` の `any` による走査も同様。
  - `validate_latency:50-58` は ordinal ごとに `next(...)` で走査し直している（O(n²)）。point ごとに 1 回まとめれば済む。
  - `.100`（:81,:90）と `('speechEnqueued','speechStarted','speechFinished')`（:50,:56）は定数名にする。
  - `passed` を 2 段階で代入している（:81,:86）ので、1 つの式にする。
- **注意**: `validate_latency` で `metrics()` の part ベースの fallback を流用すると検証が緩む。その流用は振る舞いの変更になる。
- 指摘元: S7、R8。確信度は高。

### CS8【些末・すべて厳密に保持】
- `ReplySentenceBuffer.swift:95-96`: `ready == snapshot.endIndex` なので、`String(snapshot[..<ready])` は `snapshot` と同じ（S8、E6）。
- `ordinal == 0 ? .first : .remainder` が 4 か所にある（`SentenceReplyPlayback:118,128,146`、`Speaker:172`）。`ReplySpeechPart(ordinal:)` にまとめる（R6）。
- `firstCandidate` の once 用キーを毎 snapshot で組み立て直している。局所 flag でも済むが、1 返答あたり µs 程度なので任意（E5）。

### CS9【延期推奨・test のみ】latency benchmark が既存の device trial harness を複製している
- **箇所**: `ResponseLatencyDeviceBenchmark.trial`（HEAD:119-165）は、`SupertonicIntegrationDeviceTests.trial`（:89-129）とほぼ同じ手順を繰り返している。speaker と trace の準備、100ms の sampler、90 秒の deadline と `cancelAndWait`、後片付けの順序、events の encode。
- **コスト**:
  - private な helper を closure で受け渡すための配線が、約 12 行ある。
  - 2 つの copy は、すでにずれ始めている: `inputs` に `processedChunks` が無い、error の文字列化が異なる。
- **案**: 既存の `trial` に `prepareFirstSentence:` と追加フィールドの引数を足し、benchmark は extension から呼ぶ。
- **延期の理由**: 証拠の行の形式と同じ build での比較を保つには、実機で取り直す必要がある。merge 後の整理として記録する。
- 指摘元: R1、A7。

### CS10【任意・小】不一致時に取り消しが効かない区間
- **何が起きるか**: 推論が vendor の denoise loop に入るまでの区間では、取消が効かない。`SupertonicEngine.synthesize` の中の `textProcessor.call`、`loadVoiceStyle`（約 290KB の JSON を decode）、duration と text encoder の推論がそれにあたる。
- **案**: `SupertonicEngine.swift:61-62` の間（loadVoiceStyle の後、`tts.call` の前）に `try Task.checkCancellation()` を 1 行足せば、vendor の外のまま取消を早められる。
- 振る舞いを変えるのは、取消のタイミングが早まることだけ。効果は ms 程度で、不一致の返答 1 回につき 1 回だけ。
- 失敗した gate の分解では残差の主因が PCM 開始側だったので、優先度は低い。
- style の cache は、spec が同梱しないと決めているので延期。
- 指摘元: E1。確信度は中。

## 不採用・延期（理由つき）
- **E2: 確定文の正規化を、候補と原文が一致したら再利用する**: spec 4（確定文は通常どおり読み補正する）に反する。注入される normalize に純粋性の契約も無い。効果は µs 程度なので不採用。
- **E3: debounce Task を nonisolated にする、または send の後で join する**: 効果は µs で、後者は既存の race の決着の仕方を変える。不採用。
- **A6/R9: 2000 の上限が 6 か所に散っている**: 散らばりは今回より前からある。共有定数化は別作業で延期。speaker の検査自体は reuse 経路の spec 5 に必要なので残す。
- **R10、S8: テスト用の偽物や makeSUT の共通化**: 価値が低い。このファイルの既存の書き方（30 か所が inline で組み立て）に合わない。
- **Vendor の Helper に入れた step 間の取消**: 深さはここが正しい。wrapper からは同期ループを止められない。
- **`<=16` と 75ms を置く層**:
  - `<=16` は、正規化後の文字列を見られる唯一の層である speaker にあり、正しい。75ms は spec どおり playback にあり、正しい。
  - 問題は名前が無いことだけ（CS5）。
- **候補の扱いの他の層**:
  - `next()` が候補を読み飛ばすのは正しい封じ込めで、使っている側に候補の存在は漏れていない。
  - 候補を ReplySentenceBuffer で検出するのも、保護区間を知る唯一の層なので正しい。
- **E2 の亜種: 元文字の長さで適格性を前もって絞る**: Latin をカナにすると長さが伸び縮みするので、意味が変わる。不採用。
