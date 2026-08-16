# Cat Mouth Expression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the frightening center seam from the cat's cream muzzle and make even a one-word spoken reply visibly animate its mouth.

**Architecture:** Replace the two mirrored, independently stroked muzzle layers with one symmetric closed contour. Centralize the delegate-driven mouth-pose order in a small value type used by both voice and typed speech loops; keep all speech, lifecycle, and audio behavior otherwise unchanged.

**Tech Stack:** Swift 6.3, SwiftUI, XCTest, AVSpeechSynthesizer lifecycle events, Xcode 26.6, iOS 26.5 SDK, physical iPhone 16 Pro on iOS 26.6.

## Global Constraints

- Work only on `feature/cat-mouth-expression` in `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-cat-mouth-expression`.
- Keep the implementation on-device and dependency-free.
- Keep speech animation driven by existing speech lifecycle events; do not add timers, audio amplitude analysis, phoneme synchronization, or audio taps.
- Keep `.started = .small`; cycle `willSpeak` as `.wide`, `.medium`, `.small` for voice and typed replies.
- Use mouth openings `0.025`, `0.055`, and `0.090`; keep wide below `0.095` and inside the muzzle.
- Finish, cancellation, pause, scene inactivity, and failure must still close the mouth.
- Preserve the existing Reduce Motion crossfade and all non-mouth character geometry.
- Validate the final visual and short-reply motion on the connected iPhone 16 Pro before merging.

---

### Task 1: Unified muzzle geometry

**Files:**
- Modify: `CatRobot/Conversation/UI/CatFaceShapes.swift`
- Modify: `CatRobot/Conversation/UI/CatFaceView.swift`
- Test: `CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift`

**Interfaces:**
- Consumes: `NormalizedPath.symmetricClosed(leftHalf:lowerControl:)` and `CatFaceGeometry.mouthHinge`.
- Produces: `CatFaceGeometry.muzzle: NormalizedPath`, `CatMuzzleShape` without a side parameter, and the approved mouth-opening constants.

- [ ] **Step 1: Write the failing geometry tests**

Add tests that require a single closed contour and the approved visible openings:

```swift
func testMuzzleUsesOneClosedContourWithoutASeparateCenterSeam() {
    let commands = CatFaceGeometry.muzzle.commands
    let moveCount = commands.reduce(into: 0) { count, command in
        if case .move = command { count += 1 }
    }
    let closeCount = commands.reduce(into: 0) { count, command in
        if case .close = command { count += 1 }
    }

    XCTAssertEqual(moveCount, 1)
    XCTAssertEqual(closeCount, 1)
    XCTAssertFalse(commands.contains { command in
        guard case let .line(point) = command else { return false }
        return abs(point.x - 0.5) < 0.0001 && point.y > CatFaceGeometry.mouthHinge.y
    })
}

func testMouthOpeningsAreVisibleAndStayInsideApprovedWideLimit() {
    XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .small), 0.025, accuracy: 0.0001)
    XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .medium), 0.055, accuracy: 0.0001)
    XCTAssertEqual(CatFaceGeometry.mouthOpening(for: .wide), 0.090, accuracy: 0.0001)
    XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .wide), 0.095)
}
```

- [ ] **Step 2: Run the geometry tests and confirm RED**

Run:

```bash
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=7DEC705D-D2E8-4783-93FE-D4B7B95FF8B7' \
  -derivedDataPath .build/cat-mouth-task1 \
  -only-testing:CatRobotTests/CatFaceGeometryTests
```

Expected: compilation fails because `CatFaceGeometry.muzzle` does not exist, or the opening-value assertions fail against `0.018 / 0.040 / 0.070`.

- [ ] **Step 3: Implement one exterior muzzle contour and larger openings**

Replace `leftMuzzle` with this unified symmetric contour:

```swift
static let muzzle = NormalizedPath.symmetricClosed(leftHalf: [
    .move(0.491, 0.830),
    .curve(0.412, 0.793, 0.377, 0.727, 0.394, 0.662),
    .curve(0.411, 0.600, 0.463, 0.587, 0.500, 0.615),
], lowerControl: CGPoint(x: 0.497, y: 0.840))
```

Change `mouthOpening(for:)` to return `0.025`, `0.055`, and `0.090` for small, medium, and wide. Include `muzzle` once in `landmarksAndControlPoints`. Make `CatMuzzleShape` render `CatFaceGeometry.muzzle` without `CatFaceSide`, then replace the two-layer `ForEach` in `CatFaceView` with one fill-and-stroke layer:

