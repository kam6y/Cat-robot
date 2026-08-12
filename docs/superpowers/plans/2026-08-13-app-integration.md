# App Integration and Device Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the domain, Apple services, and cat interface into a responsive foreground conversation, then prove the MVP on the connected iPhone 16 Pro.

**Architecture:** One `@MainActor @Observable` `ConversationViewModel` owns UI state plus distinct capture, segmentation, turn, preflight, and audio-event tasks. Monotonic session/capture/turn identities prevent stale callbacks from mutating a newer conversation. It stops capture at each utterance boundary, takes deterministic wake/engagement fast paths before optional classification, streams one stateful reply into captions, speaks it, and resumes capture only after normal TTS completion; pause/background/interruption require explicit resume.

**Tech Stack:** SwiftUI, Observation, AVFAudio permission API, OSLog signposts, Swift 6, iOS 26, XCTest, xcodebuild/devicectl.

## Global Constraints

- Work in `feature/app-integration`, branched from main after foundation, domain, services, and interface are squash-integrated.
- Request microphone access only after **会話を始める**. Typed input remains available if permission or speech fails.
- Keep the direct wake-name and active engagement paths classifier-free. Do not add a reply validator, factuality pass, cloud call, persistent transcript, or analytics.
- Stop actual capture while classifying, generating, or speaking; automatically resume only after normal foreground turn completion.
- Pause/background/interruption clears engagement and pending clarification and never silently resumes.
- Pause/background/interruption performs per-turn stop/deactivation only; it does not release prepared Speech assets. Run the explicit service teardown only when the conversation screen or its app-root owner is actually leaving.
- Stream cumulative Foundation Models snapshots by replacement, not append.
- Target latency is under 2 seconds from detected utterance end to first visible fast-path reply and under 4 seconds to audible reply; measure classified turns separately. Targets guide UX and are not release gates.
- Use real device `Not so bad`, UDID `00008140-000610311A90801C`, iOS 26.6; simulator UDID is `0D540017-B9D7-4E42-B99F-6D0840FD41DA`.
- Automatic signing: team `VUB4VP6453`, bundle `com.kamby.CatRobot`.
- Integrate with `git merge --squash`; push and retain `feature/app-integration`.

## Prerequisite integration base

Do not create `feature/app-integration` until `feature/apple-services` and `feature/cat-interface` are clean, reviewed, and complete. From the main worktree, squash `feature/apple-services` into `main` first, then squash `feature/cat-interface`; regenerate once, run the combined simulator suite and `git diff --check`, commit each bounded squash, and push `main` plus both retained feature branches. Branch `feature/app-integration` from that exact combined `main`. Task 1 must not begin against a branch missing `AppleSpeechSynthesizer`, `AppleAudioSessionController`, or the final `ConversationView` action/accessibility contract.

## Integration contract

```swift
protocol MicrophoneAuthorizing: Sendable {
    func requestAccess() async -> Bool
}

@MainActor @Observable
final class ConversationViewModel {
    private(set) var viewState: ConversationViewState
    func startConversation() async
    func toggleListening() async
    func retryRecovery() async
    func showTypedInput()
    func submitTypedText(_ text: String) async
    func sceneBecameInactive() async
    func handleAudioSessionEvent(_ event: AudioSessionEvent) async
    func shutdown() async
}
```

The initializer receives `MicrophoneAuthorizing`, `ModelAvailabilityChecking`, `SpeechRecognizing`, `AddressClassifying`, `ReplyGenerating`, `SpeechSpeaking`, `AudioSessionControlling`, `AddresseePolicy`, a monotonic `now: @Sendable () -> TimeInterval`, and `serviceTeardown: @escaping @Sendable () async -> Void`. Fakes implement every external side effect and use a no-op teardown unless a lifecycle test injects a counter.

