# Facing Addressing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace name-based classifier bypass with fresh head-facing evidence while keeping the existing 30-second follow-up rule.

**Architecture:** ConversationCamera owns fresh face metadata and a third, listening-only capture demand. ConversationViewModel reads a synchronous MainActor attention dependency before routing; AddresseePolicy preserves pending yes/no and engagement semantics. Existing neck tracking, image snapshots and their single event consumer remain intact.

**Tech Stack:** Swift, SwiftUI, Vision revision 3, AVCapture, XCTest, Ruby project generator. No new dependencies.

**Spec:** docs/superpowers/specs/2026-11-06-facing-addressing-design.md

## Global Constraints

- Head direction is sufficient; preserve the 30-second soft and 300-second hard engagement windows.
- Current base is main `04c3de85e9030135f261099c9055be56834f5626`; implement on `codex/issue-22-gaze-addressing` in the existing isolated worktree.
- Reuse 0.4-second freshness and existing yaw correction / 30-degree yaw / 25-degree pitch bounds; multiple visible faces fall back to classification.
- No camera images are retained or transmitted for attention. No paid API, live microphone or robot motion in automated tests.
- Root is the only implementation writer; Claude pair and simplify are read-only, followed by one fresh native whole-branch reviewer and reciprocal reception.
- Integration and normal signed physical-device installation are authorized by the established same-workflow request; never force push or overwrite other worktrees.

## Review Focus

- Speech finalization may take time: stale observations at routing must fall back rather than outlive camera ownership.
- A permission prompt can deactivate the scene, then resolve after foreground return; preserve start ownership and avoid duplicate prompts or stuck listening.
- Tracking, attention and look may overlap: one owner ending must not stop another, and events must still reach the original tracking consumer.
- A late old frame after turn-away or resume must not revive an obsolete facing state.
- A pending negative confirmation must not become a reply merely because the user is facing the screen.

---

### Task 1: Replace name-based routing with camera-facing evidence

**Files:**
- Modify: `CatRobot/Conversation/Domain/AddresseePolicy.swift`, `CatRobot/Conversation/Integration/ConversationViewModel.swift`, `CatRobot/Conversation/Integration/ConversationDependencies.swift`
- Modify: `CatRobot/Vision/ConversationCamera.swift`, `CatRobot/App/ConversationComposition.swift`, `CatRobot/App/ConversationAppCoordinator.swift`
- Modify: `CatRobot/App/CameraTrackingSettingsPane.swift`, `CatRobot/Resources/Info.plist`, `CatRobot/Conversation/UI/OnboardingView.swift`, `README.md`, `docs/superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md`
- Test: `CatRobotTests/Conversation/Domain/AddresseePolicyTests.swift`, `CatRobotTests/Conversation/Integration/ConversationFakes.swift`, affected conversation integration tests, `CatRobotTests/Vision/ConversationCameraTests.swift`, camera/app integration tests
- Generate: `CatRobot.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: existing `FaceObservation`, `FaceTrackingGeometry.selectFace(_:yawCorrection:)`, `RobotClock`, `ConversationCamera.setEnvironment(...)`, `FaceCaptureSource.events()`.
- Produces: `ConversationCamera.hasFreshFacingFace(yawCorrection: Double) -> Bool`; `ConversationDependencies.isFacingScreen: @MainActor @Sendable () -> Bool` (default false); `AddresseePolicy.route(..., isFacingScreen: Bool = false)`.

- [x] **Step 1: Write behavioral RED tests using existing interfaces.** Name-prefixed speech with no active engagement must classify the complete input; a visible listening camera must capture without tracking/look demand; name-only speech must not receive a local fixed acknowledgement. Run the tests against the old implementation and preserve actual assertion failures.
- [x] **Step 2: Add interface declarations for test compilation and write the remaining failing tests before implementation.** Cover fresh facing bypass with no name, turn-away/stale/malformed/old-generation fallback, pending yes/no priority, 30-second continuation and 300-second expiry, independent permission/capture while tracking is off, shared look/tracking ownership, failure recovery and lifecycle invalidation. Interface scaffolds must return false / remain unused until RED is observed.
- [x] **Step 3: Implement the minimal camera cache/demand, route replacement and live composition.** Update existing tests that deliberately relied on the removed name feature to exercise facing or normal classification explicitly; preserve original transcript expectations. Update camera purpose copy and README.
- [x] **Step 4: Regenerate the project and verify focused tests.** Run `ruby scripts/generate_project.rb`, `ruby scripts/test_generate_project.rb`, build and focused XCTest through the private issue22 driver. Expected: deterministic generation and all related tests pass. Fix unexpected failures using systematic debugging.
- [x] **Step 5: Run full verification and commit.** `CAT_REVIEW_SIMULATOR=7AA37431-6439-44A1-9747-956E96D8BFF4 python3 /tmp/cat-issue22-gaze-addressing-20261106/run-ios-tests.py final2 full`; expected all unit tests pass, with the two hardware/paid suites explicitly excluded. Run the full suite through `task-done` once, record source binding, RED/GREEN evidence and decisions, then commit the unchanged verified source. Append the resulting commit identity to the ledger; avoid a redundant full-suite repeat solely for bookkeeping. Never mutate code or HEAD while a driver process is running.

## Whole-branch review and authorized integration

- [x] Freeze the branch diff and source hash. Ask Claude to run actual `/simplify` with four read-only review angles; independently request one fresh native code review with spec, plan, ledger and exact diff. Save each report before exchange.
- [x] Apply receiving-code-review on both sides, exchange findings and record technical adoption/rejection. For important fixes, add a reproducing RED test, fix in one pass and run focused plus full verification. Defer minor polish with a record.
- [x] Install a normally signed review build on the connected iPhone and request a short head-facing behavior check while independent work continues.
- [ ] Commit final evidence; fetch and validate main, squash this branch to one main commit, check tree identity and build/install/launch the normal final-main app. Non-force push main, verify remote hash and issue #22 closure, archive and remove only this plan's owned execution workspace, retain feature branch and host worktree. Post-commit integration completion is recorded in `/tmp/cat-issue22-gaze-addressing-20261106/integration.json`.
