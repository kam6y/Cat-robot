# Simplification review: idle sleeping working tree (b200, base f6eeedad)

Scope: the uncommitted change only. Line numbers are from the current working tree. Every finding keeps behavior and the approved face design as they are.

---

## Product code

### S1 `CatRobot/App/ConversationAppCoordinator.swift:95-106`: `enterSleeping()` is a copy of the body of `forwardPauseIfNeeded()` (`:396-404`)
- **Cost:** Five lines are copied word for word: `activeStartIntentID = nil`, `startTask?.cancel()`, `viewModel.invalidateForSceneInactivity()`, and the `pauseTask = Task { await viewModel.sceneBecameInactive(); self?.pauseTask = nil }` pair. These are the "stop the conversation" steps. If someone later changes the pause sequence (for example, extra cleanup in `sceneBecameInactive` handling), they now have to change it in two places.
- **Simpler:**
  ```swift
  private func pauseConversation() {
      activeStartIntentID = nil
      startTask?.cancel()
      viewModel.invalidateForSceneInactivity()
      pauseTask = Task { @MainActor [weak self, viewModel] in
          await viewModel.sceneBecameInactive()
          self?.pauseTask = nil
      }
  }
  private func enterSleeping() {
      invalidateActionTasksForSceneInactivity()
      pauseConversation()
      updateRobotScene(scenePhase)
  }
  // forwardPauseIfNeeded: guard…; didForwardPauseSinceActive = true; deferredPermissionPrompt = false; pauseConversation()
  ```
  Behavior is the same. `updateRobotScene` still runs after `invalidateForSceneInactivity`. The `Task` body runs only after the current main-actor turn, so it still runs after `updateRobotScene`. Nothing in `updateRobotScene` reads `activeStartIntentID`, `startTask` or `pauseTask`.
- **Confidence:** high. No test changes.

### S2 `ConversationAppCoordinator.swift:169` and `:175`: the same `!isSleeping` guard sits in both caller and callee
- **Cost:** `resumeListeningIfNeeded()` checks `!isSleeping` and then calls `launchStart()`, whose first line is `guard !isSleeping`. The only other caller of `launchStart` is `beginConversation()`. That method runs only from `.onboarding`, and inactivity cannot be `.sleeping` there because `updateInactivity` monitors only when `destination == .conversation`. So one of the two guards can never be the one that stops a call, and a reader cannot tell which one is meant to hold.
- **Simpler:** keep one guard at the choke point. Keep `launchStart`'s `guard !isSleeping` and drop `!isSleeping` from the condition list in `resumeListeningIfNeeded`, or the other way round. Behavior is the same.
- **Confidence:** high. No test changes.

### S3 `CatRobot/Conversation/Inactivity/ConversationInactivity.swift:50-62, 83-97`: duplicated reset logic, and two branches in `evaluate` that end up in the same place
- **Cost:**
  - `recordActivity()` and `wake()` have the same body except for the leading `guard state != .sleeping`.
  - In `evaluate()`, the pending-speech branch (`:85-90`) and the normal path (`:91-96`) both compute "sleepy or awake from `sleepyAt`". The normal path also reads `clock.now` up to three times.
  - Together these make the state machine look like it has more paths than it does.
- **Simpler:**
  ```swift
  func recordActivity() { guard state != .sleeping else { return }; restart() }
  func wake() { restart() }                       // face tap only
  private func restart() { lastActivity = clock.now; setState(.awake); evaluate() }

  // in evaluate(), after the phase switch:
  let now = clock.now
  let sleepyAt = …, sleepingAt = …
  let finishingSpeech = phase == .listening && hasPendingSpeech   // keep the existing comment
  if now >= sleepingAt, !finishingSpeech { setState(.sleeping); return }
  setState(now >= sleepyAt ? .sleepy : .awake)
  guard !finishingSpeech else { return }
  let deadline = now >= sleepyAt ? sleepingAt : sleepyAt
  // …schedule timer as today
  ```
  Behavior is the same, branch for branch. With pending speech it sets sleepy or awake and schedules no timer. Without it, it sleeps when past `sleepingAt`, otherwise sets sleepy or awake and schedules a timer for the next deadline. Reading the clock once only removes a sub-microsecond skew between the three reads.
