# Independent code review: idle sleeping

Reviewed the uncommitted changes at `f6eeedadb96e9c13e7ec2c2656114b332ddcd4f2` in `/Users/goodapple/.codex/worktrees/b200/Cat_robot`, including the five untracked implementation/test files, against the supplied design and plan. All 35 source hashes match `scope.json`; `scope.diff` SHA-256 is `155914efc2305b8b47959bec63f54a25b575f61b3e896e2bea7eaa70e934fc37`. No checkout, index, project, test, or documentation files were changed.

## Strengths

- The inactivity owner uses a monotonic clock, preserves elapsed time across settings/background suspension, and makes sleeping sticky. Coordinator gates cover foreground, settings, recovery, new conversation, and typed actions; tap wake explicitly joins shutdown.
- Accepted speech is reported at routing/classification acceptance, not at arbitrary ASR activity. Busy phases preserve the last interaction time. Existing regressions cover background speech, pending provisional recognition, long replies, and shutdown/tap races.
- Sleep shuts down the existing resource owners rather than creating competing microphone/camera/motion ownership. The integration test uses the real tracking and motion coordinators, including cancellation and restart assertions.
- Settings normalize both bounds and the ordered pair without overflow. UI wording explains that both values are measured from the same interaction and take effect after closing settings.
- Sleeping is excluded from `express`, and its gold lids are implemented independently of the existing face presets. The comparison image agrees with the documented measurements and small tip differences. Geometry, accessibility, and rendering checks are meaningful.
- Normalizing the generated project showed exactly two added product sources and three added test sources, with no removed sources or target build-setting changes. Both schemes are identical after ignoring regenerated target IDs.

## Issues

### Critical

None found.

### Important

**R1 — Text-only conversations never arm inactivity monitoring after microphone denial.**

- **Location:** `CatRobot/App/ConversationAppCoordinator.swift:89–92`, `:143–147`, and `:75`.
- **Trigger:** On a fresh app session, deny microphone access, choose the offered “文字で話しかける” recovery, submit a valid typed message, let its reply finish, then leave the screen untouched for the configured thresholds.
- **Cause/effect:** Monitoring requires `hasStartedConversation`, but its only transition to `true` is guarded by `phase.permitsFaceTracking`. The failed voice preflight cannot set it. A successful typed-only turn ends in `.paused`, which also fails that guard. `onAddressedActivity` records the time but never enables monitoring. The supported text-only conversation therefore stays awake indefinitely, even after a successful exchange; no sleepy/sleeping transition occurs. This is independent of R2: the final state here is `.paused`, not `.failed`.
- **Actual path:** Microphone denial is published at `ConversationViewModel.swift:487–492`; the UI explicitly offers typed input in `ConversationErrorPresentation.swift:13–15`. Typed admission reports activity at `ConversationViewModel.swift:243–244`; without voice capture, `:655–658` completes in `.paused`. `launchAction` calls `completeConversationStartIfEligible` only after that operation finishes (`ConversationAppCoordinator.swift:422–423`). The pre-existing `ConversationRecoveryTests.testMicrophoneDeniedTypedTurnUsesOnlyTypedPreflightAndRetainsCaption` (`:292–328`) confirms this supported paused outcome. The new typed inactivity integration case starts with successful voice capture, so it misses this path.
- **Fix:** Separate “inactivity has an interaction/session to monitor” from “voice startup completed and camera tracking may be enabled.” Arm monitoring on an accepted typed interaction, preserving the existing camera permission/preflight gates. Add a coordinator regression with `microphoneAllowed: false`, real action submission, then 299/300/600-second checks and draft preservation.
- **Severity:** Important: the complete new feature is unavailable for a supported input mode. This does not imply microphone/camera leakage in the denied-permission path.

**R2 — A terminal conversation failure permanently cancels the inactivity deadline.**

