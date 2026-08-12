# Conversation Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the pure Swift state, timing policies, addressee fast paths, and service contracts that make Cat Robot's foreground conversation fast and testable.

**Architecture:** Keep timing and routing deterministic in value types. Apple-framework adapters conform to small async protocols later; the domain imports Foundation only and never imports SwiftUI, Foundation Models, Speech, or AVFAudio.

**Tech Stack:** Swift 6, Foundation, XCTest, iOS 26.0+.

## Global Constraints

- Work in `feature/conversation-domain`, created from integrated `main`, in `.worktrees/feature-conversation-domain`.
- Run `ruby scripts/generate_project.rb` after adding files.
- Preserve iOS 26.0, Swift 6 strict concurrency, no packages, and Japanese-first behavior.
- Optimize conversation flow: wake-name and engaged turns skip model classification; no reply validator or confidence score.
- Soft engagement expiry is 30 seconds; hard expiry is 300 seconds; pending clarification expires after 15 seconds.
- End a turn after 1.2 seconds of silence, with a 20-second maximum turn duration.
- Integrate with `git merge --squash`; push and retain `feature/conversation-domain`.

## Public contract

Create focused files below `CatRobot/Conversation/Domain/` with this shared surface:

```swift
enum ConversationPhase: Equatable, Sendable {
    case idle, preparing, listening, classifying, clarifying, thinking, speaking, paused
    case failed(ConversationServiceError)
}

enum AddressTarget: Equatable, Sendable { case addressed, ambiguous, notAddressed }
struct SpeechRecognitionEvent: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    static func provisional(_ text: String) -> Self { .init(text: text, isFinal: false) }
    static func finalized(_ text: String) -> Self { .init(text: text, isFinal: true) }
}
enum SpeechEvent: Equatable, Sendable {
    case started, willSpeak(range: Range<Int>), finished, cancelled
}
enum ModelAvailability: Equatable, Sendable {
    case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unsupportedLocale
}
enum ConversationServiceError: Error, Equatable, Sendable {
    case microphoneDenied, speechAssetsUnavailable, speechLocaleUnsupported, speechUnrecognized, speechCaptureFailed, speechCaptureAlreadyRunning
    case speechVoiceUnavailable, speechSynthesisFailed, audioSessionFailed, modelUnavailable(ModelAvailability)
    case modelLocaleUnsupported, modelAssetsUnavailable, guardrailViolation, refusal, contextExceeded
    case modelBusy, modelGenerationFailed, cancelled
}

protocol ModelAvailabilityChecking: Sendable { func availability() async -> ModelAvailability }
protocol AddressClassifying: Sendable { func classify(_ utterance: String) async throws -> AddressTarget }
protocol ReplyGenerating: Sendable {
    func prewarm() async
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}
protocol SpeechRecognizing: Sendable {
    func prepare() async throws
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
    func stop() async
}
protocol SpeechSpeaking: Sendable {
    func prepare() async throws
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error>
    func stop() async
}
enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
}
protocol AudioSessionControlling: Sendable {
    var events: AsyncStream<AudioSessionEvent> { get }
    func activate() async throws
    func deactivate() async
}
```

---

### Task 1: Shared conversation types and service protocols

**Files:**
- Create: `CatRobot/Conversation/Domain/ConversationTypes.swift`
- Create: `CatRobot/Conversation/Domain/ConversationServices.swift`
- Test: `CatRobotTests/Conversation/Domain/ConversationTypesTests.swift`

**Interfaces:**
- Produces: every type and protocol in the public contract above.
- Consumes: Foundation only.

- [ ] **Step 1: Write the failing contract test**

```swift
import XCTest
@testable import CatRobot

final class ConversationTypesTests: XCTestCase {
    func testFailurePhaseRetainsActionableCause() {
        XCTAssertEqual(
            ConversationPhase.failed(.modelUnavailable(.modelNotReady)),
            .failed(.modelUnavailable(.modelNotReady))
        )
    }

    func testRecognitionEventsDistinguishProvisionalAndFinalText() {
        XCTAssertNotEqual(
            SpeechRecognitionEvent.provisional("ねこ"),
            .finalized("ねこ")
        )
    }
}
```

- [ ] **Step 2: Regenerate and prove the test fails**

Run: `ruby scripts/generate_project.rb && xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/ConversationTypesTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`

Expected: compile failure because domain types do not exist.

- [ ] **Step 3: Implement exactly the public contract**

Put enums in `ConversationTypes.swift` and protocols in `ConversationServices.swift`. Keep declarations internal to the app module; tests use `@testable`.

- [ ] **Step 4: Run the focused test**

