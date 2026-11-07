# claude_issue25 — Navigator recon for issue #28 (read-only, 2026-11-06 ~17:58Z; branch codex/issue-28-multiple-facing = main b59f0b9d, tree clean)
## Minimal change (one clause)
- CatRobot/Vision/ConversationCamera.swift:60 — delete `observation.faces.count == 1` from the guard; keep `return FaceTrackingGeometry.selectFace(observation.faces, yawCorrection:) != nil`. selectFace (FaceTrackingGeometry.swift:7-23) already filters `isValid && isFacingScreen` BEFORE ranking (comment :12), returns nil for [] and for any invalid correction, so "one or more valid facing faces" == `selectFace != nil`. It is the single definition of a valid facing face; do not add a new predicate/API (Reuse would flag it).
- Do not touch selectFace / project / FaceTrackingCoordinator: neck target choice and camera sharing then cannot regress through this change. Freshness (<0.4 s), generation, permission, heat, listening-phase and eligibility checks are all earlier guard clauses (:57-59) and stay unchanged.
## RED (new test in FacingAddressingTests, uses existing FacingCameraHarness.emit(faces:) so it compiles at HEAD; every case is false at HEAD because of the count clause)
Fresh harness per case, emit the multi-face frame directly, assert isFacing == true (harness correction 8.5 → window yaw [-38.5°, 21.5°], pitch ±25°):
1. facing + turned (yaw 1 rad), and the same pair in reverse order;
2. two facing faces at distinct positions (not the identical-rectangle pair);
3. larger, more central turned face (e.g. x 0.35 size 0.3, yaw 60°) + off-centre facing face (x 0.75) — the issue "not hidden" criterion at camera level;
4. nearer face just outside the corrected window (yaw +25°) + farther face inside (yaw −35°);
5. malformed rectangle (x −0.1) + valid facing face → true. Pin deliberately: the issue says 有効でこちら向きの顔が1人以上.
Same step, existing test: remove the `[face(), face()]` row from testMultipleFacesAndUnknownOrMalformedHeadPoseFallBack (spec changed) and rename it without "Multiple".
## Guards (pass at HEAD for the wrong reason — the count clause — so they only prove something after GREEN; label as guards, not RED)
- multi-face frames that must stay false: all turned; turned + NaN yaw; malformed + turned; infinite pitch + turned.
- latest-frame semantics with several faces: multi-face facing frame → newer all-turned multi-face frame → false; older facing frame (capturedAt 0) cannot restore it.
- 0.4 s expiry on a multi-face frame (0.399 true / 0.400 false).
- Generation/heat/permission/lifecycle: already covered by the single-face tests because those guards run before the removed clause; no duplication needed.
- Classifier bypass / full-transcript reply: view-model tests inject isFacingScreen, so already covered; one optional two-face variant of testLiveCompositionWiresFacingWithoutRobotOrTracking (turned centre + facing off-centre) gives end-to-end wiring evidence cheaply.
- ConversationCameraTests: no hasFreshFacingFace test there; no change needed unless you want the guard cases at that layer instead.
## Docs
- README.md:10 must change ("こちらを向いた顔を1人だけ" and "複数人" in the fallback list). Add the accepted limitation: face direction is not matched to the speaker.
- Implication to document (not code): facing now also arms/renews the 30 s continuation and the 5 min cap when several people are in frame; the rules themselves are unchanged.
- docs/superpowers/specs/2026-11-06-facing-addressing-design.md:16 and docs/validation/2026-11-06-facing-addressing.md:9,:14 are dated #22 records. Question: add a #28 spec/validation that supersedes them (as done for #24) rather than rewriting history?
- "分岐図": no branch diagram found in docs/README (no mermaid/flowchart/分岐図 hit). Question: where does it live?
## Process questions for the ACK
- My standing protocol says Claude does not run xcodebuild/devices/commits. When you hand me Driver edit rights: may I run the task run-ios-tests.py for RED/GREEN, or do you run tests and I only edit?
- Please name write ownership per file at every swap (e.g. Claude owns FacingAddressingTests.swift + ConversationCamera.swift; codex owns docs) so we never edit concurrently.
- Device check (two people in frame, one facing) is a user/codex gate.
