# Cat Robot Gemma 4 Foundation Models PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The user-approved review budget in this plan overrides any skill default that would continue review/fix loops until clean.

**Goal:** Run Gemma 4 E2B as Cat Robot's reply and vision backend through the iOS 27 Foundation Models API while retaining the Apple content-tagging address classifier, adding bounded context compaction and explicit local memory, and proving the PoC on the connected iPhone 16 Pro.

**Architecture:** Keep the existing sequential address-classification flow and replace only reply generation with Google's official `LiteRTLMFoundationModels` adapter. A model store verifies the pinned artifact once, a stateful reply actor owns Foundation Models transcripts and compaction, and a separate local memory actor persists only explicit facts. Physical-device probes use the same `LanguageModelSession` path as the app and have hard run limits.

**Tech Stack:** Swift 6.0 strict concurrency, SwiftUI, iOS 27, Xcode 27, Apple Foundation Models, Google LiteRT-LM `0.16.0`, XCTest, Ruby `xcodeproj 1.27.0`.

**Spec:** `PLAN.md` is the approved PoC specification and execution plan. The acceptance criteria and validation budgets below are normative.

## Baseline and workspace

- Worktree: `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-foundationmodels-poc`
- Branch: `feature/gemma4-foundationmodels-poc`
- Base: local `main` at `d3db63e5e4770d17fb4180e0d4a5baac56d4d051`
- Existing comparison branch is read-only reference: `feature/gemma4-e2b-comparison`
- `ruby scripts/test_generate_project.rb`: PASS on 2026-08-24.
- Xcode 27 compiled the existing app and tests for iOS 27 Simulator. Two automation attempts produced incomplete `.xcresult` bundles, so test completion was not claimed and no further retry was made. At implementation start, run one fresh baseline test with a new result bundle. If it is again incomplete, record that blocker without an unchanged rerun.

## Global constraints

- Use `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`; do not change global `xcode-select`.
- Raise the deployment target to iOS 27.0 and the project upgrade marker to Xcode 27.
- Use local `main` base only. Do not fetch, pull, push, open a PR, or merge.
- Do not checkout, merge, rebase, cherry-pick, or edit `feature/gemma4-e2b-comparison`; inspect it only with `git show` and `git diff`.
- Pin `https://github.com/google-ai-edge/LiteRT-LM` to exact `0.16.0` and link product `LiteRTLMFoundationModels`.
- Use `LiteRTLanguageModel` through Apple `LanguageModelSession`; LiteRT direct generation is diagnostic-only and cannot satisfy reply or vision acceptance.
- Keep `FoundationModelAddressClassifier` backed by `SystemLanguageModel(useCase: .contentTagging)` and keep classifier then reply execution sequential.
- Do not add app-level thinking/reasoning configuration, UI, transcript storage, or output stripping.
- Normal reply cap is 256 output tokens. Explicit detailed requests and image replies use 512.
- Normal style is conclusion-first and one to three sentences; detail expands only when requested.
- Persist only explicit memory commands. Do not infer facts from ordinary utterances or summaries.
- Use a 20% context reserve: `operationalContextBudget = floor(validatedContextCapacity * 0.8)`.
- Model context calibration is capped at 14 full-model runs. Vision validation is capped at 8 inference runs.
- Formal whole-diff review/fix/revalidate is capped at two rounds. A clean first round ends review.
- Do not repeat full SHA, full build, full test suite, device sweep, or context sweep when inputs and binaries are unchanged.
- Do not implement production download orchestration, cloud memory, embeddings, unrelated refactors, other models, other LiteRT versions, or a fallback adapter.

## Fixed model artifact

```swift
static let gemma4E2B = GemmaModelDescriptor(
    identifier: "litert-community/gemma-4-E2B-it-litert-lm",
    revision: "6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94",
    fileName: "gemma-4-E2B-it.litertlm",
    remoteURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94/gemma-4-E2B-it.litertlm")!,
    expectedBytes: 2_588_147_712,
    expectedSHA256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
    minimumFreeBytes: 3_200_000_000
)
```

The model is stored under Application Support and excluded from backup. Full SHA-256 runs only after a new download, a pin change, a missing trusted verification record, a size/metadata mismatch, or a concrete load failure. A normal warm launch uses the verification record and file metadata and must not hash 2.6 GB again.

## Authoritative references

