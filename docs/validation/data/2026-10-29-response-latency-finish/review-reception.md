# Root: technical reception and decisions

Read both complete reports, verified findings against current code and frozen3472b95. Applied superpowers:receiving-code-review: source verification before edits, no blind agreement. Claude and the independent reviewer also receive each other's reports in separate preserved files. Root remains sole writer.

## Important completion gate
Fresh I1 accepted: main's restored kanji-preserving pronunciation changes the workload admitted by the normalized16-character bound. Old all-kana54-trial evidence cannot certify current runtime. Added kanji-heavy16-character mismatch and Latin/Japanese delayed-hit fixtures; preserve existing katakana boundary. Require fresh66 rows, all <=100ms per-fixture paired p95 regression and all required3/3 reuse+median improvement; current-model smoke and current source/native receipt. Clearly mark old report historical. Closed by current66/66 foreground paired successes and all11 acceptance gates PASS on76a8a9b, plus3/3 current-model smoke successes. Sources263 match, native receipt matches, normal launch restored. See paired/cloud raw data and summaries.

## Claude simplify findings
- CS1 accepted with correction: the recorded8/2/1.05 fields validate artifact consistency, not live observed engine options. Wording 'never fails' is too broad. Keep validator; document declarations and verify actual speaker steps8, Helper thread2/default speed1.05 through tested source hashes. Merely sharing a constant would not turn metadata into observation. No extra runtime telemetry/API.
- CS2 accept a small same-task rethrows trace helper, preserving tool concrete types, TaskLocal scopes, actor hops, returned values and error/cancel outcomes. Verify existing tool/trace/turn tests and strict Swift6 compilation. No generic wrapper or extra test-only production API.
- CS3a accept common confirmed fallback; keep cancellation check on failed hint. CS3c accept typed begin/end enum values and derive callback rawValue. CS3d accept one trim after raw length/NUL validation. Rename local speculative task to candidateSynthesis to distinguish model preparation lifetime.
- CS3b defer async-let/owned-task restructuring: sound structured-concurrency idea but trace scheduling/compiler constraints were not proven by read-only reviewers; current explicit cancel/join is tested with uncooperative inference. Keep those safety checks and ownership visible. No need for a new drain abstraction this close to integration.
- CS4 accept one committed-sentence send helper, keeping event/send order. Keep existing explicit pending timer cancel/join sites rather than introducing a nested mutable-state capture helper.
- CS5 accept named normalized grapheme limit and stable Duration (16 and75ms unchanged), reference current bound in boundary assertions and twice-delay in protected-prefix test. Keep hand-checked literal fixture lengths in addition. Defer extra Fixture expected-attempt property: only three test IDs are involved, all checked physically; new schema/initialization plumbing adds little here.
- CS6 defer actor hint-state enum rewrite and removal of candidate release/failure guard. Candidate release frees storage; explicit guard is legible. Accept safe optional binding in cancelSend/cancelReceive, preserving UUID gate and continuations.
- CS7 defer offline summary traversal optimizations/shared constants: small fixed data, not speech hot path; preserve strict validation and established schema. No demonstrated correctness defect.
- CS8 accept direct snapshot assignment when ready==endIndex (Swift String value semantics; same characters). Defer ordinal enum helper and firstCandidate micro-cache: negligible cost and existing trace dedup correctness.
- CS9 defer device harness consolidation: test schema/lifecycle refactor unrelated to current production latency; avoid mixing it into acceptance.
- CS10 defer extra cancellation checkpoint/style cache: checkpoint changes cancellation timing and is outside behavior-preserving simplify; no demonstrated gate need, cache explicitly excluded by design.
- Explicitly reject reuse of candidate normalization for confirmed input, prefiltering by original length, nonisolated debounce, and moving join after send. They change approved semantics or race settlement. Keep confirmed re-normalization, normalized eligibility and join ownership.

## Independent minor and declined-to-judge rulings
- Fresh M1 deferred: no current timer-reset defect shown. Existing cancellation implementation is intact; deterministic pre75ms timer-reset coverage would need a timing seam or scheduler-sensitive sleeps. Do not introduce that runtime abstraction at closing. Cost: this distinct future-regression trigger remains less directly covered.
- Language quality: preserve user-selected Latin-only correction and main's tested native package; latency review is not a complete pronunciation audit. Cost if wrong: unsupported/rare input may still fail or sound unnatural; no broad quality claim.
- Acoustic/ASR/ordinary conversation gain: replay callbacks and small typed smoke only. Actual voice boundary timing not collected; no broad daily-use speedup claim. Cost: observed fixture improvements may not transfer to normal use.
- Long-duration thermal/energy: retain cooldown, per-run heat/footprint data; no endurance or energy guarantee. Cost: long sessions may differ.
- Hard native-call deadline: retain per-step checks, serial inference and cancel/join; current measured gate required, no mathematical bound promised. Cost: individual ONNX call can still delay cancellation.
- Unchanged memory/ASR/robot logic: preserve order and run integrated whole suite, without whole-app audit. Cost: unrelated latent defects are not ruled out.
- Build/project certification: executor runs full Swift suite, project contract, Python and asset/native receipt checks and source equality, rather than accepting read-only reviewer certification. Cost if source proof wrong: results could attach to a different implementation.

Final current acceptance and fix verification are recorded in the accompanying validation report/ledger; a pending benchmark never counts as passing.
