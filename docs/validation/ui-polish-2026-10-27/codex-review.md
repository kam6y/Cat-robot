# Final code review — UI polish

Reviewed baseline `1d9e1d0` through the frozen working tree in `/Users/goodapple/.codex/worktrees/b200/Cat_robot`, including `b3250e7` and calibration changes subsequently committed unchanged as `f85f74e` (final range `1d9e1d0..f85f74e`, per executor confirmation). Read the combined diff, current conversation/calibration/settings integration, spec, plan, and ledger. Verified all 223 source hashes match `review-source.json`; `git diff --check 1d9e1d0` is clean. No checkout changes, builds, hardware operations, or delegated reviews were performed.

## Strengths

- `ConversationViewState.swift:84–100` derives the listening chip from phase, inactivity, and blocking memory state. There is no parallel visibility state to leave stale after speaking, pausing, failing, or sleeping. The shared chip renderer keeps its existing menu clearance and stable identifiers.
- `RobotCalibrationView.swift:30–80` retains one externally owned session and persistent category state across the standard/accessibility branches. Category changes do not begin or close calibration. The custom accessibility-detail Back returns only to the category list; the root exit still uses the existing confirmation and model close path.
- `RobotCalibrationView.swift:185–260` preserves session bindings, canEdit conditions, restore/save actions, and Stop. Parent settings still disable Done and interactive dismissal while calibration exists. The model and BLE protocol behavior are unchanged.
- Calibration tests exercise actual SwiftUI navigation and rendered controls, including category/draft identity, text-size transitions, confirmation cancellation, large-text detail navigation, and longest disconnected status text. I inspected rendered standard calibration, xxxLarge disconnected calibration, AX5 detail, and listening-plus-editor screenshots; their controls and content hierarchy match the intended design.
- User-facing static copy is consistently changed to ハード across connection, settings, permission strings, calibration, and accessibility labels.

## Critical

None found.

## Important

None found.

## Minor

1. **The new listening chip is not included in the multi-chip/editor layout regression case.** `CatRobotTests/Face/FaceConversationPresentationTests.swift:237` still exercises paused/reconnecting/heat chips, while the new typed listening test at line 275 uses listening alone. The trigger to cover is listening with reconnecting and heat warnings (and looking if that combination is intentionally supported) while typed input is open in a short viewport. This is a narrow coverage gap, not an observed product defect: all chips use the same layout, and existing multi-chip and new single-listening coverage provide substantial protection. Optionally parameterize the existing short-viewport case to include the listening combination, retaining menu/editor non-overlap assertions. It is not a merge blocker.

## Declined to judge

- Physical BLE motion, calibration persistence on the device, and emergency-stop timing: no hardware operations were authorized for this review; implementation leaves those mechanisms unchanged, and simulator fake transport cannot establish physical behavior.
- Manual Japanese keyboard composition/selection behavior: explicitly excluded by the spec; existing UIKit fixture coverage does not establish real IME behavior.
- Model-tool descriptions and natural-language gesture names containing 首: explicitly outside the static UI vocabulary change; no request to change model tool semantics.
- iPad/portrait-specific redesign: the surrounding design scope excludes iPad and targets the app's landscape presentation; no supported-layout defect was observed here.
- Permanently reserving listening-chip height in typed-input mode: considered and declined as a defect. The accepted spec explicitly gives the face the space remaining after chip/editor layout. The screenshot and revised growth/separation assertions are consistent with that contract; a different allocation is a design preference.
- Unrelated historical settings/model/session behaviors: only their integration with the changed views and preservation of existing guards were reviewed, not a new audit of those systems.

## Validation and readiness

`calibration-fixed.log` records the focused successful run; `calibration-large-start.log` now records the new direct-AX5 settings → robot → calibration → detail test passing (1 test, 0 failures, TEST SUCCEEDED). The source hash check confirms the reviewed frozen files. The full suite result is still pending at this review cutoff; I did not run or claim it passed.

**Ready to merge? Yes from code review, conditional on the planned full-suite validation passing for this source set and completion of its validation record.** No Critical or Important defect was found. The optional minor coverage improvement should not delay completion by itself.