Run the Step 2 command again. Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add CatRobot/Conversation/Domain CatRobotTests/Conversation/Domain CatRobot.xcodeproj
git commit -m "feat: add conversation domain contracts"
```

### Task 2: Silence-based utterance segmentation

**Files:**
- Create: `CatRobot/Conversation/Domain/UtteranceSegmenter.swift`
- Test: `CatRobotTests/Conversation/Domain/UtteranceSegmenterTests.swift`

**Interfaces:**
- Produces: `UtteranceSegmenter.Configuration(silenceInterval: 1.2, maximumDuration: 20)`, `receive(_:at:)`, and `utteranceIfReady(at:) -> String?`.
- Consumes: `SpeechRecognitionEvent`; timestamps are `TimeInterval` supplied by the coordinator.

- [ ] **Step 1: Write failing behavior tests**

```swift
final class UtteranceSegmenterTests: XCTestCase {
    func testFinalTextClosesAfterSilence() {
        var sut = UtteranceSegmenter()
        sut.receive(.provisional("ねこ、"), at: 0)
        sut.receive(.finalized("ねこ、今日どう？"), at: 0.4)
        XCTAssertNil(sut.utteranceIfReady(at: 1.59))
        XCTAssertEqual(sut.utteranceIfReady(at: 1.6), "ねこ、今日どう？")
        XCTAssertNil(sut.utteranceIfReady(at: 2.0))
    }

    func testMaximumDurationClosesNoisyTurn() {
        var sut = UtteranceSegmenter()
        sut.receive(.finalized("長い話"), at: 5)
        sut.receive(.provisional("まだ続く"), at: 24.9)
        XCTAssertEqual(sut.utteranceIfReady(at: 25), "長い話")
    }
}
```

- [ ] **Step 2: Run only this test and observe missing-type failure**

Use the Task 1 command with `-only-testing:CatRobotTests/UtteranceSegmenterTests`.

- [ ] **Step 3: Implement the minimal segmenter**

Trim whitespace, ignore empty results, replace provisional text, append finalized segments once, track first/latest activity, and clear all state after returning a completed utterance. `isFinal` does not itself close the turn. A provisional-only turn that reaches the maximum duration emits nothing and resets so its timestamp cannot leak into the next turn.

- [ ] **Step 4: Run focused tests, then commit**

Expected: both segmentation tests pass.

```bash
git add CatRobot/Conversation/Domain/UtteranceSegmenter.swift CatRobotTests/Conversation/Domain/UtteranceSegmenterTests.swift CatRobot.xcodeproj
git commit -m "feat: segment continuous speech into turns"
```

### Task 3: Engagement and conversational addressee policy

**Files:**
- Create: `CatRobot/Conversation/Domain/EngagementWindow.swift`
- Create: `CatRobot/Conversation/Domain/AddresseePolicy.swift`
- Test: `CatRobotTests/Conversation/Domain/AddresseePolicyTests.swift`

**Interfaces:**
- Produces: `EngagementWindow.arm(at:)`, `isActive(at:)`, `refresh(afterReplyAt:)`, `clear()`.
- Produces: `AddresseeRoute.wakeOnly`, `.accept(String)`, `.classify(String)`, `.confirmPending(original: String)`, `.ignore` and `AddresseePolicy.route(_:at:engagement:pending:)`.
- Consumes: wake names `ねこ`, `猫ちゃん`, `Cat Robot`, `キャットロボット`; short Japanese yes/no tokens.

- [ ] **Step 1: Write failing policy tests**

```swift
final class AddresseePolicyTests: XCTestCase {
    func testWakeNameAcceptsAndStripsOnlyLeadingAddress() {
        let result = AddresseePolicy().route("猫ちゃん、今日どう？", at: 0, engagement: .inactive, pending: nil)
        XCTAssertEqual(result, .accept("今日どう？"))
    }