- Apple custom model protocol: `https://developer.apple.com/documentation/foundationmodels/languagemodel`
- Apple context management: `https://developer.apple.com/documentation/foundationmodels/managing-the-context-window`
- Google Swift overview: `https://developers.google.com/edge/litert-lm/swift`
- Exact package manifest: `https://github.com/google-ai-edge/LiteRT-LM/blob/v0.16.0/Package.swift`
- Exact Foundation Models adapter: `https://github.com/google-ai-edge/LiteRT-LM/blob/v0.16.0/swift/apple_fm/LiteRTLanguageModel.swift`
- Pinned model card: `https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm`
- Existing local context evidence: `git show feature/gemma4-e2b-comparison:docs/validation/2026-08-23-classifier-context-follow-up.html`

Read these exact references only. Do not replace them with current `main`, a newer release, or a general web survey during implementation.

## Target file map

### Project configuration

- Modify `.gitignore`: ignore `*.litertlm`, partial downloads, model verification records copied outside Application Support, and device evidence exports containing raw prompts.
- Modify `scripts/generate_project.rb`: iOS 27, Xcode 27 marker, exact LiteRT package, `LiteRTLMFoundationModels` product.
- Modify `scripts/test_generate_project.rb`: assert the exact dependency, product, deployment target, marker, and model ignore rules.
- Regenerate `CatRobot.xcodeproj/project.pbxproj` and `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`.
- Create `CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` through package resolution.
- Modify `README.md`: Xcode 27/iOS 27 requirements, model size/download, PoC limitations.

### Domain and integration

- Create `CatRobot/Conversation/Domain/ReplyRequest.swift`: multimodal request and output policy.
- Modify `CatRobot/Conversation/Domain/ConversationServices.swift`: accept `ReplyRequest` and expose explicit Gemma preparation.
- Modify `CatRobot/Conversation/Domain/ConversationTypes.swift`: model-download and memory errors only where UI recovery needs distinct handling.
- Modify `CatRobot/Conversation/Integration/ConversationDependencies.swift`: compose Apple classifier availability plus Gemma reply preparation.
- Modify `CatRobot/Conversation/Integration/ConversationViewModel.swift`: deterministic memory commands and existing cancellation ownership.
- Modify `CatRobot/Conversation/UI/ConversationViewState.swift` and `ConversationView.swift`: bounded model-preparation progress only.

### Gemma backend

- Create `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`.
- Create `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`.
- Create `CatRobot/Conversation/Services/GemmaModelStore.swift`.
- Create `CatRobot/Conversation/Services/GemmaFoundationModelFactory.swift`.
- Create `CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift`.
- Modify `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`: check the Apple content-tagging classifier rather than the replaced Apple general reply model.
- Modify `CatRobot/Conversation/Services/FoundationModelErrorMapper.swift` only for concrete new iOS 27 errors observed during the compile probe.

### Context and memory

- Create `CatRobot/Conversation/Context/ConversationTurn.swift`.
- Create `CatRobot/Conversation/Context/TokenBudgeting.swift`.
- Create `CatRobot/Conversation/Context/ConversationContextController.swift`.
- Create `CatRobot/Conversation/Memory/MemoryFact.swift`.
- Create `CatRobot/Conversation/Memory/MemoryCommandParser.swift`.
- Create `CatRobot/Conversation/Memory/LocalMemoryStore.swift`.

### PoC probes and evidence

- Create `CatRobot/Diagnostics/VisionFixtureFactory.swift`.
- Create `CatRobot/Diagnostics/GemmaVisionDeviceProbe.swift`.
- Create `CatRobot/Diagnostics/GemmaContextCalibrationProbe.swift`.
- Create `CatRobot/Diagnostics/PoCProcessMetrics.swift`.
- Create `CatRobotTests/Diagnostics/GemmaVisionDeviceProbeTests.swift`.
- Create `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`.
- Create `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md` during execution.

### Unit and integration tests

- Create tests mirroring each new service under `CatRobotTests/Conversation/Services`, `Context`, and `Memory`.
- Modify `CatRobotTests/Conversation/Integration/ConversationFakes.swift`.
- Modify `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`.
- Modify `CatRobotTests/Conversation/Integration/AppCompositionTests.swift`.
- Modify existing Foundation Models classifier tests only to assert it remains Apple-backed; do not rewrite the classifier.

---

### Task 1: Establish the iOS 27 and LiteRT package contract

