# Idle Cat Life Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make a waiting cat subtly alive and add a cute yawn before sleepy.
**Architecture:** A cancellable face sequence runner renders sparse keyframes, with a deterministic planner and injected clock/random source for tests. The existing inactivity owner supplies an activity generation and the existing motion owner admits or rejects optional eye-led neck cues. Claude owns vector geometry/render comparison; Codex owns scheduling and integration.
**Tech Stack:** Swift 6, SwiftUI, XCTest, existing macOS face render harness.
**Spec:** docs/superpowers/specs/2026-10-30-idle-cat-life-design.md

## Global Constraints
- Existing nine expression presets remain unchanged; no audio/model changes or new dependencies.
- Neck: existing MotionCoordinator only, yaw ±3°, pitch ±2°, speed 10; no delayed replay.
- Disable decorative movement for Reduce Motion, inactive/background, sleeping and active interaction.
- Preserve inactivity deadlines; one yawn per visible eligible inactivity episode.
- Codex image generation → Claude vector tracing → existing renderer and comparison checks.

## Review Focus
- Listening with new partial words must immediately cancel idle behavior (Task 2).
- Settings/background return must not replay a yawn (Task 2).
- A cancelled sequence must not send a late neck cue or overwrite a newer pose (Task 2).
- Tracking, stale hardware status, tool reservations and disabled idle movement must reject neck cues (Task 3).
- New mouth and eye paths must not alter existing presets or clip at full opening (Task 1).

### Task 1: Trace and verify the yawn
**Files:** CatRobot/Conversation/UI/CatFaceAppearance.swift, CatFaceShapes.swift, new CatFaceRenderer.swift extracted from CatFaceView.swift; scripts/face-render/* and render_face.sh; CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift; docs/design/idle-cat-life-2026-10-30/*.
**Interfaces:** CatFaceAppearance.yawn: CGFloat (default 0), static yawning: CatFaceAppearance; Eye.blink: CGFloat (default 0); internal CatFaceCanvas accepts appearance/mouthOpening/blink/lineScale. Existing preset values and view initializer remain source compatible.
- [x] Capture baseline with scripts/render_face.sh preview /private/tmp/cat-idle-life-20261030/baseline (completed before edits).
- [x] Add geometry checks for full yawn contained in canvas, shut eyes, open mouth, and yawn=0 preserving existing shape; run check expecting missing feature failure.
- [x] Claude traces the generated reference and adds interpolatable properties; update renderer/harness source lists.
- [x] Render full yawn plus existing presets; compare color masks, bounds, overlay and unaffected presets against baseline. Iterate tracing until geometry agrees within raster/antialias limits; document any unavoidable reference texture difference.
- [x] Run geometry and iOS face rendering tests; commit verified vector work.

### Task 2: Schedule and interrupt face life
**Files:** new CatRobot/Conversation/UI/CatFaceLife.swift; CatFaceView.swift; ConversationViewState.swift; ConversationView.swift; ConversationInactivity.swift; AppRootView.swift; new CatRobotTests/Face/CatFaceLifeTests.swift; ConversationViewStateTests.swift.
**Interfaces:** CatFaceLifeContext(expression, enabled, activityGeneration); CatFaceLifeFrame(appearance, duration, hold, neckCue); CatFaceLifePlanner produces sparse sequences; CatFaceLifeRunner.run(context:) uses RobotClock and RobotRandomSource, emits frames and optional neck cues. ConversationViewState.allowsIdleFaceLife gates real waiting. Inactivity.activityGeneration advances only on accepted activity/wake.
- [x] Add RED tests for listening eligibility, suppression by interaction/held/look/typed/error/memory states.
- [x] Add RED tests for bounds/spacing, sleepy blink, closed-eyes large-mouth yawn, one-shot episode, no initial/re-entry replay, cancellation before a neck cue, and restoration of actual preset.
- [x] Implement planner, cancellation-safe runner and SwiftUI animation integration without a perpetual display timer.
- [x] Use transient pose only for eligible neutral/sleepy; route lifecycle and settings gating from ConversationView.
- [x] Regenerate projects and run focused behavior/view tests; commit.

### Task 3: Couple occasional neck cues and verify
**Files:** Motion/RobotMotionControlling.swift, MotionCoordinator.swift; App/ConversationAppCoordinator.swift; ConversationActions in ConversationViewState.swift; MotionCoordinatorTests.swift; docs/validation/2026-10-30-idle-cat-life.md.
**Interfaces:** setIdleFaceDriven(Bool); requestIdleFaceMotion(yaw: Double, pitch: Double); cancelIdleFaceMotion(). Protocol defaults remain no-ops for non-hardware consumers. App uses face-driven idle scheduling; motion retains all admission guards.
- [x] Add RED tests: no autonomous random columns in face-driven mode, accepted cue obeys caps/speed, rejected cue is never queued, tracking/tool/status/settings/background/idle-disabled gates, interruption invalidates pending writes.
- [x] Implement synchronous admission into existing idle column, cancellation and app action wiring.
- [x] Run focused motion, app lifecycle and face suites; verify existing render regressions, then full simulator suite and project-generation contract.
- [x] Inspect static and animated render artifacts and authorized iPhone presentation; record limitations without claiming unobserved hardware results.
- [x] Run a fresh whole-branch review with requesting-code-review and evaluate feedback with receiving-code-review; resolve material findings and rerun affected checks.
- [x] Commit and leave the completed feature branch available. Main merge/push was outside the initial request; the later explicit request authorizes a squash merge to main and push after Claude simplify, reciprocal review, and final verification.

## Completion record
Tasks1–3 complete. Kept one cohesive feature commit because rendering, scheduling and app ownership integrate together. Final evidence: docs/validation/2026-10-30-idle-cat-life.md. User delegated detail choices; the vector preserves existing palette and uniform mouth stroke, with measured reference residuals explicitly documented instead of claiming pixel identity. The first three whisker comparisons were superseded by the corrected cream|white mask in round4.

## Follow-up integration
The user subsequently authorized Claude `/simplify`, independent Codex subagent review, reciprocal `receiving-code-review`, and squash merge to main with push. The reviewed feature ends at `1c11416`; final checks ran on the identical squash-applied main tree. See the validation document and its merge-results.json for results.
