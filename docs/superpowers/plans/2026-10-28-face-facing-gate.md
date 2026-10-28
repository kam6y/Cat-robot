# Face Facing Gate Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans. Codex owns production changes and execution; the user explicitly requested agmsg pair programming with Claude, who owns test changes and reciprocal review.

**Goal:** Follow only faces approximately oriented toward the cat, preserving existing loss and camera behavior.

**Architecture:** Carry Vision yaw/pitch metadata in FaceRectangle. Filter valid rectangles by finite angular limits before the existing deterministic target selection. Reuse the coordinator's empty-candidate hold and 10-second return path.

**Tech Stack:** Swift 6, iOS 27, AVFoundation, Vision revision 3, XCTest.

**Spec:** docs/superpowers/specs/2026-10-28-face-facing-gate-design.md

## Global Constraints

- Capture remains configured at 3fps with image buffers no larger than 640×480.
- Eligibility: the current rule (correction-centered yaw window, pitch limit, inclusive bounds) is defined only in the [spec](../specs/2026-10-28-face-facing-gate-design.md)'s 方式 section. Both angles must be present and finite; unknown angles fail closed, and orientation is checked before the existing ranking.
- Existing freshness, capture-time pose, generation, heat, background, audio and snapshot behavior remain.
- No ARKit, eye-gaze model, new UI settings, new periodic task, commit or push as part of this implementation trial.

## Review Focus

- Missing or nonfinite orientation must not enable motion or renew the loss deadline.
- A nearer turned face must not mask an eligible farther face.
- An ineligible newer frame must invalidate an older pending eligible frame.
- A returning face must resume only through existing freshness/pose checks.
- Adapter radians, upright orientation and request revision must agree with test inputs; physical thresholds require real-person validation.

### Task 1: Gate face selection by head orientation

Historical: Task 1 implemented the initial gate, yaw ±30° around 0 (not yet correction-centered) and pitch ±25°. The follow-ups in the execution record below changed it.

**Files:**
- Modify: CatRobot/FaceTracking/FaceTrackingTypes.swift, FaceTrackingGeometry.swift, AppleFaceCaptureSource.swift
- Test: CatRobotTests/FaceTracking/FaceTrackingGeometryTests.swift, FaceTrackingCoordinatorTests.swift, FaceTrackingTestDoubles.swift
- Inspect/update explicit synthetic faces in CatRobotTests/Vision/ConversationCameraTests.swift if needed.
- Document: README.md and docs/validation/2026-10-28-face-facing-gate.md

**Initial Task 1 interfaces:** FaceRectangle adds optional yawRadians and pitchRadians, default nil for absent metadata. The initial gate kept selectFace/project signatures unchanged. The later correction-centering follow-up below makes yawCorrection mandatory for selectFace; project and the coordinator-facing API remain unchanged.

- [x] Run existing geometry, coordinator and motion tests before changes: 67 tests, zero failures.
- [x] Claude adds an existing-API missing-orientation rejection test; Codex runs it and records the expected failure.
- [x] Codex adds the optional metadata contract and adapter propagation. Claude writes angular and coordinator behavioral regressions, explicitly setting frontal angles in existing valid test fixtures.
- [x] Run new regression tests before adding the angle predicate; confirm failures describe unfiltered sideways/missing faces and incorrect loss renewal.
- [x] Add the finite, inclusive radian angle predicate to the common face selection filter. Keep projection and loss timing unchanged.
- [x] Regenerate the project and run the deterministic generation contract.
- [x] Run all face tracking, motion, capture/camera sharing and look-related regression classes. Expected: all pass with no failures.
- [x] Review the full diff with Claude and a fresh code reviewer; fix verified blockers and validate relevant changes.
- [x] Build the signed Debug app for generic iOS: BUILD SUCCEEDED, exit 0.
- [x] Install/launch on the already-used iPhone after the user reconnected it: both exit 0; running PID 2234 matches the new installation path. Real-person orientation/servo behavior remains unverified.

