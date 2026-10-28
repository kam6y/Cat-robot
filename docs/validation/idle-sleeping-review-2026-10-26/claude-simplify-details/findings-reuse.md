# /simplify: REUSE review, idle-sleeping working tree (b200, feature/look @ f6eeedad + uncommitted)

Scope: the uncommitted change only. Line numbers refer to the current working tree. All proposed changes keep behavior identical: same face design, same camera position (front camera on screen LEFT), same printed harness output.

## Findings (ranked)

### R1. Measure.swift:388-413 copies the nose/mouth/whisker detection from `report` (Measure.swift:147-181)
- **What is duplicated:** `reportSleeping` repeats about 30 lines of `report`:
  - the coral `components(... minimumCount: 200)` nose search
  - the cream `components(... minimumCount: 150)` search that excludes rects grown by 2 px
  - the `isMouth` rule (±10% of screen width)
  - the merge of mouth parts into one `Component`
  - the whisker sort key and the `"\(side) whisker \(index % 3 + 1)"` naming
  - the `describe`/`columnProfile` print lines

  The doc comment on `reportSleeping` (Measure.swift:285) says the nose, mouth and whiskers are measured "the same way as the adopted image" (採用画像と同じ計測). Today that only holds because the two copies happen to match.
- **Cost:** a threshold or naming change in one copy silently breaks the sleeping-vs-sleepy and draft-vs-render feature comparison. `measure.txt` is diffed across rounds, so drift is easy to miss.
- **Use instead:** extract one private helper, for example `static func noseMouthWhiskers(bitmap:tones:screen:excluding: [CGRect]) -> (nose: Component?, mouth: Component, whiskers: [(name: String, component: Component)])`. It holds only the detection: the thresholds, `isMouth`, the merge, the sort and the names.
  - `report` passes `eyeBounds` and keeps its own prints, including the nose-width line.
  - `reportSleeping` passes `arcBounds` and keeps its prints plus `featureProfile`.
  - Printing stays in each caller, so stdout and `measure.txt` stay byte-identical.
- **Confidence:** high. No tests are affected, because the harness is not under XCTest.

### R2. `FaceRender.runSleeping` (Render.swift:24-79) repeats the scaffolding of `run(round:)` and `run(directory:)`
- **What is duplicated:**
  - The round-exists guard and its error text: Render.swift:27-31 matches 15-19 word for word.
  - The `save` closure: 33-37 matches 88-92 word for word.
  - The stacked "compare" image with the 0.35-grey separator: 53-58 vs 125-130.
  - The 50% "overlay" image: 59-62 vs 131-134.
  - The "scale reference to mock size" compose: 49-51 vs 135-137.
  - The IoU formatting `.map { String(format: "%@ %.3f", ...) }.joined(separator: ", ")`: 73-74 vs 138-139.
- **Cost:** six blocks have to be kept in sync by hand. The `--overwrite` policy text exists twice, and any change to the comparison layout (separator, alpha, label) needs two edits.
- **Use instead:** extract these helpers in Render.swift:
  - `private static func roundDirectory(_ base: String, round: Int, overwrite: Bool) throws -> String` for the guard. `run(round:)` and `runSleeping` both call it.
  - `private static func saveComparison(reference: CGImage, rendered: CGImage, name: String, save: (CGImage, String) throws -> Void) throws -> String`. It writes `compare-<name>.png` and `overlay-<name>.png` and returns the formatted IoU string. Both callers print it with their existing prefix.
  - The `save` closure can become a small local struct, or stay as one copy in a shared `writer(directory:)` closure factory.

  The images and the printed lines stay identical.
- **Confidence:** high. Tests are not affected.

### R3. The sleeping draft path, the "scale draft to 1280×720" step and the IoU are computed twice in one `render_face.sh sleeping` run
- **What is duplicated:** `scripts/render_face.sh sleeping` (render_face.sh:73-82) runs `render-sleeping` and then `measure --sleeping`.
  - Both build the draft path: Measure.swift:213 and Render.swift:45 each spell out `.../sleeping-draft.png` from `sleepingDirectory`.
  - Both scale the draft to the canvas size with `compose` + `drawImage`: Measure.swift:256-259 and Render.swift:49-51.
  - Both run `toneAgreement` with the same format string: Measure.swift:260-262 and Render.swift:73-75.
