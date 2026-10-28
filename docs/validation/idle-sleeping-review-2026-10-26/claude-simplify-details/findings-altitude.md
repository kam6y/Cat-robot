# Altitude review: idle sleeping (uncommitted working tree on f6eeedad)

- **Scope:** uncommitted changes in `/Users/goodapple/.codex/worktrees/b200/Cat_robot` (branch feature/look).
- **Line numbers:** taken from the current working tree, not from the diff hunks.
- **Quality only:** no correctness bug hunt.
- **Spec decisions are kept:** sleeping is sticky until a tap, servo hold is kept while asleep, and `express` cannot reserve `sleeping`.

## Headline: is sleeping as a side-channel the right altitude?

Yes. Keep `ConversationInactivity` as a coordinator-level owner beside the `ConversationPhase` machine. Four reasons, all from the code:

- **A phase would not survive the VM's rewrites.** The VM rewrites `viewState.phase` on many paths: `transition` (ConversationViewModel.swift:1556-1610) and `publish`→`presentFailure` (1611-1630). Those paths include pause, failure, retry and new conversation. If sleeping were a phase, every one of them would have to refuse to leave it. The spec also requires memory retry, settings, background/foreground, new conversation and recovery to run while the cat stays asleep.
- **Most of what sleeping gates belongs to the coordinator.** That covers camera, face tracking, look, expression visibility, motion control mode, the `RobotSettingsModel` application mode and the wake lock. The VM owns only the microphone.
- **A new phase case would spread everywhere.** `ConversationPhase` is switched exhaustively in `FaceExpression.automatic`, `ConversationAccessibility`, `allowsTypedSubmission` and the camera/motion environment consumers. A new case would touch all of them for no gain.
- **A coordinator-level mode enum (running / settings / background / sleeping) would be a rewrite.** It would absorb the scene and settings ownership that was already reviewed in the base commits. That is out of scope.

So where the state lives is right. What is not at the right altitude is how its effects are spread out:

- the coordinator adds `!isSleeping` to many separate conditions (A1);
- the VM→coordinator callback carries two different signals (A2);
- one phase list is written twice (A3);
- the view layer mixes ViewState accessors with inline checks, and one gate is inert (A4).

## Findings

### A1: ConversationAppCoordinator.swift:24, 90-91, 95-106, 123, 127, 138, 145, 148, 169, 175, 231, 252

**Summary:** sleeping is added as about ten separate `!isSleeping` conditions instead of once, in a named eligibility check.

**Why this is symptom-level:**

- **The sleeping rule is decided one call site at a time.** The base already repeats `destination == .conversation && scenePhase == .active && isVoiceSettingsClosed` inline at 90-91, 127, 144, 169 and 438-439. The diff adds `&& !isSleeping` to some of these and not to others:
  - Wake lock (438-439) leaves it out on purpose: the spec keeps the screen on during standby.
  - Monitoring (90-91) also leaves it out on purpose.
  - `resumeListeningIfNeeded` (169) and `launchStart` (175) both check it, so the two checks overlap.

  Which checks include sleeping is now an unwritten choice at each call site. The next gate someone adds (a new tool or sensor) has to work the rule out again.
- **The robot-mode rule is written two ways.** The rule is "standby puts the robot in `.inactive` unless the settings sheet owns it". It appears in `activeControlMode` (123) and again in `updateRobotScene` as `setApplicationMode(isSleeping && isVoiceSettingsClosed ? .inactive : nil)` (231). `openVoiceSettings` then needs an explicit `settingsModel?.setApplicationMode(nil)` (252) to undo the second version.
- **The pause tail is copied.** `enterSleeping` (95-106) repeats the end of `forwardPauseIfNeeded` (396-404): clear the start intent, `startTask?.cancel()`, `viewModel.invalidateForSceneInactivity()`, and the `pauseTask` that awaits `sceneBecameInactive`.

**Deeper change:** name the checks once and use them everywhere.

```swift
private var conversationOwnsForeground: Bool { destination == .conversation && scenePhase == .active && isVoiceSettingsClosed }
private var conversationMayRun: Bool { conversationOwnsForeground && !isSleeping }
private var standbyApplicationMode: RobotControlMode? { isSleeping && isVoiceSettingsClosed ? .inactive : nil }
```

