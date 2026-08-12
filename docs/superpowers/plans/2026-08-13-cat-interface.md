# Cat Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an accessible iOS 26 landscape interface whose original SwiftUI-vector cat visibly listens, thinks, clarifies, and speaks over a dark StandBy-like canvas.

**Architecture:** Views consume immutable `ConversationViewState` plus action closures, so this branch compiles with preview data and contains no microphone/model orchestration. `CatFaceView` uses normalized paths and independently animatable layers traced from the generated reference; only a development preview may show the raster overlay.

**Tech Stack:** SwiftUI, Swift 6, iOS 26 Liquid Glass, XCTest, generated reference `docs/design/cat-character-reference-v1.png`.

## Global Constraints

- Work in `feature/cat-interface`, branched from main after `conversation-domain`, inside `.worktrees/feature-cat-interface`.
- Use semantic black (`Color(uiColor: .systemBackground)` with forced dark scheme) and semantic foreground colors; do not hard-code a bright white-on-black flashing design.
- Use Regular Liquid Glass only for the lower functional control group. Do not put glass on the cat, captions, transcript, or background.
- Both landscape rotations, status bar visible, safe areas honored, controls at least 44×44 points.
- Dynamic Type, VoiceOver, Reduce Motion, Reduce Transparency, and Increase Contrast remain understandable without animation or color.
- Production UI is code-drawn. The raster reference is copied only to a development asset catalog and excluded from Release.
- Do not add snapshot libraries, third-party dependencies, service implementations, or model validation UI.
- Integrate with `git merge --squash`; push and retain `feature/cat-interface`.

## UI contract

```swift
enum CatVisualState: Equatable, Sendable { case idle, listening, thinking, clarifying, speaking, failed }
enum MouthPose: Equatable, Sendable { case closed, small, medium, wide }
enum ConversationRecoveryAction: Equatable, Sendable { case retry, openSettings, showTypedInput }
struct ConversationRecovery: Equatable, Sendable {
    var title: String
    var action: ConversationRecoveryAction
}

struct ConversationViewState: Equatable, Sendable {
    var phase: ConversationPhase
    var catState: CatVisualState
    var mouthPose: MouthPose
    var microphoneStatus: String
    var activityStatus: String
    var provisionalTranscript: String
    var caption: String
    var typedText: String
    var showsTypedInput: Bool
    var errorMessage: String?
    var recoveries: [ConversationRecovery]
}

struct ConversationActions {
    var toggleListening: () -> Void
    var showTypedInput: () -> Void
    var updateTypedText: (String) -> Void
    var sendTypedText: () -> Void
    var performRecovery: (ConversationRecoveryAction) -> Void
}
```

---

### Task 1: Presentation state and onboarding disclosure

**Files:**
- Create: `CatRobot/Conversation/UI/ConversationViewState.swift`
- Create: `CatRobot/Conversation/UI/OnboardingView.swift`
- Test: `CatRobotTests/Conversation/UI/ConversationViewStateTests.swift`

**Interfaces:**
- Produces: the UI contract above and `OnboardingView(onStart:)`.
- Consumes: `ConversationPhase` from the domain branch.

- [ ] **Step 1: Write failing presentation tests**

```swift
final class ConversationViewStateTests: XCTestCase {
    func testListeningCopySeparatesMicrophoneFromAssistantActivity() {
        let state = ConversationViewState.listening
        XCTAssertEqual(state.microphoneStatus, "端末上で聞き取り中")
        XCTAssertEqual(state.activityStatus, "話しかけてください")
    }

    func testSpeakingStillReportsCaptureAsTemporarilyPaused() {
        let state = ConversationViewState.speaking(caption: "こんにちは")
        XCTAssertEqual(state.microphoneStatus, "返事の間は聞き取りを休止")
        XCTAssertEqual(state.activityStatus, "話しています")
    }

    func testFailureCarriesAVisibleNextAction() {
        let state = ConversationViewState.failed(
            message: "準備が必要です",
            recoveries: [.init(title: "もう一度確認", action: .retry)]
        )
        XCTAssertEqual(state.errorMessage, "準備が必要です")
        XCTAssertEqual(state.recoveries.map(\.action), [.retry])
    }
}
```

- [ ] **Step 2: Regenerate and run the focused test; expect missing types**

Run: `ruby scripts/generate_project.rb && xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/ConversationViewStateTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO`

- [ ] **Step 3: Implement the state factories and onboarding**

Onboarding copy must say: **AIの猫と話そう**, **音声と会話はこのiPhone上で処理されます**, **マイクは会話画面を開いている間だけ使います**, **AIの返事には間違いが含まれることがあります**, and one prominent **会話を始める** button. Do not trigger permission from `onAppear`; only call `onStart` from the button.

- [ ] **Step 4: Run focused tests and commit**

```bash
git add CatRobot/Conversation/UI CatRobotTests/Conversation/UI CatRobot.xcodeproj
git commit -m "feat: add conversation presentation contract"
```

### Task 2: Trace the generated cat into normalized SwiftUI vectors

**Files:**
- Create: `CatRobot/Conversation/UI/CatFaceView.swift`
- Create: `CatRobot/Conversation/UI/CatFaceShapes.swift`
- Create: `CatRobot/Preview Content/Preview Assets.xcassets/CatReference.imageset/Contents.json`
- Copy development-only: `CatRobot/Preview Content/Preview Assets.xcassets/CatReference.imageset/cat-reference.png`
- Modify: `scripts/generate_project.rb`
- Test: `CatRobotTests/Conversation/UI/CatFaceGeometryTests.swift`