    func testEngagedTurnSkipsClassifierButHardExpiryDoesNotExtend() {
        var engagement = EngagementWindow()
        engagement.arm(at: 0)
        engagement.refresh(afterReplyAt: 290)
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 299, engagement: engagement, pending: nil), .accept("続けて"))
        XCTAssertEqual(AddresseePolicy().route("続けて", at: 301, engagement: engagement, pending: nil), .classify("続けて"))
    }

    func testAffirmativeUsesPendingOriginalAndNegativeDropsIt() {
        let pending = PendingClarification(utterance: "明日の予定は？", expiresAt: 15)
        XCTAssertEqual(AddresseePolicy().route("うん", at: 2, engagement: .inactive, pending: pending), .accept("明日の予定は？"))
        XCTAssertEqual(AddresseePolicy().route("違う", at: 2, engagement: .inactive, pending: pending), .ignore)
    }
}
```

- [ ] **Step 2: Run the test and observe missing-type failure**

Use `-only-testing:CatRobotTests/AddresseePolicyTests`.

- [ ] **Step 3: Implement policy and expiry state**

`EngagementWindow` stores immutable arm time and mutable soft expiry. `refresh` never changes hard expiry. `PendingClarification` stores one trimmed utterance and expiry. Empty/filler speech routes to `.ignore`; expired pending state falls through to normal routing. A standalone wake name routes to `.wakeOnly` so integration can acknowledge it locally without an empty model prompt. A separator after any wake name is authoritative. When Japanese ASR supplies no separator, accept only if the remainder begins with one of: `今日`, `今`, `明日`, `どう`, `何`, `なに`, `いつ`, `どこ`, `誰`, `だれ`, `なぜ`, `なんで`, `元気`, `教えて`, `聞いて`, `お願い`, `おはよう`, `こんにちは`, `こんばんは`; otherwise preserve the original and classify it.

- [ ] **Step 4: Run all domain tests and commit**

Run: `xcodebuild test ... -only-testing:CatRobotTests/ConversationTypesTests -only-testing:CatRobotTests/UtteranceSegmenterTests -only-testing:CatRobotTests/AddresseePolicyTests`

Expected: all domain tests pass.

```bash
git add CatRobot/Conversation/Domain CatRobotTests/Conversation/Domain CatRobot.xcodeproj
git commit -m "feat: add fast conversational address routing"
```

### Task 3.1: Represent speech-synthesis failure

**Files:**
- Modify: `CatRobot/Conversation/Domain/ConversationTypes.swift`
- Modify: `CatRobotTests/Conversation/Domain/ConversationTypesTests.swift`

**Interfaces:**
- Adds one recovery-facing error, `ConversationServiceError.speechSynthesisFailed`.
- Both an adapter failure and a rejected overlapping `speak` call map to this one MVP error; the adapter may distinguish the internal cause without expanding the public recovery surface.

- [ ] **Step 1: Write a failing contract test**

Verify that `ConversationPhase.failed(.speechSynthesisFailed)` can retain and compare the synthesis cause.

- [ ] **Step 2: Prove the case is absent, then add only the enum case**

Run only `CatRobotTests/ConversationTypesTests`; expect a missing-member compilation failure before implementation and a passing focused suite afterward.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-08-13-conversation-domain.md CatRobot/Conversation/Domain/ConversationTypes.swift CatRobotTests/Conversation/Domain/ConversationTypesTests.swift
git commit -m "fix: represent speech synthesis failures"
```

### Task 3.2: Preserve wake-only and undelimited Japanese fast paths

**Files:**
- Modify: `CatRobot/Conversation/Domain/AddresseePolicy.swift`
- Modify: `CatRobotTests/Conversation/Domain/AddresseePolicyTests.swift`
- Modify: `docs/superpowers/specs/2026-08-12-cat-robot-mvp-design.md`
- Modify: `docs/superpowers/plans/2026-08-13-app-integration.md`

**Interfaces:**
- Adds `AddresseeRoute.wakeOnly` for a recognized wake name with no remaining content.
- Keeps clear separator-delimited wake names on the fast path and permits only the documented starter allowlist when Japanese ASR omits the separator.

- [ ] **Step 1: Write focused failing tests**

Cover every wake name as `.wakeOnly`, every wake name followed without a separator by `今日どう？` as `.accept("今日どう？")`, and retain collision tests that classify the full original utterance.

- [ ] **Step 2: Implement the bounded fast path**

Return `.wakeOnly` rather than `.ignore` for a wake-only utterance. Do not broaden raw prefix matching: an immediate Latin letter/digit remains a collision, and an undelimited non-starter remainder falls through to classification.

- [ ] **Step 3: Verify and commit**

Run the focused addressee suite and all three domain suites.

```bash
git add CatRobot/Conversation/Domain/AddresseePolicy.swift CatRobotTests/Conversation/Domain/AddresseePolicyTests.swift docs/superpowers/specs/2026-08-12-cat-robot-mvp-design.md docs/superpowers/plans/2026-08-13-conversation-domain.md docs/superpowers/plans/2026-08-13-app-integration.md
git commit -m "fix: preserve explicit wake fast paths"
```

### Task 4: Branch verification and integration

- [ ] Run `ruby scripts/generate_project.rb`.
- [ ] Run the full simulator suite: `xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`.
- [ ] Confirm `git diff --check` and `git status --short` show no unintended files.
- [ ] Commit any generator-only project update as `build: register conversation domain files`.
- [ ] From main, run `git merge --squash feature/conversation-domain`, commit `feat: add conversation domain`, push `main`, then push `feature/conversation-domain` without deleting it.
