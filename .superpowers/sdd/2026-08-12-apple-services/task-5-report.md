# Task 5 Report: Progressive Japanese Speech Recognition

## Result

Implemented `AppleSpeechRecognizer` as the concrete `SpeechRecognizing` actor and added a live iOS 26.5 `AVAudioEngine` / `SpeechAnalyzer` capture driver. The recognizer streams progressive and final Japanese transcription events without trimming text or treating `isFinal` as stream completion.

## TDD evidence

Initial RED, after adding only `AppleSpeechRecognizerTests.swift` and regenerating the project:

- Command: `xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AppleSpeechRecognizerTests test`
- Exit: 65
- Expected cause: `SpeechCaptureDriving` and `AppleSpeechRecognizer` were missing.

Shutdown-reentrancy RED, added after lifecycle review and before its production fix:

- Command selected only `testShutdownRejectsNewStartUntilReservationReleaseCompletes`.
- Exit: 65; the new start incorrectly succeeded during suspended reservation release and created a second driver.

Independent-review RED, after adding the five required lifecycle regressions and before changing production code:

- Command: the focused `AppleSpeechRecognizerTests` command above.
- Exit: 65.
- Expected cause: the tests referenced the not-yet-implemented production `SpeechCaptureRunPhase` and `SpeechCaptureCancellationCoordinator`. The same focused suite also contained the new tail-event, start-error/teardown race, and non-cooperative preparation/shutdown scenarios.

Final GREEN:

- Focused recognizer suite after the first review fixes: 18 tests, 0 failures, exit 0.
- Full simulator suite after the review fixes: 74 tests, 0 failures, exit 0.
- Project generator checks: `ruby scripts/generate_project.rb --check` and `ruby scripts/test_generate_project.rb` passed.

Suspended-start rereview RED, before serializing in-flight start teardown:

- Command selected the new stop/start and shutdown/start race tests.
- Exit: 65; 2 tests executed, 2 failed.
- Both public `start()` calls incorrectly returned streams. The controlled log also showed normal teardown starting before the suspended driver start settled.

Start-time background-failure audit RED, before extending the same serialization contract:

- Command selected only `testFailureDuringSuspendedStartWaitsForSettlementBeforeImmediateTeardown`.
- Exit: 65; 1 test executed with 3 assertions failing.
- Immediate cancellation ran before start settled (`cancelCallCount == 1` instead of `0`), the log was `immediateTeardown -> startSettled`, and the original `.speechCaptureFailed` was lost as `.cancelled`.

Suspended-start rereview GREEN:

- Focused `AppleSpeechRecognizerTests` after final review: 22 tests, 0 failures, exit 0.
- Focused result bundle: `Test-CatRobot-2026.08.13_06-06-58-+0900.xcresult`.
- Final full simulator suite after the generation-scoping fix: 78 tests, 0 failures, 0 skipped, exit 0.
- Full result bundle: `Test-CatRobot-2026.08.13_06-08-33-+0900.xcresult`.
- Project generator checks and `git diff --check` passed again after the rereview fix.

Final-review generation-scope RED, before fixing stale lifecycle joins:

- Focused recognizer command exited 65 because the new `SpeechStartTeardownOwnership` contract type did not yet exist.
- The accompanying race tests were strengthened to prove the original `start()` remains pending through suspended driver teardown and reservation release, and that normal stop completes before release begins.
- The final implementation records the exact owner lifecycle ID for each superseded start, so a stale start can never join a newer generation.

## Lifecycle and API decisions

- `AppleSpeechRecognizer` retains one `SpeechAssetPreparer` for its ownership lifetime and creates one driver per capture run.
- State is explicit: unprepared, preparing, prepared, starting, running, stopping, and shutting down. A preparation identity retains its fresh driver and task; concurrent or second starts are rejected with `.speechCaptureAlreadyRunning`.
- `prepare()` is idempotent and performs asset/transcriber plus analyzer/audio-format preflight only; it does not install a microphone tap or start the engine.
- `stop()` takes the lossless path: remove tap; stop/reset engine; synchronously flush the converter and yield its tail; finish input; finalize through end of input; await analysis; drain results; finish the public stream. It never cancels the analyzer/tasks on the normal path.
- `shutdown()` uses normal stop for a running capture, immediate teardown for a merely prepared capture, and exclusive shutdown ownership through reservation release. If preparation ignores task cancellation and succeeds, shutdown cancels that retained driver before releasing the reservation; stale prepare/start callers receive `.cancelled` and cannot publish it.
- The live implementation uses installed iOS 26.5 signatures for `SpeechAnalyzer.Options`, `bestAvailableAudioFormat`, `analyzeSequence`, `finalizeAndFinishThroughEndOfInput`, and `cancelAndFinishNow`.

## Concurrency and failure decisions

- Each preparation and public run has an identity. One matching outer teardown owns a run; start errors, failures, stop, consumer termination, and shutdown join that teardown, whose completion can reset state only while it still owns the same generation. Late callbacks cannot tear down a later run.
- The starting state retains the one shared driver-start task. Stop, shutdown, and start-time background failure take lifecycle ownership, wait for that task to settle, and only then call normal or immediate teardown. A superseded public `start()` joins the owner and throws `.cancelled` for stop/shutdown or preserves the original background failure.
- `start()` publishes its stream only by atomically transitioning the same capture identity from starting to running. A delayed successful driver start therefore cannot resurrect microphone capture after teardown, and the next run remains unavailable until teardown completes.
- Stop/shutdown ownership records a fixed start-ID-to-lifecycle-ID mapping. The stale start waits only that recorded generation—even if a newer capture begins and tears down before the old actor continuation resumes.
- The outer output gate remains open to tail events while graceful stop finalizes and drains, then finishes the public stream. Immediate cancellation closes the gate before driver teardown.
- Analyzer, result-stream, converter/tap, engine-start, and consumer-termination failures converge on one immediate teardown. The live driver's cancellation coordinator gives reentrant callers the same in-progress task, so every caller waits through `cancelAndFinishNow()` and state clearing.
- The tap callback never transfers `AVAudioPCMBuffer` into a task. `SpeechTapBridge` is the narrow `@unchecked Sendable` boundary and protects converter plus input continuation with `NSLock`; conversion/yield and stop-time flush/finish are serialized inside it.
- Failure teardown stops accepting buffers, finishes input without converter flush, cancels analysis/results, invokes `cancelAndFinishNow`, and maps non-domain failures to `.speechCaptureFailed`.
- The live run-phase gate accepts result events during graceful finalization while suppressing recursive background failures. Immediate cancellation suppresses both late events and failures. Cancellation maps to `.cancelled` only when observed as an external operation failure.

## Files

- Added `CatRobot/Conversation/Services/AppleSpeechRecognizer.swift`.
- Added `CatRobotTests/Conversation/Services/AppleSpeechRecognizerTests.swift`.
- Regenerated `CatRobot.xcodeproj/project.pbxproj` and shared scheme references.
- Added this report.

## Risks and scope

- Live microphone/Speech asset behavior still depends on device permissions, installed assets, and runtime audio routing; those responsibilities are deliberately outside Task 5.
- No permission UI, audio-session policy, utterance segmentation, or app composition was added.
- Tests use bounded condition polling plus explicitly controlled suspension gates. They validate outer lifecycle behavior and the production run-phase/cancellation coordinator without pretending a fake AV engine call list proves framework ordering.