- **Monitoring and wake lock:**
  - Monitoring (90-91) becomes `hasStartedConversation && conversationOwnsForeground`.
  - The wake lock (438-439) becomes `conversationOwnsForeground`. This makes the spec's "standby keeps the wake lock" visible in the code.
- **Conversation gates:** face visibility (127), the start-completion guards (144-148) and the resume guard (169) become `conversationMayRun`. Keep the `!isSleeping` guard in `launchStart` (175): it is the one gate every start passes through (`beginConversation`, resume, and any future caller), so the overlap with 169 is acceptable defense.
- **Robot mode:**
  - `activeControlMode` becomes `standbyApplicationMode ?? (isVoiceSettingsClosed ? .conversation : settingsModel?.effectiveControlMode ?? .settings)`.
  - `updateRobotScene(.active)` and `openVoiceSettings` both call `setApplicationMode(standbyApplicationMode)`. In `openVoiceSettings` this evaluates to nil, because `isOpeningVoiceSettings` is already true.
- **Pause tail:** extract a small helper from `forwardPauseIfNeeded` and have `enterSleeping` reuse it. The `didForwardPauseSinceActive` latch and the destination guard stay in the caller. New code reuses the existing tail; the base logic is not rewritten.
- **What it removes and keeps:**
  - It removes several inline `!isSleeping` conditions (127, 145, 148, 169), one of the two robot-mode versions, the explicit `nil` reset, and the copied pause tail.
  - Keep `launchAction(allowWhileSleeping:)` (407-418) as is. It is a deliberate exception for each action that needs it: tap-to-wake and memory retry.

**Behavior:** identical. Every named check gives the same boolean at every call site, including the deliberate wake-lock and monitoring exceptions.

**Confidence:** medium-high. **Tests:** none need to change. The existing ConversationIdleIntegrationTests and RobotLifecycleIntegrationTests cover these paths.

### A2: ConversationViewModel.swift:97, 808, 816, 828 and ConversationAppCoordinator.swift:76, 84-93

**Summary:** `onPhaseChange` carries two signals. Pending-speech updates go through the phase handler, so the face, camera and tracking environment is refreshed on every partial speech-recognition (ASR) result.

**Why this is symptom-level:**

- **The phase signal itself is already correct.** `viewState.phase` has exactly two writers: `transition` (1567, which notifies at 1609) and `publish`→`viewState.presentFailure` (1624, which notifies at 1629). Those two are the real phase chokepoints.
- **The other three calls are not phase changes.** They are pending-speech notifications. They exist because `ConversationInactivity` needs `hasPendingSpeech`, and the phase callback was the only channel:
  - the end of `receiveRecognition` (808), which runs on **every** recognition event;
  - `synchronizeCaptureTimingWithSegmenter` (816);
  - `presentUnrecognizedSpeechWhileListening` (828).
- **The coordinator treats them as phase changes.** `conversationPhaseDidChange` (84-87) calls `updateFaceEnvironment(phase:)`. That runs `expressions.setVisible`, `look.setVisible`, `camera.setEnvironment` (which does `refreshAuthorization()` + `reconcile()` + a possible revoke, ConversationCamera.swift:74-82) and `faceTracking.setEnvironment` (`reconcile()`).
- **Before this diff, that work ran only on real phase changes**, through AppRootView's `.onChange(of: viewModel.viewState.phase)`. Now it also runs on every partial result. The inputs are unchanged, so the work is redundant, but it is a hidden cost and the name will mislead the next reader.

**Deeper change:** split the signal.

- Keep `onPhaseChange` at the two phase writers.
- Add `onPendingSpeechChange: @MainActor () -> Void`, called at 808, 816 and 828.
- **Do not dedupe this in the VM per channel** ("send only when `hasPendingSpeech` flips"). The clear at 911 reaches the inactivity owner only through the *phase* channel (the same-phase `transition(.listening)` at 732), so a VM-side "last sent" baseline for the pending channel would stay `true`. The next capture's first partial (808) would then match that stale baseline and be suppressed, and the owner could arm the timer and sleep mid-utterance. If dedupe is wanted, do it only at the receiver: `ConversationInactivity` comparing against its stored `hasPendingSpeech`, which sees both channels.
- The coordinator wires it straight to `updateInactivity()`, which already reads `viewModel.viewState.phase`, so the inactivity inputs are unchanged.
- This removes the per-result face-environment churn and gives each callback one meaning.

