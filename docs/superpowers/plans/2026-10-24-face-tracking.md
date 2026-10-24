# Face Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Native execution was already selected; preserve it. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the neck toward an on-device detected face during conversation, with default-on permission handling and safe interaction with existing motions.

**Architecture:** A serial video-only AVFoundation/Vision adapter emits value-only observations. A main-actor coordinator applies lifecycle, permission, thermal, freshness, and loss policy; pure geometry aligns capture-time observations with robot pose. MotionCoordinator remains the only neck arbiter and RobotLink retains its last-write checks.

**Tech Stack:** Swift 6, SwiftUI/Observation, AVFoundation, Vision, XCTest; existing RobotClock and RobotLink; no new package.

**Spec:** `docs/superpowers/specs/2026-10-24-face-tracking-design.md` (approved with initial ON / permission denial OFF).

## Global Constraints

- Local front video only, no images persisted or sent to conversation services; no AVAudioSession reconfiguration or audio input.
- Actual image buffers ≤640×480; actual acquisition ≤5fps; unsupported configurations fail closed for tracking only.
- Automatic tracking speed 20%, yaw ±45°, pitch ±10°, ±4° deadband; one return to center at speed 10 after 10 seconds since last valid capture.
- Capture freshness ≤400ms; STATUS freshness ≤1s; capture-time pose interpolation from 1s history; never substitute completion time for capture time.
- Priority: explicit stop/background/disconnect > tool > acknowledgement > tracking > idle. Only an owned tracking MOVE may be superseded while moving.
- Default tracking ON; saved false remains false; denied/restricted permission persists OFF and does not fail conversation preflight.
- Camera runs only for eligible foreground conversation, ready neck, authorized camera and fair-or-lower temperature; serious/critical suspend camera/tracking/idle, then 10s cool recovery.
- Both landscape directions; no preview or eye redesign; calibration/settings own the neck and suppress capture.
- Reuse isolated worktree `/Users/goodapple/.codex/worktrees/9b35/Cat_robot`, branch `feature/face-tracking`. No push. Preserve existing voice/calibration contracts.
- Regenerate Xcode files with `ruby scripts/generate_project.rb`; never hand-edit PBX entries. Tests use `/private/tmp/cat-ios-link/run-tests.sh`; each task's completion check runs the entire simulator suite.

## Review Focus

- A permission dialog overlaps a scene transition or settings exit: a late approval must not revive capture in the wrong screen (Task 5 integration fixture).
- Backpressure holds a tracking write while a tool, calibration, or stop takes ownership: old writes must be invalidated at the actual send boundary (Task 2 FakeTransport fixture).
- A face result is delayed across rotation/reconnect while STATUS remains superficially fresh: both capture generation and pose history must be rejected (Tasks 1/3 fixtures).
- Camera capture can contend with speech audio or deliver unexpected frame dimensions/rate despite nominal settings: enforce negotiated and observed limits, keep audio untouched (Task 4 policy tests and Task 6 device check).
- A neck already moving from another owner cannot be distinguished by a generic moving flag: require explicit ownership and connection continuity; tracking must not steal it (Task 2 ownership tests).

## File map

- `CatRobot/FaceTracking/FaceTrackingTypes.swift`: Sendable observations, authorization/status enums, source boundary.
- `CatRobot/FaceTracking/FaceTrackingGeometry.swift`: deterministic face selection, projection and capture-time pose history.
- `CatRobot/FaceTracking/FaceTrackingCoordinator.swift`: permission, eligibility, observations and lost-face policy; no direct BLE send.
- `CatRobot/FaceTracking/AppleFaceCaptureSource.swift`: serial camera/Vision adapter and camera format policy.
- Existing `RobotMotionControlling.swift`, `MotionCoordinator.swift`, `RobotLink.swift`: tracking state, arbitration and power-hold guard.
- Existing preferences, composition, app coordinator/root, connection/settings views and Info.plist: persistence and lifecycle/UI wiring.
- Matching `CatRobotTests/FaceTracking/*` plus existing Motion/RobotLink/app integration tests: deterministic behavior tests.