The view model serializes all public actions through one lifecycle generation. It owns separate cancellable `preflightTask`, `captureTask`, `segmentationTask`, `turnTask`, and `audioEventTask`, plus monotonic session/capture/turn counters. Repeated start/resume calls join or ignore the current preflight; pause/background/interruption invalidates the generation before awaiting child teardown. Every recognition event, timer firing, model snapshot, speech event, and preflight completion verifies its captured identity before changing state or restarting capture. A completed utterance invalidates that capture identity before its lossless recognizer stop, so any final tail event from the closed capture cannot seed a second turn.

---

### Task 1: Permission, error presentation, and dependency composition

**Files:**
- Create: `CatRobot/Conversation/Integration/MicrophonePermissionService.swift`
- Create: `CatRobot/Conversation/Integration/ConversationErrorPresentation.swift`
- Create: `CatRobot/Conversation/Integration/ConversationDependencies.swift`
- Test: `CatRobotTests/Conversation/Integration/ConversationErrorPresentationTests.swift`

**Interfaces:**
- Produces: `MicrophoneAuthorizing`, live `MicrophonePermissionService`, Japanese error copy, and `ConversationDependencies.live()` including explicit service teardown.
- Consumes: all domain/service protocols and concrete Apple adapters.

- [ ] **Step 1: Write failing actionable-copy tests**

```swift
final class ConversationErrorPresentationTests: XCTestCase {
    func testMicrophoneDenialOffersTypedFallback() {
        let value = ConversationErrorPresentation(.microphoneDenied)
        XCTAssertEqual(value.message, "マイクを使えません。設定で許可するか、文字で話しかけてください。")
        XCTAssertTrue(value.offersTypedInput)
        XCTAssertEqual(value.recoveries, [
            .init(title: "設定を開く", action: .openSettings),
            .init(title: "文字で話す", action: .showTypedInput),
        ])
    }

    func testModelPreparingOffersRetry() {
        let value = ConversationErrorPresentation(.modelUnavailable(.modelNotReady))
        XCTAssertEqual(value.recoveries, [.init(title: "もう一度確認", action: .retry)])
    }

    func testUnrecognizedSpeechOffersRetryAndTyping() {
        let value = ConversationErrorPresentation(.speechUnrecognized)
        XCTAssertEqual(value.message, "うまく聞き取れませんでした")
        XCTAssertEqual(value.recoveries.map(\.action), [.retry, .showTypedInput])
    }
}
```

- [ ] **Step 2: Regenerate and run the focused test; expect missing types**

Run: `ruby scripts/generate_project.rb && xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/ConversationErrorPresentationTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`

- [ ] **Step 3: Implement permission and composition**

Use `AVAudioApplication.requestRecordPermission()` in the live permission service. The app uses iOS 26 `SpeechTranscriber` and does not instantiate `SFSpeechRecognizer`, so it requests only microphone consent; no separate Speech-recognition authorization flow is needed. Map every `ConversationServiceError` with an exhaustive switch to plain Japanese plus one or more `ConversationRecovery` values; microphone denial offers both Settings and typed input, and other errors use retry, Settings, or typed-input recovery as appropriate without exposing debug descriptions. `ConversationDependencies.live()` constructs exactly one reply service, concrete `AppleSpeechRecognizer`, synthesizer, and audio-session controller per app conversation lifetime; classifier sessions remain internally one-shot. Do not start any service during composition.

Keep the concrete recognizer reachable while exposing it to orchestration through the domain existential:

```swift
@MainActor
static func live() -> ConversationDependencies {
    let concreteRecognizer = AppleSpeechRecognizer()
    let recognizer: any SpeechRecognizing = concreteRecognizer
    let serviceTeardown: @Sendable () async -> Void = {
        await concreteRecognizer.shutdown()
    }
    return ConversationDependencies(
        // other live dependencies,
        recognizer: recognizer,
        serviceTeardown: serviceTeardown
    )
}
```

`ConversationDependencies` retains both the existential and the closure for the same concrete instance. Its fake/test factory supplies `serviceTeardown: {}` by default; lifecycle tests may inject an actor-backed counter. Do not add `shutdown` to `SpeechRecognizing`.