**Do not go further than that.** Two tempting chokepoints would change behavior:

- **"Notify only when the phase really changes"** (a `didSet` on `viewState` that compares phases, or de-duplicating inside `transition`). On the `.ignore` and `.dismissPending` routes the phase never leaves `.listening`. `finishClosingCapture` clears `captureIsClosing` at 911, and the same-phase `transition(to: .listening)` in `startCapture` (732) is the only notification after that. De-duplicating it would leave the inactivity owner holding a stale `hasPendingSpeech == true`, and standby would be deferred until some unrelated later push.
- **Driving pending speech from `didSet` on `segmenter` / `captureIsClosing`.** That would fire in the middle of a method. For example, at 911 it would fire before `performTurn` routes an addressed utterance, and the cat could fall asleep before `onAddressedActivity` resets the deadline.

The hand-placed call sites are the safe points. They only need their own name.

**Behavior:** identical for inactivity. The face environment receives the same values, computed less often.

**Confidence:** medium-high on the split; high on the warning against a `didSet` or de-duplicating chokepoint. **Tests:** none need to change. A test that counts `setEnvironment` calls per partial result could pin the improvement.

### A3: ConversationInactivity.swift:77-82 and ConversationViewState.swift:48

**Summary:** the list of phases where inactivity counts and sleepy may show is written twice, in two layers.

**Why this is symptom-level:**

- `evaluate` switches `case .idle, .listening, .paused: break; default: setState(.awake); return`.
- `faceExpression` separately tests `phase == .listening || phase == .idle || phase == .paused` before showing `.sleepy`.
- While monitoring is on, the timer already forces `.awake` in every other phase, so the two lists must agree. They agree today, but nothing ties them together. Adding a phase, or changing which phases count, needs two coordinated edits.

**Deeper change:** one exhaustive check on the enum, placed next to `allowsTypedSubmission` and `permitsFaceTracking`.

```swift
extension ConversationPhase {
    var countsTowardInactivity: Bool { switch self { case .idle, .listening, .paused: true; default: false } }
}
```

- `evaluate` becomes `guard phase.countsTowardInactivity else { setState(.awake); return }`.
- `faceExpression` uses `inactivity == .sleepy && phase.countsTowardInactivity`.
- An exhaustive switch makes "does a new phase count?" a compile-time decision.

A stronger option was considered and is not recommended here: the timer stops forcing `.awake` during busy phases and stays purely time-based, so the face gate lives only in ViewState. That changes the assertion at `ConversationInactivityTests.testBusyTurnDefersStandbyWithoutResettingElapsedTime` (line 55 asserts `.awake`).

**Behavior:** identical. The phase list is the same, including `.paused`.

**Note for the correctness reviewers** (not an altitude proposal): the spec says sleepy shows "only while idle/listening", but both sites include `.paused`. Consolidating turns this into one decision. The name above deliberately does not encode either reading.

**Confidence:** high. **Tests:** none need to change.

### A4: ConversationViewState.swift:44-53, 90-92; ConversationView.swift:80, 117, 211, 233; ConversationAccessibility.swift:30-42

**Summary:** the sleeping presentation is split between ViewState accessors and inline View checks, and one gate sits on a property with two meanings.

**Why this is symptom-level:**

- **The `allowsTypedSubmission` gate is inert.** `allowsTypedSubmission` (90-92) gained `!isSleeping`, but the property has two readers, and the term has no effect for either:
  - **The VM:** it uses the property as a domain guard (ConversationViewModel.swift:221, 243) on its **own** `viewState`. There `inactivity` is always `.awake`, because only AppRootView.swift:108 sets it, on the composed copy.
  - **The view:** ConversationView.swift:226 reads it only inside `typedInput`, which line 211 already hides while sleeping.

  The real gate is `launchAction` in the coordinator (408, 417). Someone reading the VM guard would wrongly conclude that the VM itself blocks typed turns while asleep.
- **Some sleeping rules live in ViewState and some in the View.** Caption, status text and microphone text go through ViewState `displayed*` accessors. The View also has its own inline `state.isSleeping` checks: `prioritizesContent` (80), the provisional transcript (117), the typed panel (211) and the microphone symbol (233). Every new piece of VM content shown on screen has to remember to add its own check.
- **The standby string is duplicated.** "待機中・タップで起こす" appears at ConversationViewState.swift:52 and ConversationAccessibility.swift:40.

