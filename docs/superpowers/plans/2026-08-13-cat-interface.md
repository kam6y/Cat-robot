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
        for point in CatFaceGeometry.landmarksAndControlPoints {
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
    }

    func testCanonicalCanvasMatchesTheFullReferenceRaster() {
        XCTAssertEqual(CatFaceGeometry.aspectRatio, 1672.0 / 941.0, accuracy: 0.0001)
    }

    func testMirroredFeaturePairsAreSymmetric() {
        for pair in CatFaceGeometry.mirroredFeaturePairs {
            XCTAssertEqual(pair.left.x + pair.right.x, 1, accuracy: 0.001)
            XCTAssertEqual(pair.left.y, pair.right.y, accuracy: 0.001)
        }
    }

    func testMouthOpeningIncreasesAcrossSpeakingPoses() {
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .closed),
                          CatFaceGeometry.mouthOpening(for: .small))
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .small),
                          CatFaceGeometry.mouthOpening(for: .medium))
        XCTAssertLessThan(CatFaceGeometry.mouthOpening(for: .medium),
                          CatFaceGeometry.mouthOpening(for: .wide))
    }
}
```

- [ ] **Step 2: Run focused tests; expect missing geometry**

- [ ] **Step 3: Implement shapes by tracing at low-opacity in a DEBUG preview**

Use normalized coordinates over the **full 1672×941 raster**, preserving its `1.7768` aspect ratio so a direct `scaledToFit` overlay aligns. The cat occupies approximately `x: 0.238...0.766`, `y: 0.062...0.967`, centered at `x = 0.5`. Define each left-hand landmark once and mirror right-hand features with `x -> 1 - x`. Include every anchor and Bézier control point in `landmarksAndControlPoints`, and include eyes, ear tips, and whisker endpoints in `mirroredFeaturePairs`.

Use these low-node landmarks instead of tracing every fur pixel:

- Eye centers: `(0.404, 0.515)` and `(0.596, 0.515)`; iris radii about `(0.032, 0.075)`, pupil radii about `(0.018, 0.060)`.
- Muzzle centers: `(0.450, 0.700)` and `(0.550, 0.700)`; nose center `(0.500, 0.625)`; mouth hinge `(0.500, 0.688)`.
- Left inner ear: `M(0.289,0.377) C(0.271,0.290 0.259,0.122 0.278,0.102) C(0.306,0.073 0.363,0.198 0.367,0.263)`, then return with no more than two shallow fur notches; mirror it.
- Left sclera: `M(0.340,0.497) C(0.358,0.451 0.382,0.435 0.409,0.439) C(0.434,0.443 0.449,0.486 0.451,0.570) C(0.430,0.592 0.399,0.605 0.374,0.589) C(0.351,0.574 0.341,0.535 0.340,0.497) Z`; mirror it.
- Left muzzle: `M(0.500,0.615) C(0.463,0.587 0.411,0.600 0.394,0.662) C(0.377,0.727 0.412,0.793 0.491,0.830) C(0.507,0.812 0.502,0.702 0.500,0.615) Z`; mirror it.
- Nose: `M(0.500,0.592) C(0.532,0.592 0.538,0.611 0.524,0.632) C(0.515,0.646 0.505,0.663 0.500,0.663) C(0.495,0.663 0.485,0.646 0.476,0.632) C(0.462,0.611 0.468,0.592 0.500,0.592) Z`.
- Left whiskers: `M(0.234,0.628) C(0.289,0.596 0.347,0.605 0.388,0.638)`, `M(0.242,0.702) C(0.290,0.666 0.344,0.642 0.393,0.657)`, and `M(0.269,0.766) C(0.306,0.724 0.355,0.689 0.400,0.684)`; mirror with round caps and joins.

Keep the outer contour similarly low-node and symmetric: start near `(0.353,0.921)`, pass through left cheek/head `(0.373,0.799)`, `(0.253,0.669)`, `(0.269,0.570)`, `(0.287,0.398)`, left ear tip `(0.273,0.071)`, and forehead `(0.417,0.219)`, then mirror across `x = 0.5` and close near `(0.647,0.921)`. Build layers in this order: outer head/ears, inner ears/forehead marks, sclera/iris/pupil/highlight/lid, muzzle, nose, mouth/tongue/fangs, and whiskers. Use restrained solid colors derived from the reference: dark charcoal fur (`#202123`), warm cream (`#FFF0D8`, not pure white), amber iris (`#C78A3D`), teal marks (`#4FA5A3`), muted salmon (`#BE766E`/`#C97970`), and near-black outlines. Do not recreate gradients, textures, or every tuft for this MVP.