**Files:**
- Modify: `.gitignore`
- Modify: `scripts/generate_project.rb`
- Modify: `scripts/test_generate_project.rb`
- Modify: `README.md`
- Regenerate: `CatRobot.xcodeproj/project.pbxproj`
- Create through SwiftPM: `CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Interfaces:**
- Produces: an iOS 27 app target linking exact `LiteRTLMFoundationModels` 0.16.0.
- Produces: compile-time availability of `LiteRTLanguageModel`, `EngineConfig`, and `Backend`.

- [ ] **Step 1: Capture one fresh baseline before source changes**

Run once:

```bash
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -quiet \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -resultBundlePath /tmp/CatRobotGemmaBaseline.xcresult \
  test
```

Expected: a complete result bundle with the existing suite passing. If the bundle is incomplete again, record the environment blocker and do not unchanged-rerun.

- [ ] **Step 2: Write failing generator assertions**

Update the generator contract to require:

```ruby
LITERT_LM_URL = "https://github.com/google-ai-edge/LiteRT-LM"
LITERT_LM_VERSION = "0.16.0"
LITERT_PRODUCT = "LiteRTLMFoundationModels"
DEPLOYMENT_TARGET = "27.0"
```

Assert exactly one package reference, exact version, the Foundation Models product on the app target, no direct package product on the test target, and `LastUpgradeCheck == "2700"`.

- [ ] **Step 3: Verify the contract fails before implementation**

Run:

```bash
ruby scripts/test_generate_project.rb
```

Expected: FAIL on the first new iOS 27 or LiteRT assertion.

- [ ] **Step 4: Implement the generator changes and model ignore rules**

Link `LiteRTLMFoundationModels`, not only `LiteRTLM`. Add these repository ignores:

```gitignore
*.litertlm
*.litertlm.*.download
*.model-verification.json
device-evidence-private/
```

- [ ] **Step 5: Regenerate and verify determinism**

Run:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

Expected: PASS. Run the generator once more and confirm it introduces no additional project diff.

- [ ] **Step 6: Resolve packages and compile the official adapter API**

Run one package resolution and one build. The first adapter call must compile in app code with this pinned API shape:

```swift
import LiteRTLM
import LiteRTLMFoundationModels

let config = try EngineConfig(
    modelPath: modelPath,
    backend: .gpu,
    visionBackend: .cpu(),
    audioBackend: nil,
    maxNumTokens: contextCapacity,
    cacheDir: cacheDirectory.path
)
let model = LiteRTLanguageModel(engineConfig: config)
let session = LanguageModelSession(model: model)
```

If the exact tag does not provide this API, stop instead of switching dependencies.

- [ ] **Step 7: Commit the project contract**

```bash
git add .gitignore README.md scripts CatRobot.xcodeproj
git commit -m "build: add iOS 27 LiteRT Foundation Models dependency"
```

---

### Task 2: Implement bounded artifact download and one-time integrity verification

**Files:**
- Create: `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`
- Create: `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`
- Create: `CatRobot/Conversation/Services/GemmaModelStore.swift`
- Test: corresponding files under `CatRobotTests/Conversation/Services`

**Interfaces:**
- Produces: `GemmaModelPreparing.prepare(progress:) async throws -> URL`.
- Produces: `GemmaModelVerificationRecord` for warm-launch fast validation.

- [ ] **Step 1: Define the immutable descriptor and verification interfaces**

```swift
struct GemmaModelDescriptor: Equatable, Sendable, Codable {
    let identifier: String
    let revision: String
    let fileName: String
    let remoteURL: URL
    let expectedBytes: Int64
    let expectedSHA256: String
    let minimumFreeBytes: Int64
}

struct GemmaModelVerificationRecord: Equatable, Sendable, Codable {
    let identifier: String
    let revision: String
    let fileName: String
    let byteCount: Int64
    let sha256: String
    let modificationDate: Date
    let verifiedAt: Date
}

struct GemmaModelDownloadProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64?
}