**Deeper change:** make ViewState the single presentation projection, following the existing `displayedCaption` pattern.

- Add derived `displaysTypedInput` (`showsTypedInput && !isSleeping`), `displayedProvisionalTranscript` (`isSleeping ? "" : provisionalTranscript`) and a `microphoneSymbol`. The View reads only these.
- Drop `!isSleeping` from `allowsTypedSubmission`, so it again means "the phase and memory allow a typed turn".
- Hoist the standby strings to one constant shared with `ConversationAccessibility`.
- Keep the projection in ViewState, **not** in AppRootView's state composition. The snapshot fixtures (FaceConversationPresentationTests.swift:106-123) and ConversationIdlePresentationTests set `inactivity` directly on a state. They keep working only if the projection is derived from that field.

**Behavior:** identical. Every rendered value is the same, and the typed draft is still kept because the VM state is untouched.

**Confidence:** high on the inert `allowsTypedSubmission` term; medium on moving the inline View checks. **Tests:** `ConversationIdlePresentationTests.swift:14` (`XCTAssertFalse(state.allowsTypedSubmission)`) would change to assert that the typed panel is not displayed. Snapshots are unchanged.

### A5: ConversationIdleSettings.swift:12-36; ConversationSettingsView.swift:33, 72, 74; ConversationInactivity.swift:64

**Summary:** the model owns the settings rule (sleepy and standby minutes, standby later than sleepy), which is the right place. But the bounds are written four times, and the settings object can end up with a second owner.

**Why this is symptom-level:**

- **The bounds are written four times.** The ranges 1...1439 and 2...1440, and the rule sleeping ≥ sleepy+1, are written out in the `sleepyMinutes` setter (15-16), the `sleepingMinutes` setter (24-25) and `init` (32-35). The Stepper `in:` values (72, 74) repeat the ranges, so changing one bound needs four edits.
- **There can be a second owner.** `ConversationSettingsView.init` falls back to `idleSettings ?? ConversationIdleSettings()` (33). That creates a second, unconnected instance over `.standard` defaults, and the live `ConversationInactivity` would not see its edits. The existing camera fixture at FaceConversationPresentationTests.swift:31 takes this path today.
- **`settingsDidChange()` has no production caller.** `ConversationInactivity.settingsDidChange()` (64) is called only by tests (ConversationInactivityTests.swift:25, 80, 83). In production, new thresholds take effect through `closeVoiceSettings` → `updateInactivity()` → `setMonitoring` → `evaluate`. That matches the footer text "変更は設定を閉じたときに反映します".

**Deeper change:**

- Add `static let sleepyRange = 1...1439` and `static let sleepingRange = 2...1440`, plus one `static func normalized(sleepy:sleeping:) -> (Int, Int)`. Use them in both setters, in `init` and in the Stepper `in:`.
- Make `idleSettings` a required parameter, as `voiceSettings` and `modelSettings` already are. Optionally create it in AppRootView like its siblings and pass it to both the coordinator and the sheet, instead of reaching through `coordinator.inactivity.settings`.
- Delete `settingsDidChange()` and drive those tests through `setMonitoring(true, phase:)`, the production path.

**Behavior:** identical in production.

**Confidence:** medium. **Tests:** the two inactivity tests swap `settingsDidChange()` for `setMonitoring(...)`, and the camera fixture passes an explicit instance backed by its own UserDefaults suite.

### A6: CatFaceShapes.swift:378

**Summary:** `highlightDrop` special-cases the exact endpoint `lid == 1` instead of the geometric condition it stands for.

**Why this is symptom-level:**

- **Why the guard exists.** The doc comment on `guard lid > 0.000_1, lid < 1` gives the reason as "there is no highlight to show under a fully closed lid, so don't move it". With a fully closed lid the drop search would push the highlight far below the eye; it is possible (unverified, not stated in the code) that without the guard the static `sleeping` preset would also put highlight points outside the canvas-bounds check (CatFaceGeometryTests.swift:14-24 / Check.swift:24).
- **What it really means.** The condition is "the lid edge already covers the whole outline, so no drop can make the highlight visible". That is true from roughly lid ≈ 0.9 (depending on tilt), not only at 1.
- **The in-between frames still compute the large drop.** That covers the sleepy (0.55) → sleeping (1) animation in [≈0.9, 1). It is invisible: highlights are clipped to the outline (CatFaceView.swift:135) and the lid covers them. But those frames carry off-canvas highlight points that the endpoint-only test never sees.