### Task 1: Observation geometry, pose history and persistent preference

**Files:** Create `CatRobot/FaceTracking/FaceTrackingTypes.swift`, `FaceTrackingGeometry.swift`, `CatRobotTests/FaceTracking/FaceTrackingGeometryTests.swift`, `FaceTrackingPreferencesTests.swift`; modify `CatRobot/RobotLink/RobotPreferences.swift`; regenerate `CatRobot.xcodeproj/project.pbxproj`.

**Interfaces:**
- Produces `FaceRectangle(x:y:width:height:)` (Double normalized raw unmirrored image, lower-left origin), `FaceLandscapeOrientation` (`landscapeLeft`, `landscapeRight`), `FaceObservation(generation:capturedAt:completedAt:orientation:horizontalFieldOfView:aspectRatio:faces:)`.
- Produces `FacePose(yaw:pitch:)`; `FacePoseHistory.record(at:pose:)`, `pose(at:now:) -> FacePose?`, `reset()`; `FaceTrackingGeometry.selectFace(_:)`, `project(_:pose:) -> FacePose?`.
- Produces `RobotPreferences.trackingEnabled: Bool`, key `robot.trackingEnabled` default true.
- Produces main-actor `FaceCaptureSource` with authorization, `requestAuthorization() async -> FaceCameraAuthorization`, `events() -> AsyncStream<FaceCaptureEvent>`, `start(generation:orientation:)`, `stop()`; adapter arrives Task 4, fake Task 3.

- [ ] Step 1: Add tests with hand-calculated 90°/4:3 FOV fixtures: center preserves yaw 30/pitch -3; raw image x=.75 at orientation right means observer-left yaw -26.565051; left rotates both axes; image y=.75 gives +20.556045°. Test nearest center, equal-distance larger-area then coordinate tie; malformed rectangles/FOV/NaN rejected. Pose samples at 10 and 10.2 interpolate midpoint to (15,-2); missing brackets, >1s age and nonfinite values fail; reset discards history. Preferences default ON, setting OFF survives recreation.
- [ ] Step 2: Generate project and run focused tests: `/private/tmp/cat-ios-link/run-tests.sh -only-testing:CatRobotTests/FaceTrackingGeometryTests -only-testing:CatRobotTests/FaceTrackingPreferencesTests`. Expected: missing new behavior/symbols, then RED behavioral assertions against minimal stubs if needed.
- [ ] Step 3: Implement the interfaces. Convert normalized x/y through tangent projection, add pose, apply independent ±4° deadband and clamp yaw/pitch; store only finite ordered pose samples, retain a boundary sample for interpolation without allowing >1s-old poses. Use latest-first bounded history, no extrapolation.
- [ ] Step 4: Rerun focused command and `ruby scripts/test_generate_project.rb`. Expected: PASS. Completion command: `/private/tmp/cat-ios-link/run-tests.sh`, expected all tests pass (device-only tests may skip).
- [ ] Step 5: Commit `feat: add face projection and tracking preference`.

### Task 2: Motion ownership, tracking cadence and face-aware acknowledgement

**Files:** Modify `CatRobot/Motion/RobotMotionControlling.swift`, `MotionCoordinator.swift`, `CatRobot/RobotLink/RobotLink.swift`, motion test doubles; create `CatRobotTests/Motion/FaceTrackingMotionTests.swift`; extend relevant RobotLink tests.

**Interfaces:**
- Consumes Task 1 `preferences.trackingEnabled`.
- Produces `RobotTrackingState` cases `.disabled`, `.searching`, `.following(RobotTrackingTarget)`, `.holding`, `.returnToCenter`; `setTrackingState(_:)`, `setAutomaticMotionSuspended(_:)` on RobotMotionControlling. Retain `updateTrackingTarget(_:)` compatibility by translating it.
- Existing `RobotTrackingTarget(yaw:pitch:validUntil:)` remains fresh-face-only input for look_at_user. Track sent pose separately from expiry.

