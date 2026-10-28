# /simplify efficiency review: conversation inactivity / sleeping (uncommitted scope on f6eeedad)

Reviewer angle: EFFICIENCY only (not correctness). Line numbers refer to the current working tree of
`/Users/goodapple/.codex/worktrees/b200/Cat_robot`.

## Findings

### E1: Every speech-recognition partial now refreshes the whole face environment (medium priority)
- **Where:** `CatRobot/Conversation/Integration/ConversationViewModel.swift:808` (end of `receiveRecognition`), `:816` (`synchronizeCaptureTimingWithSegmenter`) and `:828` (`presentUnrecognizedSpeechWhileListening`). These call `onPhaseChange`, which goes to `CatRobot/App/ConversationAppCoordinator.swift:84-87` (`conversationPhaseDidChange`), and that runs `updateFaceEnvironment(phase:)` (`:126-141`) plus `updateInactivity`.
- **Cost:**
  - These three call sites exist only so the inactivity monitor sees changes to `hasPendingSpeech`. The phase is still `.listening` at all of them.
  - Because they go through `conversationPhaseDidChange`, each non-empty partial result runs this synchronously on the main actor:
    - `expressions.setVisible` and `look.setVisible`
    - `ConversationCamera.setEnvironment` (`CatRobot/Vision/ConversationCamera.swift:74`). This calls `refreshAuthorization()`, which reads `AVCaptureDevice.authorizationStatus(for: .video)` via `AppleFaceCaptureSource.authorization`, writes the observable `authorization` property, then runs `reconcile()`.
    - A full `FaceTrackingCoordinator.reconcile()` (`CatRobot/FaceTracking/FaceTrackingCoordinator.swift:100` → `reconcile`). That reads `link.snapshot` several times and runs `recordCurrentPose`, `processPending` and `updateLoss` (which writes the observed `status`). It also runs `scheduleWake`, which allocates a deadline array.
  - The app listens continuously, so this runs for every volatile result of any nearby speech, including ambient talk nobody aimed at the cat. That is several times a second while anyone talks.
  - Before the diff, the removed `AppRootView` `.onChange(of: viewModel.viewState.phase)` ran this only when the phase actually changed.
  - In the rare case where the segmenter has no activity, `receiveRecognition` calls `onPhaseChange` twice: once inside `synchronizeCaptureTimingWithSegmenter`, then again at `:808`.
  - Each call is cheap (estimated a few to tens of µs), so the waste is in how often it runs, not in any single call. The `status`/`authorization` writes do not add a separate view invalidation: `AppRootView` is already invalidated by the `provisionalTranscript` write in the same main-actor turn.
- **Cheaper alternative (identical behaviour):** in the coordinator, remember the last phase forwarded (an `@ObservationIgnored var lastForwardedPhase: ConversationPhase?`, starting as `nil`).
  - Call `updateFaceEnvironment(phase:)` only when the phase differs from it; always call `updateInactivity(phase:)`.
  - This restores exactly the old `onChange` dedupe for the face environment. Every other input to `updateFaceEnvironment` (destination, scene, settings, sleeping, `hasStartedConversation`) already has its own explicit call site, and face tracking reconciles itself on link, source and wake events.
  - The inactivity monitor still sees every pending-speech change, so the deadline semantics, including sleepy appearing at the next partial, are unchanged.
  - Equivalent alternative: split the view-model hook into `onPhaseChange` (only from `transition`/`publish`) and `onPendingSpeechChange` (the three listening-only sites), with the coordinator mapping the latter to `updateInactivity()` only.
- **Confidence:** high that the work is redundant; low-to-moderate magnitude.
- **Tests:** none need to change. The direct callers `CatRobotTests/FaceTracking/FaceTrackingAppIntegrationTests.swift:178-180` and `CatRobotTests/Vision/LookIntegrationTests.swift:139-143` alternate between different phases, so a dedupe on change still forwards every call they make.

### E2: The inactivity timer is cancelled and re-created on every evaluation, even when its deadline has not changed (low)
- **Where:** `CatRobot/Conversation/Inactivity/ConversationInactivity.swift:72-104` (`evaluate`).
  - Every call does `generation &+= 1; timer?.cancel()` and then builds a new `Task` that sleeps to the same deadline.
  - Calls that repeat the same evaluation back to back:
    - `scenePhaseDidChange` (`ConversationAppCoordinator.swift:197`) followed by `resumeListeningIfNeeded` (`:168`)
    - `closeVoiceSettings` (`:284`) followed by `resumeListeningIfNeeded` (`:168`)
    - new conversation: `recordActivity()` (`:355`) immediately followed by `updateInactivity()` (`:356`)
    - `completeConversationStartIfEligible` (`:147`) right after `transition(to: .listening)` has already evaluated
- **Cost:** about 2–4 Task allocations and clock-sleep registrations per foreground, settings close or conversation start, where 1 is enough. These are user and lifecycle events, so the frequency is low.
  - This is not a per-partial cost. During recognition, `segmenter.receive` has already set activity, so `evaluate` takes the `hasPendingSpeech` early return and creates no Task (see Checked areas).