**Deeper change:** make the rule geometric, so it holds for every animated lid value and not just one preset. Either option works:

- return 0 when `lidEdgeV` is ≥ 1 across the highlight's u-span (the eye is already covered there), or
- clamp `needed` so the highlight's top never goes below the outline's bottom.

**Behavior:** identical pixels. Under a covering lid the highlight is clipped and hidden either way, and the `sleeping` preset still gets a drop of 0.

**Confidence:** low-medium. The code is small, but the guard is a constant tied to the symptom. **Tests:** none need to change.

### A7: scripts/face-render/Render.swift:13-19 vs 24-30, 44-74 vs 117-139; main.swift:47-57

**Summary:** a separate sleeping command is right, but it copies the round guard and the compare / overlay / color-agreement (IoU) block.

**Why this is symptom-level:**

- **The round guard is copied verbatim.** The check "this round already has files; use --overwrite" appears in both `run(round:)` and `runSleeping`.
- **The comparison block is re-implemented.** The top/bottom comparison with a separator, the 50% overlay and the `toneAgreement` print are written again for a different reference/rendered pair.
- **`main.swift` is mostly fine.** It shares argument parsing for `render` and `render-sleeping`, then branches on `arguments[0]`.

**Deeper change (keep the separate command):**

- Extract `roundDirectory(design:round:overwrite:) throws -> String`.
- Extract `writeComparison(reference:rendered:name:save:) -> [(ToneClass, Double)]`, covering compare, overlay, an optional diff image and IoU.
- `run(round:)` and `runSleeping` then differ only in what they render and which reference they load.
- Collapsing everything into `render --design DIR` is **not** recommended. The reference images differ (a cropped device screenshot vs a full-canvas draft), and so do the outputs (diff image, `measure.txt`).

**Behavior:** identical outputs. **Confidence:** medium. **Tests:** none (harness only).

## Verdict: right altitude (do not change)

- **`ConversationInactivity` as its own owner.** It should not be a phase or a VM concern; see the headline. Sleeping has to survive VM phase changes and gates resources the coordinator owns.
- **`onAddressedActivity` at the four routing decisions** (ConversationViewModel.swift:244, 966, 976, 1002).
  - "Addressed" is a routing outcome and cannot be derived from the phase. `.thinking` is entered by both typed and voice turns, `.speaking` by both wake-only and reply playback, and `.clarifying` by ambiguous (not addressed) speech.
  - Engagement arming (1123-1124, 1191-1193) happens *after* the reply and uses `.none` for clarification, so it cannot stand in either.
  - The four sites map one-to-one to the spec's "accepted addressed speech / typed submission".
  - The coordinator's own `recordActivity()` calls for the tap and for a new conversation (314, 355) are coordinator-level user actions and belong there.
- **The manual `updateInactivity()` pushes in the coordinator** (147, 168, 197, 251, 284, 356). Each sits right after a monitoring input changes.
  - A `didSet` chokepoint on `showsVoiceSettings` / `isOpeningVoiceSettings` would add a brief wrong state. At 276-277, `isOpeningVoiceSettings = false` runs before `showsVoiceSettings = true`. Monitoring would briefly turn on mid-handoff, and the cat could fall asleep there.
  - Keep the explicit calls.
- **The `phase == .listening` gate on `hasPendingSpeech`** (ConversationInactivity.swift:85) is load-bearing, not a quick patch.
  - The pause path never resets the segmenter (ConversationViewModel.swift:1386-1406).
  - `transition(to: .paused)` notifies *before* `captureIsClosing` and `activeCaptureID` are cleared. So `hasPendingSpeech` is stale outside listening, and even an `activeCaptureID != nil` check would still be true during that callback.
  - At most, move the `.listening` check into the VM's own definition (`viewState.phase == .listening && (…)`), so the timer receives a self-consistent boolean. That is optional.