- [ ] Step 1: Write tests for two targets ≤5Hz, latest-only under backpressure, identical angles/new expiry no resend, expired target no send; moving owned tracking can update and be preempted by tool, foreign MOVE/gesture cannot. Assert no STOP/TORQUE 0 between owned tracking and tool. Holding suppresses idle; return sends once when owner clears; searching permits idle. OFF/inactive invalidates held writes; active tracking holds PWM even with idle disabled; explicit stop still wins; heat suspends idle. Add relative acknowledgement at yaw30/pitch2: dip to -3 and return2, yaw30 preserved; pitch -9.5 skips (<1° room), -8 shrinks to2°. Old no-face acknowledgement behavior preserved.
- [ ] Step 2: Run `/private/tmp/cat-ios-link/run-tests.sh -only-testing:CatRobotTests/FaceTrackingMotionTests -only-testing:CatRobotTests/RobotLinkTests`; expected RED for new arbitration behavior.
- [ ] Step 3: Implement ownership tied to connection ID and written tracking token; reservation invalidates pending tracking, tool start may supersede only owned tracking. Retain existing cycle completion checks; don't refactor turn cancellation. Use command-equivalent angles for deduplication; cadence starts at actual successful write. Clamp automatic motion/speed; reset session ownership on disconnect/scene stop. Update RobotLink idle-power-off guard to honor enabled tracking.
- [ ] Step 4: Run focused tests then completion command `/private/tmp/cat-ios-link/run-tests.sh`. Expected PASS including existing motion/calibration/lifecycle tests.
- [ ] Step 5: Commit `feat: arbitrate continuous face tracking with robot motions`.

### Task 3: Tracking coordinator and lifecycle policy

**Files:** Create `CatRobot/FaceTracking/FaceTrackingCoordinator.swift`, `CatRobotTests/FaceTracking/FaceTrackingCoordinatorTests.swift`, `FaceTrackingTestDoubles.swift`; extend types from Task 1.

**Interfaces:**
- Consumes FaceCaptureSource, RobotLinkControlling updates, RobotClock, RobotPreferences, RobotMotionControlling Task 2 methods.
- Produces observable main-actor `FaceTrackingCoordinator` with `status`, `setEnabled(_:) async`, `requestPermissionForConversation() async`, `setEnvironment(conversationVisible:sceneActive:mode:phase:)`, `setOrientation(_:)`, `setThermalState(_:)`, `resetConversation()`. Camera permission completion never directly bypasses eligibility.
- `FaceCaptureEvent` cases `.observation(FaceObservation)`, `.unavailable(generation:)`, `.interrupted(generation:)`; successful empty observation means no face, not source failure.

- [ ] Step 1: Fake source/clock tests: composition creates no camera; ON+notDetermined waits explicit request; denied/restricted persist OFF, saved OFF never prompts; late permission after leave doesn't start. Eligible ready foreground starts, settings/calibration/inactive/paused/error/disconnect/disable stop and advance generation. Reject old generation/orientation/result after reconnect. Feed bracketing STATUS plus face and assert absolute pose delivered; hold at 9.99s, center exactly10s once, no-face frames don't renew deadline, new valid face cancels return. Serious/critical stop automatic activity and fair must last10s to resume; reheat cancels recovery. No matching pose keeps only latest fresh frame pending until next STATUS.
- [ ] Step 2: Run `/private/tmp/cat-ios-link/run-tests.sh -only-testing:CatRobotTests/FaceTrackingCoordinatorTests`; expected RED.
- [ ] Step 3: Implement eligibility reconciliation, generation invalidation, freshness, pose history, lost timers from capturedAt and thermal recovery. Keep latest frame only, cap state/queues, publish simple Japanese states. Source failure suspends capture until a deliberate eligibility transition; don't create retry loops.
- [ ] Step 4: Focused test then completion `/private/tmp/cat-ios-link/run-tests.sh`; expected PASS.
- [ ] Step 5: Commit `feat: coordinate face tracking permissions and lifecycle`.

### Task 4: Video-only front-camera Vision adapter