- [ ] **Step 4: Run focused tests and commit**

```bash
git add CatRobot/Conversation/Integration CatRobotTests/Conversation/Integration CatRobot.xcodeproj
git commit -m "feat: compose live conversation dependencies"
```

### Task 2: View-model happy path and fast routing

**Files:**
- Create: `CatRobot/Conversation/Integration/ConversationViewModel.swift`
- Create: `CatRobotTests/Conversation/Integration/ConversationFakes.swift`
- Test: `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`

**Interfaces:**
- Produces: `ConversationViewModel` methods in the integration contract.
- Consumes: `UtteranceSegmenter`, engagement/pending clarification state, and all injected services.

`ConversationHarness` passes an actor-backed `FakeServiceTeardown.call` closure to the view model and exposes that probe as `teardownProbe`; the general fake `ConversationDependencies` factory still defaults to the no-op `{}`:

```swift
actor FakeServiceTeardown {
    private(set) var callCount = 0

    func call() {
        callCount += 1
    }
}

let teardownProbe = FakeServiceTeardown()
let serviceTeardown: @Sendable () async -> Void = {
    await teardownProbe.call()
}
```

- [ ] **Step 1: Write failing orchestration tests with actor-safe fakes**

```swift
@MainActor
final class ConversationViewModelTests: XCTestCase {
    func testWakeTurnSkipsClassifierAndStreamsThenSpeaks() async throws {
        let harness = ConversationHarness()
        harness.reply.snapshots = ["やあ", "やあ、元気だよ"]
        await harness.sut.startConversation()
        await harness.emitCompletedUtterance("猫ちゃん、元気？")
        let classifierCalls = await harness.classifier.calls
        let replyPrompts = await harness.reply.prompts
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(classifierCalls, [])
        XCTAssertEqual(replyPrompts, ["元気？"])
        XCTAssertEqual(spokenTexts, ["やあ、元気だよ"])
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testEngagedFollowUpAlsoSkipsClassifier() async throws {
        let harness = ConversationHarness()
        await harness.completeTurn("ねこ、質問", at: 0)
        await harness.completeTurn("もう少し教えて", at: 10)
        let classifierCalls = await harness.classifier.calls
        let replyPrompts = await harness.reply.prompts
        XCTAssertEqual(classifierCalls.count, 0)
        XCTAssertEqual(replyPrompts.last, "もう少し教えて")
    }

    func testWakeOnlyAcknowledgesLocallyAndArmsFastFollowUp() async throws {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.emitCompletedUtterance("猫ちゃん")

        let firstSpokenTexts = await harness.speaker.texts
        let firstClassifierCalls = await harness.classifier.calls
        let firstReplyPrompts = await harness.reply.prompts
        XCTAssertEqual(firstSpokenTexts, ["なあに？"])
        XCTAssertTrue(firstClassifierCalls.isEmpty)
        XCTAssertTrue(firstReplyPrompts.isEmpty)

        await harness.completeTurn("今日どう？", at: 10)
        let classifierCallCount = await harness.classifier.calls.count
        XCTAssertEqual(classifierCallCount, 0)
    }

    func testClassifiedAddressRepliesAndArmsFastFollowUp() async throws {
        let harness = ConversationHarness(classification: .addressed)
        await harness.completeUnengagedTurn("今日どう？", at: 0)
        await harness.completeTurn("もう少し教えて", at: 10)
        let replyPrompts = await harness.reply.prompts
        let classifierCalls = await harness.classifier.calls
        XCTAssertEqual(replyPrompts, ["今日どう？", "もう少し教えて"])
        XCTAssertEqual(classifierCalls.count, 1)
    }

    func testUnrelatedSpeechReturnsToListeningWithoutReply() async throws {
        let harness = ConversationHarness(classification: .notAddressed)
        await harness.completeUnengagedTurn("テレビ消した？", at: 0)
        let replyPrompts = await harness.reply.prompts
        XCTAssertTrue(replyPrompts.isEmpty)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testAudioActivatesBeforeRouteBoundRecognizerPreparation() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        XCTAssertLessThan(
            harness.calls.firstIndex(of: .activateAudio)!,
            harness.calls.firstIndex(of: .prepareRecognizer)!
        )
    }
}
```

