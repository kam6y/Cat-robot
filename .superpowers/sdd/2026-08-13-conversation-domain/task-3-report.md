# Task 3 report — engagement and conversational addressee policy

## Status

PASS. The specified missing-type RED, focused GREEN, expanded requirement RED/GREEN, and all-domain verification were observed on the requested iOS Simulator.

## RED evidence

After adding exactly the three planned tests and regenerating the project, I ran:

```sh
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AddresseePolicyTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

The command exited 65 with `** TEST FAILED **`. Swift compilation reported `cannot find 'AddresseePolicy' in scope`, `cannot find 'EngagementWindow' in scope`, and `cannot find 'PendingClarification' in scope`. This is the intended feature-absent RED.

After the three planned tests became green, I added focused tests for the remaining written interface and policy requirements. Their first run exited 65 because `EngagementWindow.clear()` and the 15-second pending initializer did not exist. Adding only those APIs exposed the remaining behavior RED: all wake names, filler rejection, Japanese yes/no sets, pending-confirmation routing, and pending expiry failed until implemented.

## Implementation

Added two Foundation-only value-type files:

- `EngagementWindow` records the arm timestamp and 30-second soft expiry. Reply refresh moves only the soft expiry; activity remains capped by the original 300-second hard expiry. `clear()` resets both values.
- `PendingClarification` trims its one in-memory utterance and supports either an explicit expiry or a 15-second expiry derived from its creation timestamp.
- `AddresseePolicy` trims input, ignores empty/filler speech, recognizes all four leading wake names, performs case-insensitive matching for `Cat Robot`, and strips only the leading address plus separators.
- An unexpired pending clarification accepts short Japanese affirmatives, ignores short negatives, and otherwise preserves the original through `.confirmPending`. Expired pending state falls through.
- Active engagement accepts immediately; otherwise routing requests classification.

An address consisting only of a wake name routes to `.ignore`. Accepting it would send an empty utterance toward reply generation, adding latency without conversational content; ignoring it is consistent with the policy's empty-speech rule. The next substantive addressed utterance still uses the normal wake fast path.

## Debugging note

The first implementation run revealed one test failure: `猫ちゃん、今日どう？` produced `今日どう` instead of `今日どう？`. The xcresult failure message showed that trimming a punctuation character set from the whole remainder removed meaningful trailing punctuation. The implementation now drops separator characters only from the beginning of the post-wake remainder and preserves the rest verbatim.

## GREEN evidence

The focused suite, including the planned and requirement-focused tests, exited 0 after project regeneration:

```sh
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AddresseePolicyTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

I then ran the three domain suites together:

```sh
xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/ConversationTypesTests -only-testing:CatRobotTests/UtteranceSegmenterTests -only-testing:CatRobotTests/AddresseePolicyTests -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
```

The all-domain command exited 0; Xcode reported the test operation completed after 54.170 seconds.

## Files and self-review

- Added `CatRobot/Conversation/Domain/EngagementWindow.swift`.
- Added `CatRobot/Conversation/Domain/AddresseePolicy.swift`.
- Added `CatRobotTests/Conversation/Domain/AddresseePolicyTests.swift`.
- Regenerated `CatRobot.xcodeproj` to register the production and test files.

The tests protect the 30/300/15-second boundaries, clear behavior, hard-expiry immutability under refresh, all wake-name paths, leading-only address matching, case-insensitive Latin matching, filler handling, pending yes/no/other ordering, pending expiry, active fast path, and classifier fallback. The implementation imports only Foundation and does not modify earlier domain implementations. `git diff --check` is clean. No Task 3 implementation concern remains.

## Task-review fixes

The task reviewer identified two noise/collision paths. Each fix received its own focused RED/GREEN cycle before the aggregate reruns:

1. I added `testPunctuationOnlyNoiseIsIgnored` for `…`, `、`, and `。。。`. Its first focused run exited 65 with three assertion failures. Routing now requires the normalized token (input without surrounding whitespace/punctuation) to be nonempty. The same focused test then exited 0 after 39.181 seconds.
2. I expanded the wake collision test to cover concatenated continuations after every configured wake name: `ねこまんま`, `猫ちゃんねる`, `Cat Robotics`, and `キャットロボット工房`. The first focused run exited 65 with three failures; the existing Latin check already rejected its collision. Wake matching now requires the match to end the utterance or be followed by a separator for every wake name. Valid separator-prefixed cases remain covered by `testAllWakeNamesUseLeadingFastPath`. The collision test then exited 0 after 68.868 seconds.

The engagement timing test also now asserts that the original hard expiry is inactive at exactly 300 seconds after arming, even when the soft expiry was refreshed.

Fresh post-review verification after regenerating the project:

- The complete `AddresseePolicyTests` suite exited 0 after 46.727 seconds.
- The combined `ConversationTypesTests`, `UtteranceSegmenterTests`, and `AddresseePolicyTests` command exited 0 after 46.813 seconds.
