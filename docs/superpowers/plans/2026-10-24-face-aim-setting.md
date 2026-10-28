# Face Aim Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Let the user persistently tune face-tracking screen aim from the existing calibration screen.

**Architecture:** RobotPreferences owns the persisted correction; the face coordinator reads it at each projection and passes it to pure geometry. The calibration view binds local controls to preferences and keeps the existing stopped-capture contract.

**Tech Stack:** Swift 6, SwiftUI, Observation, UserDefaults, XCTest. No new dependencies or firmware changes.

**Spec:** `docs/superpowers/specs/2026-10-24-face-aim-setting-design.md`

## Global Constraints

- Default8.5°, range0...20°, step0.5°, same physical left-camera correction in both landscape orientations.
- Autosave on iPhone; apply only with new face observations after returning to conversation.
- Keep robot calibration save/restore separate and unambiguous; preserve all capture/motion ownership and expiry rules.
- Use the current isolated feature/face-tracking worktree and the previously chosen Native execution method. Review only this addition, since the preceding tracking feature was already reviewed.

## Review Focus

- Existing installs without a key must use8.5°; stored0° must not become a missing-value default.
- Nonfinite/out-of-range stored or assigned values must not produce invalid motion or controls.
- Changing correction during calibration must not start capture or send automatic movement.
- Returning to conversation must consume the saved value on a fresh frame; old observations stay invalid.
- Large text must keep the controls reachable; hardware restore/save must not appear to reset the autosaved app setting.

### Task 1: Persisted screen-aim control through calibration UI

**Files:** Modify `RobotPreferences.swift`, `FaceTrackingGeometry.swift`, `FaceTrackingCoordinator.swift`, `RobotCalibrationView.swift`, `RobotConnectionView.swift`; tests in existing FaceTrackingPreferences/Geometry/Coordinator/AppIntegration and RobotPresentation test files. No new Swift source files.

**Interfaces:**
- `RobotPreferences.trackingYawCorrection: Double` persisted, normalized to0...20 step0.5, missing/nonfinite8.5; static default/range/step for the view.
- `FaceTrackingGeometry.project(_:yawCorrection:pose:) -> FacePose?`; finite0...20 only, correction before deadband, pitch unchanged.
- `RobotCalibrationView(session:preferences:onClose:)`; required shared preferences from settings composition.

- [x] Add a failing coordinator regression with persisted correction14° producing yaw-14° at camera center instead of the existing-9°; add preference round-trip,0/20 bounds, malformed values, and configured geometry cases. Run focused tests and observe the missing behavior.
- [x] Add normalized persistence and pass the value through real coordinator/geometry. Keep existing9° fixture expectations explicit. Run focused tests to green.
- [x] Add slider+stepper+8.5° reset to calibration view with local autosave explanation, pass shared preferences, clarify hardware-only save/restore labels. Extend existing render fixtures to show the entire calibration scroll area.
- [x] Add/extend app integration coverage for saved correction while settings/calibration remain stopped and first new conversation frame uses it. Run full `/private/tmp/cat-ios-link/run-tests.sh`; expected all pass except existing device-only skips. Inspect rendered attachments at normal/max text.
- [x] Commit implementation and run one fresh review of this addition from463730e. Verify/fix actionable findings with focused regression then full suite if behavior changes.
- [x] Build signed iPhone app with exact source SHA, verify embedded revision, install and launch normally. Record tests/render/device evidence and pending physical observation; commit validation docs.

Final user adjustment: default/reset8.5°, preserve existing saved values. The user considers this topic complete after this update; remaining historical hardware checks are not reclassified as passed.

Completed final default/reset8.5° update: related64 tests passed, signed source3c9f646 verified, iPhone installed and normally launched22:44:53JST. The requested work is closed per the user.
