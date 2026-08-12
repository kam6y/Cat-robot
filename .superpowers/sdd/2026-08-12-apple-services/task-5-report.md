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

Final GREEN:

- Focused recognizer suite: 13 tests, 0 failures, exit 0.
- Full simulator suite on the final production state: 69 tests, 0 failures, exit 0.
- Project generator contract: `ruby scripts/test_generate_project.rb` passed.

## Lifecycle and API decisions

- `AppleSpeechRecognizer` retains one `SpeechAssetPreparer` for its ownership lifetime and creates one driver per capture run.
- State is explicit: unprepared, prepared, running, and stopping. Concurrent or second starts are rejected with `.speechCaptureAlreadyRunning`.
- `prepare()` is idempotent and performs asset/transcriber plus analyzer/audio-format preflight only; it does not install a microphone tap or start the engine.
- `stop()` takes the lossless path: remove tap; stop/reset engine; synchronously flush the converter and yield its tail; finish input; finalize through end of input; await analysis; drain results; finish the public stream. It never cancels the analyzer/tasks on the normal path.
- `shutdown()` uses normal stop for a running capture, immediate teardown for a merely prepared capture, and retains `.stopping` ownership through reservation release. Repeated shutdowns release a successful reservation once.
- The live implementation uses installed iOS 26.5 signatures for `SpeechAnalyzer.Options`, `bestAvailableAudioFormat`, `analyzeSequence`, `finalizeAndFinishThroughEndOfInput`, and `cancelAndFinishNow`.

## Concurrency and failure decisions

- Each public run has a UUID. Failure and termination callbacks are accepted only for the matching running capture; late callbacks cannot tear down a later run.
- Analyzer, result-stream, converter/tap, engine-start, and consumer-termination failures converge on one idempotent immediate teardown.
- The tap callback never transfers `AVAudioPCMBuffer` into a task. `SpeechTapBridge` is the narrow `@unchecked Sendable` boundary and protects converter plus input continuation with `NSLock`; conversion/yield and stop-time flush/finish are serialized inside it.
- Failure teardown stops accepting buffers, finishes input without converter flush, cancels analysis/results, invokes `cancelAndFinishNow`, and maps non-domain failures to `.speechCaptureFailed`.
- Cancellation maps to `.cancelled` only when observed as an external operation failure; self-generated cancellation callbacks are suppressed after entering stopping state.

## Files

- Added `CatRobot/Conversation/Services/AppleSpeechRecognizer.swift`.
- Added `CatRobotTests/Conversation/Services/AppleSpeechRecognizerTests.swift`.
- Regenerated `CatRobot.xcodeproj/project.pbxproj` and shared scheme references.
- Added this report.

## Risks and scope

- Live microphone/Speech asset behavior still depends on device permissions, installed assets, and runtime audio routing; those responsibilities are deliberately outside Task 5.
- No permission UI, audio-session policy, utterance segmentation, or app composition was added.
- Tests use deterministic driver and asset-inventory seams; they validate lifecycle/error contracts without asserting child-task scheduler order.