**Files:** Create `CatRobot/FaceTracking/AppleFaceCaptureSource.swift`, `CatRobotTests/FaceTracking/FaceCapturePolicyTests.swift`; modify Info.plist.

**Interfaces:**
- Implements FaceCaptureSource, emits Task 1/3 DTOs. Initializer is inert. Worker owns AVCaptureSession, delegate and Vision on one serial background queue; public bridge only transfers Sendable values.
- Pure `FaceCapturePolicy` selects compatible format/output dimensions + min/max frame duration from value descriptors; converts sample host presentation time to RobotClock monotonic time through simultaneous anchors; validates actual dimensions and frame cadence.

- [ ] Step 1: Write policy tests: choose ≤640×480/5fps supported range; reject only15/30fps formats and oversize outputs; invalid/nonfinite clocks/durations fail; host mapping preserves a 200ms-old capture time instead of completion time. Test observed oversize/too-fast frame policy and latest-only result buffering. Source authorization rejection is injected in coordinator tests; real dialogs/device are Task6.
- [ ] Step 2: Focused `/private/tmp/cat-ios-link/run-tests.sh -only-testing:CatRobotTests/FaceCapturePolicyTests`; expected RED.
- [ ] Step 3: Use local SDK/Apple primary docs to confirm nonmirrored raw orientation and effective FOV/aspect. Configure front video only, zoom1/stabilization off, no auto audio config, late-frame discard, supported duration ≥.2s. Run Vision rectangle detection serially; normalize raw coordinates per Task1 orientation, emit no images. Use host-clock mapping for CMSampleBuffer PTS; generation captures callbacks. Interruption/error notifications stop/emit failure; invalidate pending frames on stop/rotation. Add camera usage text from spec.
- [ ] Step 4: Focused + completion `/private/tmp/cat-ios-link/run-tests.sh`, `ruby scripts/test_generate_project.rb`, and signed iPhone build; expected PASS, no sendability warnings or MainActor capture work.
- [ ] Step 5: Commit `feat: detect faces locally with low-rate front camera`.

### Task 5: Composition, permission sequencing and settings UI

**Files:** Modify ConversationComposition, ConversationAppCoordinator, AppRootView, CatRobotApp, ConversationSettingsView, RobotConnectionView/RobotSettingsModel as needed; extend `CatRobotTests/Motion/RobotLifecycleIntegrationTests.swift`, `CatRobotTests/Conversation/Integration/AppCompositionTests.swift`, `CatRobotTests/FaceTracking/FaceTrackingAppIntegrationTests.swift`.

**Interfaces:**
- Consume real FaceTrackingCoordinator as optional dependency in app coordinator/root/settings and concrete member of live composition. Forward robot mode changes to both motion and face coordinator. Forward conversation phase via root onChange; scene/settings transitions synchronously gate capture.
- First conversation permission request occurs after awaited viewModel.startConversation microphone/preflight flow; lifecycle rechecks before requesting. Setting ON invokes async permission flow, but settings visibility keeps capture off.

- [ ] Step 1: Integration tests: live composition inert; first conversation waits microphone permission before camera permission; denied camera leaves conversation listening and preference OFF; inactive camera dialog then active does not duplicate microphone/preflight/start. Opening settings during pending permission never starts capture; closing settings/foreground resumes only with new frame. New conversation resets lost timer; stop/error/paused suppress capture. Persisted OFF stays OFF after root recreation.
- [ ] Step 2: Run `/private/tmp/cat-ios-link/run-tests.sh -only-testing:CatRobotTests/FaceTrackingAppIntegrationTests -only-testing:CatRobotTests/AppCompositionTests -only-testing:CatRobotTests/RobotLifecycleIntegrationTests`; expected RED.
- [ ] Step 3: Wire shared coordinator, forward ownership and phase changes, serialize first permission with existing start intent. Add 顔追尾 toggle/status and settings-open action for denied camera; explanation: local only/no save/send; holding continues when enabled. Camera status never blocks chat UI.
- [ ] Step 4: Focused + completion `/private/tmp/cat-ios-link/run-tests.sh`; expected PASS. Regenerate/build iPhone target, verify permissions and both landscape layouts.
- [ ] Step 5: Commit `feat: connect face tracking to conversation and settings`.