- **Cheaper alternative:** store `armedDeadline`. After computing `deadline`, return early if `deadline == armedDeadline && timer != nil`. That check must come before `generation &+= 1` / `timer?.cancel()`, otherwise the live timer fails its token check.
  - This is the same pattern `FaceTrackingCoordinator.scheduleWake` already uses (`guard next != wakeDeadline`).
  - Do not remove the leading `updateInactivity()` calls. `testForegroundAndSettingsCloseEvaluateExpiredTimeBeforeStartingMicrophone` depends on evaluating before the robot scene and microphone start.
- **Confidence:** high on the redundancy, low on its importance.
- **Tests:** no change needed. `ManualRobotClock.pendingSleepCount` would drop, but no test asserts it here.

### E3: Opening or closing settings while sleeping briefly passes the robot through `.conversation` mode (low)
- **Where:**
  - `ConversationAppCoordinator.swift:252-253` (`openVoiceSettings`): `setApplicationMode(nil)` before `settingsDidOpen()`.
  - `ConversationAppCoordinator.swift:285-286` (`closeVoiceSettings`): `settingsDidClose()` before `updateRobotScene` sets `.inactive`.
- **Cost:**
  - When sleeping, the app mode is `.inactive`. On open, `setApplicationMode(nil)` notifies `effectiveControlMode == .conversation`, then `settingsDidOpen()` notifies `.settings`, so the robot goes `.inactive → .conversation → .settings`.
  - On close it goes `.settings → .conversation` (from `settingsDidClose`), then `.conversation → .inactive` (from `updateRobotScene`).
  - Each hop is a full `MotionCoordinator.setControlMode` transition (`cancelAuto`, `resetPowerOff`, `service()`, which can enqueue strength or power-off work) plus a `FaceTrackingCoordinator.setControlMode` reconcile. That is two transitions per open or close instead of one.
  - This only happens when the user opens or closes settings while the cat is asleep.
- **Cheaper alternative (same final state):**
  - Open: call `settingsDidOpen()` first, then `setApplicationMode(nil)`. The first notify becomes an `.inactive` no-op, then one real `.inactive → .settings` hop.
  - Close: if `isSleeping`, call `settingsModel?.setApplicationMode(.inactive)` before `settingsDidClose()`. That gives one `.settings → .inactive` hop, and the later notify and `updateRobotScene` become no-ops.
  - When not sleeping, both orders behave exactly as today, because `setApplicationMode(nil)` is equality-guarded.
- **Confidence:** medium. Traced through `RobotSettingsModel.swift:74-97` and `MotionCoordinator.swift:219-240`, not run.
- **Tests:** no change needed. `testSleepingStopsRealTrackingAndAutomaticMotionUntilTap` asserts only the final `effectiveControlMode`.
- Hand-off: whether the zero-length `.conversation` window can have side effects is a correctness question for the bug reviewer.

### E4: `onStateChange` refreshes the face environment on awake↔sleepy changes, and twice on wake (low)
- **Where:** `ConversationAppCoordinator.swift:77-81` (`else { self.updateFaceEnvironment() }`).
- **Cost:**
  - Nothing `updateFaceEnvironment` reads depends on sleepy: `visible` and the tracking flag use only `!isSleeping`. So each awake↔sleepy change runs one full camera and tracking fan-out (as in E1) for nothing.
  - On sleeping→awake, the only route is `wakeFromSleeping` (`:115-116`). It calls `inactivity.wake()`, which triggers this refresh, then immediately calls `updateRobotScene`, which ends in `updateFaceEnvironment()` again.
  - Frequency: about 2–3 times per idle cycle. Negligible on its own.
- **Cheaper alternative:** pass the previous state to `onStateChange` (or have the coordinator track it) and refresh only when leaving `.sleeping`. That keeps today's ordering on wake.
  - Dropping the branch entirely would also be redundant-free, but it would reorder tracking enable against `motion.setControlMode` on wake, so it is not strictly the same behaviour.
- **Confidence:** high on the redundancy, very low impact. Optional.
- **Tests:** none.

### E5: `closedLid` is built on every animation frame for every expression (negligible, optional)
- **Where:** `CatRobot/Conversation/UI/CatFaceShapes.swift:191` (`closedLid: closedLid(frame: frame)` inside `CatFaceGeometry.eye`). It is drawn only when `eye.closed > 0.001` (`CatFaceView.swift:161-163`).
- **Cost:**
  - Per eye per animation frame: one extra `NormalizedPath` (a move, 4 cubic curves, 13 points mapped through `EyeFrame`) and its array allocation. That is about 5% of the other eye geometry and well under 1 µs.
  - Frames only happen during the 0.25 s expression changes, the 0.14 s mouth changes and the neutral blink. The face is static while sleepy or sleeping (blinking happens only on neutral, and there is no `TimelineView`), so standby adds no per-frame work.
- **Cheaper alternative (only if wanted):**
  - Store the `EyeFrame` in `EyeGeometry` and make `closedLid` a computed property (`var closedLid: NormalizedPath { CatFaceGeometry.closedLid(frame: frame) }`).
  - `eye.closedLid.bounds`, `all`, `mirroredShapes`, the tests and the harness keep compiling unchanged, and the renderer evaluates it only when it draws it.
