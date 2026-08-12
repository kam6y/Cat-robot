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

- Focused recognizer suite after the review fixes: 18 tests, 0 failures, exit 0.
- Full simulator suite after the review fixes: 74 tests, 0 failures, exit 0.
- Project generator checks: `ruby scripts/generate_project.rb --check` and `ruby scripts/test_generate_project.rb` passed.

## Lifecycle and API decisions

- `AppleSpeechRecognizer` retains one `SpeechAssetPreparer` for its ownership lifetime and creates one driver per capture run.
- State is explicit: unprepared, preparing, prepared, running, stopping, and shutting down. A preparation identity retains its fresh driver and task; concurrent or second starts are rejected with `.speechCaptureAlreadyRunning`.
- `prepare()` is idempotent and performs asset/transcriber plus analyzer/audio-format preflight only; it does not install a microphone tap or start the engine.
- `stop()` takes the lossless path: remove tap; stop/reset engine; synchronously flush the converter and yield its tail; finish input; finalize through end of input; await analysis; drain results; finish the public stream. It never cancels the analyzer/tasks on the normal path.
- `shutdown()` uses normal stop for a running capture, immediate teardown for a merely prepared capture, and exclusive shutdown ownership through reservation release. If preparation ignores task cancellation and succeeds, shutdown cancels that retained driver before releasing the reservation; stale prepare/start callers receive `.cancelled` and cannot publish it.
- The live implementation uses installed iOS 26.5 signatures for `SpeechAnalyzer.Options`, `bestAvailableAudioFormat`, `analyzeSequence`, `finalizeAndFinishThroughEndOfInput`, and `cancelAndFinishNow`.

## Concurrency and failure decisions

- Each preparation and public run has an identity. One matching outer teardown owns a run; start errors, failures, stop, consumer termination, and shutdown join that teardown, whose completion can reset state only while it still owns the same generation. Late callbacks cannot tear down a later run.
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
