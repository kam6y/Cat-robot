# Voice Barge-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Let a person interrupt the cat by voice without losing their first words or treating unheard audio as delivered.
**Architecture:** Share an echo-cancelled audio graph between recognition and PCM playback. A capture survives reply interruption while owned tasks cancel/join the previous reply. A delivery receipt corrects only the interrupted turn's memory.
**Tech Stack:** Swift concurrency, AVAudioEngine voice processing, SpeechAnalyzer, existing Claude and Supertonic, XCTest.
**Spec:** docs/superpowers/specs/2026-10-30-voice-barge-in-design.md

## Global Constraints
- Keep Claude, Supertonic, selected voice and the 1.2-second utterance boundary.
- Concurrent recognition is permitted only with a confirmed echo-cancelled path; unsupported paths retain half-duplex behavior.
- Never log conversation text or send audio to a new provider.
- Maintain task/generation ownership through every await; explicit stop and route/lifecycle changes supersede old work.
- User delegated design approval to Codex/Claude agreement. Native pair implementation; Codex owns simulator/device operations and git commits.

## Review Focus
- First ASR words arrive while old synthesis cancellation is blocked: Task 3 must retain them without overlapping replies.
- Completed generation is ahead of playback: Task 2 must remove unheard sentences and distinguish partial playback.
- Reset/forget or a newer reply races an old correction: Task 2 must leave newer/deleted memory untouched.
- A capture/playback stop or route change arrives during graph startup: Task 1 must release only the correct owner and never enable raw concurrent capture.
- Natural completion races an interruption or repeated interruptions: Task 3 must retain one live capture and reject late old caption/mouth callbacks.

### Task 1: Echo-cancelled duplex audio (Claude)

**Files:** New Services/ConversationAudioEngine.swift and service tests; modify AppleSpeechRecognizer.swift, AppleAudioSessionController.swift, Supertonic/PCMPlayer.swift, App composition and related audio/composition tests.
**Interfaces:** Consumes SpeechRecognizing.supportsConcurrentPlayback: Bool { get async } (default false, Codex adds it). Produces a shared engine injected into recognizer/player; recognizer returns capability only for a successfully configured AEC path. Existing prepare/start/stop and speak/stop signatures remain.

- [x] Add failing ownership tests: stop capture retains playback; stop playback retains capture; audio-session deactivation releases engine; failed voice processing cannot enable concurrent capture; startup/cancellation and stale-stop race cannot stop newer owner.
- [x] Codex runs affected suites and records RED before implementation.
- [x] Implement shared graph and injection, including actual input format conversion and voice-processing/ducking settings supported by installed SDK. Keep unsupported-path behavior safe.
- [x] Codex runs targeted audio/recognizer/speaker/composition tests and records GREEN.
- [x] Commit the integrated audio/control/memory change after both agents review it (shared protocol and project references require an atomic buildable commit).

### Task 2: Delivery receipts and interrupted memory (Codex)

**Files:** New Domain/ReplyDelivery.swift and tests; modify ConversationServices.swift, ReplyPlaybackCoordinator.swift, SentenceReplyPlayback.swift, MotionReplyGenerator.swift, ClaudeConversationService.swift, OnDeviceFallbackReplyGenerator.swift, FoundationModelReplyService.swift and playback/memory tests.
**Interfaces:** ReplyDeliveryContext.current is a task-local UUID. ReplyInterruption carries id, prompt, completedText and interruptedSentence flag. ReplyGenerating.interruptReply(_ interruption: ReplyInterruption) async has a no-op default. Coordinator.interruptAndWait() cancels and joins current playback and applies its immutable receipt once. Generic cancelAndWait remains unchanged. A sentence-enqueued update carries original text/ordinal for delivery accounting.

- [x] Add tests for finished-first/partial-second, no audio yet, late finished events, duplicate interruption, and queue removal; add memory tests that correct a fully generated reply and preserve earlier turns.
- [x] Run tests and confirm expected missing-feature failures (add interface scaffolding only if needed to reach behavioral RED).
- [x] Implement immutable progress snapshots and cancellation joining; track exact delivery IDs/revisions/operation epochs in primary/fallback memory.
- [x] Add/verify stale correction after reset/forget/newer turn, cancelled generation, compaction and persistence failure behavior. Invalidate cached model context without clearing unrelated memory. Fallback forwards receipt and drops its uncorrectable cached session.
- [x] Run playback, Claude/fallback, memory and motion suites; include this independently verified change in the integrated implementation commit.

### Task 3: Keep capture across voice interruption (Codex)

**Files:** Modify ConversationViewModel.swift, test fakes, and new ConversationBargeInTests.swift.
**Interfaces:** Start concurrent capture before voice generation/fixed speech only when supportsConcurrentPlayback is true. Keep capture ID/segmenter when interrupting. One interruption task cancels old turn, calls interruptAndWait, then releases segmentation to begin the new turn. Lifecycle detach joins it. Do not enable microphone for a paused typed-only reply.

- [x] Add behavioral RED tests: capture open during generation/speech; first partial stops old reply and final begins next reply; next words during blocked speaker stop remain intact; punctuation-only recognition does not stop speech.
- [x] Implement concurrent capture admission and promotion to listening on natural completion, invalidating old turn ownership synchronously before awaits.
- [x] Add RED/GREEN regression tests for repeated interruption, stale old updates, route/background/settings pause, capture failure, fixed clarification, and finish-vs-interrupt race.
- [x] Run all related conversation/motion/idle/lifecycle tests, then include the change in the integrated implementation commit.

### Task 4: Whole-branch verification and device evaluation (joint)

**Files:** Update README conversation behavior and add docs/validation/2026-10-30-voice-barge-in.md with commands/results/limits.

- [x] Exchange reviews of audio and control/memory changes; obtain one fresh whole-branch code review and address Critical/Important findings with focused regression tests.
- [x] Run full simulator suite, diff checks and iPhone build on the final source.
- [ ] Evaluate known cat speech only and known external speech on device; record false interruptions, detection-to-stop timing, capture continuity, volume/voice change and route limitations. Do not conflate mocked tests with acoustic results.
- [x] Save validation findings and commit the finished work. Keep scope to #18; later conversation improvements remain Issues #19–#21.

## Final status

Implementation, reciprocal review, independent review with its Important finding fixed, full simulator tests, and signed iPhone test build are complete. The app was subsequently installed on iPhone 16 Pro; cold start, three immediate pause/resume cycles, and background resume intent passed after fixing internal audio-route notifications. Actual acoustic acceptance remains pending. On 2026-10-31 the user authorized simplification, reciprocal review, final verification, and squash integration into main with push. Keep Issue #18 open for the remaining acoustic evaluation; see docs/validation/2026-10-30-voice-barge-in.md for evidence and limits.


The 2026-10-31 integration review is complete: Claude simplification and reciprocal review accepted, the full-playback interruption annotation race reproduced and fixed, 960 simulator tests passed with 4 device-only skips, project-generation contract passed, and signed iPhone build verified. The acoustic acceptance checkbox above intentionally remains open.