- **Location:** `CatRobot/Conversation/Inactivity/ConversationInactivity.swift:72–82`.
- **Trigger:** Successfully start a conversation, then reach a terminal recognition, generation, or speech error and leave the error screen untouched. For example, use the existing speech-failure fixture after voice startup.
- **Cause/effect:** `.failed(...)` falls into the same default branch as active work. The branch cancels the timer, sets inactivity to `.awake`, and returns without scheduling another deadline. A terminal failure has no work left that will naturally publish a later listening phase, so the cat remains awake indefinitely. It can even change from sleepy back to awake on an unaddressed recognition failure. Existing failure cleanup already stops the audio/camera paths; the issue is the promised inactivity behavior, not a claim of continued capture.
- **Evidence:** `ConversationViewModel.publish` reports the failed phase at `:1623–1629`; `performVoiceFailureCleanup` finishes before that terminal UI is left for user recovery (`:1281–1320`). Existing `ConversationViewModelTests.testSpeechFailureIsVisibleAndDoesNotResumeCapture` (`:392–398`) verifies that it stays failed. A narrow native probe compiling the unchanged inactivity/settings/domain files observed `sleepy` at 350 seconds, `awake` immediately on `.failed(.modelUnreachable)`, and still `awake` at 1200 seconds; changing only the phase to `.paused` immediately produced `sleeping`.
- **Fix:** Explicitly enumerate busy phases and allow an otherwise inactive terminal error to reach standby after cleanup. Preserve useful error/recovery information as a separate presentation concern; permanent error visibility is not an in-progress operation and need not disable the inactivity clock. Add a coordinator test that leaves a completed error untouched past both deadlines.
- **Severity:** Important: an ordinary recoverable error silently disables automatic standby until another user/lifecycle action. Error text need not be removed to resolve it.

**R3 — The 20-second pending-ASR bound does not cover capture finalization.**

- **Location:** `CatRobot/Conversation/Inactivity/ConversationInactivity.swift:85–89`; `CatRobot/Conversation/Integration/ConversationViewModel.swift:120`.
- **Trigger:** Start an utterance just before the standby deadline, produce a final segment, and have `recognizer.stop()`/ASR finalization take more than 20 seconds. This is deterministically modelable with the existing `recognizerStopGate` while `beginClosingCapture` is running; it does not require new speech to keep arriving.
- **Cause/effect:** The new pending flag includes `captureIsClosing`, but the claimed 20-second release exists only inside `UtteranceSegmenter`. Once closing begins, the segmentation timer is cancelled, and `captureIsClosing` remains true until `recognizer.stop()` and the stream consumer finish (`ConversationViewModel.swift:861–887`, `:897–911`). Meanwhile the inactivity owner cancels its own timer and returns without a watchdog. The live driver awaits `analyzer.finalizeAndFinishThroughEndOfInput()` and its tasks without a timeout (`AppleSpeechRecognizer.swift:688–707`). A delayed finalizer therefore defers sleep without a bound, leaving conversation tracking/automatic motion eligible while the phase is still listening. The live microphone is stopped before finalization; this finding does not claim it keeps recording during that await.
- **Evidence/limit:** A narrow probe confirms the owner remains sleepy with pending speech at 700 seconds after pending began at 599, and immediately sleeps when the pending flag clears. The production call path above establishes why that flag can outlive the segmenter's cap. I did not induce a real Speech framework stall or run a device test. The new unfinished-recognition test (`ConversationIdleIntegrationTests.swift:210–224`) covers provisional-only expiry, not a suspended closing/finalization operation.
- **Fix:** Bound the whole ASR-pending interval, including finalization, and provide safe cancellation/cleanup when the bound expires before entering standby. Do not merely clear the Boolean while leaving an unowned finalizer running. Add a gate-based closing test past the cap and verify standby resources, late-result rejection, and subsequent tap wake.
- **Severity:** Important: an explicit timeout guarantee is missing on a real asynchronous path. The defect is conditional on delayed finalization, not evidence that normal devices routinely hang.

### Minor

**R4 — Old captions are hidden during sleep but reappear on wake.**