protocol GemmaModelPreparing: Sendable {
    var installedModelURL: URL { get }
    func prepare(progress: (@Sendable (GemmaModelDownloadProgress) -> Void)?) async throws -> URL
}
```

- [ ] **Step 2: Write failing tests for integrity policy**

Cover exactly these cases with small fixtures:

- new download hashes once and atomically installs;
- matching size, modification date, pin tuple, and record returns without hashing;
- missing record hashes once;
- size or metadata mismatch hashes once;
- load-failure invalidation permits one reverify/redownload path;
- cancellation removes only the owned partial file;
- concurrent callers share one preparation task;
- backup exclusion is applied to the installed model directory.

- [ ] **Step 3: Implement streaming SHA and atomic installation**

Use CryptoKit `SHA256` with chunked reads rather than loading 2.6 GB into memory. Download to a UUID partial path, validate bytes and digest, write the verification record, then rename into place.

- [ ] **Step 4: Verify targeted tests**

Run only the model store and integrity test classes. Expected: PASS without network and without the real model.

- [ ] **Step 5: Commit the model store**

```bash
git add CatRobot/Conversation/Services/GemmaModel* CatRobotTests/Conversation/Services/GemmaModel*
git commit -m "feat: add bounded Gemma model store"
```

---

### Task 3: Introduce the multimodal reply contract and output policy

**Files:**
- Create: `CatRobot/Conversation/Domain/ReplyRequest.swift`
- Modify: `CatRobot/Conversation/Domain/ConversationServices.swift`
- Modify: `CatRobotTests/Conversation/Integration/ConversationFakes.swift`
- Test: `CatRobotTests/Conversation/Domain/ReplyRequestTests.swift`

**Interfaces:**
- Produces: one request type for text, optional image, and output cap.
- Preserves: cumulative text snapshot streaming.

- [ ] **Step 1: Write tests for response policy**

Required cases:

```swift
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: .init(text: "こんにちは")), 256)
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: .init(text: "詳しく教えて")), 512)
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: requestWithImage), 512)
```

- [ ] **Step 2: Define domain types without importing UIKit into the protocol layer**

```swift
struct ReplyImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

struct ReplyRequest: Equatable, Sendable {
    let text: String
    let image: ReplyImage?

    init(text: String, image: ReplyImage? = nil) {
        self.text = text
        self.image = image
    }
}

enum ReplyDetailPolicy {
    static func maximumTokens(for request: ReplyRequest) -> Int {
        if request.image != nil { return 512 }
        let detailedPhrases = ["詳しく", "詳細に", "理由も", "もう少し説明"]
        return detailedPhrases.contains(where: request.text.contains) ? 512 : 256
    }
}

protocol ReplyGenerating: Sendable {
    func prepare(progress: (@Sendable (GemmaModelDownloadProgress) -> Void)?) async throws
    func streamReply(to request: ReplyRequest) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}
```

- [ ] **Step 3: Implement deterministic detail detection**

Only explicit Japanese detail phrases and image presence select 512. Ordinary long prompts do not automatically expand the answer.

- [ ] **Step 4: Update fakes and existing tests to compile**

Do not change address-classifier interfaces.

- [ ] **Step 5: Commit the domain contract**

```bash
git add CatRobot/Conversation/Domain CatRobotTests/Conversation
git commit -m "refactor: add multimodal reply request"
```

---

### Task 4: Build the official Foundation Models Gemma reply path

**Files:**
- Create: `CatRobot/Conversation/Services/GemmaFoundationModelFactory.swift`
- Create: `CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift`
- Modify: `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`
- Modify: `CatRobot/Conversation/Integration/ConversationDependencies.swift`
- Test: corresponding service and app-composition tests

**Interfaces:**
- Consumes: verified model URL and `ReplyRequest`.
- Produces: cumulative text snapshots from `LanguageModelSession`.
- Keeps: Apple content-tagging classifier unchanged.

- [ ] **Step 1: Write failing factory tests around an injectable session client**

The live factory creates `EngineConfig` with text GPU, vision CPU, no audio, no reasoning configuration, a writable cache path, and a provisional `24_576` context capacity. The provisional literal is replaced by the measured final value in Task 9.

- [ ] **Step 2: Implement the factory and explicit capability checks**

```swift
protocol GemmaSessionClient: Sendable {
    func prewarm() async
    func stream(request: ReplyRequest, maximumTokens: Int) async throws -> AsyncThrowingStream<String, Error>
}
```

The live client creates `LiteRTLanguageModel` and `LanguageModelSession`. Assert vision availability from `model.capabilities`; do not expose reasoning.

- [ ] **Step 3: Implement reply streaming with existing busy/cancellation semantics**

Keep one active generation per actor, map Foundation Models errors through the existing mapper, and keep cumulative snapshots compatible with `ConversationViewModel`.

- [ ] **Step 4: Compose live dependencies**

Use:

```swift
classifier: FoundationModelAddressClassifier()
reply: GemmaFoundationModelReplyService(...)
```

`FoundationModelAvailabilityService` must report availability for `SystemLanguageModel(useCase: .contentTagging)`. Gemma download/readiness belongs to `reply.prepare(progress:)`, so a missing artifact does not prevent the preparation flow from starting.

- [ ] **Step 5: Prove classifier invariance**

Add an app-composition assertion that the production classifier remains Apple-backed. Do not introduce `GemmaAddressClassifier`.

- [ ] **Step 6: Run targeted reply, classifier, error-mapper, and composition tests**

Expected: PASS on Simulator with fakes; no real model download.

- [ ] **Step 7: Commit the text backend**

```bash
git add CatRobot/Conversation CatRobotTests/Conversation
git commit -m "feat: route replies through LiteRT Foundation Models"
```

---

### Task 5: Add deterministic vision fixtures and the Foundation Models vision probe

**Files:**
- Create: `CatRobot/Diagnostics/VisionFixtureFactory.swift`
- Create: `CatRobot/Diagnostics/GemmaVisionDeviceProbe.swift`
- Test: `CatRobotTests/Diagnostics/GemmaVisionDeviceProbeTests.swift`

**Interfaces:**
- Produces: three generated images with semantic predicates.
- Produces: bounded device evidence from the same reply service.

- [ ] **Step 1: Generate exact CoreGraphics fixtures**

```swift
enum VisionFixtureID: String, CaseIterable, Sendable {
    case redTriangleAboveBlueSquare
    case blueSquareAboveRedTriangle
    case greenCircleLeftOfYellowStar
}