`ConversationHarness.emitCompletedUtterance` feeds a final recognition event and advances a test-only `flushSegmentation(at:)` seam by 1.2 seconds; production schedules the same flush with `Task.sleep(for:)` and cancels/reschedules it on new activity.

- [ ] **Step 2: Run tests; expect missing view model/harness**

- [ ] **Step 3: Implement start and happy-path turn-taking**

`startConversation` requests permission, checks model availability, prepares the installed Japanese synthesis voice, activates audio, then prepares route-bound speech recognition, prewarms reply, and starts recognition. Audio activation must precede `AppleSpeechRecognizer.prepare()` because the latter captures `inputNode.outputFormat` and constructs its converter. Repeated starts while preflight is pending join or no-op; a permission/preflight completion from an invalidated generation cannot publish success or failure.

A completed utterance invalidates its capture identity, cancels its segmentation timer, and awaits the recognizer's lossless stop before starting any newer recognition stream. Before handling any accepted route, consume and clear the current pending clarification; this applies to `.wakeOnly`, `.accept`, and a classified `.addressed` result, and happens before local acknowledgement or reply generation. `.wakeOnly` immediately captions and locally speaks the fixed phrase `なあに？`, never calls the classifier or reply session, arms engagement after acknowledgement finishes, and resumes capture. `.accept` goes directly to `streamReply`; `.classify` calls the classifier once. A classified `.addressed` result enters reply generation and arms engagement after the reply; `.ambiguous` enters the clarification flow; `.notAddressed` sends nothing to the reply session and starts a fresh recognition stream only after prior capture teardown completes. Replace caption with each cumulative snapshot. Speak only the final nonempty snapshot. On speech word events cycle `small/medium/wide`; on finish arm engagement for an explicit wake, confirmed pending utterance, or classified address, otherwise refresh an already active engagement; reset mouth and start one fresh recognition stream.

Add focused race tests for two concurrent starts; scene inactivity while permission/preflight is suspended; pause during reply streaming; background during TTS; a tail recognition result after utterance close; stale model snapshot or speech-finished event after a newer session; duplicate interruption/inactive events; and rapid pause/resume. Each proves stale callbacks do not update the UI, arm engagement, or restart capture.

If reply generation finishes without a nonempty snapshot, show a recoverable model-generation error with retry and typed fallback and do not speak or arm engagement. If generation is cancelled because the lifecycle changed, publish neither stale error nor restart. If TTS fails, show a visible synthesis error, do not arm engagement, and leave listening paused until explicit recovery. A normal speech terminal event resumes capture exactly once.

- [ ] **Step 4: Run focused tests and commit**

```bash
git add CatRobot/Conversation/Integration CatRobotTests/Conversation/Integration CatRobot.xcodeproj
git commit -m "feat: orchestrate responsive voice turns"
```

### Task 3: Clarification, cancellation, typed fallback, and context reset

**Files:**
- Modify: `CatRobot/Conversation/Integration/ConversationViewModel.swift`
- Test: `CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift`

**Interfaces:**
- Extends: view-model behavior without changing its public method names.

- [ ] **Step 1: Write failing recovery tests**

