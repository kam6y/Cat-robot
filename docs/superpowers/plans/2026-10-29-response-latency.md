# Response Start Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the selected model and voice while hiding first-sentence TTS preparation behind generation finalization.

**Architecture:** The existing parser exposes a tentative complete first sentence without changing its committed output. A bounded channel can offer that candidate after 75ms of stable content; the speaker owns one preparatory task and reuses PCM only after normal confirmation and exact canonical-input validation. Existing cancellation, memory commit, ASR finalization, and later sentence prefetch contracts stay intact.

**Tech Stack:** Swift concurrency, XCTest, jpreprocess 0.15.0, Supertonic 3, ONNX Runtime 1.24.2.

**Spec:** `docs/superpowers/specs/2026-10-29-response-latency-design.md` (user approved).

## Global Constraints

- Work only on feature/response-latency from main7733e20; do not merge/push main.
- Preserve selected model/voice/effort/instructions, memory/usage/forget ordering and 1.2s silence.
- Preserve 8 steps, speed1.05, CPU2threads and inference arithmetic order.
- Ordinal0 only, one candidate attempt and one in-flight inference; later prefetch stays one sentence ahead.
- Canonical input trims edge whitespace/newlines after normalizing; validate raw/normalized limits before trimming; display and memory retain originals.
- Never play or release motion before existing confirmation; failed/cancelled/unmatched preparation is discarded and joined.
- Physical tests use isolated memory/usage; no production memory/settings writes. Host timings are not iPhone acceptance.

## Review Focus

- Candidate corrected after an uninterruptible inference starts: cancel and join before final synthesis, with no stale PCM or overlapping inference.
- Trailing whitespace and punctuation/quote extension: reuse only equal validated synthesis inputs and preserve every original character.
- Generation/normalization failure after speculative PCM is ready: no playback or incorrect error replacement.
- Queue backpressure, unstable prefixes, and next-turn cancellation: preserve complete output and ownership.
- Real device early/late/changed confirmation: improve long-tail first-audio median and limit immediate/miss p95 regression to100ms.

---

### Task 1: Bounded first-sentence preparation

**Files:** Modify `ReplySentenceBuffer.swift`, `ReplySentenceStreamBuffer.swift`, `SpeechSentenceChannel.swift`, `SentenceReplyPlayback.swift`, `ReplyPlaybackCoordinator.swift`, `SupertonicSentenceSpeaker.swift` in their existing Domain/Integration/Services locations; `CatRobot/Vendor/Supertonic/Helper.swift` and `PROVENANCE.md`. Tests in existing `CatRobotTests/Conversation/Integration/SentenceReplyPlaybackTests.swift` and related parser/speaker suites.

**Interfaces:** `ReplySentenceBuffer.preparationCandidate: String?`; `ReplySentenceStreamBuffer.preparationCandidate: SpeechSentence?`; `SpeechSentenceInput` has `candidate`/`sentence`; `SpeechSentenceChannel.offerPreparation(_:)` and `nextInput()` with old `next()` still returning committed sentences. `ReplyPlaybackCoordinator`/`SentenceReplyPlayback` accept `prepareFirstSentence: Bool = true` for paired control trials. `SupertonicSentenceSpeaker` owns preparation internally; synthesize/normalize injected functions remain unchanged.

- [ ] Write `testFirstSentenceSynthesisStartsBeforeGenerationCompletesButPlaybackWaitsForConfirmation` against existing public coordinator/speaker APIs; expect synthesis while reply stream is open and zero playback until finish. Run focused test. Expected: assertion timeout on old code, then cleanly finish the stream.
- [ ] Add gated behavior cases for mismatch/drain, candidate-only synthesis failure, cancelled inference, whitespace reuse, confirmed overlong output, generation failure, unstable/protected prefixes; observe the missing early-preparation assertions fail before implementation.
- [ ] Implement parser candidate exposure without altering confirmed output; bounded candidate delivery separate from committed queue, with committed/error precedence and at most one offered attempt.
- [ ] Own the75ms stable-content timer in enqueue, cancel and join it on replacement/exit; preserve original stream failure and limits.
- [ ] Own candidate normalization/synthesis in speaker; normalize confirmed text again and enforce pre-trim output limit, reuse only equal canonical input/current voice, otherwise cancel/join and synthesize final; audit only committed inputs.
- [ ] Add cancellation checks between denoising steps, no mathematical changes; document vendor change.
- [ ] Run focused playback, parser, channel and speaker suites via external runner. Expected: all pass; no missed/duplicate original text or stale audio. Commit task1.

### Task 2: Timing and device comparison

**Files:** `ReplyTrace.swift`, `OSReplyTraceSink.swift`, relevant four `Conversation/Tools/*Tool.swift` files, `CatRobotTests/Device/SupertonicIntegrationDeviceTests.swift`, a focused device benchmark helper if needed, and dedicated runner/summarizer scripts.

**Interfaces:** Add content-free firstCandidate/preparation/synthesis/tool start/end events with optional typed tool identity. Existing trace decoding accepts absent optional metadata. Device benchmark receives paired `prepareFirstSentence` flags and identical replay snapshots/times; records actual playback timestamps, synthesis counts/hit/miss, memory/thermal and original text.

- [ ] Add behavioral trace tests for tool success/failure/cancellation balancing and absence of content, then make them pass with notice-level timing. Reuse timing hooks for actual synthesis and distinguish discarded attempts from accepted inputs.
- [ ] Build a gated physical stage for immediate, delayed single-sentence, two-sentence, quoted/number, and corrected-candidate streams. Alternate control/enabled order for at least3repetitions; use current selected voice,8steps. Test summarizer on controlled records for missing events/wrong run/source and paired acceptance limits.
- [ ] Add a small real-current-Claude smoke using test-only memory/usage and no real robot/camera side effects; record client-tool and candidate timing separately from fixed replay.
- [ ] Generate project deterministically if files added; run generation contract and targeted tests. Expected: pass. Commit task2.

### Task 3: Acceptance, review and durable evidence

**Files:** New `docs/validation/2026-10-29-response-latency.md` with data subdirectory; `docs/README.md` index.

**Interfaces:** Source hashes tie final tested files to results; matched replay records retain source/run/settings and timing definitions.

- [ ] Run full Swift suite once on integrated code and related asset/generation checks. Expected: zero failures, physical-only tests explicitly skipped.
- [ ] Run signed paired device trials in foreground and real-Claude smoke. Expected: exact original text, one accepted synthesis on hit, no playback before confirmation, delayed first-audio median improvement; immediate/miss p95 regression<=100ms. Adjust only eligibility/delay if measured gate fails and record the reason.
- [ ] Ask existing agmsg Claude for bounded whole-diff review while validation runs; dispatch one fresh final reviewer as executing-plans requires. Receive findings technically and fix material issues with regression tests. Re-run only checks affected by new changes or failures.
- [ ] Save all findings/decisions, paired metrics, source proof, limits and auditory-assessment status. Confirm normal device launch if installed, clean worktree and feature branch state. Commit evidence; do not merge main.