struct VisionExpectation: Equatable, Sendable {
    let shapes: Set<String>
    let colors: Set<String>
    let relation: String
}
```

Use a white 512 by 512 canvas, saturated colors, separated shapes, and no embedded text.

- [ ] **Step 2: Write semantic-rubric tests**

Do not assert one exact generated sentence. Parse a guided response containing `shapes`, `colors`, `count`, and `relation`, then compare fields.

- [ ] **Step 3: Implement the device probe through `LanguageModelSession`**

Run exactly three fixtures and one no-image control. A failed case gets one unchanged retry. Total vision inference runs cannot exceed eight. One clear prompt correction is allowed; further tuning stops with evidence.

- [ ] **Step 4: Keep vision entry diagnostic-only**

Expose the probe through a physical-device XCTest or DEBUG launch argument. Do not add a product `PhotosPicker`, media library, image history, editing, compression settings, or multi-image selection in this PoC.

- [ ] **Step 5: Run fixture unit tests**

Expected: PASS without model inference.

- [ ] **Step 6: Commit vision support**

```bash
git add CatRobot/Diagnostics CatRobotTests/Diagnostics
git commit -m "feat: add bounded Gemma vision probe"
```

---

### Task 6: Implement explicit local memory

**Files:**
- Create: `CatRobot/Conversation/Memory/MemoryFact.swift`
- Create: `CatRobot/Conversation/Memory/MemoryCommandParser.swift`
- Create: `CatRobot/Conversation/Memory/LocalMemoryStore.swift`
- Test: corresponding memory tests
- Modify: `ConversationDependencies.swift`, `ConversationViewModel.swift`, and fakes

**Interfaces:**
- Produces: local-only fact CRUD and deterministic command parsing.
- Limits: 50 facts and 1,024 injected tokens.

- [ ] **Step 1: Define the stored record and commands**

```swift
struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fact: String
    let createdAt: Date
    var updatedAt: Date
    let sourceTurnID: UInt64
}

enum MemoryCommand: Equatable, Sendable {
    case remember(String)
    case list
    case forgetMatching(String)
    case forgetAll
    case none
}
```

- [ ] **Step 2: Write parser and persistence tests first**

Cover supported Japanese forms, ordinary utterances returning `.none`, restart reload, bounded count, deterministic duplicate update, individual deletion, full deletion, and deleted facts not appearing in prompt context.

- [ ] **Step 3: Implement an actor-backed atomic JSON store**

Store in Application Support. Write to a sibling temporary file and replace atomically. Do not add cloud sync, embeddings, automatic LLM extraction, or encryption UI.

- [ ] **Step 4: Route commands before reply generation**

Memory commands are handled by deterministic app logic. Gemma may generate the acknowledgement after the store mutation, but it must not decide what is persisted.

- [ ] **Step 5: Verify restart and deletion integration tests**

Expected: explicit facts survive a new store instance; ordinary speech and working summaries do not.

- [ ] **Step 6: Commit memory**

```bash
git add CatRobot/Conversation/Memory CatRobot/Conversation/Integration CatRobotTests/Conversation
git commit -m "feat: add explicit local conversation memory"
```

---

### Task 7: Implement token budgeting and atomic auto-compaction

**Files:**
- Create: `CatRobot/Conversation/Context/ConversationTurn.swift`
- Create: `CatRobot/Conversation/Context/TokenBudgeting.swift`
- Create: `CatRobot/Conversation/Context/ConversationContextController.swift`
- Test: corresponding context tests
- Modify: `GemmaFoundationModelReplyService.swift`

**Interfaces:**
- Produces: projected token accounting and a rebuildable context state.
- Uses: session-scoped summary, four recent turn pairs, persistent facts, current input, image tokens, and output reserve.

- [ ] **Step 1: Define exact budgeting types**

```swift
struct ConversationContextPolicy: Equatable, Sendable {
    let validatedContextCapacity: Int
    let recentTurnPairCount: Int
    let compactTargetFraction: Double

