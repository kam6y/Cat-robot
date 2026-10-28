# Fresh Codex code review

Reviewed `9ee8dacbe31e2bc3295eaa8f623049cc771bfb64..d3e2fb096179d64a62fc0a847bd723ad699a2af2` in `/Users/goodapple/.codex/worktrees/b200/Cat_robot`, against the fixed review package and the UI reorganization, UI polish, and face-size tuner specifications/plans. The user's later 80% main-face choice overrides the historical 85% requirement; the tuner correctly retains its original 85% initial/reset value.

This was a read-only review. I ran no build, XCTest, simulator, device, or robot operation and made no checkout/index/branch changes. The only written artifact is this report. HEAD and the clean checkout were confirmed during review.

## Strengths

- **Presentation state remains separate from control behavior.** `ConversationViewState.swift:79–112` derives chips, dimming, and accessible replies; the changed view-model paths set/clear the tap-resume marker without replacing the speech lifecycle. The new tests exercise tap pause, audio interruptions, typed turns, failures, and foreground resumption. `RobotSettingsModel.swift:205–227` retains reconnect visibility through retry attempts while resetting device identity and suppressing never-connected startup retries.
- **The important editor transitions have direct behavioral coverage.** `ConversationView.swift:88–113` keeps one typed-input child outside the changing upper-content branch. `FaceConversationPresentationTests.swift:339–434` checks actual UIKit editor identity, caret/selection, preserved draft text, and focus dismissal when a send clears an error, rather than only comparing rendered images.
- **Calibration retains its existing ownership and save protocol.** `RobotCalibrationView.swift:39–80` keeps its navigation modifiers on one stable container and uses explicit guarded exits; both the root and accessibility detail expose STOP. Its sections share the existing session. Tests cover category changes, draft/session identity, standard/accessibility navigation depths, guarded back, text-size round trips, and disconnected layouts. Adjacent session/settings-model tests cover save readback, restore, cancellation, and disconnect behavior.
- **Onboarding persists at the intended moment and restarts through the existing lifecycle.** Completion is stored on the start action; a completed installation selects conversation and starts on active. Tests cover first launch, denied microphone recovery, permission-dialog transitions, repeated active events, and background resumption. Review mode only closes its sheet.
- **The tuner uses the real renderer and a single normalized value.** Its target directly references the three production face-rendering files. `FaceSizePreview.swift:10–15` matches the main face geometry, and `FaceSizeTuningModel.swift:19–40` uses the same clamped 0.5% value for drawing, persistence, display, and copy. Its distinct bundle ID and source list keep it independent of the main app and hardware services. The main 80% frame calculation retains safe-area horizontal and screen vertical centering.
- **Project churn is accounted for.** Normalizing generated UUIDs in the main pbxproj leaves only the expected new production/test file references; the scheme changes are corresponding target IDs, with no main build-setting change found.

## Issues

### Critical

None found.

### Important

None found.

### Minor

**R1 — Optional: the tuner's selected expression becomes a tall vertical column at maximum text size.**

- **Location:** `tools/face-size-tuner/Sources/FaceSizeTunerView.swift:14–17` and `:51–56`.
- **Trigger/effect:** At `.accessibility5`, the toolbar falls back to icon-only buttons, but the Picker still renders the selected expression as `Text`. In the recorded `docs/validation/face-size-tuner-2026-10-27/images/largest-text-controls-75.png`, 「聞き取り」 wraps one character per line into an approximately 250pt-tall control over the left eye. The current tuner source is unchanged from the implementation that produced this evidence.
- **Why it matters:** Users adjusting the scale at large text sizes lose much of the simultaneous face preview and must switch to fullscreen to inspect it. This is presentation polish, not lost functionality: the controls and fullscreen return path remain available.
- **Minimal improvement:** At accessibility sizes, give the expression selector its own horizontal row, or use a compact selector label with an explicit accessibility value, so the selected name does not become a vertical column. Preserve the overlay layout so this does not move the face.
- **Verification:** Extend the existing maximum-text control fixture to cover expression-selector geometry and nontruncated access to the selection; visually inspect the controls/fullscreen pair and confirm the face center and scale remain unchanged.
- **Disposition:** Optional; does not block merge.

## Test coverage and evidence

I inspected the changed presentation/state/integration tests, onboarding tests, tuner tests, and relevant preexisting calibration settings/session tests. The meaningful coverage is strongest around editor identity, navigation/session retention, persistence, scale normalization, and save/restore protocol outcomes. Some rendering cases produce attachments without asserting every visual detail; I have not treated those attachments as comprehensive runtime proof.

The historical records show 837 passed / 2 attended-device skips out of 839 main tests after UI polish, 5/5 tuner tests, and 15/15 `FaceConversationPresentationTests` after the main scale changed to 80%. These are inspected records, not fresh executions from this review. The 80% tests use an expectation independent of the product constant. I also inspected recorded images for the normal 80% conversation, standard onboarding, largest-standard disconnected calibration, and maximum-text tuner controls. Known incomplete image captures were not used to infer a failure or a successful display.

## Declined to judge

- **Physical Bluetooth motion/STOP timing, audio output, actual microphone/camera permissions, and Japanese keyboard composition:** no device/runtime operations were authorized for this review; source and fixture coverage cannot establish physical behavior.
- **Attended VoiceOver speech/gesture behavior and exact display on the installed iPhone:** the review checks policy and accessibility-tree coverage; no fresh attended inspection was performed, and installation success is not visual verification.
- **Editor continuity when changing OS Reduce Transparency or switching its internal standard/accessibility input mode mid-edit:** the relevant wrapper and `TypedInputView` branching predate the reviewed range. I did not classify this separate, unexecuted scenario as a regression introduced by the new height/card layout.
- **Supporting the opposite landscape orientation:** the current requirement preserves LandscapeRight/camera-left; broadening orientation support would expand scope.
- **Redesigning underlying speech, memory, BLE, or calibration protocols:** unchanged mechanisms were read where needed to assess the UI integration; this is not a comprehensive audit of those subsystems.

## Recommendations

No required code change identified. R1 can remain optional. Retain the existing distinction between fixture assertions, recorded screenshots, installation evidence, and attended device verification when reporting readiness.

## Assessment

**Ready to merge? Yes.**

The reviewed implementation matches the current requirements, and I found no concrete correctness or lifecycle regression requiring a fix. The single finding is optional tuner layout polish; this assessment is based on source review and the clearly identified historical validation, with the runtime limitations above.