- **Location:** `CatRobot/Conversation/UI/ConversationViewState.swift:51`; `CatRobot/App/ConversationAppCoordinator.swift:95–117`.
- **Trigger/effect:** Complete a reply, wait for standby, then tap the face. `displayedCaption` temporarily returns an empty string, but the stored caption is never cleared. The preparing/listening transitions do not clear it, so the old reply resurfaces when `inactivity.wake()` removes the override. The design explicitly says sleeping clears old captions.
- **Fix:** Clear the old caption when entering standby while retaining the typed draft and conversation memory. Extend the presentation/integration check through a full sleep→wake cycle; the current presentation test checks only the sleeping projection.
- **Severity:** Minor: stale presentation, without data loss or blocked operation.

## Recommendations

Resolve R1–R3 before merge, with regressions at the coordinator boundary rather than only setting `ConversationInactivity` inputs directly. Keep R1 and R2 separate: enabling monitoring for a typed-only session will not fix the terminal-failure phase branch. Retain the existing shutdown ownership and sticky wake guards while adding the ASR cap.

The stored full-suite summary records 791 tests, 789 passed, two hardware-only skips, and zero failures. I inspected that evidence, not reran the suite. The independent probe used native `swiftc` and temporary files only; no Xcode build, simulator execution, physical-app interaction, or full-suite tests were performed. Its output supports the state-machine findings, not end-to-end hardware claims.

## Declined to judge

- Physical microphone/camera indicators, neck settling, and tap wake on the connected robot: the requested read-only review explicitly excluded device interaction, and the user's positive visual impression is not a detailed hardware validation log.
- A fresh comprehensive audit of unchanged firmware, BLE implementation, and prior conversation internals: these had a separate prior review and were only inspected here where the new inactivity integration changes their behavior. The ASR finalization dependency is included as R3 because the new pending-state contract relies on it.

## Assessment

**Ready to merge? No.**

The normal voice path and visual implementation are well covered, but typed-only use and terminal errors escape the inactivity behavior, and ASR finalization can exceed its advertised bound. These are localized, actionable gaps rather than a need to redesign the feature.

## R3 clarification after ownership review

This clarification supersedes R3's assertion of an already specified end-to-end **20-second** finalization guarantee. The actual `UtteranceSegmenter.maximumDuration` bounds accumulation of an utterance (or expiry of provisional-only recognition). It does **not** bound `SpeechAnalyzer` graceful finalization. The design explicitly mentions the existing utterance maximum; it does not separately assign a finalization grace period. The code definitely permits unbounded standby deferral if finalization remains suspended, but I withdraw the claim that this alone proves a violation of a specified 20-second graceful-finalization timeout. Treat that part of R3 as a robustness recommendation unless the owners confirm an end-to-end pending-ASR deadline. R1/R2 and the overall “No” verdict remain unchanged.

### Existing cancellation/ownership behavior

- `SpeechRecognizing` exposes `prepare`, `start`, and `stop` only (`ConversationServices.swift:22–26`). Calling `stop()` again while `.stopping(id)` joins `waitForLifecycle(id)` (`AppleSpeechRecognizer.swift:151–158`). It does not escalate graceful shutdown.
- `shutdown()` also waits for an existing `.stopping(id)` before acquiring its own shutdown lifecycle (`:193–204`). Even a fresh running shutdown uses the same graceful `stopCapture` (`:216–218`). It is not a force-cancel escape hatch.
- Cancelling the stream consumer works only while recognizer state is `.running`; `consumerTerminated` returns for `.stopping` (`:353–359`). `captureFailed` also joins an existing stop (`:346–347`). Therefore cancelling the VM's consumer, issuing another stop, or calling shutdown cannot currently interrupt an owned finalization.
- The **lower-level driver** does expose `cancel()`. `LiveSpeechCaptureDriver.cancel` can change `.gracefullyFinalizing` into `.immediatelyCancelling` (`:475–477`, `:714–731`), suppresses further output, cancels its analysis/results tasks, and calls `analyzer.cancelAndFinishNow()`. Its cancellation coordinator coalesces reentrant cancellation and waits for that operation (`:485–501`). This is an available cancellation request mechanism, not evidence of a hard real-time guarantee that Apple's cancellation call itself must finish by a particular instant.