- **Confidence:** high. No test changes.

### S4 `ConversationInactivity.swift:33, 73, 98, 101`: the `generation` token repeats what task cancellation already guarantees
- **Cost:** Each `generation &+= 1` is paired with `timer?.cancel()` in the same synchronous main-actor call. `timer` is the only reference to a running timer task, and it is reassigned only right after that cancel. A stale timer therefore always has `Task.isCancelled == true` by the time it resumes on the main actor, so `self.generation == token` never decides anything. The token is also captured after `setState(...)`, which can call back into the coordinator, so it would not protect against re-entrancy either. That is one stored counter and one extra condition for nothing.
- **Simpler:** delete `generation` and `token`, and keep `guard !Task.isCancelled, let self else { return }`. Behavior is the same.
- **Confidence:** medium. The coordinator uses a "cancel + generation" belt-and-braces idiom on purpose (`actionSceneGeneration`). In that case the generation also covers tasks that are not cancelled together, which does not happen here. No test changes.

### S5 `ConversationInactivity.swift:64`: `settingsDidChange()` has no production caller
- **Cost:** It is only `evaluate()` under a public name. Production applies threshold changes when the sheet closes: `closeVoiceSettings` → `updateInactivity` → `setMonitoring` → `evaluate`. That matches the footer "変更は設定を閉じたときに反映します". Only `ConversationInactivityTests` (`:25, 80, 83`) call it, so the API suggests a live-update path that does not exist.
- **Simpler:** remove it. In the tests, replace `idle.settingsDidChange()` with `idle.setMonitoring(true, phase: .listening)`, which is what production does. Behavior is the same.
- **Confidence:** medium, because the plan's interface list named it. Three test lines change.

### S6 `CatRobot/Conversation/Integration/ConversationViewModel.swift:805-808` with `:816`: `onPhaseChange` fires twice in a row on one path
- **Cost:** In `receiveRecognition`, the `else` branch calls `synchronizeCaptureTimingWithSegmenter()`. That method now ends with `onPhaseChange(viewState.phase)` (`:816`), and then `:808` calls `onPhaseChange` again. Each call runs `conversationPhaseDidChange`, which runs `updateFaceEnvironment` (four environment pushes) and `setMonitoring`. That `setMonitoring` call cancels and rebuilds the inactivity timer. Separately, three of the five new `onPhaseChange` sites (`:808, 816, 828`) do not change the phase. They are "pending speech changed" notifications under a phase-change name, which is why they also drive face-environment updates for every partial ASR result.
- **Simpler:**
  - Minimal fix: move the notify out of `synchronizeCaptureTimingWithSegmenter` (restoring its pre-diff body) and into its only other caller, `flushSegmentation` (`:362`: `synchronizeCaptureTimingWithSegmenter(); onPhaseChange(viewState.phase)`). The site count stays at three and the double fire is gone.
  - Optional: rename or split those three sites into an `onPendingSpeechChange` callback that the coordinator maps to `updateInactivity()` only.
  - Behavior is the same, since `evaluate` is idempotent for equal inputs.
- **Confidence:** medium-high for the double-fire fix. The split is optional, and overlaps with the efficiency angle. No test changes.

