# Task 2 report — Fresh guided-generation addressee classifier

## Status

PASS. Tests were added first and observed failing for the missing Task 2 types. The focused classifier suite and the full existing simulator suite pass with the minimal implementation.

## RED evidence

After adding only `FoundationModelAddressClassifierTests.swift` and regenerating the project, this command exited 65 with `** TEST FAILED **`:

```sh
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelAddressClassifierTests test
```

The compiler reported the expected missing Task 2 API:

- `Cannot find type 'AddressModelClient' in scope`
- `Cannot find type 'GeneratedAddressTarget' in scope`

This was a genuine feature-missing RED; the simulator reached test-target compilation.

## Installed SDK contract checked

The production implementation was checked against the installed iOS 26.5 `FoundationModels.swiftinterface` before it was written. The interface confirms:

- `SystemLanguageModel(useCase:guardrails:)` supports `.contentTagging` and `.default` guardrails.
- `LanguageModelSession(model:instructions:)` accepts an instructions builder.
- Guided `respond(to:generating:options:)` returns the generated content.
- `GenerationOptions` accepts `.greedy` sampling and an explicit temperature.
- `@Generable` and `@Guide(description:)` match the installed macro signatures.

## Implementation

- Added `FoundationModelAddressClassifier`, which forwards each utterance unchanged to an injected `AddressModelClient`, maps every generated target to the domain target, and maps thrown framework failures through `FoundationModelErrorMapper`.
- Added a stateless live client that constructs a `.contentTagging` `SystemLanguageModel` with default guardrails and a new `LanguageModelSession` inside every classification call.
- Added guided `@Generable` output restricted to addressed, ambiguous, or not-addressed.
- Used deterministic `GenerationOptions(sampling: .greedy, temperature: 0)`.
- The live classifier retains no prompt, transcript, prior decision, or reply-generation session.
- Unit tests use an actor-isolated fake and never call the live model.

## GREEN evidence

The focused command above exited 0 with `** TEST SUCCEEDED **`:

```text
FoundationModelAddressClassifierTests: 2 tests, 0 failures
Selected tests: 2 tests, 0 failures
```

The full existing simulator suite then exited 0:

```sh
xcodebuild -quiet -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
```

The project-generator regression suite also exited 0 with `PASS: deterministic CatRobot project contract`:

```sh
ruby scripts/test_generate_project.rb
```

`git diff --cached --check` exited 0 with no output after staging the exact Task 2 file set.

## Files

- Added `CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift`.
- Added `CatRobotTests/Conversation/Services/FoundationModelAddressClassifierTests.swift`.
- Regenerated `CatRobot.xcodeproj` so both recursive source files are included and the shared scheme references the regenerated target identifiers.

## Self-review

- Mutating any generated-target mapping breaks the three-output assertions.
- Dropping, duplicating, reordering, or rewriting a client request breaks the literal prompt list or request-count assertion.
- Removing Task 1 error mapping breaks the real `GenerationError.guardrailViolation` assertion.
- Swift 6 complete-concurrency checking compiles the actor fake and the `Sendable` service seam without isolation weakening.
- The production client creates model/session state only in the method-local scope and cannot contaminate the stateful reply session.
- Scope is limited to Task 2 source/test files, generated project metadata, and this report.