```swift
CatMuzzleShape()
    .fill(Palette.cream)
    .stroke(Palette.outline, lineWidth: outline * 0.75)
```

Keep `mouthStem` from nose bottom to `mouthHinge`; do not add another center path.

- [ ] **Step 4: Run the geometry tests and confirm GREEN**

Run the Step 2 command. Expected: `CatFaceGeometryTests` passes with zero failures.

- [ ] **Step 5: Commit the geometry change**

```bash
git add CatRobot/Conversation/UI/CatFaceShapes.swift \
  CatRobot/Conversation/UI/CatFaceView.swift \
  CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift
git commit -m "fix: unify the cat muzzle outline"
```

### Task 2: Visible first-word speech pose

**Files:**
- Modify: `CatRobot/Conversation/UI/ConversationViewState.swift`
- Modify: `CatRobot/Conversation/Integration/ConversationViewModel.swift`
- Test: `CatRobotTests/Conversation/UI/ConversationViewStateTests.swift`
- Test: `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`
- Test: `CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift`

**Interfaces:**
- Consumes: `MouthPose` and the existing `.started`, `.willSpeak`, `.finished`, and `.cancelled` speech events.
- Produces: `SpeechMouthPoseSequence.nextWordPose() -> MouthPose`, shared by both speech loops.

- [ ] **Step 1: Write failing sequence and integration tests**

Add the pure sequence test:

```swift
func testSpeechMouthSequenceOpensWideOnFirstWordAndCyclesWithoutRepeatingStart() {
    var sequence = SpeechMouthPoseSequence()
    XCTAssertEqual(sequence.nextWordPose(), .wide)
    XCTAssertEqual(sequence.nextWordPose(), .medium)
    XCTAssertEqual(sequence.nextWordPose(), .small)
    XCTAssertEqual(sequence.nextWordPose(), .wide)
}
```

Add a manual-speaker voice test to `ConversationViewModelTests`:

```swift
func testShortVoiceReplyOpensWideOnFirstWordAndClosesAfterFinish() async {
    let harness = ConversationHarness(speakerAutomaticallyFinishes: false)
    await harness.sut.startConversation()
    let turn = Task { await harness.emitCompletedUtterance("猫ちゃん", at: 0) }
    await harness.speaker.waitUntilTextCount(1)

    await harness.speaker.yield(.started)
    let didShowSmall = await harness.waitUntil {
        harness.sut.viewState.mouthPose == .small
    }
    XCTAssertTrue(didShowSmall)
    await harness.speaker.yield(.willSpeak(range: 0..<3))
    let didShowWide = await harness.waitUntil {
        harness.sut.viewState.mouthPose == .wide
    }
    XCTAssertTrue(didShowWide)
    await harness.speaker.yield(.finished)
    await harness.speaker.finish()
    await turn.value

    XCTAssertEqual(harness.sut.viewState.mouthPose, .closed)
}
```

Add the typed equivalent to `ConversationRecoveryTests`:

```swift
func testShortTypedReplyOpensWideOnFirstWordAndClosesAfterFinish() async {
    let harness = ConversationHarness(
        microphoneAllowed: false,
        speakerAutomaticallyFinishes: false
    )
    await harness.sut.startConversation()
    let turn = Task { await harness.sut.submitTypedText("こんにちは") }
    await harness.speaker.waitUntilTextCount(1)

    await harness.speaker.yield(.started)
    let didShowSmall = await harness.waitUntil {
        harness.sut.viewState.mouthPose == .small
    }
    XCTAssertTrue(didShowSmall)
    await harness.speaker.yield(.willSpeak(range: 0..<5))
    let didShowWide = await harness.waitUntil {
        harness.sut.viewState.mouthPose == .wide
    }
    XCTAssertTrue(didShowWide)
    await harness.speaker.yield(.finished)
    await harness.speaker.finish()
    await turn.value

    XCTAssertEqual(harness.sut.viewState.mouthPose, .closed)
}
```

- [ ] **Step 2: Run the new motion tests and confirm RED**

Run:

```bash
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=7DEC705D-D2E8-4783-93FE-D4B7B95FF8B7' \
  -derivedDataPath .build/cat-mouth-task2 \
  -only-testing:CatRobotTests/ConversationViewStateTests \
  -only-testing:CatRobotTests/ConversationViewModelTests/testShortVoiceReplyOpensWideOnFirstWordAndClosesAfterFinish \
  -only-testing:CatRobotTests/ConversationRecoveryTests/testShortTypedReplyOpensWideOnFirstWordAndClosesAfterFinish
```

Expected: compilation fails because `SpeechMouthPoseSequence` does not exist, or the first `willSpeak` assertions receive `.small`.

- [ ] **Step 3: Implement and share the deterministic sequence**

Add this value type beside `MouthPose` in `ConversationViewState.swift`:

```swift
struct SpeechMouthPoseSequence {
    private static let wordPoses: [MouthPose] = [.wide, .medium, .small]
    private var wordIndex = 0

    mutating func nextWordPose() -> MouthPose {
        defer { wordIndex += 1 }
        return Self.wordPoses[wordIndex % Self.wordPoses.count]
    }
}
```

In both `speakTypedReply` and `speakAndResume`, replace `mouthIndex` and the local `[.small, .medium, .wide]` array with `var mouthSequence = SpeechMouthPoseSequence()` and:

```swift
case .started:
    viewState.mouthPose = .small
case .willSpeak:
    viewState.mouthPose = mouthSequence.nextWordPose()
```

Keep the voice latency calls and `.finished = .closed` behavior exactly where they are.

- [ ] **Step 4: Run the motion tests and confirm GREEN**

Run the Step 2 command. Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Run related lifecycle tests**

Run:

```bash
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=7DEC705D-D2E8-4783-93FE-D4B7B95FF8B7' \
  -derivedDataPath .build/cat-mouth-task2 \
  -only-testing:CatRobotTests/ConversationViewModelTests \
  -only-testing:CatRobotTests/ConversationRecoveryTests \
  -only-testing:CatRobotTests/ConversationViewStateTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Commit the motion change**

```bash
git add CatRobot/Conversation/UI/ConversationViewState.swift \
  CatRobot/Conversation/Integration/ConversationViewModel.swift \
  CatRobotTests/Conversation/UI/ConversationViewStateTests.swift \
  CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift \
  CatRobotTests/Conversation/Integration/ConversationRecoveryTests.swift
git commit -m "fix: make short replies visibly move the mouth"
```

### Task 3: Full and physical-device verification

**Files:**
- Verify only: all feature changes and the connected physical device.

**Interfaces:**
- Consumes: the completed geometry and pose sequence from Tasks 1 and 2.
- Produces: test, signed-build, installation, launch, screenshot, and human-observation evidence for PR review.

- [ ] **Step 1: Run the complete simulator suite**

```bash
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=7DEC705D-D2E8-4783-93FE-D4B7B95FF8B7' \
  -derivedDataPath .build/cat-mouth-final
```

Expected: all 234 or more tests pass with zero failures.

- [ ] **Step 2: Build and sign for the connected iPhone 16 Pro**

```bash
xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-000610311A90801C' \
  -derivedDataPath .build/cat-mouth-device \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration
```

Expected: `** BUILD SUCCEEDED **` for `iPhone17,1` using bundle identifier `com.kamby.CatRobot`.

- [ ] **Step 3: Install and launch the signed app**

```bash
xcrun devicectl device install app \
  --device 59199D1B-26D5-5063-8A43-BE38E8008EAD \
  .build/cat-mouth-device/Build/Products/Debug-iphoneos/CatRobot.app

xcrun devicectl device process launch \
  --device 59199D1B-26D5-5063-8A43-BE38E8008EAD \
  --terminate-existing com.kamby.CatRobot
```

Expected: install and launch both succeed.

- [ ] **Step 4: Re-run the short-reply visual smoke**

On the landscape conversation screen, say `猫ちゃん`. Confirm on the physical display and with Xcode device screenshots that:

- the cream muzzle has one uninterrupted fill and exterior outline with no black center seam below the short nose stem;
- `なあに？` is captioned and audible;
- the mouth visibly changes `small -> wide -> closed` during the short reply;
- the mouth stays inside the muzzle and automatic listening resume still works.

- [ ] **Step 5: Review and integrate without deleting the branch**

Request an independent read-only review, address only Critical or Important findings, push `feature/cat-mouth-expression`, open a PR into `main`, and squash-merge it with branch deletion disabled. Confirm the remote feature branch remains available after merge.
