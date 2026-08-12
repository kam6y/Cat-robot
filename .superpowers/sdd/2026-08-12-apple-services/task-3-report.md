# Task 3 report — Stateful prewarmed streaming reply service

## RED

- Added `CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift` before any production implementation.
- Command:

  ```sh
  ruby scripts/generate_project.rb
  xcodebuild -quiet -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelReplyServiceTests test
  ```

- Result: expected failure, exit 65 / `** TEST FAILED **`.
- Relevant diagnostics:

  ```text
  cannot find type 'ReplyModelClient' in scope
  Testing cancelled because the build failed.
  ```

This is the intended RED: the tests compile against the requested reply client seam and service, neither of which existed.

## GREEN

- Implemented `FoundationModelReplyService` as an actor with one lazily created client, explicit prewarming, stateful reuse, replacement/prewarm on reset, and `.modelBusy` rejection while generation is active.
- Wrapped the source stream so completion, error, and consumer cancellation all clear `isGenerating` in the actor-isolated `defer` path. Consumer termination cancels the forwarding task, which in turn cancels the live model stream.
- Added a retained `LiveReplyModelClient` around one `LanguageModelSession`, default guardrails, the specified Japanese Cat Robot instructions, temperature `0.5`, and maximum `160` response tokens.
- Forwarded each `snapshot.content` verbatim. There is no trim, validation, rewrite, retry, second request, or cloud path.
- Preserved already-mapped domain failures and routed all other client/framework failures through `FoundationModelErrorMapper`.

### Verification commands and results

```sh
ruby scripts/generate_project.rb
xcodebuild -quiet -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelReplyServiceTests test
```

Result: exit 0. Xcode result summary: 7 passed, 0 failed, 0 skipped.

```sh
git diff --check
xcodebuild -quiet -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
```

Result: exit 0. `git diff --check` emitted no diagnostics. Xcode result summary: 34 passed, 0 failed, 0 skipped.

### Design decisions

- The injected factory is synchronous and `@Sendable`. The service stores the newly created client before its first suspension, so actor reentrancy cannot create duplicate live sessions.
- `ReplyModelClient` operations are async so actor-based test clients can model stream state safely; the live implementation remains serialized by the service actor.
- The forwarding task is owned by the returned stream. Its actor-isolated cleanup clears busy state before finishing the downstream continuation, so the next turn can start immediately after collection completes or fails.
- A context exhaustion error is surfaced once. Reset remains an explicit coordinator action and never replays the user's prompt.

### Changed files

- `.superpowers/sdd/2026-08-12-apple-services/task-3-report.md`
- `CatRobot/Conversation/Services/FoundationModelReplyService.swift`
- `CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift`
- `CatRobot.xcodeproj/project.pbxproj`
- `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`

### Remaining risks

- Simulator tests use injected clients and do not execute the hardware-backed Foundation Models session. The plan intentionally defers real model smoke testing to the connected-iPhone app integration phase.
- `reset()` is designed for the coordinator's documented context-exhaustion path after a stream has ended; this task does not add an unrelated active-stream cancellation API.
