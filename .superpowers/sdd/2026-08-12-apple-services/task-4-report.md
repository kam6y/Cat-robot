# Task 4 report — Japanese Speech assets and iOS 26 audio conversion

## RED

- Added both Task 4 test files before either production file and regenerated the project.
- Command:

  ```sh
  ruby scripts/generate_project.rb
  xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/SpeechAssetPreparerTests -only-testing:CatRobotTests/SpeechAudioConverterTests test
  ```

- Result: expected failure, exit 65 / `** TEST FAILED **`.
- Relevant diagnostics named only the missing Task 4 surface:

  ```text
  cannot find type 'SpeechAssetInventory' in scope
  cannot find type 'SpeechAudioConverter' in scope
  cannot find type 'SpeechAudioConverterBackend' in scope
  cannot find type 'SpeechAudioConversionOutcome' in scope
  ```

- After the first minimal converter implementation, added a regression test for draining multiple `.haveData` outputs without resupplying the input. The focused test failed as intended: it received frame lengths `[100]` and input presence `[true]`, instead of `[100, 40]` and `[true, false]`.

## GREEN

- Implemented `SpeechAssetPreparer` as an actor. Its `SpeechAssetInventory` seam owns every environment-dependent Speech query: transcriber availability, equivalent-locale lookup, installation, installed status, reservation, and release.
- The live inventory creates `AssetInstallationRequest` internally and downloads it when present; the final request type never crosses the seam. Installation cancellation maps to `.cancelled`, while other request/download failures and a non-installed result map to `.speechAssetsUnavailable`.
- Reservation is best-effort and recorded only after a `true` result. Explicit release clears the stored locale before awaiting, so it is reentrancy-safe and idempotent.
- Implemented the iOS 26 project-local `SpeechAudioConverter`. Equal PCM formats pass through with an explicit `CMTime`; differing PCM formats use `AVAudioConverter`, drain all nonempty `.haveData` / `.inputRanDry` buffers, preserve continuous output time, emit trailing primed frames on one flush, then reset.
- The converter's non-Sendable input buffer and mutable supply flag live only in the narrowly scoped `ConverterInputState: @unchecked Sendable`, whose lifetime is one synchronous converter call. No iOS 27-only Speech helpers or general audio abstractions were added.
- Converter construction failures, `.error` status, and `NSError` outcomes map to `.speechCaptureFailed`.

### Verification commands and results

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/SpeechAssetPreparerTests -only-testing:CatRobotTests/SpeechAudioConverterTests test
```

Result: exit 0 / `** TEST SUCCEEDED **`; 19 tests passed, 0 failed.

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
```

Result: exit 0 / `** TEST SUCCEEDED **`; 53 tests passed, 0 failed.

```sh
git diff --check
```

Result: exit 0 with no diagnostics.

One earlier GREEN attempt was interrupted before test execution because Xcode's Simulator worker was waiting to materialize while another task used the same destination. After the competing run was stopped, the single focused rerun and full suite above completed normally.

### API and design decisions

- `SpeechAssetInventory` returns operations and domain-relevant values, never Apple's nonconstructible `AssetInstallationRequest`, which keeps the test seam Sendable and fakeable.
- A false or throwing reserve call cannot make otherwise installed Speech assets unavailable; it only forgoes eviction protection.
- Conversion remains synchronously owned and serialized by its caller. The backend seam exists only to force status/error/drain paths deterministically; production still delegates directly to one retained `AVAudioConverter`.
- After the first resampled output timestamp is derived from the input `AVAudioTime`, subsequent output timestamps advance only by emitted analyzer-rate frames, so discontinuous capture timestamps cannot create gaps inside one converter stream.

### Changed files

- `.superpowers/sdd/2026-08-12-apple-services/task-4-report.md`
- `CatRobot/Conversation/Services/SpeechAssetPreparer.swift`
- `CatRobot/Conversation/Services/SpeechAudioConverter.swift`
- `CatRobotTests/Conversation/Services/SpeechAssetPreparerTests.swift`
- `CatRobotTests/Conversation/Services/SpeechAudioConverterTests.swift`
- `CatRobot.xcodeproj/project.pbxproj`
- `CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`

### Remaining risks

- Simulator tests intentionally replace Speech asset inventory state with fakes. Japanese asset download/reservation and framework availability still require the connected-iPhone smoke test in the later composition/integration task.
- The converter is deliberately not internally synchronized. Task 5 must retain it behind its serialized capture owner, as required by the plan.

## Review fix round 1 — speech converter stream state

### RED

- Added three focused regressions before changing production code:
  - an invalid timestamp on the first resampled input permanently consumes the stream's single timeline-initialization attempt until flush;
  - a zero-frame resampling input cannot discard pending converter tail state;
  - a timestamp sample rate below `0.5`, which rounds to an invalid zero `CMTimeScale`, is omitted.
- The focused run failed as expected. The converter accepted a later timestamp after the first invalid one, invoked the backend for the empty input and lost the pending flush tail, and reached Speech's `AnalyzerInput` precondition with an invalid zero-timescale `CMTime`.

### GREEN

- Added a per-stream `timelineInitializationAttempted` flag. The first nonempty resampling input consumes the attempt whether its timestamp is valid or invalid; successful flush/reset clears it for the next stream.
- Zero-frame resampling input now returns immediately without calling the backend or mutating converter stream state.
- Centralized sample-rate-to-timescale validation and require the rounded value to be within `1...CMTimeScale.max`. The validated analyzer timescale is retained at initialization and used for output timeline advancement.

### Verification commands and results

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/SpeechAudioConverterTests test
```

Result: exit 0 / `** TEST SUCCEEDED **`; 12 tests passed, 0 failed.

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
```

Result: exit 0 / `** TEST SUCCEEDED **`; 56 tests passed, 0 failed.

The first full-suite attempt stopped before test execution when the sandbox lost its CoreSimulatorService connection (exit 70). Re-running with simulator access completed successfully with the result above.

```sh
git diff --check
```

Result: exit 0 with no diagnostics.