- **Cost:** two places define the "draft vs render IoU" number that the round's review reads. A change to how the draft is scaled must be made in both, or `measure.txt` and the render log disagree.
- **Use instead:**
  - Add `static let sleepingDraftPath = "\(sleepingDirectory)/sleeping-draft.png"` next to `Measurement.sleepingDirectory` (Measure.swift:11).
  - Add one helper, for example `FaceRender.scaledToCanvas(_ image: CGImage, like canvas: CGImage) -> CGImage`, that both call.
  - Use R2's IoU formatter for the agreement line, and keep each caller's own prefix (`"render: sleeping ..."` vs `"sleeping: ..."`) so the output does not change.
- **Confidence:** medium-high. Tests are not affected.

### R4. `ConversationAppCoordinator.enterSleeping` (ConversationAppCoordinator.swift:95-106) repeats the pause sequence of `forwardPauseIfNeeded` (396-404)
- **What is duplicated:** both run `activeStartIntentID = nil; startTask?.cancel(); viewModel.invalidateForSceneInactivity()` and then create the same `pauseTask = Task { await viewModel.sceneBecameInactive(); self?.pauseTask = nil }`. `openVoiceSettings` (258-264) has a third partial copy, which only differs in the task's continuation.

  The spec (`docs/superpowers/specs/2026-10-26-idle-sleeping-design.md`, line 6) says the feature "reuses the coordinator's existing microphone, camera, motion and lifecycle cancellation paths". The code copies that path instead.
- **Cost:** a later fix to the pause sequence would have to be applied in both places. Examples: pausing face/look as well, or a change in how `pauseTask` is chained. `wakeFromSleeping` awaits `pauseTask` (line 112) and depends on both copies creating it the same way.
- **Use instead:** extract `private func pauseConversation()` containing exactly those four steps.
  - `forwardPauseIfNeeded()` keeps its guard and its `didForwardPauseSinceActive = true` / `deferredPermissionPrompt = false` lines, then calls `pauseConversation()`.
  - `enterSleeping()` becomes `invalidateActionTasksForSceneInactivity(); pauseConversation(); updateRobotScene(scenePhase)`.

  Moving `updateRobotScene` after the `Task` creation does not change anything: the task body cannot run until the current synchronous MainActor code finishes.

  Do **not** have `enterSleeping` call `forwardPauseIfNeeded()` directly. That would set `didForwardPauseSinceActive` and clear `deferredPermissionPrompt`, which changes behavior.
- **Confidence:** high. Tests stay the same.

### R5. The set of phases that count as idle is written twice: ConversationInactivity.swift:77-82 and ConversationViewState.swift:48
- **What is duplicated:** `ConversationInactivity.evaluate()` uses `switch phase { case .idle, .listening, .paused: break; default: setState(.awake) }`. `ConversationViewState.faceExpression` uses `phase == .listening || phase == .idle || phase == .paused`. They are the same rule: the timer advances, and the sleepy face shows, only outside a busy turn.
- **Cost:** if the rule changes (for example, adding `.failed` or `.clarifying`), the face and the timer can disagree, so the cat looks sleepy while the timer is deferred or the other way round.
- **Use instead:** follow the existing `extension ConversationPhase` convention (`allowsTypedSubmission` in ConversationViewState.swift:78-87, `permitsFaceTracking` in FaceTrackingTypes.swift:57-64). Add `var allowsInactivity: Bool { switch self { case .idle, .listening, .paused: true; default: false } }` and use it in both places: `guard phase.allowsInactivity else { setState(.awake); return }` and `if inactivity == .sleepy, phase.allowsInactivity`.
- **Confidence:** medium-high. Tests are not affected.