### Smallest safe implementation point, if adopted

Put a bounded graceful-finalization helper **inside `AppleSpeechRecognizer.stopCapture`, around the current `try await capture.driver.stop()` at line 381**. This owner already holds the precise `RunningCapture`, output gate, and the surrounding `.stopping`/`.shuttingDown` lifecycle. No new VM-level force-cancel protocol is needed for a separately chosen finalization grace period.

The helper must own both the graceful-stop operation and its deadline task. If the deadline wins, first close the output gate to new tail events, then invoke/await `capture.driver.cancel()`, and also join the original graceful-stop task before returning. Cancel and join the deadline task when graceful finalization wins. Keep the existing lifecycle state until all of that finishes; only its existing caller may run `completeLifecycle`. Route timeout/error cleanup through one owner so the catch path does not issue a second independent driver cancellation. A task-group race that only cancels its losing child, or a timeout task that returns while `driver.stop()` is still running, does not satisfy this requirement.

The live driver is single-run: normal cancellation clears its run state and a future capture uses a new driver. Joining the old finalizer before releasing recognizer ownership additionally prevents old teardown from overlapping that future capture. No early `completeLifecycle`, no detached abandoned finalizer, and no clearing of `hasPendingSpeech` to pretend cleanup finished.

A 20-second **grace period measured from `driver.stop()`** could allow roughly 20 seconds of utterance accumulation plus 20 seconds of finalization. It is not a 20-second end-to-end ASR cap. If the latter is the product requirement, the remaining deadline must be carried to the finalization owner; the current parameterless `stop()` provides no such budget. Those are different policies and should not be conflated.

### Focused regression that would substantiate the fix

Use `AppleSpeechRecognizerTests` with its existing suspended normal-stop and suspended cancellation gates, plus an injected deadline sleeper/clock. The current fake's `cancel()` does **not** release `normalStopGate` (`:856–875`), so simply waiting for the old fake will hang; model cancellation-driven finalizer unwinding explicitly, with a separate controlled finalizer-return gate.

1. Start capture; request stop and hold graceful finalization. Issue a second stop, and verify both are pending and a fresh start is rejected without constructing another driver.
2. Release the injected deadline. Assert exactly one immediate cancellation begins, late tail events are dropped, and both stop callers remain pending while cancellation cleanup is held.
3. Let cancellation finish but keep the old finalizer-return gate closed. A fresh start must still be rejected and neither stop may report completion. This is the key assertion against an unowned finalization task.
4. Release the old finalizer. Both stops should finish once, the stream should terminate once under the chosen timeout policy, and a new capture should start on a second driver. A late old timer/event must not affect the new stream.
5. Retain the existing under-deadline tail-result test (`testNormalStopDeliversTailResultBeforeFinishingWithoutCancellation`, `:30–56`). Add/retain the shutdown ordering control: reservation release follows owned stop cleanup, and normal stop alone does not release the reservation.

Existing tests already substantiate generation-scoped start/teardown (`:343–401`, `:405–454`, `:552–579`), running-consumer cancellation (`:326–341`), graceful tail acceptance and failure suppression (`:628–640`), late-event rejection (`:642–650`), and coalesced cancellation (`:652–686`). They do not currently test a deadline escalating an already suspended normal stop.

If R3 is adopted for the idle feature, one additional coordinator regression should begin closing recognition before the inactivity deadline, exercise that bounded recognizer finalization path, and then verify sleeping plus tap wake. A VM fake whose `stop()` simply becomes unblocked by the test proves scheduling only; it cannot prove the production cancellation/ownership fix.

No implementation changes or tests were run for this clarification; this was a read-only trace of the existing service and tests.
