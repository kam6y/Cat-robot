# Content-Tagging Availability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the production availability check use the same Apple content-tagging model as the existing address classifier.

**Architecture:** Add one explicit, injectable availability-purpose boundary and route the live snapshot through its content-tagging model. Preserve the current snapshot-to-domain mapping and keep tests free of live model inference.

**Tech Stack:** Swift 6.0 strict concurrency, iOS 26 deployment target, Xcode 27 beta 5 FoundationModels, XCTest, Ruby xcodeproj 1.27.0.

**Spec:** `docs/superpowers/specs/2026-08-24-gemma4-independent-tools-design.md`

## Global Constraints

- Work only in `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-independent-tools` on `feature/gemma4-independent-tools`, based on `29958332f4a3b0e5f90bfb45f06effc4d0d79666`.
- Keep `FoundationModelAddressClassifier` on `SystemLanguageModel(useCase: .contentTagging, guardrails: .default)` and do not rewrite it.
- Do not add LiteRT-LM, a reply backend, tool composition, UI, device inference, or unrelated refactors.
- Use `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild`; do not change global `xcode-select`.
- Run tests on device `00008140-000610311A90801C`; this plan performs no model inference.
- Do not push, pull, fetch, create a PR, merge, rebase, cherry-pick, or change another worktree/branch.

---

### Task 1: Align availability with content tagging

**Files:**
- Modify: `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`
- Modify: `CatRobotTests/Conversation/Services/FoundationModelAvailabilityServiceTests.swift`

**Interfaces:**
- Consumes: `FoundationModelAvailabilitySnapshot` and the existing `ModelAvailabilityChecking` contract.
- Produces: `FoundationModelAvailabilityPurpose.contentTagging` and a service initializer whose default purpose is content tagging and whose snapshot factory receives that purpose.

- [x] **Step 1: Write the failing default-purpose test**

Add a test that constructs the service through an injected purpose-aware snapshot factory, records the purpose without creating `SystemLanguageModel`, calls `availability()`, and asserts the recorded value is exactly `.contentTagging`. The production change that makes this test fail is selecting `.general` or omitting the purpose when constructing the live availability snapshot.

```swift
private final class AvailabilityPurposeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: FoundationModelAvailabilityPurpose?

    var value: FoundationModelAvailabilityPurpose? {
        lock.withLock { storedValue }
    }

    func record(_ value: FoundationModelAvailabilityPurpose) {
        lock.withLock { storedValue = value }
    }
}

func testDefaultAvailabilityPurposeIsContentTagging() async {
    let recorder = AvailabilityPurposeRecorder()
    let service = FoundationModelAvailabilityService(
        locale: Locale(identifier: "ja-JP"),
        snapshotForPurpose: { purpose in
            recorder.record(purpose)
            return .init(availability: .available, supportsLocale: true)
        }
    )

    _ = await service.availability()

    XCTAssertEqual(recorder.value, .contentTagging)
}
```

- [x] **Step 2: Run the test and verify RED**

Regenerate the project, then run only `FoundationModelAvailabilityServiceTests`.

```bash
ruby scripts/generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotContentTaggingRed -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests
```

Expected: compilation fails because `FoundationModelAvailabilityPurpose` and `snapshotForPurpose` do not exist.

- [x] **Step 3: Implement the minimal purpose boundary**

Define one internal `Equatable, Sendable` purpose case. Make the injected initializer default to `.contentTagging`. Route the live initializer through the same purpose and map its sole case directly to `SystemLanguageModel(useCase: .contentTagging, guardrails: .default)`. Preserve all existing locale and availability mapping behavior.

```swift
enum FoundationModelAvailabilityPurpose: Equatable, Sendable {
    case contentTagging
}

init(
    locale: Locale,
    purpose: FoundationModelAvailabilityPurpose = .contentTagging,
    snapshotForPurpose: @escaping @Sendable (FoundationModelAvailabilityPurpose) -> FoundationModelAvailabilitySnapshot
) {
    self.locale = locale
    snapshot = { snapshotForPurpose(purpose) }
}
```

- [x] **Step 4: Run the task validation bundle**

```bash
ruby scripts/test_generate_project.rb
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination id=00008140-000610311A90801C -derivedDataPath /tmp/CatRobotContentTaggingGreen -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests -only-testing:CatRobotTests/FoundationModelAddressClassifierTests
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination generic/platform=iOS -derivedDataPath /tmp/CatRobotContentTaggingBuild CODE_SIGNING_ALLOWED=NO
```

Expected: generator contract passes, both targeted test classes pass with zero failures, and the generic-device build exits 0.

- [x] **Step 5: Commit**

```bash
git add CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift CatRobotTests/Conversation/Services/FoundationModelAvailabilityServiceTests.swift
git commit -m "fix: align availability with content tagging"
```
