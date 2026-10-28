# Independent implementation review

Reviewed checkout: `/Users/goodapple/.codex/worktrees/b200/Cat_robot`.
Base: `29a6bbbc3b9d83f847e0070204c5c8377e696da7`.
Head: `dbd04589ed780822b66720691f92131784012029` (`feature/look`).

Read-only review of the implemented branch, in architecture, lifecycle, BLE/motion, firmware, and presentation passes. The checkout was clean at the start and end. No source, index, branch, device, or robot mutation occurred. No additional reviewers were dispatched.

The findings below are source-confirmed control-flow defects, with proposed deterministic regression scenarios. I did not execute those new scenarios or repeat the full suite. The supplied evidence is 755 iOS tests executed, 753 passed, 2 explicit device-only skips, plus the final 7 LookToolTests passing; these are existing results, not a fresh run by this reviewer.

## Strengths

- Camera ownership is centralized. Tracking and look reuse one capture source, physical and consumer generations are distinguished, and the final tool handoff rechecks image freshness and ownership. The real FoundationModels dispatch tests and image-session lifetime tests exercise useful boundaries beyond simple mocks.
- Reply-turn identity is captured before actor hops and shared by motion, expressions, and look. Expression expiry does not restore an obsolete conversation state, and sentence mouth events are separated from the once-per-reply motion release.
- RobotLink revalidates queued work at the write boundary, uses expiring commands, preserves manual/tool precedence, and invalidates operations across connection epochs. Calibration persistence checks both the save sequence and the read-back values.
- Short-term saves are serialized with deletion, and old save completions cannot overwrite the newest persistence state. Long-term memory has serialized mutations and generation-scoped writers.
- Firmware separates platform adapters from the motion core and has substantive trajectory, state-machine, anchored-gesture, and interruption tests. Recorded validation clearly distinguishes commanded angles and software timing from physical measurements.

## Issues

### Critical

None found.

### Important

#### I1. A new conversation can restore the old conversation after an early preflight failure

- **Location:** `CatRobot/Conversation/Services/Claude/ClaudeConversationService.swift:130–140`, especially line 140. App trigger: `CatRobot/Conversation/Integration/ConversationViewModel.swift:480–496` and `407–421`.
- **Trigger:** Launch with an existing short-term snapshot, fail voice preflight before `prepareMemory()` (for example, microphone access is denied), and choose “新しい会話を始める”. Then submit typed input or recover microphone/model availability.
- **Effect:** The UI announces a new conversation, but the next successful preparation loads the previous summary and turns. The robot can continue a conversation the user explicitly reset.
- **Evidence:** `reset()` clears only the actor's initially empty memory and saves only when `prepared` is true. It neither replaces the stored snapshot nor marks an unprepared reset as authoritative. The microphone/model checks return before memory preparation, so this is reachable through normal UI. `startNewConversation()` calls reset and unconditionally announces success. Existing service reset tests first generate or prepare a conversation; the new-session UI tests use a fake reset counter.
- **Proposed fix:** Give short-term reset a defined persisted result even before restoration, and serialize it with any in-flight preparation/store work. Preserve long-term facts and the existing forget-failure protection. Surface a reset persistence failure rather than silently restoring the previous session later.
- **Target regressions:** Seed old summary/turns, call reset before prepare, then generate and verify the new instructions and stored snapshot exclude old short-term content while retaining long-term facts. Add the microphone-denied → new conversation → typed-input integration path. Also guard a suspended initial load against overwriting a newer reset.

#### I2. Returning calibration controls to their starting values can leave a different preview applied after exit

- **Location:** `CatRobot/RobotLink/RobotSettingsModel.swift:119–136`; `CatRobot/RobotLink/RobotCalibrationSession.swift:54` and `99–117`.
- **Trigger:** Open calibration at value A. Preview B and let that write complete. Return the controls to A, then exit before the throttled A preview is sent, or after that preview fails under BLE backpressure.
- **Effect:** Exit proceeds without confirmation or restoration, cancels the queued A preview, and leaves B applied on the robot. The displayed draft was A and can say “保存済み”, while the robot retains a different calibration; subsequent motions use B until it is corrected or the robot restarts.
- **Evidence:** `preview()` assigns `draft` synchronously but sends later after the 100 ms throttle. `hasNewChanges` compares only `draft` and entry. `closeCalibration()` skips all save/restore work when those values match, then `session.cancel()` invalidates the pending preview. Preview send errors are swallowed, so waiting longer does not establish applied equality either. The unchanged-exit test covers no edits, not a round trip through another applied value.
- **Proposed fix:** Separate draft equality from whether the applied robot state has been confirmed restored. If any preview may have changed the robot, complete and verify restoration before dismissing on the restore path, including when the draft equals entry. Retain the current disconnect warning and prohibition on replaying old drafts after reconnect. This may add a read/write on an edited exit; a never-edited exit can remain cheap.
- **Target regression:** With ManualRobotClock and the real RobotLink harness, write B, call `preview(A)` without advancing the throttle, then close. Assert the screen remains until A is written/read back and that no SAVE_CAL is issued. Repeat with the final preview expired under backpressure.

#### I3. Calibration changes during direct waveform playback bypass the motion limits

