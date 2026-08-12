# Task 6 Report: Retained Japanese Speech Synthesis and Mouth Events

## Result

Implemented `AppleSpeechSynthesizer` as the `@MainActor` concrete `SpeechSpeaking` service. It retains one live `AVSpeechSynthesizer`, publishes start/range/terminal mouth events, rejects overlapping speech, and scopes cancellation and delegate delivery to a monotonic utterance run ID.

## TDD evidence

Initial RED, after adding only the focused tests and regenerating the project:

- Command selected `AppleSpeechSynthesizerTests` on the shared iOS 26.5 Simulator.
- Exit: 65.
- Expected cause: `SpeechSynthesizerDriving`, `SpeechVoiceDescriptor`, `SpeechSynthesizerDriverEvent`, and `AppleSpeechSynthesizer` did not exist.

Initial GREEN:

- Focused synthesizer suite: 14 tests, 0 failures.
- Self-audit then added delayed old-run termination and live unknown-voice coverage; the final pre-review focused suite was 16 tests, 0 failures.

Bounded-wait pre-review RED/GREEN:

- A new regression test first failed to compile because the bounded collector API and timeout error did not exist.
- The minimal XCTest collector now caps terminal waits, cancels and awaits its collector task on timeout, and was directly verified to deliver iterator `.cancelled` termination in 0.013 seconds.
- Final focused suite: 17 tests, 0 failures, 0 skipped. Result bundle: `/tmp/CatRobotTask6FocusedPostReview.xcresult`.
- Final full simulator suite: 95 tests, 0 failures, 0 skipped. Result bundle: `/tmp/CatRobotTask6FullPostReview.xcresult`.
- Generic iOS Debug build with signing disabled succeeded after the production implementation.

## Lifecycle and API decisions

- `prepare()` caches the preferred voice and is idempotent. Canonical exact `ja-JP` equality wins, with canonical Japanese language-code fallback; absence maps to `.speechVoiceUnavailable` before enqueue.
- The internal class-bound `@MainActor` driver seam exposes Sendable voice descriptors and events, a throwing fakeable enqueue boundary, and the framework's real `stopSpeaking(at:)` Boolean.
- `speak()` installs its captured-run termination callback before enqueue. One active stream/utterance is allowed; overlap and enqueue failures map to `.speechSynthesisFailed`, and failed state is cleared for a later run.
- `didStart`, UTF-16 `NSRange` bounds, `didFinish`, and `didCancel` are forwarded unchanged in lifecycle order. Matching terminal events clear state before finishing the stream and resume matching stop waiters.
- `stop()` callers join one teardown. A true framework result waits for matching cancellation; false immediately publishes `.cancelled` and finishes because no callback is guaranteed.
- Consumer cancellation/drop, delayed stream termination, and stale driver callbacks carry their original run ID and cannot affect a newer run.

## AVFoundation isolation

- The live driver retains the synthesizer, selected-voice lookup, active utterance, and run ID on MainActor.
- A narrowly scoped `@unchecked Sendable` delegate proxy reduces each non-Sendable utterance synchronously to an integer identity token, queues only Sendable event data under a lock, and drains it on MainActor.
- The live driver's throwing guard only enforces that the voice selected during preflight is still present in its retained lookup. It does not reinterpret the framework's Void `speak` API as throwing.
- Delegate events are accepted only when their token matches the retained utterance. Terminal callbacks release both retained utterance and run ID after forwarding.

## Files

- Added `CatRobot/Conversation/Services/AppleSpeechSynthesizer.swift`.
- Added `CatRobotTests/Conversation/Services/AppleSpeechSynthesizerTests.swift`.
- Regenerated `CatRobot.xcodeproj/project.pbxproj` and the shared scheme references.
- Added this report.

## Verification

- `ruby scripts/generate_project.rb --check`
- `ruby scripts/test_generate_project.rb`
- Swift frontend parse checks for the new production and test files
- `git diff --check`

## Risks and scope

- Real voice inventory, audible output, delegate timing, interruptions, and routing still require the planned iPhone smoke test.
- Audio-session ownership and microphone/speaker coexistence belong to Task 7 and were intentionally not added here.
- No service composition or UI integration was added.