```swift
@MainActor
final class ConversationRecoveryTests: XCTestCase {
    func testAmbiguousSpeechAsksOnceThenAffirmativeUsesOriginal() async throws {
        let harness = ConversationHarness(classification: .ambiguous)
        await harness.completeUnengagedTurn("明日の予定は？", at: 0)
        let clarificationTexts = await harness.speaker.texts
        XCTAssertEqual(clarificationTexts.last, "今の、ぼくに言った？")
        await harness.completeUnengagedTurn("うん", at: 3)
        let replyPrompts = await harness.reply.prompts
        XCTAssertEqual(replyPrompts.last, "明日の予定は？")
    }

    func testNewExplicitWakeConsumesPendingBeforeFreshEngagement() async throws {
        let harness = ConversationHarness(classification: .ambiguous)
        await harness.completeUnengagedTurn("明日の予定は？", at: 0)
        let clarificationTexts = await harness.speaker.texts
        XCTAssertEqual(clarificationTexts.last, "今の、ぼくに言った？")

        await harness.completeUnengagedTurn("猫ちゃん、今日どう？", at: 3)
        await harness.completeTurn("もう少し教えて", at: 10)

        let replyPrompts = await harness.reply.prompts
        let classifierCalls = await harness.classifier.calls
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(replyPrompts, ["今日どう？", "もう少し教えて"])
        XCTAssertEqual(classifierCalls, ["明日の予定は？"])
        XCTAssertEqual(spokenTexts.filter { $0 == "今の、ぼくに言った？" }.count, 1)
        XCTAssertFalse(replyPrompts.contains("明日の予定は？"))
    }

    func testBackgroundStopsEverythingAndRequiresExplicitResume() async {
        let harness = ConversationHarness()
        await harness.sut.sceneBecameInactive()
        let recognizerIsRunning = await harness.recognizer.isRunning
        let audioIsActive = await harness.audio.isActive
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertFalse(recognizerIsRunning)
        XCTAssertFalse(audioIsActive)
        let teardownCallCount = await harness.teardownProbe.callCount
        XCTAssertEqual(teardownCallCount, 0)
    }

    func testShutdownRunsServiceTeardownOnlyOnce() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()

        await harness.sut.shutdown()
        await harness.sut.shutdown()

        let teardownCallCount = await harness.teardownProbe.callCount
        XCTAssertEqual(teardownCallCount, 1)
    }

    func testTypedTextWorksWhenMicrophoneDenied() async {
        let harness = ConversationHarness(microphoneAllowed: false)
        await harness.sut.startConversation()
        await harness.sut.submitTypedText("こんにちは")
        let replyPrompts = await harness.reply.prompts
        XCTAssertEqual(replyPrompts, ["こんにちは"])
    }

    func testEmptyFinalRecognitionShowsRecoveryWithoutStoppingListening() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.emit(.finalized(""))
        XCTAssertEqual(harness.sut.viewState.errorMessage, "うまく聞き取れませんでした")
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry, .showTypedInput])
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.retryRecovery()
        XCTAssertNil(harness.sut.viewState.errorMessage)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testExplicitResumeRepreflightsBeforeListening() async {
        let harness = ConversationHarness()
        await harness.sut.sceneBecameInactive()
        await harness.sut.toggleListening()
        let availabilityCheckCount = await harness.modelAvailability.checkCount
        let recognizerPrepareCount = await harness.recognizer.prepareCount
        let speakerPrepareCount = await harness.speaker.prepareCount
        XCTAssertEqual(availabilityCheckCount, 1)
        XCTAssertEqual(recognizerPrepareCount, 1)
        XCTAssertEqual(speakerPrepareCount, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }
}
```

- [ ] **Step 2: Run tests and observe failures**

- [ ] **Step 3: Implement recovery rules**

For `.ambiguous`, retain only one `PendingClarification`, speak the fixed local question without sending it to the reply session, and wait for yes/no. Negative/timeout discards it. Any accepted route consumes and clears the pending clarification before local acknowledgement or reply generation, including an affirmative acceptance of its original utterance and a new explicit wake-name turn that supersedes it; an old pending utterance must never reappear after a fresh accepted turn. An empty finalized recognition event presents `.speechUnrecognized` with **もう一度** and **文字で入力** while capture remains in `.listening`; `retryRecovery()` clears this card without restarting the already-running capture, and `showTypedInput()` opens the fallback. For paused or failed availability states, `retryRecovery()` reruns the same preflight as explicit resume. `pause`, scene inactivity, and any audio interruption cancel timer/model/stream tasks, stop recognizer/speaker, deactivate audio, and clear engagement/pending state, but deliberately retain the Speech asset reservation for low-latency explicit resume. `toggleListening()` from paused reruns model availability, speech-asset preparation, synthesis-voice preparation, and audio activation before starting capture; a failed preflight stays visibly failed/paused and never pretends to listen. Context exceeded resets the reply session once and shows that short-term conversation memory was reset; it does not retry the same prompt silently. Typed text bypasses addressee classification.

