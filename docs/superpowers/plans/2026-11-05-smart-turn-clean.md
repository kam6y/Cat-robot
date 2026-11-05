# Smart Turn clean implementation plan

Spec: docs/superpowers/specs/2026-11-05-smart-turn-clean-design.md
Base: 6ddf6ba. Historical source: 0249e34.

## Global Constraints
Keep work in the existing isolated worktree on feature/smart-turn-clean. Execute inline; no implementation delegation. One Xcode/device process at once. Preserve backup branches and historical evidence. No merge/push. No comparative harness or linguistic endpoint rules. Required model assets remain pinned and git-ignored.

### Task 1: Restore the audio-only service
Interfaces: AudioTurnEndConfiguration/State/Signal; AudioTurnEndCapture; SmartTurnService; pinned resources.
- [x] Port only the previously tested isolated audio service, model/resource code and its tests from 0249e34. Add a failing behavioral test proving the default service requests after 7 silence frames, rejects p=0.5, accepts >0.5, and times out once after 94 frames.
- [x] Run focused audio tests. Expected: new default-policy test fails on old defaults.
- [x] Remove legacy policy switches; make the sole policy strict >0.5/7/94. Update old tests to explicitly test their chosen internal configurations or the sole policy. Run focused audio and asset tests. Expected: all pass.
- [x] Commit the service and model packaging.

### Task 2: Connect Smart Turn to the original conversation lifecycle
Interfaces: optional audio event; recognition driver; original segmenter/VM closing lifecycle; live composition.
- [x] Add compile-compatible inert audio-event/segmenter interfaces and behavioral tests for provisional-only close, unfinished words without suffix rules, final tail exactly once, punctuation/no activity, stale/resumed signals and old capture IDs, plus ordinary half-duplex continuation.
- [x] Run tests. Expected: audio closure tests fail because the base ignores the signal.
- [x] Implement only recognition tap/preparation/release hookup, segmenter audio close and configurable fallback, VM event handling, live Smart Turn service and attribution.
- [x] Run targeted integration tests. Expected: pass. Verify no changes to base playback, memory and audio-session source.
- [x] Commit integration.

### Task 3: Verify and deliver the normal app
User amendment: remove added fallback, propagate model/pipeline errors, and preserve cancellation. User clarification (2026-11-06): the original ASR 1.2-second silence endpoint is a primary path and remains; remove only later 3-second timeout/override and 100 ms abandonment. Earlier strict audio-only temporary configuration is superseded. Final review identified preparation cancellation forwarding; parent also reproduced dropped latest-pause inference. Both are covered by RED/GREEN and the final suite.
- [x] Run complete simulator suite, Python asset checks and generated project validation. Expected: no test failures; device-only tests may skip.
- [x] Commit candidate and request one fresh whole-branch review against 6ddf6ba. Re-grade findings; fix material issues with RED/GREEN and a green suite. No re-review.
- [x] Build a signed normal app, verify no test plug-ins and valid signature, install and launch on the connected iPhone. Expected: successful process launch, Smart Turn enabled through normal composition.
- [x] Record evidence, removed-feature scope and review rulings in a new validation report; commit and leave branch clean.

## Review Focus
Check half-duplex base lifecycle is unchanged outside necessary endpoint integration; no legacy barge/heuristic/adaptive/FM/comparison code survives. Check required model preparation is cancellable without joining synchronous work and actual failures stop with an explicit error; preserve the original ASR primary endpoint; actual tap hookup and teardown feed/retire the audio gate correctly. Check stop-final text is neither lost nor duplicated, stale/resumed/raw-pending signals cannot close, no-activity signals cannot produce phantom turns, and production composition enables the same sole policy tested. Inspect all resource/build dependencies. Synthetic prior evidence does not establish human or noisy-room accuracy.