- **Confidence:** high that the cost is negligible. Not recommended unless convenient.
- **Tests:** none, if done as a computed property.

## Checked areas that are clean

- **`ConversationInactivity.setMonitoring` on recognition partials:** no Task is created per partial. `segmenter.receive` sets `firstActivityAt` before the callback, so `hasPendingSpeech` is true and `evaluate` takes the early return (an integer increment, cancelling a nil timer, one `clock.now`). The timer is re-armed once when the pending speech clears, which is about one Task per turn. Busy phases set `.awake` without a timer.
- **`hasPendingSpeech`** (`ConversationViewModel.swift:120`): O(1), two stored-property reads.
- **`setState`:** equality-guarded, so the observable `inactivity.state` (read in `AppRootView.body`) only notifies on real changes. There is no observation churn from the monitor.
- **`ConversationIdleSettings`:**
  - UserDefaults is read only in `init` (two `object(forKey:)` calls).
  - The getters return cached stored properties. `evaluate` reads those, never UserDefaults, and nothing reads defaults in a `body` or on a timer tick.
  - The settings sheet gets the shared `coordinator.inactivity.settings` instance. The `?? ConversationIdleSettings()` fallback in `ConversationSettingsView.init` is reached only by the camera fixture test.
  - Writes happen only on a Stepper change: two `set` calls, which is fine.
- **`ConversationIdleClock`:** a `ContinuousClock` duration read plus one `Task.sleep` per armed deadline. No polling.
- **Closures and retention:**
  - `onAddressedActivity`, `onPhaseChange` and `onStateChange` all capture `[weak self]` only.
  - The timer Task captures `[weak self, clock]`.
  - `enterSleeping`'s Task holds `viewModel` strongly only until `sceneBecameInactive()` returns.
  - No long-lived closure keeps a large enclosing scope alive.
- **`enterSleeping` / `wakeFromSleeping`:** the awaits depend on each other (shutdown must finish before `startConversation`), so they cannot run in parallel.
- **`activeControlMode`** is a trivial computed property, and `RobotSettingsModel.setApplicationMode` is equality-guarded (`RobotSettingsModel.swift:80-83`), so the repeated `.inactive` calls in `updateRobotScene` cause no churn. The one exception is E3.
- **`AppRootView`:** adds one observed read (`coordinator.inactivity.state`, which changes only on state changes) and drops one `onChange` comparison. There is no new per-body work.
- **`ConversationView`:** `ConversationAccessibility` is rebuilt about 5 times per body (pre-existing pattern), and the new sleeping branch is O(1). The `displayed*` and `faceExpression` computed properties are O(1).
- **Face drawing:**
  - `drawEye` skips the closed-lid fill when `closed ≤ 0.001`.
  - `Palette.closedLid` is a `static let`; `.opacity` is built only when drawn.
  - The `highlightDrop` guard `lid < 1` removes the bisection loop for fully closed eyes, so it saves work.
  - `animatedKeyPaths` growing from 55 to 57 adds about 4% to the existing array-backed `AnimationVector`, which was already designed that way.
- **`FaceExpression.expressible`:** a `static let`. `normalized` does a linear scan of 9 cases once per tool call.
- **`UtteranceSegmenter.flushDelay`:** the change adds no work, and the number of re-arms per partial in `scheduleSegmentationFlush` is unchanged. Side note: for provisional-only speech the absolute deadline now stays the same across partials, so that per-partial re-arm could be skipped. It is base code, so not recommended here.
- **Tests:**
  - The idle integration tests use `ManualRobotClock`, with no wall-clock sleeps. `waitUntil` only yields until its condition is true.
  - The 5 `UIHostingController` fixtures in `testInactivityFixturesRender` are distinct states (the typed-hidden variants are deliberate checks), so none can be shared.
  - `closedLidThickness` makes about 400 `CGPath.contains` calls per sample, a few ms per test.
  - `RobotAppHarness` defaults to a real `ConversationIdleClock`, but that only parks one suspended Task per coordinator, which is cancelled on deinit.
- **Harness (`scripts/face-render`):**
  - `components` is a linear flood fill. Calling it 3 times per image in `reportSleeping` matches the existing `Measurement.run` pattern.
  - The per-pixel filters are bounded: 25 lookups per pixel for `core`, and a contains check against 2 rects for `creams`, reached only for cream pixels. `columns` is built once per arc. The diff loop in `Render.runSleeping` is linear.
  - `render-sleeping` and `measure --sleeping` both decode and scale the draft and compute the same IoU when `render_face.sh sleeping` runs both. This is acceptable: it is offline, not O(n²), and removing either copy would change that command's output.

## Out of scope (for other reviewers)
- `ConversationInactivity.settingsDidChange()` (`ConversationInactivity.swift:64`) is called only from tests. Production re-reads the settings when the sheet closes, through `updateInactivity()`. This is a simplification item, not an efficiency one.