### Task 6: Whole-feature verification and attended device acceptance

**Files:** Create `docs/validation/2026-10-24-face-tracking.md`; add targeted device probe/diagnostic value aggregation only if existing device-test pattern needs it; no persisted image/face-coordinate history.

**Interfaces:** Consumes all preceding production components. Records exact source revision, device/FW, dimensions/intervals, observed direction/naturalness, and explicit pending acceptance items.

- [ ] Step 1: Run full simulator suite and iPhone signed build, inspect diff for source isolation, background capture, privacy and lifecycle omissions. Expected all tests PASS and build success. Any discovered defect requires failing regression first, then fix and suite.
- [ ] Step 2: Dispatch one fresh whole-branch reviewer per executing-plans with spec/plan/ledger and Review Focus; evaluate findings, fix Important/Critical with RED→GREEN and full suite. Do user-requested simplify again before any new integration if needed; no integration while meaningful checks are pending.
- [ ] Step 3: Install exact committed revision, normal launch, ask user for hardware observation only where required. Test both landscape orientations/left-right/up/down, multi-face,10s loss, settings/calibration/background, and voice+nod. Record actual buffer size/rate, thermal state, PWM/no jumping. Motion latency ≤500ms is physical/video observation, not inferred from BLE timestamp. Record failures honestly, correct and retry affected cases.
- [ ] Step 4: Save validation with passed/pending limits (Qi2 one-hour acceptance separate). Completion command `/private/tmp/cat-ios-link/run-tests.sh`, expected PASS; commit `docs: record face tracking validation`. Do not call hardware acceptance complete without observation.

#### Task6 continuation: quieter tracking from attended feedback

Files: `FaceCapturePolicy.swift`, `MotionCoordinator.swift`, `FaceCapturePolicyTests.swift`, `FaceTrackingMotionTests.swift`, `FaceTrackingCoordinatorTests.swift`, and the validation record. Uses existing APIs; no new public interface.

- [ ] Adjust capture-selection tests to require a supported 3fps range; retain actual5fps rejection and timestamp-rounding fixture. Add motion fixtures with target20° then20.1/19.8/21.9° producing only the first MOVE, cumulative22° producing a second, and independent pitch suppression. Cover ownership loss and large shifts. Run the focused suite and observe RED before production edits.
- [ ] Select3fps. In autonomous following only, retain each last-written tracking axis until its target differs by at least20 deci-degrees, using current automatic ownership; ordinary first targets and ownership changes bypass suppression. Keep normal cadence/expiry/admission checks. Run focused tests to GREEN.
- [ ] Run full `/private/tmp/cat-ios-link/run-tests.sh`, signed iPhone build, verify embedded committed SHA, install and repeat attended stationary/moving checks. Record actual results and remaining limits; do not infer thermal benefit from fewer frames.

姿勢補間待ちの追加条件: 新しい顔の画像が400ms以内で、前後のSTATUSを待っている間は通常の見失いへ切り替えない。以前の目標の有効期限は延長せず、新規MOVEは新しく投影できた目標だけを使用する。待機画像自体が400msで失効したら保持へ移る。3fps・処理50ms・STATUS5Hzでの一瞬の保持と、後続STATUSが来ない場合の期限切れをテストする。所有者を失った後は同じ目標でも再取得できることも検証する。

#### Task6 continuation: PWM restart boundary

- [x] Reproduce ServoDriver channel reset on disable/re-enable with a real-driver host test using recording Arduino/Servo boundaries; assert disabled duty0, retained timer/channel on resume, calibrated pulses, and no output in CATNECK_NO_PWM. Run `python3 firmware/tools/test_servo_driver.py` and observe RED.
- [x] Preserve allocated servo channels when PWM is disabled, release output to zero duty, and write current planner pulses to resume. Keep all Supervisor stopping/returning timeouts and protocol/calibration behavior. Build baseline and candidate firmware and run `pio test -e native` plus the host adapter test.
- [ ] Compare restart on the attended robot after centering. Retain the candidate only with observed improvement and stopped-output checks; otherwise restore the known baseline and record the remaining hardware limit. Firmware flashing must preserve NVS/bonds.


