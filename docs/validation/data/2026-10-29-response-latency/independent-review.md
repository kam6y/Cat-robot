# Fresh final code review — response latency

Reviewed base `7733e201cf0bf7d9feeea7352a11d4e82b8c2d03` through head `857495898adfa201ebfc98ca07f1a9724c7fb04f`, the supplied review package, approved design, implementation plan, and progress-ledger rulings. This was a read-only source review: no builds, tests, repository edits, index/HEAD changes, or delegated reviewers. The reported focused test passes and deterministic-generation pass are executor evidence, not checks rerun by this reviewer.

## Strengths

- The committed parser output remains separate from the tentative hint. Eligibility uses the existing quote/code/URL-aware boundary parser, ordinal zero, stable-prefix capability, and a 75 ms canonical-content timer. The channel keeps its bounded committed queue and prioritizes committed input, failure, and closure over a stored hint (`ReplySentenceBuffer.swift:93`, `SpeechSentenceChannel.swift:21`, `SentenceReplyPlayback.swift:100`).
- Speculative synthesis is owned by the active speaker operation. A changed confirmed synthesis input cancels the task and awaits its result before final synthesis; error, end-of-input, and cancellation paths also join it. The main playback loop checks cancellation before auditing or playing PCM (`SupertonicSentenceSpeaker.swift:74`, `:114`, `:130`, `:135`, `:217`). The added gated mismatch test explicitly holds an uncooperative inference open and checks maximum concurrent synthesis remains one.
- Confirmation normalizes the original again, checks the untrimmed normalized limit/NUL/empty constraints, and only reuses equal canonical input under the operation's captured voice. Original text is carried separately to the audit and captions. PCM validation completes before reuse (`SupertonicSentenceSpeaker.swift:122`, `:144`, `:174`). Generation failure while speculative PCM is ready cannot flush the unconfirmed tail into playback.
- Existing queue-backpressure/failure and complete-output coverage remains alongside new hit, mismatch, candidate-only failure, cancellation/next-turn, whitespace, limit, and protected-prefix cases. Motion release remains tied to actual speech-start updates, not preparation. The engine remains actor-serialized, with cancellation checks added between native denoising steps and before the vocoder without changing inference arithmetic.
- Trace additions use typed, content-free metadata and close synthesis/tool intervals on failures. The physical benchmark alternates baseline/prepared ordering, uses the selected voice and fixed inference settings, and retains raw trace/input/resource records. Cloud smoke uses isolated memory/usage and no-op robot/camera controllers.
- Normalizing the generated project diff's GUIDs leaves only the new benchmark source/file membership additions; no logical resource/build-setting removal was observed. The ledger's reuse of existing runner/reporting infrastructure is reasonable.

## Issues

### Critical

None found.

### Important

None found in the reviewed implementation. Physical acceptance is still pending and is not treated as a passed gate.

### Minor

1. **Thermal and cooldown summaries combine all modes instead of the named group.**
   - Location: `scripts/summarize_supertonic_integration.py:126-127`.
   - Evidence: the loop was renamed to `for key, group_rows in grouped.items()`, but `cooldownSeconds` and `hotEnds` still iterate the outer `rows`. All other per-group summaries use `group_rows`/`good`. With baseline cooldown 2 s/no hot ending and prepared cooldown 7 s/one hot ending, both group summaries therefore report 9 s/one hot ending.
   - Effect: the exported report cannot accurately compare thermal behavior or cooldown cost between baseline and preparation, and combining historical stages also contaminates each stage's totals. Start-time acceptance calculations are unaffected.
   - Recommendation: use `group_rows` in both comprehensions and add a regression case with unequal cooldown/hot-ending totals in two groups.

## Recommendations

Fix the small reporting defect before writing durable device conclusions. Complete the already-planned integrated suite and physical acceptance runs, and tie the final report to the actual tested source. Preserve the distinction between playback callback timing and an acoustic measurement; no numerical improvement or subjective sound-quality claim is justified by this source review alone.

## Declined to judge

- Actual iPhone median improvement and immediate/changed-candidate p95 regression: the physical acceptance run is pending; no device results were supplied as completed evidence.
- Actual memory/thermal change, audible glitches, and subjective voice quality on hardware: these require the pending physical records/listening, not inference from host tests or code.
- Final integrated full-suite and final evidence-document completeness: Task 3 is explicitly in progress; this review did not run tests or treat pending artifacts as completed.
- Previously merged jpreprocess correctness and unrelated native pronunciation behavior: explicitly excluded from re-review; only the existing input-validation/cancellation boundary needed by this change was inspected.
- Generated GUID spelling/order: intentionally excluded as generator churn; logical source/resource/build-setting changes were inspected instead.
- Alternative models, voices, reasoning effort, silence thresholds, memory/usage ordering, and speculative LLM/tool execution: outside the approved optimization scope; no expansion into those alternatives is recommended.

## Verdict

**Code review: acceptable with one minor reporting fix; no Critical or Important findings.**

**Ready for final acceptance/merge: not yet established.** The ownership, confirmation, and validation implementation is consistent with the approved contract, but the scheduled full-suite and device acceptance evidence must still establish readiness. This verdict does not authorize merging or replace those gates.
