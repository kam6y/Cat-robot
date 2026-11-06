# Multiple Facing Addressing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept speech without address classification whenever at least one current eligible face looks toward the screen, including multiple-person frames.

**Architecture:** Remove only the one-face rejection in the shared camera attention query. Reuse the current geometry selector and unchanged routing; verify the actual camera-to-conversation boundary.

**Tech Stack:** Existing Swift/Vision/XCTest, fixed native assets and packages; no new application dependency.

**Spec:** docs/superpowers/specs/2026-11-07-multiple-facing-addressing-design.md

## Global Constraints

- Base main b59f0b9dc93d97ee79204e824961bafdd390cb19; branch codex/issue-28-multiple-facing; preserve managed host worktree.
- User explicitly chose Driver/Navigator pair programming with actual Claude via agmsg. Exchange roles at test boundaries and within15–30minutes; one acknowledged source writer at a time.
- Preserve0.4s freshness, head-angle correction/bounds, camera lifecycle/permission/heat, capture sharing, hardware independence, pending yes/no precedence and30s/300s engagement.
- No changes to models, effort/voice defaults, native library, history policy, or speaker behavior. #27/#29 are out of scope.
- Freeze code/test/project/native/scripts input during every build/test. Full unit run excludes the existing two dedicated hardware/paid test classes; no paid API calls are needed for automated tests.
- Prior standalone flow artifact is missing from the current worktree, but its exact delivered copy and generator exist in task-private storage. Restore and update that artifact as required by #28; preserve all unrelated diagram content.

## Review Focus

- A nearer/larger turned-away face must not hide a valid facing face.
- Invalid or unknown head poses must neither grant attention nor hide another valid facing face.
- A multiple-face observation must expire and lose ownership like a single-face observation.
- The real view model must bypass classification and retain the full utterance, without relying only on a mocked attention boolean.
- Confirmation negatives, hardware independence, camera sharing and lifecycle invalidation must remain covered.

### Task 1: Multiple-face admission, coupled behavioral tests and documentation

**Files:** Modify CatRobot/Vision/ConversationCamera.swift, CatRobotTests/Conversation/Integration/FacingAddressingTests.swift, README.md, the FR-CONV-2 living requirement and the superseded issue22 spec note; create/update docs/application-flow.html and dated issue28 validation records.

**Interfaces:** Existing hasFreshFacingFace(yawCorrection: Double) -> Bool, FaceTrackingGeometry.selectFace, ConversationHarness(isFacingScreen:), and live composition callback. No new public API.

- [x] **Step 1:** Run existing FacingAddressingTests, ConversationCameraTests and FaceTrackingGeometryTests unchanged. Expected: all pass as baseline.
- [x] **Step 2:** Codex Driver adds real camera→VM cases in testMultipleFacesBypassClassifierWhenAnyEligibleFaceLooksTowardScreen, using literal multiple-face fixtures and asserting classifier calls empty and reply prompt equal to the entire submitted utterance. Move the old two-facing negative fixture into positive coverage; retain all-invalid/all-turned negatives. Extend live composition and freshness with multiple-face coverage. Claude Navigator reviews the changed tests. Run targeted RED before production edits. Expected: the one-face guard rejects the positive cases.
- [x] **Step 3:** After RED, acknowledge ownership transfer to Claude Driver. Remove the exact-count gate in hasFreshFacingFace; Codex Navigator checks the diff and runs no simultaneous source edits. Freeze and run focused face/camera/routing/tracking tests. Expected: all pass; no other production behavior changes.
- [x] **Step 4:** Exchange roles after GREEN. Codex Driver updates the living README, marks the issue22 single-person condition superseded, and restores/updates the standalone flow with any-facing wording/examples. Claude Navigator checks semantics and artifact operation. Expected: offline diagram works; existing historical review/validation reports remain intact.
- [x] **Step 5:** Run final full XCTest via task-done while source is frozen. Expected: zero failures and skips, matching input/native receipt. Commit tested source with source→commit identity mapping. Meaningful review fixes require RED→GREEN and fresh appropriate verification.

## Whole-branch review and integration

- [ ] Freeze the source and preserve actual Claude /simplify four independent reports and one fresh native whole-branch review before exchange.
- [ ] Mutually receive findings, apply justified Important/Critical fixes, record any Minor deferrals and final scoped verification.
- [ ] Build/install/launch the normal signed preview app with0XCTest/no test arguments and request the real multiple-person confirmation. Continue independent reviews while awaiting it.
- Post-commit gate: fetch latest main, squash to one commit with identical tree, build/install/launch normal final-main app before non-force push; verify remote hash, issue closure and clean worktree. Preserve branch/host, archive/remove only this plan's workspace. Record actual post-commit hashes/PID/status in task-private integration.json.
