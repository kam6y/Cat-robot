# Task 1 report — Foundation Models availability and failure mapping

## Status

PASS. Tests were written and observed failing for the missing Task 1 types before production code was added. The focused suites and the full existing simulator suite pass after the minimal implementation.

## RED evidence

After adding only the two specified test files and regenerating the project, this command exited 65 with `** TEST FAILED **`:

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests -only-testing:CatRobotTests/FoundationModelErrorMapperTests test
```

The compiler reported the expected missing Task 1 API, including:

- `Cannot find type 'FoundationModelAvailabilitySnapshot' in scope`
- `Cannot find 'FoundationModelAvailabilityService' in scope`
- `Cannot find type 'FoundationModelFailureKind' in scope`
- `Cannot find 'FoundationModelErrorMapper' in scope`

This was a genuine feature-missing RED; CoreSimulator reached the build and did not block compilation.

## Installed SDK contract checked

The implementation was checked against the installed iOS 26.5 `FoundationModels.swiftinterface` before production code was written. It confirms:

- `SystemLanguageModel.supportsLocale(_:)` and the three current unavailable reasons.
- Nonfrozen `SystemLanguageModel.Availability.UnavailableReason`, requiring `@unknown default`.
- All nine current `LanguageModelSession.GenerationError` cases: context exceeded, assets unavailable, guardrail violation, unsupported guide, unsupported language or locale, decoding failure, rate limiting, concurrent requests, and refusal.
- Nonfrozen `GenerationError`, requiring `@unknown default`.

No installed-SDK signature mismatch was encountered.

## Implementation

- Added an injectable, `Sendable` availability snapshot seam so tests do not initialize or call a live system model.
- Added the production `SystemLanguageModel` availability adapter for the Japanese locale.
- Added a pure `FoundationModelFailureKind` mapper used by tests and by the real `GenerationError` overload.
- Mapped cancellation before model errors and conservatively mapped unknown/non-model failures to `.modelGenerationFailed`.
- Pattern-matched every installed generation error case without reading or returning `Context.debugDescription` or refusal details.

## GREEN evidence

The focused command above exited 0 with `** TEST SUCCEEDED **`:

```text
FoundationModelAvailabilityServiceTests: 1 test, 0 failures
FoundationModelErrorMapperTests: 2 tests, 0 failures
Selected tests: 3 tests, 0 failures
```

The full existing suite was then run with:

```sh
xcodebuild -quiet -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
```

It exited 0. `git diff --check` also exited 0 with no output.

The project-generator regression suite also exited 0 with `PASS: deterministic CatRobot project contract`:

```sh
ruby scripts/test_generate_project.rb
```

## Files

- Added `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`.
- Added `CatRobot/Conversation/Services/FoundationModelErrorMapper.swift`.
- Added `CatRobotTests/Conversation/Services/FoundationModelAvailabilityServiceTests.swift`.
- Added `CatRobotTests/Conversation/Services/FoundationModelErrorMapperTests.swift`.
- Regenerated `CatRobot.xcodeproj` and its shared scheme so the new recursive source files use the generator's deterministic target identifiers.

## Self-review

- The availability test catches an incorrect mapping for each supported snapshot reason and catches locale support being ignored.
- The pure mapper test catches every failure-kind branch; cancellation has a separate regression test.
- No live Foundation Models request is made in unit tests.
- The adapter and its closure remain `Sendable` under complete Swift 6 concurrency checking.
- Scope is limited to Task 1 files, generated project metadata, and this report; domain types and plans are unchanged.
