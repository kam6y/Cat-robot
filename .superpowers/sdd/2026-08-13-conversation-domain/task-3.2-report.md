# Task 3.2 report — preserve wake fast paths

## Status

PASS. Focused tests produced the required missing-member RED, the bounded wake-name implementation made them GREEN, and all three conversation-domain suites passed.

## RED evidence

I added the `AddresseePolicyTests` coverage before changing production code, regenerated the project, and ran:

```sh
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AddresseePolicyTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

The first sandboxed attempt could not reach compilation because CoreSimulatorService was unavailable. I stopped that diagnostic attempt and reran the same focused test with simulator access. It exited 65 with `** TEST FAILED **`; Swift compilation reported `type 'AddresseeRoute' has no member 'wakeOnly'` at the new expectation. This was the intended feature-absent RED.

During self-review, I added a separate behavioral test for the requirement that classification preserve the full original transcript, including surrounding whitespace. Before changing production, that single test exited 65 and Xcode named `AddresseePolicyTests.testClassificationPreservesFullOriginalTranscript()` as the failing test. The existing implementation had returned its trimmed working copy, so this was the intended behavior RED.

## Implementation

- Added `AddresseeRoute.wakeOnly`.
- Kept separator-delimited wake names authoritative and removed only their leading separator run.
- Added exactly the documented nineteen conversational starters for undelimited ASR output.
- Preserved the unmodified remainder on accepted routes and the complete original utterance on classification fallback.
- Kept Latin-letter/digit suffixes and unlisted Japanese prefix collisions on classification.

The tests cover all four aliases as wake-only variants, all four aliases joined directly to `今日どう？`, every documented starter, the four named collisions, a Latin-digit collision, and existing empty/filler/punctuation behavior.

## GREEN evidence

After the minimal production change, I regenerated and reran the focused command above. It exited 0. After the self-review fix, the new single behavioral test also exited 0.

I then ran:

```sh
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/ConversationTypesTests -only-testing:CatRobotTests/UtteranceSegmenterTests -only-testing:CatRobotTests/AddresseePolicyTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

The final combined domain command exited 0; Xcode reported the test operation completed after 36.308 seconds.

## Debug notes

- The only infrastructure issue was the initial sandboxed CoreSimulator connection failure; rerunning with simulator access reached Swift compilation and supplied the genuine RED.
- The project generator produced no project-file diff because the changed Swift files were already registered.

## Self-review

- Removing `.wakeOnly`, any documented starter, or the explicit separator path causes focused tests to fail.
- The starter list is closed and literal; no heuristic or broad Japanese prefix acceptance was added.
- `Cat Robotics`, `Cat Robot2`, and the three Japanese collision examples retain their full input when classified; a separate test also preserves surrounding whitespace.
- Internal/trailing content punctuation remains untouched after only leading wake separators are dropped.
- `git diff --check` passed, and no generated or transient build files are part of the intended commit.

## Task-review documentation follow-up

The task review approved production code and identified a downstream orchestration ambiguity in the documents. I corrected documentation only:

- The design policy now orders explicit wake handling first, pending clarification second, and active engagement third, matching `AddresseePolicy` and the desired clarification UX.
- The integration plan requires every accepted route to consume pending clarification before acknowledgement or reply generation, rather than assigning that responsibility only to `.wakeOnly`.
- A concrete recovery-plan test now establishes an ambiguous pending utterance, supersedes it with explicit wake-plus-content, verifies a newly engaged unnamed follow-up remains classifier-free, and verifies the old pending utterance never resurfaces.
- Async values in the Task 2 and Task 3 XCTest examples are awaited into local variables before entering XCTest autoclosures.
- Task 3.2 now records that the coordinator, not the pure domain route, owns pending-state consumption.

No production or executable test file changed in this follow-up. Verification is `git diff --check` plus inspection of the documentation-only file list.