    var operationalContextBudget: Int {
        Int((Double(validatedContextCapacity) * 0.8).rounded(.down))
    }
}

struct TokenProjection: Equatable, Sendable {
    let instructions: Int
    let summary: Int
    let recentTurns: Int
    let persistentMemory: Int
    let currentInput: Int
    let images: Int
    let outputReserve: Int
    let margin: Int
    var total: Int { instructions + summary + recentTurns + persistentMemory + currentInput + images + outputReserve + margin }
}

struct ConversationTurn: Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct ConversationContextState: Equatable, Sendable {
    let summary: String?
    let recentTurns: [ConversationTurn]
}

struct PreparedReplyContext: Equatable, Sendable {
    let state: ConversationContextState
    let projection: TokenProjection
    let requiresSessionRebuild: Bool
}
```

- [ ] **Step 2: Write failing threshold and preservation tests**

Cover 256/512 reserve, image/memory inclusion, exact 80% boundary, summary separation from persistent facts, last four pairs verbatim, prompt exactly once, rollback on cancellation/failure, repeated compaction, and one context-exceeded retry.

- [ ] **Step 3: Implement the context actor**

```swift
actor ConversationContextController {
    func prepare(_ request: ReplyRequest, persistentFacts: [MemoryFact]) async throws -> PreparedReplyContext
    func record(user: ReplyRequest, assistant: String) async
    func recoverFromContextExceeded(_ request: ReplyRequest, persistentFacts: [MemoryFact]) async throws -> PreparedReplyContext
    func reset() async
}
```

Compaction summarizes old turns with a dedicated Gemma session, retains four pairs verbatim, targets at most 40% of validated capacity, constructs a replacement transcript/session, then swaps only after successful preparation.

- [ ] **Step 4: Add one retry around context exceeded**

The current prompt is never appended twice. After one compact-and-retry failure, return the mapped error.

- [ ] **Step 5: Calibrate token estimation only three times**

Compare small, medium, and near-threshold values once each against provider/runtime accounting. Reuse that evidence; do not run iterative estimator tuning.

- [ ] **Step 6: Run context unit and integration tests**

Expected: PASS with fake session clients and no model.

- [ ] **Step 7: Commit compaction**

```bash
git add CatRobot/Conversation/Context CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift CatRobotTests/Conversation
git commit -m "feat: add bounded conversation compaction"
```

---

### Task 8: Integrate model preparation, memory, and cancellation into the app lifecycle

**Files:**
- Modify: `ConversationDependencies.swift`
- Modify: `ConversationViewModel.swift`
- Modify: `ConversationViewState.swift`
- Modify: `ConversationView.swift`
- Modify: integration fakes and tests

**Interfaces:**
- Preserves: existing lifecycle generation IDs, turn ownership, classifier sequencing, audio teardown, and reply reset behavior.
- Adds: bounded preparation progress and memory command results. Vision remains a diagnostic path in Task 5.

- [ ] **Step 1: Write integration tests for the new flow**

Required sequences:

```text
voice: recognize -> Apple classify -> Gemma reply -> speak
typed: submit -> Gemma reply -> speak
remember: parse -> persist -> acknowledgement
contextExceeded: compact -> retry once -> speak or fail
cancel: stop streaming -> preserve last committed context
```

- [ ] **Step 2: Replace `prewarm()` with explicit model preparation**

Expose download progress without changing signing or global configuration. In voice preflight, check Apple classifier availability, then finish `reply.prepare(progress:)` before activating the audio session. Typed input also prepares the reply backend before generation. A model-preparation failure maps to a recoverable Cat Robot error.

- [ ] **Step 3: Preserve Apple classifier order**

Voice turns must still call `dependencies.classifier.classify` before the Gemma reply. Typed turns may keep the existing direct-reply behavior.

- [ ] **Step 4: Preserve existing concurrency ownership**

Do not introduce detached tasks around session mutation. All context and memory mutations go through their actors; UI changes remain `@MainActor`.

- [ ] **Step 5: Run existing and new integration tests**

Expected: existing lifecycle, interruption, clarification, cancellation, latency, and typed-input tests remain green.

- [ ] **Step 6: Commit app integration**

```bash
git add CatRobot/Conversation CatRobotTests/Conversation
git commit -m "feat: integrate Gemma context and memory lifecycle"
```

---

### Task 9: Run bounded physical-device context calibration and freeze the measured capacity

**Files:**
- Create: `CatRobot/Diagnostics/GemmaContextCalibrationProbe.swift`
- Create: `CatRobot/Diagnostics/PoCProcessMetrics.swift`
- Test: `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`
- Modify after measurement: `GemmaFoundationModelFactory.swift`, `ConversationContextController.swift`
- Append evidence: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`