### R6. The idle-minute bounds are magic numbers in six places instead of using the `RobotPreferences` range pattern
- **What is duplicated:**
  - `1`/`1439` and `2`/`1440` appear as inline `min(max(...))` at ConversationIdleSettings.swift:15, 24, 32 and 34.
  - They appear again as Stepper ranges `in: 1...1439` and `in: 2...1440` at ConversationSettingsView.swift:72 and 74.
  - The defaults `5` and `10` are inline at ConversationIdleSettings.swift:32 and 35.
- **Cost:** if the model clamp and the UI range drift apart, the Stepper can offer values that the model silently rewrites, or the other way round. The spec's 1–1439 / 2–1440 contract lives in six places.
- **Use instead:** `RobotPreferences` (RobotPreferences.swift:14-16) already sets the pattern: `nonisolated static let trackingYawCorrectionRange` / `defaultTrackingYawCorrection` are used by both the model's normalizer and `RobotCalibrationView` (lines 62-77).
  - Add `static let sleepyMinutesRange = 1...1439`, `sleepingMinutesRange = 2...1440`, `defaultSleepyMinutes = 5` and `defaultSleepingMinutes = 10` to `ConversationIdleSettings`.
  - Clamp with `min(range.upperBound, max(range.lowerBound, v))`.
  - Pass `in: ConversationIdleSettings.sleepyMinutesRange` (and the sleeping range) to the Steppers.
- **Confidence:** medium. Tests stay the same.

### R7. ConversationView re-derives sleeping overrides inline instead of using the `displayed*` projections this change adds
- **What is duplicated:** the change adds `displayedCaption`, `displayedActivityStatus` and `displayedMicrophoneStatus` to `ConversationViewState` (ConversationViewState.swift:51-53) so that the view does not branch on `isSleeping`. The view still has hand-written gates:
  - `state.showsTypedInput && !state.isSleeping` twice, at ConversationView.swift:80 and 211.
  - `!state.isSleeping, !state.provisionalTranscript.isEmpty` at 117.
  - `if state.isSleeping { return "mic.slash.fill" }` at 233.

  Separately, the literal `"待機中・タップで起こす"` is defined in both `ConversationViewState.displayedActivityStatus` (line 52) and `ConversationAccessibility.init` (ConversationAccessibility.swift:40).
- **Cost:** the two typed-input gates must stay identical, or layout priority and the input bar disagree. The wake-status string has two sources, one for the visible text and one for VoiceOver.
- **Use instead:** add `var displaysTypedInput: Bool { showsTypedInput && !isSleeping }` and `var displayedProvisionalTranscript: String { isSleeping ? "" : provisionalTranscript }` next to the existing `displayed*` properties, and use them at 80, 211 and 117. For the string, put a single `static let sleepingStatus` on `ConversationViewState` (or on `ConversationInactivityState`) and reference it from both places.
- **Confidence:** medium. Tests are not affected; the existing string assertions still pass.

### R8 (low). Coordinator: the sleeping guard for "show typed input" is written in two action closures
- **What is duplicated:** `showTypedInput` (ConversationAppCoordinator.swift:318-321) and `performRecovery(.showTypedInput)` (345-347) each do `guard !isSleeping; viewModel.showTypedInput()`. The base code already had the `viewModel.showTypedInput()` call twice; this change adds the same guard to both.
- **Cost:** a future guard on showing typed input must be added in two places.
- **Use instead:** add `private func showTypedInputIfAwake()` and call it from both closures.
- **Confidence:** low, since this is a small cleanup. Tests stay the same.

## Areas checked and found clean (no existing helper to call)

