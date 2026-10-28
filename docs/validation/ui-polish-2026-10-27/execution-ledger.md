# SDD ledger — plan: docs/superpowers/plans/2026-10-27-ui-polish.md

Pre-flight: Task 1 supplies hardware copy; Task 2 owns its calibration view and RobotPresentationTests copy. No shared file edits.
Baseline: 223 inputs match prior full suite (832 total, 830 passed, 2 attended-device skips, 0 failures), confirmed before this task.
Execution: User explicitly requested Claude/Codex pair implementation; existing settings define UI style. Plan records the requested work without another permission gate.

Task 1 RED: chips-red.log, 16 tests, 6 assertion failures due to absent listening chip and prior hardware copy. GREEN probe: 23/24 passed; existing typed-face height threshold assumed no listening row. Image confirms the new row uses 32pt and face is 172pt. Updated assertion measures row+face space and separation from editor; no layout change.

Task 1: complete (focused verification: ConversationViewStateTests 15 + RobotConnectionStatusTests 7 + new listening UI and typed-face UI 2 = 24 passed, 0 failed, in calibration-red.log; expected failures isolated to Task 2). Final whole-suite verification remains.
Task 2 RED: four new category tests fail because calibrationCategory identifiers are absent; old navigation test also fails old Stop label and confirmation dialog lookup, which requires follow-up after implementation. No model/product changes to calibration during RED.

Task 2: complete (calibration-fixed.log 9/9 passed; calibration-large-start.log 1/1 passed starting from accessibility5 settings; full suite follows).
Pair review: preserve existing typed-face allocation after chip visibility changes; editor stays fixed and normal face keeps its 85% frame. Strengthened typed-face test to check 100pt viewport growth gives 100pt face growth with no overlap. README uses hardware labels.
Validation fixes: explicit category selection on entry, stable VStack for navigation modifiers, nonduplicated Slider AX labels. Confirmation lookup failure also occurred before the new product implementation; its cause is not attributed solely to Group. Current unchanged-wait navigation tests pass. Added fixture cleanup on throw, not a production behavior change.

Final review: fresh independent gpt-6-astra review, Critical 0 / Important 0 / Minor 1. Full suite at f85f74e: 839 total, 837 passed, 2 attended-device skips, 0 failures. All 223 inputs match before, after, review, and committed objects.
Final: minor (deferred): Add listening + reconnecting + heat to the existing short-viewport multi-chip/editor case. Existing multi-chip and new single-listening coverage pass; no observed product defect.
Final: Ruling: Keep typed-input face allocation based on remaining space — the editor stays fixed, normal face retains its 85% frame, and the accepted design uses available height — cost if wrong: listening transitions may feel visually distracting.
Final: Ruling: Physical BLE, device persistence and stop timing remain outside this UI-only simulator verification — the underlying mechanisms are unchanged — cost if wrong: hardware-only regressions would need attended verification.
Final: Ruling: Real Japanese IME and spoken VoiceOver are not inferred from UIKit assertions — fixtures establish UI state and AX labels only — cost if wrong: device-specific interaction issues remain undetected.
Final: Ruling: Gesture/tool semantics containing 首 remain unchanged — the request concerns static user-facing hardware labels — cost if wrong: future wording expansion needs a separate semantic change.
Final: Ruling: Retain the existing landscape target without an iPad/portrait redesign — this is a refinement of the established layout — cost if wrong: unsupported layouts are not established by these fixtures.
Final: Ruling: Review adjacent settings/session integrations, not unrelated historical subsystem behavior — guards and session identity are covered here — cost if wrong: unrelated pre-existing issues remain outside this evidence.
Final visual record: seven complete rendered images inspected and retained. Several other hierarchy captures omit content, and confirmation capture is black; excluded from visual proof without asserting a rendering root cause. Corresponding geometry, navigation, confirmation and cancellation assertions passed.
Final disposition: keep feature/ui-reorganization and its existing host-managed worktree. No merge, push, installation, or physical commands. Archive this ledger with validation before removing only this plan's scratch directory.
