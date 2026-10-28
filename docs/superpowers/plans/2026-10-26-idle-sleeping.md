# Idle Sleeping Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, paired with the user-requested Claude agent for vector work and cross-review.

**Goal:** Add configurable sleepy/standby timeouts and a matching sleeping face that wakes only by tap.

**Architecture:** A monotonic inactivity owner reports awake/sleepy/sleeping to ConversationAppCoordinator. Accepted conversation activity resets it; existing lifecycle methods stop audio, camera and automatic motion.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, existing Xcode project generator and face renderer.

**Spec:** `docs/superpowers/specs/2026-10-26-idle-sleeping-design.md`

## Global Constraints
- Defaults: sleepy after 5 minutes, standby after 10 total minutes.
- Both thresholds are configurable and persisted; standby is later than sleepy.
- Sleeping wakes only by a face tap. Keep the face visible while stopping microphone, camera and automatic neck motion.
- image_gen draft → Claude vector reconstruction → visual comparison.

## Review Focus
- Foreground/settings-close racing an expired deadline must not restart capture.
- A face tap racing asynchronous pause must resume once after shutdown.
- Unaddressed/ambiguous speech must not extend idle time.
- Busy turns finish before standby; their phase changes cannot erase elapsed time.
- Settings changes preserve a valid persisted pair and cannot wake a sleeping cat.

## Task 1: Inactivity timing and preferences (Codex)
Files: new Conversation/Inactivity/ConversationInactivity.swift, ConversationIdleSettings.swift; new ConversationInactivityTests.swift.
Interfaces: `ConversationInactivity(settings:clock:)`, `state`, `setMonitoring(_:phase:)`, `recordActivity()`, `wake()`, `settingsDidChange()`, `onStateChange`.
- [x] Add failing tests for 299/300/599/600-second boundaries, activity reset, busy deferral, suspension, sticky sleeping and persisted invalid settings.
- [x] Run focused tests to see the missing behavior fail.
- [x] Implement the minimal observable state owner and normalized settings.
- [x] Run focused tests to green.

## Task 2: App integration and controls (Codex)
Files: ConversationViewModel, ConversationAppCoordinator, AppRootView, ConversationSettingsView, ConversationViewState, ConversationView; integration tests.
Interfaces: accepted-activity and phase callbacks from VM; coordinator exposes inactivity settings/state and composes presentation.
- [x] Add failing integration tests for voice/typed reset, not-addressed speech, stopping resources, no foreground/settings wake, tap wake during pause, new-conversation/recovery gates.
- [x] Implement callbacks, cancellation ordering, presentation and settings controls.
- [x] Run focused integration tests and project-generator checks.

## Task 3: Sleeping vector and visual agreement (Claude)
Files: FaceExpression, CatFaceAppearance/Shapes/View, face-render helpers and face tests; docs/design/sleeping-2026-10-26.
- [x] Generate and save image_gen draft and exact prompt.
- [x] Claude measures the draft, adds sleeping vector geometry and adapts render fixtures without changing existing faces or express allowlist.
- [x] Render actual SwiftUI output and compare the draft with component positions, curvature, taper and colors; correct material differences.
- [x] Capture iOS rendering and verify animation endpoints/interpolation.

## Task 4: Integration validation and review
- [x] Regenerate project with `ruby scripts/generate_project.rb`; `ruby scripts/test_generate_project.rb` passes.
- [x] Run `xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=40C29D25-C8EC-42C7-8145-65AB37A2BB7D' -derivedDataPath /tmp/CatRobotIdleSleepDerived CODE_SIGNING_ALLOWED=NO test` and inspect result.
- [x] Claude and Codex cross-review owned changes and fix important issues with regression tests.
- [x] Record evidence, limitations and final visual comparison; leave unrelated work intact.

## Execution evidence

Completed 2026-10-26 in `feature/look` at base `f6eeedad`. The deterministic clock tests, coordinator regressions, accepted-speech callbacks and settings integration are implemented. The deadline preserves pending speech until the 20-second segmentation limit; a regression also fixes provisional-only segmentation scheduling. Claude implemented the sleeping vector from the image_gen draft and independently reviewed lifecycle races.

Final simulator run: 791 tests, 789 passed, 2 hardware-only skips, 0 failures. Product and test source hashes match the final capture provenance. The only later diagnostic-source edit corrects the printed sampling-bound label in Measure.swift; it does not change values or the app. See `docs/validation/2026-10-26-idle-sleeping.md` and `docs/design/sleeping-2026-10-26/visual-comparison.md`. Physical-device deployment is outside this validation.