### S7 `CatRobot/Conversation/UI/ConversationAccessibility.swift:30-41`: `isSleeping` is stored next to a `listeningSemantic` that it then overrides
- **Cost:** When the cat is asleep, `listeningSemantic` is set to `.resume`, but both of its readers (`listeningAction`, `listeningHint`) skip it through `isSleeping ? … :` ternaries. So the stored semantic is wrong, and the struct carries a private flag only to correct it. `assistantStatus = "待機中・タップで起こす"` also repeats the literal in `ConversationViewState.displayedActivityStatus` (`ConversationViewState.swift:52`).
- **Simpler:** add the case to the semantic.
  ```swift
  enum ConversationListeningSemantic { case resume, pause, wake
      var actionLabel: String { … case .wake: "猫を起こす" }
      var hint: String { … case .wake: "タップして会話を再開します" } }
  // init: if inactivity == .sleeping { listeningSemantic = .wake; microphoneValue = "停止中"; assistantStatus = …; return }
  var listeningAction: String { listeningSemantic.actionLabel }   // back to pre-diff
  var listeningHint: String { listeningSemantic.hint }
  ```
  Delete `private let isSleeping`. Optionally share the "待機中・タップで起こす" literal through one `static let`. Every string VoiceOver reads stays the same. Only `listeningSemantic`'s own value changes while asleep (`.wake` instead of `.resume`), and no code or test reads it in that state.
- **Confidence:** medium-high. No test changes (`ConversationIdlePresentationTests` checks only the strings).