**Interfaces:**
- Produces: runtime accepted boundary, validated capacity, and 80% operational budget.
- Constraint: no more than 14 full-model context runs including a flake retry.

- [ ] **Step 1: Implement deterministic requests and result records**

```swift
struct ContextProbeResult: Codable, Equatable, Sendable {
    let configuredCapacity: Int
    let actualInputTokens: Int
    let outputReserve: Int
    let coldStart: Bool
    let timeToFirstTokenSeconds: Double
    let totalResponseSeconds: Double
    let residentBytesBefore: UInt64?
    let residentBytesAfter: UInt64?
    let thermalBefore: String
    let thermalAfter: String
    let outcome: String
}
```

- [ ] **Step 2: Unit-test the finite search controller**

Coarse candidates are exactly `2_048`, `8_192`, `16_384`, `24_576`, and `32_000`. Boundary search performs at most four bisections, reaches approximately 512-token resolution in the widest interval, and rounds to an accepted alignment. Stability collects three successful runs at the final candidate, including at least one cold start. Coarse, boundary, stability, fallback confirmation, and any flake retry share one hard budget of 14 full-model runs.

- [ ] **Step 3: Run physical probes serially through Foundation Models**

Use device `00008140-000610311A90801C`, a ten-minute per-run timeout, and a deterministic synthetic corpus. Include 512 output reserve. Release cached LiteRT engines between different configurations to avoid retaining multiple multi-GB engines.

- [ ] **Step 4: Classify outcomes without unbounded retry**

Distinguish invalid configuration, context exceeded, OOM/app termination, timeout, cancellation, memory warning, thermal serious/critical, and output failure. An unchanged failed command gets at most one flake retry, counted within 14.

- [ ] **Step 5: Freeze the result into production configuration**

Replace the provisional `24_576` literal with the highest candidate that has three successful stability runs under the same binary and configuration. If the top candidate fails stability, use remaining run budget only to confirm an already-observed lower candidate; do not extend the 14-run cap. Compute:

```swift
let operationalContextBudget = Int(
    (Double(validatedContextCapacity) * 0.8).rounded(.down)
)
```

Do not call a guessed value `runtimeHardLimit`; report a success lower bound and failure upper bound when the boundary remains unresolved.

- [ ] **Step 6: Run one real auto-compaction event**

Use the final capacity and prove the current prompt appears once, summary and four recent pairs remain, persistent facts remain separate, and the post-compact conversation continues.

- [ ] **Step 7: Commit the calibrated configuration and evidence**

```bash
git add CatRobot/Diagnostics CatRobotTests/Diagnostics CatRobot/Conversation docs/validation
git commit -m "test: calibrate Gemma context on iPhone 16 Pro"
```

---

### Task 10: Complete integrated physical-device acceptance

**Files:**
- Update: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`
- Modify source only for concrete acceptance failures within scope

**Interfaces:**
- Produces: finite evidence for every acceptance criterion.

- [ ] **Step 1: Run final generator and Simulator validation once**

Run `ruby scripts/test_generate_project.rb`, targeted tests affected by the last code change, then one full Simulator suite. Do not clean DerivedData unless a concrete stale-cache signature exists.

- [ ] **Step 2: Build, install, and launch on the physical device**

Record Xcode build, SDK, device OS/build, LiteRT version, Package.resolved pin, model revision, model size, and the single initial SHA result.

- [ ] **Step 3: Verify text and routing**

Prove a voice utterance follows Apple content-tagging classification then Foundation Models-backed Gemma reply. Prove a typed utterance uses Gemma reply. Verify 256 and 512 caps without exact prose assertions.

- [ ] **Step 4: Run bounded vision acceptance**

Run the three fixtures and no-image control under the Task 5 cap. Record raw responses with no private user content.

- [ ] **Step 5: Run memory acceptance**

Save one explicit fact, restart, list it, delete it, and prove it is no longer injected. Prove one ordinary utterance is not persisted.

- [ ] **Step 6: Verify warm-cache behavior and offline inference**

On a normal warm launch, prove full SHA does not rerun. After the model is installed, prove ordinary inference does not require network access.

- [ ] **Step 7: Record limitations**

State that LiteRT Swift and the Foundation Models adapter are early-preview dependencies, transcript replay may increase long-context TTFT, the model is about 2.6 GB, and production readiness is not claimed.

---

### Task 11: Run at most two formal review/fix rounds and hand off

**Files:**
- Review: current goal diff only
- Update: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`