#### Task6 continuation: fixed screen aim and anchored tool gestures

User reports and observed serial trace establish the two acceptance gaps. Continue the previously selected Native execution and existing worktree.

- [x] FW RED: raw9B0x0A packet decoded through realProtocol into realSupervisor; nod at(-34,6) keeps yaw and returns there, near-limit amplitude fits, pitch drain/queued origin/STOP/disconnect remain bounded; malformed length/ID rejected and legacy gesture still centers. Run native tests before implementation and record failure.
- [x] FW GREEN: extend Protocol.h/cpp GestureAt with id/amp/repeats/speed/yawDeci/pitchDeci, GestureSpec centers with defaults0 and anchored flag, Supervisor anchors/clamps/scales and waveform offsets; capability bit1 in BleTransport, FW0.2.0. Run native and realServoDriver tests, build both targets.
- [x] iOS RED/GREEN: add RobotCommand.gestureAt, protocol encoding, capability checks, all RobotLink priority/group/ownership paths, MotionCoordinator execution-time fresh-face anchor and cycle rest/prediction, GestureTiming anchor deltas. Test packet output from(-34,6), fresh/stale/unsupported, loss during gesture/no interruption/new acquisition, backpressure/manual takeover. Preserve legacy gestures when tracking is off or capability is absent; tracking-on gestures and small acknowledgements use fresh current STATUS even during face hold. Run focused then full tests.
- [x] Aim RED/GREEN: FaceTrackingGeometry applies fixed -9° (tuned at the user’s request after device feedback) for the physically left-mounted camera, independent of image orientation before deadband; test corrected neutral, camera-centered movement, both orientations, boundaries/limits and production coordinator output. No new settings UI.
- [ ] Verify full iOS/native suites and signed device/normal+bringup builds; preserve FW0.1.1 for rollback, update attended hardware at neutral. Compare fixed aim at50cm/1m and sideways large nod/other gestures, confirm return to same direction then live tracking. Record remaining limits honestly.

Attended follow-up: The user confirmed that sideways gestures preserve the facing direction and tracking resumes. Their request for another3° of aim correction changes the fixed correction from-5° to-8°. The existing geometry/coordinator tests passed33/33; signed app78fc55d was installed and launched normally at13:12:36JST. The8° visual comparison remains pending.

The user then requested a total correction of 10°. Adjusted the same direction from -8° to -10°. The updated geometry/coordinator fixtures passed 33/33; signed app d365916 was installed and launched normally at 16:21 JST. The 10° visual comparison remains pending.

The user requested a total correction of 14°. Adjusted the same direction from -10° to -14°. The updated geometry/coordinator fixtures passed 33/33; signed app c8c22a5 was installed and launched normally at 21:42 JST. The 14° visual comparison remains pending.

The user requested returning the total correction to 8°. Restored the existing 8° projection and geometry/coordinator fixtures, verified 33/33 tests, and installed signed app 0340663. Normal launch succeeded at 21:49 JST; visual comparison remains pending.

The user then requested a total correction of 9°. Adjusted the same direction from -8° to -9°. The updated geometry/coordinator fixtures passed 33/33; signed app bcd232b was installed and launched normally at 21:54 JST. The 9° visual comparison remains pending.

Subsequent user request: add an adjustable, persisted screen-aim control in the calibration screen. Continue with [the focused setting plan](2026-10-24-face-aim-setting.md); the user selected returning to the conversation to compare the result.

User closure: after adding the adjustment control, set its default/reset to8.5°. Installed3c9f646 at22:44:53JST and ended this topic as requested. Historical unchecked physical acceptance items remain unperformed; do not continue them without a new request.