- **Location:** `firmware/lib/catneck/src/catneck/Supervisor.cpp:143–150` and `478–491`.
- **Trigger:** While a `look_up` gesture is holding +20° with zero offset and pitch uninverted, send valid `SET_CAL(0, 0, invert=2)` through the supported serial command or BLE endpoint.
- **Effect:** The next 20 ms sample changes the commanded servo angle from approximately +20° to −20° in one step: approximately 40° / 20 ms, far above the 120°/s absolute pitch cap. This requests an abrupt physical reversal; actual force/speed was not measured in this review.
- **Evidence:** SET_CAL changes the axis conversion immediately and deliberately skips `reapplyJointTargets()` during `Playing`. Every waveform sample then uses that new conversion and calls `planner.reset()` rather than moving through the planner. The iOS calibration UI guards against an observed gesture, but the firmware's supported serial/BLE interface accepts SET_CAL in this state. The existing smooth-calibration test exercises only IDLE. The adopted direct waveform rendering and deferred gesture velocity-limit change do not make a calibration discontinuity safe; the command contract still describes an S-curve calibration transition.
- **Proposed fix:** Keep the adopted gesture waveform, but defer calibration until it can be applied through the planner, or perform a continuous handoff from the current waveform sample before applying it. Explicitly define and test the accepted/deferred behavior; do not rely solely on the app's gesture gate.
- **Target regression:** In the existing host Supervisor simulation, enter the held portion of `look_up`, apply pitch inversion (and separately an offset change), then check successive PWM-derived servo-angle deltas and acceleration against the applicable transition bounds. No real robot is needed to reproduce the discontinuous command.

### Minor

#### M1. A rejected Limits characteristic write can still modify the other axis

- **Location:** `firmware/lib/catneck/src/catneck/Supervisor.cpp:157–165`; entry path `firmware/src/platform/BleTransport.cpp:205–209`, decoder `firmware/lib/catneck/src/catneck/Protocol.cpp:156–164`.
- **Trigger:** Write an 8-byte Limits characteristic payload with valid yaw changes and a negative pitch angle limit; for example yaw velocity 500 (50°/s), pitch velocity 0, yaw angle 0, pitch angle −1.
- **Effect:** REJECTED is reported, but the yaw limit has already changed. The applied limits and planner configuration can temporarily disagree because the failure returns before `applyPlannerVelocities()`.
- **Evidence:** The characteristic decoder validates length only, then Supervisor mutates yaw before discovering the invalid pitch argument. The command-characteristic decoder separately rejects negative limits before dispatch, so testing only `decodeCommand()` misses this path. Reversing the invalid/valid axes can also mutate the valid axis.
- **Proposed fix:** Validate both axes before mutating either, or stage both new axis configurations and commit atomically. Add a direct Limits-write decode/dispatch regression asserting both limits remain unchanged on rejection. This is Minor because it requires an invalid payload and does not itself command motion.

## Coverage and recommendations

Reviewed the live app composition and lifecycle wiring; Claude reply/fallback/session/memory/tool paths; shared camera capture, validity leases and fixed-left normalization; face tracking geometry and motion ownership; expression and speech-mouth event handling; RobotLink transport, recovery, queue admission and calibration; firmware protocol, Supervisor, planner/waveform/axis and relevant platform code. Inspected relevant test cases and gaps, plus build/resource and attended-runner wiring. Historical binary/render artifacts were not exhaustively read.

Implement accepted findings only after cross-reception. Use the focused regression scenarios above, followed by the relevant existing memory, calibration, firmware, and integration checks. The recorded full suite is useful baseline evidence but does not cover these specific transitions.

## Declined to judge

- Physical servo speed, force, temperature, current, mechanical end stops, startup alignment and PWM release behavior: no robot operation or measurement was authorized. I3 identifies an output-command discontinuity, not a claimed observed injury or device motion.
- Long-duration Qi2/thermal performance, tracking latency under real camera/CPU load, and exact camera/servo geometry: source checks and prior attended observations cannot replace measurements.
- Live CoreBluetooth/NimBLE pairing, OS permission dialogs, real connection timing and stack scheduling/overflow stress: platform code was inspected, but these device-specific behaviors were not exercised.
- Opposite landscape support: deliberately excluded by the authoritative fixed-left requirement. `UIInterfaceOrientationLandscapeRight` and sensor normalization are the intended behavior.
- Aesthetic redesign of the adopted face and pixel-perfect rendering on every display/accessibility configuration: preserve the approved design. I inspected the rendering/presentation paths and tests, but did not generate a new screenshot comparison or claim visual acceptance.
- Live Claude/App Attest service behavior, production client configuration, billing accuracy, non-Apple-Intelligence device support and server-side retention: external account/device/service validation was outside this read-only review; no credentials, ignored LocalAssets or user camera images were inspected.
- Sleep/wake, pupil tracking, onboarding redesign, battery warnings and critical-temperature suspension of the whole conversation: explicitly deferred or separate product work, not presented here as defects in the implemented feature set. Camera and automatic-motion thermal suspension were reviewed.
- Third-party framework/library internals, all historical validation assets, and a comprehensive security/penetration audit: not the requested review. Local integration code and the supported firmware command validation were examined.

## Assessment

**Ready to merge: With fixes.**

The implementation has strong ownership boundaries and meaningful lifecycle tests, but I1 and I2 violate user-visible reset/restore promises, and I3 permits an unsmoothed valid calibration command during a gesture. Resolve those Important findings and add the focused regressions before treating this branch as ready; M1 is a small independent validation correction.