**Interfaces:**
- Produces: a clean or explicitly blocked PoC handoff.

- [ ] **Step 1: Dispatch one Sol/xhigh formal reviewer**

Use one `gpt-5.6-sol` subagent at `xhigh` to review requirement compliance, Swift concurrency, Foundation Models/LiteRT routing, model integrity policy, compaction prompt-once semantics, memory privacy, and whether tests prove the required behavior. Do not ask multiple agents to review the same diff.

- [ ] **Step 2: Process round 1**

Fix only in-scope Critical and Important findings, then run impact-based validation. Report Minor findings without expanding scope. If round 1 has no Critical/Important finding, skip round 2.

- [ ] **Step 3: Run round 2 only after round-1 fixes**

Ask the same reviewer for a fresh review of the changed diff. Fix in-scope Critical/Important findings and run impact-based validation. Do not run a third whole-diff review.

- [ ] **Step 4: Enforce the terminal state**

If Critical/Important findings remain after round 2, stop without claiming completion. Do not automatically continue editing in a later goal turn. If none remain and all acceptance criteria are evidenced, mark complete.

- [ ] **Step 5: Final handoff**

Report branch, worktree, base SHA, changed files, exact pins, commands/results, physical-device results, vision table, context table, validated capacity, operational budget, effective compact threshold, SHA run count/reasons, review rounds used, remaining findings, limitations, and validation report path.

## Subagent routing policy

- Root owns Git/worktree, shared interfaces, package integration, Xcode, signing, Simulator, physical device, model download, context runs, result synthesis, and completion status.
- `gpt-5.6-luna` with `max` may handle only bounded mechanical tasks such as file inventory, isolated fixture generation, isolated unit tests, and table formatting.
- `gpt-5.6-sol` with `xhigh` handles Foundation Models/LiteRT design, Swift concurrency, context-log interpretation, and formal review.
- Do not use `gpt-5.6-terra`.
- At most two subagents are active at once, with disjoint tasks and file ownership.
- Do not split work merely to use subagents and do not delegate Xcode or device operation.
- If subagents are unavailable, root proceeds rather than substituting Terra.

## Retry and evidence-reuse policy

- An unchanged failed command may be rerun once to check a flake.
- A later attempt requires a new hypothesis and a material change.
- Three consecutive occurrences of the same failure signature/root cause stop that path and produce a blocker.
- Normal TDD may continue while failure signatures change and measurable progress occurs.
- Documentation-only changes do not trigger full builds, device runs, model hashes, or context sweeps.
- Existing evidence is reused when source, binary, model, device, and relevant configuration are unchanged.
- A corruption-path test uses a small fixture; the real model is never deliberately damaged.

## Completion criteria

The PoC is complete only when all items below have evidence in the single validation report:

1. The exact official LiteRT package and `LiteRTLMFoundationModels` product resolve on Xcode 27.
2. Reply generation goes through `LanguageModelSession(model: LiteRTLanguageModel)`.
3. Apple `.contentTagging` remains the address classifier and still precedes voice reply generation.
4. Thinking/reasoning mode is absent from app configuration and UI.
5. Normal replies cap at 256; detailed and image replies cap at 512.
6. Three deterministic vision fixtures and a no-image control meet their semantic rubric within eight runs.
7. Only explicit facts persist; restart, listing, individual deletion, and full deletion work.
8. Context search finishes within 14 runs and records success/failure bounds plus the three-run stable capacity.
9. Operational budget is exactly 80% of validated capacity, and a real compaction preserves summary, four recent pairs, persistent facts, and the current prompt exactly once.
10. Initial model integrity is verified; unchanged warm launch does not rehash the artifact.
11. Generator contract, Simulator suite, signed device build, and integrated device acceptance pass.
12. Formal review consumes at most two rounds and leaves no Critical/Important finding.
13. No push, PR, merge, comparison-branch mutation, fallback model/library, or scope-external refactor occurred.