Implement `ConversationViewModel.shutdown()` as an idempotent terminal lifecycle action: guard against a second call, cancel orchestration/timer/stream work, stop recognizer and speaker, deactivate audio, clear engagement/pending state, then await the injected `serviceTeardown`. This is separate from pause and is never called between turns or merely because `sceneBecameInactive()` ran.

The explicit resume preflight uses the same order as initial start: synthesis/model checks as appropriate, then audio activation, then route-bound recognizer preparation. Stop recognizer and speaker before deactivating audio. `shouldResume` from an interruption is informational only; never reactivate automatically.

Accessibility follows the UI branch's deduplicated announcement policy. Provisional recognition and cumulative intermediate reply snapshots are never announced. When the final nonempty reply is known and speech ends normally, keep that caption visible through the `.speaking` → `.listening` transition so it is announced exactly once. Errors and recovery choices are announced once by the same policy.

- [ ] **Step 4: Run integration tests and commit**

```bash
git add CatRobot/Conversation/Integration CatRobotTests/Conversation/Integration
git commit -m "feat: recover conversation naturally"
```

### Task 4: Root view wiring and local latency signposts

**Files:**
- Modify: `CatRobot/App/AppRootView.swift`
- Modify: `CatRobot/App/CatRobotApp.swift`
- Create: `CatRobot/Conversation/Integration/ConversationLatency.swift`
- Test: `CatRobotTests/Conversation/Integration/AppCompositionTests.swift`
- Modify: `README.md`

**Interfaces:**
- Produces: onboarding-to-conversation navigation, scene lifecycle forwarding, and local `OSSignposter` intervals named `FastPathFirstCaption`, `ClassifiedFirstCaption`, `FastPathSpeechStart`, `ClassifiedSpeechStart`.

- [ ] **Step 1: Write a failing composition test**

Verify `AppRootView(dependencies:)` can be initialized with fakes and starts in onboarding without requesting microphone access or starting any service. Also test that an audio-session interruption reaches the view model, `.active` does not resume, and duplicate `.inactive`/`.background` forwarding is idempotent. Add a focused lifecycle case that enters then leaves the conversation screen twice through the idempotent exit path and observes one injected teardown call; forward `.inactive` first and prove it still observes zero teardown calls. The Apple-services composition test separately proves that this same closure reaches `AppleSpeechRecognizer.shutdown()` and releases one successful Speech reservation exactly once.

- [ ] **Step 2: Implement root composition**

Keep one stable injected `ConversationDependencies` value. Initialize `_viewModel = State(initialValue: ConversationViewModel(dependencies: dependencies))` inside `AppRootView.init(dependencies:)`; live dependencies are constructed once at app-root ownership, not during `body` updates. Show `OnboardingView`, and enter `ConversationView` only after its explicit start action. Start one retained audio-event consumer for the view-model lifetime and cancel it during concrete dependency teardown; forward interruption/route events through `handleAudioSessionEvent`.

Forward `.inactive`/`.background` scene phases to `sceneBecameInactive` idempotently; do not auto-resume on `.active` and do not invoke service teardown from scene-phase changes. Bind UI actions to view-model methods using token-aware `Task` calls, including the UI contract's explicit typed-input dismiss callback so the parent remains the source of truth. Route recovery actions explicitly: retry calls `retryRecovery()`, typed input calls `showTypedInput()`, and Settings uses SwiftUI's `openURL` with `UIApplication.openSettingsURLString`. When navigation actually leaves `ConversationView`, or when its `AppRootView` ownership ends, call and await the idempotent `ConversationViewModel.shutdown()` before discarding that lifetime. Do not call `shutdown()` on normal turn completion, manual pause, interruption, or backgrounding, preserving the prepared asset and resume latency.