- **The `UtteranceSegmenter.flushDelay` fix** (UtteranceSegmenter.swift:37-39) is in the right place.
  - `flushDelay` promises "the next time `utteranceIfReady` can change". For speech that has only provisional results, that is exactly the 20-second hard expiry.
  - The fix is pure, has domain-level unit tests (UtteranceSegmenterTests.swift:42-59), and needs no VM change.
  - Re-arming in `flushSegmentation` instead would turn a provisional-only utterance into polling every 1.2 seconds until expiry. It would only add a second safety net against skew between `now()` and `Task.sleep`, and nothing shows that is needed.
- **`ConversationIdleClock`** (ConversationInactivity.swift:4-15) is not a parallel mechanism.
  - It is a new implementation of the existing `RobotClock` protocol, and tests reuse `ManualRobotClock`.
  - Its different time base is the reason it exists: ContinuousClock includes device sleep, while `SystemRobotClock` uses uptime.
  - Moving it next to `SystemRobotClock` in RobotClock.swift would only be a placement choice.
- **`FaceExpression.expressible` + `normalized`** (FaceExpression.swift:6-12). Filtering where the LLM's text is parsed is the right depth, and nothing else calls `normalized`.
  - **The hand-written name lists predate this diff.** The names in `ExpressTool.description` (5) and `@Guide` (9) follow the repo's convention (MoveHeadTool, RememberTool). `description` is a plain `let` and could be derived from `expressible`. Whether `@Guide(description:)` accepts a non-literal is unverified; every use in the repo is a literal.
  - **The cheap guard is a test** asserting that both strings list exactly `FaceExpression.expressible.map(\.rawValue)`.
  - **`label(.sleeping)` is acceptable.** The arm (ExpressTool.swift:45) can never run, but the exhaustive switch requires it.
  - **Not recommended: splitting the enum** into an LLM enum and a preset enum. `FaceExpression` is also the renderer's preset key (`CatFaceAppearance.preset`, the harness Stubs.swift, every `allCases` test).
- **`Eye.closed` as its own animatable channel** (CatFaceAppearance.swift:25, 291).
  - It is a separate visual layer: the gold arc's opacity, not black-lid coverage.
  - Blink closes the lid through a separate `blink` value (`lidAmount = min(1, eye.lid + (1 - eye.lid) * blink)`, CatFaceShapes.swift), not through `eye.lid`.
  - Deriving the arc from the blink-inclusive lid amount would flash the gold arc on every blink.
  - Deriving it from `eye.lid` would tie the arc's fade to the lid curve and to any future near-closed expression, and would change the validated interpolation frames, which is a design change. Keep it.
- **The separate `render-sleeping` / `measure --sleeping` commands, and the `write_source` extraction in render_face.sh.** See A7 for the shared-helper cleanup only.
- **Check.swift mirroring the new XCTest checks**, including the duplicated `closedLidThickness`. The harness cannot link XCTest, so this duplication is intended and not a finding.
- **Removing AppRootView's `.onChange(of: viewState.phase)`.** Moving the phase signal into the VM makes it independent of SwiftUI update timing, and lets coordinator tests run without views. The spec asks for that ("independent of audio tasks and SwiftUI update timing"). A2 is only about the extra signals riding on it.
- **Test layering is right.**
  - Timing boundaries are unit-tested on `ConversationInactivity` with `ManualRobotClock`.
  - Lifecycle races are tested on the coordinator, which owns them: foreground or settings-close at an expired deadline, a tap during a suspended shutdown, and a save retry while asleep.
  - Stopping robot motion and tracking is tested through `RobotAppHarness`.
  - Integration tests asserting `app.inactivity.state` are fine, because that value drives the UI.
  - **Minor smell:** `testSpeechBeginningBeforeDeadlineCanFinishAndResetSleep` wraps its main assertions in `if h.sut.viewState.phase == .listening { … }` (ConversationIdleIntegrationTests.swift:200). They would be skipped silently if that precondition drifted. The `XCTAssertEqual` just before it already fails in that case, but `guard … else { XCTFail(); return }`, or no conditional, would read more clearly.
  - **Coverage gap related to A2:** no idle test exercises the `.ignore` route, where only the same-phase `transition(.listening)` clears pending speech. If anyone touches A2, add a regression test for it.