## Execution record

Entries are chronological. Thresholds, counts and PIDs in each entry describe the version tested at that time; the current rule is in the spec.

Baseline HEAD 33aa9ea; branch feature/face-facing-gate in the existing b200 worktree. Baseline evidence: /private/tmp/cat-facing-tracking-20261028/baseline.log and baseline.xcresult.

Ruling: Continue directly with the user's chosen face-orientation approach and requested pair-programming method; no additional design approval loop. Thresholds are an explicit implementation starting point, not measured accuracy claims.

Ruling: Preserve the pre-existing fresh eligible pending-image deferral at the 10-second boundary; it does not renew lastFaceAt. Ineligible observations clear pending immediately. Both reviewers requested more precise prose, not a change to this behavior.

Verification: RED missing=1 test/2 assertion failures; RED angles=44 tests/35 assertion failures; GREEN related=143 tests/0 failures; generator contract PASS. Source was then frozen for review/device build.

Delivery (initial version): implementation, regression checks and review were complete; feature branch and worktree were retained without commit/push. Generic signed iOS build passed. After the user reconnected the iPhone, installation/launch succeeded and the new process path was verified. No further source work was required at that point; real-person threshold tuning was left as an observational check.

### Follow-up (historical, superseded): Narrow the bounds

User tuning follow-up: narrowed yaw30→20 degrees and pitch25→15 degrees after real-device trial. Updated existing inclusive/outside boundary tests first: 20 tests, 8 expected assertion failures before the production limits changed. Geometry/coordinator/motion revalidated:74 tests, 0 failures; generator check and signed iOS build passed. Claude delta review found no blockers. Installed/launched on iPhone and verified new process path (PID2260); no state-machine or capture changes. The last follow-up below restored the wider bounds.

### Follow-up: Center the yaw gate on saved camera correction

User request: 左右20°の中央をカメラ位置の補正値に基づいて決めてほしい.

The correction centering remains current; the ±20° half-width used here is historical and was replaced by the next follow-up.

- [x] Claude writes regressions through existing project/coordinator APIs for shifted acceptance/rejection, fractional and endpoint settings, multi-face choice, pending hold and settings changes; root verifies RED: 50 tests, 13 expected assertion failures, exit 65.
- [x] Root changes selectFace to require yawCorrection, validates it, and uses closed radian bounds derived from [-c-20, -c+20]. Pass the same setting in both coordinator receive and project; update zero-correction tests explicitly.
- [x] Verify geometry/coordinator/motion/preferences/camera integration: 149 tests, 0 failures, exit 0. Project generation contract and Claude delta review passed. Signed build, install and launch succeeded; verified new device process PID2327.

Sign evidence: existing unmirrored capture and left camera mount; independently checked actual Vision revision3 outputs on upright images. Root used public Apple WWDC2021/10040 demo crops (image-right nose +65.65°, image-left nose -22.63°), so the demo preview mirroring does not determine the sign. A left camera means the screen lies toward image left as viewed from the camera. The saved correction remains an approximate distance-dependent alignment, as before.

### Follow-up (current bounds): Restore wider bounds while preserving correction centering

User explicitly selected: 補正した中心を維持し、左右±30°・上下±25°へ戻す. Preserve the saved preference, selection API and both correction call sites. Change only the yaw half-width and pitch bound, with existing tests and current docs updated. Earlier execution records remain historical.

- [x] Update existing angular/coordinator boundary cases; verify RED against narrow bounds: 50 tests, 17 expected assertion failures, exit 65.
- [x] Set yaw range to [-c-30, -c+30] degrees and pitch to ±25 degrees. Related 12 classes: 149 tests, 0 failures, exit 0; generator PASS. Claude delta review had no code blockers; its stale Global Constraints wording was corrected.
- [x] Signed build, install and launch all succeeded. Verified PID2340 at the new installation 265BB905-8945-4D5C-ADFF-3883DEE1F0AE; tested source hashes remain unchanged.
