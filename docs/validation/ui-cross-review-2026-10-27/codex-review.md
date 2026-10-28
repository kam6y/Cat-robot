# Independent correctness review

Scope: `9ee8dacbe31e2bc3295eaa8f623049cc771bfb64` → `90e98c2f011c027eeb88f2d6f29d080411515cb7`, branch `feature/ui-reorganization`. Read the design, plan, changed implementation/tests, and surrounding startup, capture-failure, memory, robot, and accessibility flows. Checkout remained read-only. No builds, simulator/device actions, or other review reports were used.

## Strengths

- Presentation decisions are centralized in `ConversationViewState`; pause intent and reconnection history are explicit, narrowly scoped state. Tests cover user versus system pauses, audio interruptions, typed turns during pause, sleeping suppression, failed initial connections, retry latching, and device changes.
- Returning launch reuses the existing lifecycle path. Tests exercise persisted completion, first active, denied microphone access, permission-prompt inactive/active transitions, repeated active notifications, and normal background recovery.
- The UI checks go beyond screenshot creation: they inspect actual accessibility custom content, safe-area geometry, category navigation, onboarding review dismissal, the full-width calibration destination, and the active editor's identity/caret during viewport changes.
- Generated-project inspection found all 112 app and 106 test Swift sources included, with no missing or extra entries. After normalizing generated IDs, project changes consist only of the six new source references/build entries. All 223 recorded validation-input hashes match the reviewed checkout. The recorded full suite reports 828 passed, 2 skipped, and 0 failed; I did not rerun it.

## Issues

### Critical

None found.

### Important

**R1 — Error and memory-card transitions recreate an active text editor.**

- **Location:** `CatRobot/Conversation/UI/ConversationView.swift:56` (branch selection), `:96` and `:141` (separate editor instances).
- **Trigger:** At a standard Dynamic Type size, open “文字で話しかける” while listening, place the caret inside a draft, and let the active recognizer fail. Opening the editor only sets `showsTypedInput` (`ConversationViewModel.swift:209`), so capture remains active. `captureFailed` publishes an error (`:1240`, `:1324`), making `prioritizesContent` change from false to true. A memory warning appearing or being cleared crosses the same boundary.
- **Impact:** The input moves from `typedLayout` to the structurally distinct `contentFirstLayout`, destroying the existing `TypedInputView` and its UIKit text input. The bound draft survives, but selection/caret state does not; ongoing composition can be disrupted. The new input also runs its autofocus task again (`TypedInputView.swift:65`). In the reverse direction, submitting from an error recovery screen clears the error during `transition(to: .preparing)`, recreates the input, and can refocus it immediately after Send dismissed focus.
- **Evidence:** Both layout branches contain their own `typedInput(...)`. Before this change, the editor was outside the `prioritizesContent` branch in the common `verticalBody`. Existing `ConversationRecoveryTests.testCaptureStreamFailureStopsServicesAndDeactivatesAudio` (`:881`) covers the asynchronous failure route. The new `testTypedEditorKeepsItsIdentityWhenViewportAndWarningsChange` (`FaceConversationPresentationTests.swift:293`) changes height and status-chip booleans, but never `errorMessage` or `memoryState`, so it cannot catch this regression. This is a structural code finding, not a newly executed UI reproduction.
- **Minimal fix:** Keep one editor at a common, stable structural location beneath the changing upper content, including the card layout. Extend the current identity/caret test with error appearance/removal and `.ready` ↔ `.unsaved` transitions. Also verify that clearing an error on Send does not autofocus a replacement editor. Coverage priority: 7/10.

### Minor

None requiring a separate finding.

## Recommendations

- Fix R1 and use the existing UIKit text-input identity helper to prove the same editor, selection, and draft survive card transitions. The failure-path integration tests can remain focused on service cleanup.
- For navigation regression coverage, an additional user-driven calibration test should invoke the custom Back control after a draft change, verify the confirmation, and verify that cancelling keeps calibration active. The current new navigation test closes through `model.closeCalibration(.restore)` directly; the underlying confirmation logic is unchanged, so this is an optional improvement rather than a separate defect.

## Declined to judge

- Physical microphone/camera/BLE combinations, actual VoiceOver speech, and software-keyboard behavior on the installed device: not exercised by this read-only review; the validation record explicitly leaves these unverified. Static accessibility and layout coverage is not a hardware sign-off.
- Changing Dynamic Type across the accessibility threshold while calibration is already pushed: the destination host lives in a conditionally rendered pane, but the resulting SwiftUI navigation reconciliation was not established by the inspected tests. I am not classifying an unverified navigation outcome as a defect.
- Missing an extremely brief connected state through the link's newest-only update stream: inspected as a potential limitation of historical reconnect presentation, but no concrete affected application sequence was established; no finding asserted.
- Existing face-animation, conversation-engine, and BLE protocol algorithms: unchanged and explicitly outside this UI feature; their affected integration boundaries were reviewed.

## Ready to merge: With fixes

The implementation closely follows the adopted design and has substantial behavioral and UI evidence. R1 regresses active editing across normal asynchronous error/memory updates and should be fixed before merging; no Critical issue was found.
