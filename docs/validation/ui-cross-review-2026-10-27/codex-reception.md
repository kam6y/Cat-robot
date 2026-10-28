# Codex receiving-code-review

Reviewed the complete Claude report against the fixed implementation, call sites, prior layout, and the new regression evidence. Production code is still unchanged at this reception point.

| ID | Decision | Verification / reason |
|---|---|---|
| R1 / C1 | Accept as one Important issue | Both branches construct `TypedInputView`. The real SwiftUI fixture fails 12 assertions over error appearance/removal and memory `.ready` → `.unsaved` → `.ready`: editor identity changes and selection [2,4] becomes [7,7]. Keep one editor under the conditional upper region. A separate Send/focus probe is running. Claude C1 is corroboration, not an independent discovery. |
| C2 | Accept in part | Reuse the overlaid menu view and name its size, trailing inset and chip gap so both chip clearances derive from the same dimensions. Keep the two common scroll modifiers inline: creating a generic ViewModifier for two calls adds indirection without a distinct concept. Preserve the existing layout and keep outer modifiers structurally stable while fixing R1. |
| C3 | Accept | `rg` confirms four projections have no production readers. Remove them; replace obsolete look-caption assertions with visible chip assertions and the sleeping-caption assertion with `accessibleReply == nil`. Retain raw caption/transcript/status storage and `displayedActivityStatus`, which the announcement policy still consumes. |
| C4 | Accept | `assistantStatus` is read only by one obsolete assertion. The active announcement policy reads view-state activity and does not depend on it. Remove the dead property/assignments and keep microphone/announcement tests. |
| C5 | Accept | Both active consumers use the same reconnect wording. Reuse the existing message without conflating their different visibility conditions. |
| C6 | Decline | The current custom header is part of the adopted compact layout, both current destinations explicitly restore their toolbar, and navigation tests pass. A hypothetical future destination is insufficient reason to alter the approved appearance. |
| T1 | Accept | The recursive scroll search and rightmost-detail selection are exact duplicates in two UI suites. Move these small helpers to their existing shared XCTest support; preserve traversal order and behavior. |
| T2 | Accept in part | Return the scale-1 image from the existing rendering helper and reuse it in capture/pixel measurement. Do not additionally restructure the capture-to-column-measurement data flow; that separate optimization is unnecessary here. |
| T3 | Decline | The settings overview fixture owns camera/tracking, populated memory, and its own teardown; calibration deliberately supplies only robot dependencies. Sharing the whole fixture requires optional modes and changes ownership for one caller, making this less simple. |
| T4 | Defer | The wait precedes evaluation of the current detail scroll view so navigation can finish before choosing it. Replacing the readiness wait with an arbitrary 300ms changes that contract and may scroll a stale pane. This is test runtime, not a production hot path; keep the existing deadline until an actual readiness condition is established. |
| T5 | Defer | Measured safe-area availability is not proof that SwiftUI's accessibility tree and drawing have settled. Existing fixture work encountered stale accessibility data. A safe replacement needs a separate readiness study; no blanket reduction of waits in this cleanup. |
| T6 | Record, no change | Private AX setup is confined to test support. Activation failures already report the runtime string, including `unavailable`; replacing the harness or changing failures to skips would broaden scope and could conceal missing coverage. |

## Codex review's declined-to-judge items

- Physical microphone/camera/BLE, actual VoiceOver speech, and physical-device keyboard behavior remain unverified; no device operation is part of this review task.
- Calibration across the Dynamic Type threshold was investigated instead of dropped. The added navigation check passes for `.large` → `.accessibility5` → `.large`, retaining the same calibration session and two-controller navigation stack with Stop and Back present. The maximum-size screenshot was visually inspected. Keep this coverage; no product fix is indicated by the evidence.
- Newest-only snapshot buffering can theoretically omit a very brief connection, but neither review identified an affected sequence. Do not change the BLE stream or move history ownership without a reproducible requirement.
- Unchanged face animation, conversation engine, and BLE algorithms remain outside the UI change; their integration boundaries were reviewed.

Custom-Back confirmation coverage was initially optional; the follow-up below exercises it to resolve the control-label question.

All accepted edits and validation are owned by Codex to avoid competing worktree mutations. Re-run the new editor regressions, affected presentation/accessibility/look/inactivity tests, and the full suite after the accepted cleanup.

## Follow-up reception and verification

- Claude accepted the dispositions above. Its Dynamic Type editor-boundary example was withdrawn from R1: `TypedInputView` already switched its internal field between standard and accessibility layouts before this feature.
- The Send probe also reproduced R1: the new field regained first responder and restored the old draft after the callback cleared it. After the single-editor fix, all five targeted editor/layout tests pass, including the complete 12 + 3 regression assertions (`r1-green.log`, result bundle `20-59-29`). The error/memory and post-Send screenshots were visually inspected.
- Claude questioned whether the D2 probe's short labels matched the intended app controls. The earlier D2 PASS is therefore evidence only for session/navigation/display persistence until the matching elements and guarded Back action are identified. A follow-up probe uses an actual window scene and dirty calibration, records both title/custom-label elements, and activates Back → confirmation → cancel. No calibration product change has been made.

## Final disposition

- D2 is resolved. `calibration-controls-navigation.log` establishes that the short-label element is a descendant of the app's custom Back control. The final test uses app labels, locates the real confirmation controller within the navigation hierarchy, and dismisses the popover with the public accessibility escape action. Both text sizes preserve calibration and navigation after cancellation. `calibration-controls-escape.log` passes, and the same test passes in the final full suite. No calibration product fix is needed.
- The isolated confirmation-dialog image rendered black and is excluded from curated visual evidence. Actual activation, controller/window presence, dismissal, and model/navigation assertions establish the behavior; a visual inspection of the dialog itself is not claimed.
- Accepted cleanup C2/C3/C4/C5/T1/T2 is applied, within the limits above. Claude inspected the final diff and accepted it without further findings.
- Final full suite: 832 total, 830 passed, 2 attended-device tests skipped, 0 failed. All 223 recorded source/project/dependency/orientation inputs match before and after execution. Source commit: `94eef6308f73cdda8932a71819700402b17ed9a9`.
- No unresolved Critical or Important finding remains. T4/T5 remain deferred test-performance work, and the stated physical-device and reverse calibration navigation paths remain unverified.