**Interfaces:**
- Produces: `CatFaceView(state:mouthPose:reduceMotion:)` and internal normalized shapes for head, ears, eyes, muzzle, nose, mouth, and whiskers.
- Consumes: `CatVisualState`, `MouthPose`, generated 1672×941 reference.

- [ ] **Step 1: Write failing normalized-geometry tests**

```swift
final class CatFaceGeometryTests: XCTestCase {
    func testLandmarksStayInsideNormalizedCanvas() {
        for point in CatFaceGeometry.landmarks {
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
    }

    func testMirroredEyeCentersAreSymmetric() {
        XCTAssertEqual(CatFaceGeometry.leftEye.x + CatFaceGeometry.rightEye.x, 1, accuracy: 0.001)
        XCTAssertEqual(CatFaceGeometry.leftEye.y, CatFaceGeometry.rightEye.y, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run focused tests; expect missing geometry**

- [ ] **Step 3: Implement shapes by tracing at low-opacity in a DEBUG preview**

Use a 1×1 normalized canvas. Define symmetric landmark constants once and mirror the right-hand features. Build layers in this order: head/ears, inner ears/forehead marks, eyes, muzzle, nose, upper/lower mouth, whiskers. Add a `#Preview("Trace comparison")` with:

```swift
ZStack {
    Image("CatReference").resizable().scaledToFit().opacity(0.28)
    CatFaceView(state: .speaking, mouthPose: .medium, reduceMotion: true).opacity(0.72)
}
```

Copy the reference from `docs/design/cat-character-reference-v1.png`. Update the generator to add Preview Assets only to Debug resources and set `DEVELOPMENT_ASSET_PATHS = "CatRobot/Preview Content"`; assert the Release resource phase does not contain `CatReference`. Do not add the PNG to normal Assets.

- [ ] **Step 4: Add restrained state animation**

Listening adjusts pupils/ears slightly; thinking uses a slow blink; speaking changes only mouth pose. With Reduce Motion, disable ear/blink interpolation and crossfade mouth poses. Mark the whole artwork `.accessibilityHidden(true)`; the surrounding view exposes the textual assistant state.

- [ ] **Step 5: Run focused tests, build Debug and Release, then commit**

Run geometry tests and `xcodebuild build` for Debug and Release simulator configurations. Expected: both build; Release contains no `cat-reference.png` under `.app`.

```bash
git add CatRobot/Conversation/UI CatRobotTests/Conversation/UI 'CatRobot/Preview Content' scripts/generate_project.rb CatRobot.xcodeproj
git commit -m "feat: draw animated vector cat"
```

### Task 3: Landscape conversation controls and typed fallback

**Files:**
- Create: `CatRobot/Conversation/UI/ConversationView.swift`
- Create: `CatRobot/Conversation/UI/ListeningControl.swift`
- Create: `CatRobot/Conversation/UI/TypedInputView.swift`
- Test: `CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift`

**Interfaces:**
- Produces: `ConversationView(state:actions:)`.
- Consumes: immutable UI state and callbacks only.

- [ ] **Step 1: Write failing label-model tests**

```swift
final class ConversationAccessibilityTests: XCTestCase {
    func testPausedControlHasExplicitLabelAndValue() {
        let labels = ConversationAccessibility(phase: .paused)
        XCTAssertEqual(labels.listeningAction, "聞き取りを再開")
        XCTAssertEqual(labels.microphoneValue, "一時停止中")
    }

    func testClarificationIsAvailableWithoutMotion() {
        let labels = ConversationAccessibility(phase: .clarifying)
        XCTAssertEqual(labels.assistantStatus, "聞き返しています")
    }
}
```

- [ ] **Step 2: Run tests and observe missing presentation helper**

- [ ] **Step 3: Implement the landscape composition**

Use `ViewThatFits(in: .horizontal)` for side-by-side versus stacked accessibility-size layout. Keep caption width near 520 points, let it wrap, display provisional transcript separately, and render `errorMessage` together with every button in `recoveries`; invoke `performRecovery` with the selected value. Put pause/resume, keyboard, and send controls in one lower `GlassEffectContainer`; use `.buttonStyle(.glass)` and `.glassProminent` only for the primary action. Minimum frames are 44 points.

- [ ] **Step 4: Implement typed input and accessibility**

Use `TextField(axis: .vertical)` with Japanese prompt **文字で話しかける**, return-key/send action, focus management, and a dismissible sheet or inset panel. Add explicit accessibility labels/values; never announce provisional transcript changes.

- [ ] **Step 5: Build, run all UI tests, and commit**

```bash
git add CatRobot/Conversation/UI CatRobotTests/Conversation/UI CatRobot.xcodeproj
git commit -m "feat: build landscape cat conversation interface"
```

### Task 4: Branch verification and integration

- [ ] Run all tests on the iOS 26.5 simulator.
- [ ] Build with `-configuration Release` and confirm the generated reference is absent from the app bundle with a filename search only; do not add checksums.
- [ ] Inspect both landscape orientations, an accessibility Dynamic Type preview, Reduce Motion, and Reduce Transparency.
- [ ] Run `git diff --check`; keep only intended files.
- [ ] Squash into main as `feat: add animated cat interface`, push main, then push and retain `feature/cat-interface`.