- **`ConversationIdleClock` vs the `RobotClock` family:** it conforms to the existing `RobotClock` protocol (RobotLink/RobotClock.swift), the coordinator takes `any RobotClock`, and the tests inject the existing `ManualRobotClock` (CatRobotTests/RobotLink/RobotTestDoubles.swift:6). Using ContinuousClock instead of `SystemRobotClock`'s `systemUptime` is deliberate and required by the spec, because device-sleep time must count. Only the three-line `sleep(until:)` body is copied from `SystemRobotClock`, and there is no protocol-extension default to reuse. Not flagged.
- **Timer/token pattern vs `FaceExpressionCoordinator`:** `ConversationInactivity.evaluate` (Task + `clock.sleep(until:)` + generation-token check) follows the same inline pattern as `FaceExpressionCoordinator.show` and `ConversationCamera` timeouts. The product has no shared deadline-timer type, so this is consistent with the existing convention.
- **`ConversationIdleSettings` vs `RobotPreferences` / `ConversationModelSettings` / `SpeechVoiceSettings`:** it uses the same shape (`@MainActor @Observable`, injected `UserDefaults`, `@ObservationIgnored defaults`, stored-value-plus-clamping setter). No shared base or property wrapper exists. The only reuse gap is the range constants (R6).
- **`launchAction(allowWhileSleeping:)` / `resumeListeningIfNeeded` / `wakeFromSleeping`:**
  - `wakeFromSleeping` reuses `launchAction` (and therefore `completeConversationStartIfEligible` and `updateFaceEnvironment`) and `viewModel.startConversation()`, which is the same call `toggleListening` makes from `.paused`.
  - `launchStart` is not a drop-in replacement: it has different cancellation ownership (`activeStartIntentID`) and does not await `pauseTask`.
  - The `isSleeping && isVoiceSettingsClosed` term in `updateRobotScene` (231) is close to `activeControlMode` but not interchangeable, because `activeControlMode` reads `settingsModel.effectiveControlMode`, which depends on the application mode being set at that point.
- **`ConversationViewModel.onPhaseChange`:** `announcePhase(_:)` already sits on the `transition`/`publish` path, but it runs before `viewState` is updated. Moving the callback into it would let the coordinator react, and possibly sleep, re-entrantly in the middle of a mutation. The three extra `onPhaseChange` calls (lines 808, 816, 828) signal changes in pending speech, not phase changes, so `announcePhase` is not a reuse target.
- **Tests:**
  - The new tests already reuse `ManualRobotClock`, `robotDrain`, `ConversationHarness`, `ConversationTestGate`, `FakeConversationMemoryManager`, `TestIdleTimerStorage.makeWakeLock()`, `RobotAppHarness` (extended with `idleClock:`), `FaceExpressionHarness` (ExpressToolTests) and the existing `render(_:name:typeSize:)` helper (FaceConversationPresentationTests).
  - `ConversationIdleIntegrationTests.app(_:clock:)` follows the per-file `makeCoordinator` convention (for example, ConversationAutoResumeTests.swift:7).
  - No shared ephemeral-`UserDefaults` helper exists; each harness, including `RobotLinkHarness`, builds its own suite. The new `UserDefaults(suiteName: UUID().uuidString)!` repeated in three files matches local practice. One optional hygiene point: unlike ConversationUsageMeterTests, the new tests do not remove the suites.
- **Harness: `describe` / `meanColor` / `write_source`:** the change itself already lifted `describe` and `meanColor` to `private static` for reuse (the dropped `center:` parameter had no callers) and extracted `write_source()` in `render_face.sh`. That is good reuse. `featureProfile` and `columnProfile` produce different outputs (canvas-binned centerline vs pixel-column samples) and are not duplicates.
- **Face product code:**
  - `CatFaceAppearance.sleeping` is derived from `sleepy` through the existing `updateEyes`.
  - `closedLid` uses the existing `EyeFrame.path` builder.
  - The `highlightDrop` guard extends the existing guard.

  No product-side helper is being re-implemented. `closedLidThickness` and the closed-eye visibility branch are mirrored between `CatFaceGeometryTests` and `scripts/face-render/Check.swift` by project convention, and the product has no shared helper that both could call. Not flagged.
- **ExpressTool:** the tool's `description` and `@Guide` text still list the nine names by hand, even though `FaceExpression.expressible` now exists. `@Guide` takes a macro string, and these lines predate this change, so this is noted only, not flagged.