- [ ] **Step 3: Add signposts and README limitations**

Start signposts at detected utterance end; end them on first reply snapshot and `.started` speech event. Store no content in logs. README explicitly states: foreground only, no speaker ID, no barge-in, no background listening, addressee detection can be wrong, AI replies can be wrong, and all MVP processing is on device.

- [ ] **Step 4: Run simulator suite and commit**

```bash
git add CatRobot/App CatRobot/Conversation/Integration CatRobotTests/Conversation/Integration README.md CatRobot.xcodeproj
git commit -m "feat: integrate Cat Robot conversation experience"
```

### Task 5: iPhone 16 Pro build, install, and smoke test

Create `docs/validation/2026-08-13-iphone16pro-smoke-test.md` before the run. Record Xcode version, SDK version, device name/model, iOS version, the exact build/install/launch commands and exit status, observed scenarios, latency values, and any acceptance failure honestly. Save bounded command output and Cat Robot console output under `docs/validation/logs/`; capture diagnostics before changing code when launch or runtime behavior fails. Do not record recognized utterance/reply content beyond the fixed test phrases or any device/user secrets.

- [ ] Unlock `Not so bad`, keep it awake, and run:

```bash
xcrun devicectl device info ddiServices --no-auto-mount-ddis --device 00008140-000610311A90801C
```

Expected: developer disk image services are enabled. If disabled, open Xcode's Devices and Simulators, select the unlocked phone, wait for preparation, and repeat.

- [ ] Run the full simulator suite once.

- [ ] Build and provision for the phone:

```bash
xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -configuration Debug \
  -destination 'platform=iOS,id=00008140-000610311A90801C' \
  -derivedDataPath .build/DeviceDerivedData DEVELOPMENT_TEAM=VUB4VP6453 \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -allowProvisioningDeviceRegistration
```

- [ ] Install and launch:

```bash
xcrun devicectl device install app --device 00008140-000610311A90801C \
  .build/DeviceDerivedData/Build/Products/Debug-iphoneos/CatRobot.app
xcrun devicectl device process launch --device 00008140-000610311A90801C com.kamby.CatRobot
```

Capture a bounded Cat Robot console log during the smoke session with the installed `devicectl`/`log` facilities available on this Xcode version; write the exact successful command and output path into the validation report. If process launch or runtime initialization fails, collect the launch result and console diagnostics before applying the smallest acceptance fix.

- [ ] On the phone, verify: contextual mic prompt; Japanese readiness; wake-name-only local **なあに？** acknowledgement followed by a classifier-free unnamed turn; wake-name-plus-content turn including an undelimited Japanese ASR form; natural engaged follow-up without name; unrelated speech after engagement expiry; ambiguous clarification plus yes/no; streamed caption; audible Japanese reply; moving mouth; automatic post-reply listening; manual pause; no silent resume after background/interruption; typed fallback.
- [ ] Capture signpost timings for one fast-path and one classified-path turn with Instruments. Record observed values in `docs/validation/2026-08-13-iphone16pro-smoke-test.md`; record failures honestly and fix only issues required by acceptance criteria.
- [ ] Run `git diff --check` and full tests after any fix, then commit `test: document iPhone 16 Pro smoke test`.
- [ ] Verify the app-integration worktree is clean and list its bounded commits. From the main worktree, which already contains the services/UI squash commits, run `git merge --squash feature/app-integration`, commit as `feat: deliver Cat Robot MVP`, regenerate and run the final full suite plus `git diff --check` on main, then push main and the retained `feature/app-integration`, `feature/apple-services`, and `feature/cat-interface` branches. Verify the named remote refs exist; do not delete branches.