### S8 `CatRobot/Conversation/UI/ConversationViewState.swift:91` and `CatRobot/Conversation/UI/ConversationView.swift:80, 117, 211`: a sleeping guard nothing observes, plus the same sleeping condition repeated in the view
- **Cost:**
  - `allowsTypedSubmission` gained `!isSleeping`, but it has only two consumers.
    - `ConversationViewModel.submitTypedText` (`:221, 243`) reads the view model's own `viewState`, whose `inactivity` is never set and is always `.awake`, because only `AppRootView` composes it.
    - `TypedInputView` (`ConversationView.swift:226`) is rendered only under `state.showsTypedInput && !state.isSleeping`.
    - So the clause cannot affect behavior, yet it suggests the view model enforces sleep (the coordinator's `launchAction` guard does that).
  - In `ConversationView`, `state.showsTypedInput && !state.isSleeping` appears twice (`:80`, `:211`), and `!state.isSleeping, !state.provisionalTranscript.isEmpty` appears at `:117`. The state already has a `displayed*` pattern (`displayedCaption`, `displayedActivityStatus`, `displayedMicrophoneStatus`) for exactly this.
- **Simpler:**
  ```swift
  var displaysTypedInput: Bool { showsTypedInput && !isSleeping }
  var displayedProvisionalTranscript: String { isSleeping ? "" : provisionalTranscript }
  var allowsTypedSubmission: Bool { phase.allowsTypedSubmission && !…blocksConversation }   // drop !isSleeping
  ```
  With this, the view needs no `isSleeping` checks for these three sites. Behavior is the same. The removed clause was unobservable, and the two view conditions become one property.
- **Confidence:** medium. `ConversationIdlePresentationTests.swift:14` (`XCTAssertFalse(state.allowsTypedSubmission)`) would be dropped or moved to `displaysTypedInput`.

### S9 `ConversationViewState.swift:48` and `ConversationInactivity.swift:77-82`: the "quiet phase" set is written out in two places
- **Cost:** `phase == .listening || phase == .idle || phase == .paused` in `faceExpression`, and `case .idle, .listening, .paused: break` in `evaluate`, encode the same rule: which phases count toward inactivity, and therefore which phases can show sleepy. If someone edits one and not the other, the face and the timer disagree.
- **Simpler:** one predicate next to the existing `ConversationPhase.allowsTypedSubmission` and `permitsFaceTracking` helpers.
  ```swift
  extension ConversationPhase { var countsTowardInactivity: Bool { switch self { case .idle, .listening, .paused: true; default: false } } }
  ```
  `evaluate`: `guard phase.countsTowardInactivity else { setState(.awake); return }`. `faceExpression`: `if inactivity == .sleepy, phase.countsTowardInactivity { return .sleepy }`. Behavior is the same.
- **Confidence:** medium. No test changes.

### S10 `CatRobot/Conversation/Inactivity/ConversationIdleSettings.swift:15, 24, 32-35` and `CatRobot/App/ConversationSettingsView.swift:72, 74`: each bound is written three times, and two optional parameters only fall back to a default
- **Cost:**
  - `1`/`1439` and `2`/`1440` each appear in the setter, in `init`, and in the `Stepper(in:)` range. If someone changes a limit in one place, the UI range and the stored clamp drift apart.
  - Separately, `idleSettings: ConversationIdleSettings? = nil` followed by `?? ConversationIdleSettings()` is used in the coordinator (`ConversationAppCoordinator.swift:60, 74`) and the settings view (`ConversationSettingsView.swift:30, 33`). `idleClock: (any RobotClock)? = nil` followed by `?? ConversationIdleClock()` is used in `RobotAppHarness` (`CatRobotTests/Motion/RobotLifecycleIntegrationTests.swift:15, 36`). The `nil` value means nothing except "use the default". The coordinator's own `idleClock: any RobotClock = ConversationIdleClock()` in the same parameter list shows that a main-actor default value compiles here.
- **Simpler:**
  ```swift
  static let sleepyRange = 1...1439, sleepingRange = 2...1440
  // setter/init: Self.sleepyRange.clamped(x) or min(max(x, r.lowerBound), r.upperBound); Stepper(…, in: ConversationIdleSettings.sleepyRange)
  init(…, idleSettings: ConversationIdleSettings = ConversationIdleSettings(), …)   // same for the view and the test harness
  ```
  Behavior is the same.
- **Confidence:** medium (high for the ranges). No test changes.

---

## Tests

### S11 Assertions in the new tests repeat each other
1. **`CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift:79-80` and `:135-139`.**
   - "The lid covers the whole outline" is asserted for sleeping in `testSleepingClosesEyesUnderGoldLidArc` and again in the new `closed >= 1` branch of `testPupilsAndHighlightsStayVisible`.
   - The same duplication is in the harness: `scripts/face-render/Check.swift:76-77` and `:156-160`.
   - Simpler: in the visibility test, keep only `continue` for closed eyes (the dedicated sleeping test owns the lid check), or the reverse.
   - Confidence: medium. Only the test or check changes.
2. **`CatRobotTests/Face/FaceExpressionTests.swift:31-36`.**
   - Four assertions state one fact. The first restates the implementation (`allCases.filter { $0 != .sleeping }`), and the other three follow from it or from the compiler.
   - Simpler: `XCTAssertEqual(Set(FaceExpression.allCases).subtracting(FaceExpression.expressible), [.sleeping])`.
   - Confidence: medium.
3. **`CatRobotTests/Conversation/Domain/UtteranceSegmenterTests.swift:49-50`.**
   - These lines (`XCTAssertNil(utteranceIfReady(at: 25)); XCTAssertFalse(hasActivity)`) repeat lines 33-34 of the existing `testMaximumDurationExpiresProvisionalOnlyTurnBeforeNextFinalizedTurn`, which uses the same 5 → 24.9 → 25 timeline.
   - Simpler: drop them, or fold the three `flushDelay` assertions into the existing test.
   - Also a missing blank line at `:41` and a trailing blank line at `:60`.
   - Confidence: medium.
4. **`CatRobotTests/Conversation/Inactivity/ConversationIdleIntegrationTests.swift`.**
   - Eight `ConversationHarness` tests repeat `let app = app(h, clock:); app.beginConversation(); await app.waitForOperations()` and the teardown `app.scenePhaseDidChange(.background); await app.waitForOperations(); await h.sut.shutdown()`.
   - Several also repeat the triple `state == .sleeping / phase == .paused / startCount == N`.
   - `UserDefaults(suiteName: UUID().uuidString)!` for an isolated `ConversationIdleSettings` is built in four places: `ConversationInactivityTests.swift:7, 88`, `ConversationIdleIntegrationTests.swift:9`, and `RobotLifecycleIntegrationTests.swift:35`.
   - Simpler: `startedApp(_ h:) async -> (app, clock)`, `stop(_ app:, _ h:) async`, `assertAsleep(app, h, starts:)`, and one shared test-support `ConversationIdleSettings.isolated()`.
   - Confidence: medium. Test-only.

---

## macOS render harness (`scripts/face-render`)

### S12 `scripts/face-render/Render.swift:24-79` copies `run` with small changes, and the draft-vs-render IoU is computed twice per round
- **Cost:**
  - `runSleeping` copies:
    - the round-overwrite guard (`:27-31` = `:15-19`),
    - the `written` plus `save` closure (`:32-37` = `:87-92`),
    - the stacked-compare and 50% overlay `compose` blocks (`:53-62` ≈ `:125-134`).
  - The IoU line `.map { String(format: "%@ %.3f", $0.0.rawValue, $0.1) }.joined(separator: ", ")` appears three times (`Render.swift:73-74, 138-139`, `Measure.swift:260-261`).
  - Scaling the draft to 1280×720 and computing its IoU is done in both `Render.runSleeping` (`:49-51, 73-75`) and `Measure.runSleeping` (`Measure.swift:256-262`). `scripts/render_face.sh sleeping` runs both, so each round computes and prints the same numbers twice.
  - `main.swift:47-59` matches `"render", "render-sleeping"` and then branches on `arguments[0]` again.
- **Simpler:**
  - Extract `roundDirectory(_ base:, round:, overwrite:) throws -> String`, a small `PNGSaver` (directory + `written`), `stacked(top:bottom:)`, `overlay(base:top:)`, and `formatAgreement(_:)`.
  - Optionally have `run` and `runSleeping` return `(written, directory)` so `main` prints once.
  - Either compute the sleeping IoU in one shared function called from both places, or leave it only in `measure --sleeping`, which is what lands in `measure.txt`.
  - Output files and `measure.txt` stay the same. Only the duplicate stdout line from `render-sleeping` changes, and only if you choose to drop it.
- **Confidence:** medium-high. No product or test impact.

### S13 `scripts/face-render/Measure.swift`: small amounts of dead or derivable state in `runSleeping` and `reportSleeping`
- **Cost and simpler form:**
  - `@discardableResult` (`:286`) is dead. Both call sites (`:214, 216`) use the result.
  - `var arcBounds: [CGRect] = []` plus `append` in the loop (`:300, 320`) equals `let arcBounds = arcs.map(\.bounds)`.
  - The magic `0.2231` (`:221` header and three times at `:240`) is `CatFaceGeometry.baseEyeRadii.height`. `frame.radii.height` is already computed per side in `reportSleeping`. Use `let pxPerLocalV = CatFaceGeometry.baseEyeRadii.height * 720`.
  - `draftArcs` and `renderedArcs` (`:217-218`) are just aliases.
  - `report()` keeps two local forwarding wrappers (`:36-37`), while `reportSleeping` passes `reference:` and `bitmap:` explicitly at eight call sites. Use the same two local wrappers in both.
  - Printed output stays the same, as long as `baseEyeRadii.height` stays 0.2231 and the format strings still print it.
- **Confidence:** medium. Harness only.

---

## Low-priority notes (optional)
- **`CatRobot/Conversation/UI/CatFaceShapes.swift:332-356` (`closedLid`).**
  - `upper.tipHandle.v` is `0.0` but is added to `tip.v` twice.
  - The `CGFloat(…)` casts inside the nested tuple literals are only there for typing. `typealias Edge = (tipDU: CGFloat, tipDV: CGFloat, centerDU: CGFloat, v: CGFloat)` with `let upper: Edge = (0.084, 0, 0.577, 0.573)` reads more easily.
  - The numbers must stay exactly the same, because they were fitted to the draft. Low value.
- **`ConversationInactivity.swift:6-15` (`ConversationIdleClock`).**
  - `now` can be `origin.duration(to: .now) / .seconds(1)` (Duration ÷ Duration → Double).
  - `sleep(until:)` is the same as `SystemRobotClock.sleep` (`CatRobot/RobotLink/RobotClock.swift:12-14`). This is reuse territory.
- **`ConversationAppCoordinator.swift:123, 127, 138, 231`.**
  - `isSleeping && isVoiceSettingsClosed` is the condition for the inactive mode in both `activeControlMode` and `updateRobotScene`.
  - `destination == .conversation && isVoiceSettingsClosed && !isSleeping` is shared by the two visibility booleans in `updateFaceEnvironment`.
  - One `private var` each would name the rule. Cosmetic.
- **`scripts/face-render/Render.swift:181-186` (`GalleryView`).** The column count `3` is written in five places (`cell.width * 3`, `gap * 4`, `(+2)/3`, `by: 3`, `+ 3`). Use `static let columns = 3`. Cosmetic.

## Checked and found clean (or not worth changing)
- **`ConversationAppCoordinator`.**
  - `isSleeping` has one source of truth (computed from `inactivity.state`). The view state's `inactivity` is a composed copy, following the `heldExpression`/`isLooking` pattern.
  - `launchAction(allowWhileSleeping:)` is a real flag: it is `true` at two sites, and its re-check inside the task follows an `await`.
  - The re-checks in `wakeFromSleeping` after `await pauseTask?.value` are needed.
  - The two `!isSleeping` guards in `completeConversationStartIfEligible` (`:145`, `:148`) are not redundant. The first stops `hasStartedConversation = true` while asleep.
  - The `updateInactivity()` calls that run back to back (for example `closeVoiceSettings` `:284` and then `resumeListeningIfNeeded` `:168`) are idempotent, and the earlier call has to run before `updateRobotScene` to avoid a transient `.conversation` mode. Leave them.
  - The sleep guards in `showTypedInput`, `updateTypedText` and `performRecovery(.showTypedInput)` are the coordinator-side authority, alongside the view's `.disabled`. They are layered on purpose, and integration tests drive these actions directly.
- **`ConversationViewModel`.**
  - The four `onAddressedActivity()` sites (typed, `.wakeOnly`, `.accept`, classifier `.addressed`) are each the single accept point for their route, so no common site replaces them.
  - `hasPendingSpeech` is a minimal derived property.
  - The `onPhaseChange` calls in `transition` and `publish` are needed (`publish` sets `.failed` without `transition`). The one in `presentUnrecognizedSpeechWhileListening` is needed because it resets the segmenter and that path returns early.
- **`ConversationViewState.faceExpression` precedence** (sleeping > sleepy-in-quiet-phase > look > held > automatic) is clear. Only the duplicated phase set in S9 applies.
- **`AppRootView`.** Replacing `.onChange(of: phase)` with the view-model callback removes a path. Clean.
- **`UtteranceSegmenter.flushDelay`.** One early return. It could be a ternary, but that is not worth changing.
- **`FaceExpression.expressible` and `normalized`.** Clean. `ExpressTool.label`'s `.sleeping` arm cannot be reached because `normalized` never returns `.sleeping`, but Swift's exhaustive switch needs it. Keep it rather than adding `default`.
- **`CatFaceAppearance.sleeping` / `Eye.closed`, the `CatFaceView` draw addition, and the `highlightDrop` `lid < 1` guard.** Clean. `closed` is animated on its own, separately from `lid`, so it cannot be derived from `lid` without changing the approved fade.
- **`scripts/render_face.sh` `write_source`.** This is a deduplication: the inline source-provenance block became a function used twice. Clean.
- **`closedLidThickness`** is duplicated between `CatFaceGeometryTests` and `Check.swift`. The harness mirrors the XCTest checks on purpose ("XCTest と同じ判定") and cannot import test code. Accept it.
- **`ExpressToolTests`, `FaceConversationPresentationTests.testInactivityFixturesRender`, `ConversationAccessibilityTests`** (identifier list update) and the `RobotLifecycleIntegrationTests` harness addition (beyond S10's optional parameter): clean.