Mouth openings are normalized `0`, `0.018`, `0.040`, and `0.070` for closed/small/medium/wide. Closed renders stem and smile only; small uses a restrained cavity, while medium/wide add a muted tongue and tiny fangs. Add a `#if DEBUG`-guarded `#Preview("Trace comparison")` with:

```swift
ZStack {
    Image("CatReference").resizable().scaledToFit().opacity(0.28)
    CatFaceView(state: .speaking, mouthPose: .medium, reduceMotion: true).opacity(0.72)
}
```

Copy the reference from `docs/design/cat-character-reference-v1.png`. A PBX resources phase is target-wide rather than configuration-specific: add `Preview Assets.xcassets` once to app resources, set `DEVELOPMENT_ASSET_PATHS = ["CatRobot/Preview Content"]` for both configurations, and additionally set Release `EXCLUDED_SOURCE_FILE_NAMES = ["$(inherited)", "Preview Assets.xcassets"]`. Do not add the PNG directly or put it in normal Assets. The `#if DEBUG` preview must be the only source reference to `CatReference`.

- [ ] **Step 4: Add restrained state animation**

Listening makes one restrained pupil/inner-ear adjustment of about `0.004...0.006` normalized units; thinking uses a sparse slow blink rather than a pulse; speaking changes only mouth pose. Do not rotate part of a combined head silhouette; rotate outer ears only if they are separately drawable. With Reduce Motion, disable attention/blink interpolation and crossfade fixed mouth-pose layers in about `0.10...0.12` seconds rather than morphing geometry. Mark the whole artwork `.accessibilityHidden(true)`; the surrounding view exposes the textual assistant state. Respect Increase Contrast with a stronger outline, not a color-only state cue; avoid `Canvas`/`drawingGroup()` unless a measured need appears.

- [ ] **Step 5: Run focused tests, build Debug and Release, then commit**

Run geometry tests and Debug and Release simulator builds, using fresh derived data for Release. Expected: both build. Keep a filename search and require no `cat-reference.png`/`CatReference` file below the Release `.app`. Because asset catalogs compile into `Assets.car`, also inspect rendition metadata—without checksums—and require no `CatReference` match:

```bash
RELEASE_APP=.build/CatInterfaceRelease/Build/Products/Release-iphonesimulator/CatRobot.app
find "$RELEASE_APP" -iname '*cat-reference*' -o -iname '*CatReference*'
if /usr/bin/assetutil --info "$RELEASE_APP/Assets.car" | rg -q '"Name" : "CatReference"'; then
  echo 'CatReference shipped in Release' >&2
  exit 1
fi
```

Also confirm the fresh Release build log does not list `Preview Assets.xcassets` as an `actool` input. A filename search alone cannot inspect a compiled asset catalog; do not add a checksum.

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
- [ ] Build with `-configuration Release` into fresh DerivedData and confirm the generated reference is absent using both the filename search and the `assetutil --info` rendition-name check from Task 2; do not add checksums.
- [ ] Inspect both landscape orientations, an accessibility Dynamic Type preview, Reduce Motion, and Reduce Transparency.
- [ ] Run `git diff --check`; keep only intended files.
- [ ] Squash into main as `feat: add animated cat interface`, push main, then push and retain `feature/cat-interface`.
