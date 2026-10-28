# Face Size Tuner final code review

Reviewed 2026-10-27. Base `1868b1e`, head `be3d780ba23b910371e74c4aaaf1527556f4342b`, worktree `/Users/goodapple/.codex/worktrees/b200/Cat_robot`.

## Strengths

- The independent application target compiles only the tuner, the three existing face rendering files, and rendering-harness enums. It has a separate `com.kamby.CatFaceSizeTuner` bundle ID, standard defaults in its own domain, no app-group entitlement, and no conversation/audio/Bluetooth dependencies. The reviewed diff changes no files under `CatRobot`, `CatRobotTests`, or `CatRobot.xcodeproj`.
- `FaceSizePreview.swift:10` uses the same safe-area-aware size and position formula as `ConversationView.swift:70`. The 0.85 initial/reset value therefore corresponds to the existing normal conversation layout. Controls are overlays and do not alter that geometry.
- `FaceSizeTuningModel.swift:18` funnels every change through finite-value handling, bounds, and 0.005 quantization. Display, copied decimal, persistence, and the rendered preview all consume that normalized value. No locale-dependent decimal separator is introduced into the value handed back to Codex.
- Tests cover persistence/reset, malformed numeric saved values, copied scale consistency, proportional rendered bounds for all ten expressions, and actual slider plus copy/reset/full-screen return actions at standard and accessibility5 text sizes. The supplied `controls.log` and `test-summary.json` report 5/5 passing without runtime warnings. All 14 input hashes in `source.json` match the reviewed files.
- The standard-size controls screenshot shows legible controls, and the full-screen hierarchy attachment shows an obvious return button. However, `attachments/5AA6C96F-2353-4B1F-B307-EAFB47AB0A5F.png` omits the entire face; its cause is not established. That image does not establish a stable rendered face across the transition. The executor is checking a full-window capture before handoff. Documentation clearly describes the separate-app/manual-value handoff.

## Issues

### Critical

None.

### Important

None.

### Minor

1. **The largest Dynamic Type setting makes the expression picker excessively tall.** `tools/face-size-tuner/Sources/FaceSizeTunerView.swift:49` through `:56`: the fallback changes button labels to icons but leaves the picker text sharing a constrained horizontal row. In `attachments/3C4DD19D-0EED-432A-B4E7-869B89D7ED7C.png` and `attachments/1A083945-4EFF-4BE2-BE8A-B6CF280C3492.png`, 聞き取り wraps one character per line into a large vertical capsule, and the toolbar crosses both eyes. This makes judging size while adjusting less convenient for someone using very large text. It is nonblocking because the controls remain operable and full-screen mode is available to hide them; confirmation of the rendered face in full-screen remains pending the executor's full-window capture. A compact expression-menu icon with an accessible label, or a dedicated accessibility-size arrangement, would improve this. If addressed, visually verify its largest-text screenshot; merely checking that control frames remain inside the host bounds does not catch this obstruction.

## Review focus disposition

- Initial value and 85% reset correspond to the main normal face layout: satisfied by matching formula and shared renderer, with successful reset evidence.
- Copied decimal matches preview scale: satisfied by one normalized source of truth and copy/action tests.
- Relaunch and malformed saved values recover to valid preview: satisfied by initialization normalization and persistence tests; wrong-type saved values also fall back through the optional cast.
- Toggling controls does not reposition the face and full-screen can return: overlay structure supports unchanged layout geometry, and action tests verify unchanged scale and successful return. Stable rendered face visibility was not established by the full-screen hierarchy attachment, which omits the face; the executor is checking a full-window capture before handoff.
- Separate distribution does not alter the main app size/data/hardware behavior: satisfied at the source/project level by separate bundle/defaults and absence of hardware code. Signed installation itself remains the executor's next step.

## Declined to judge

- Physical iPhone installation, provisioning, and actual device launch: not performed in this read-only review; device/build operations were explicitly excluded and are assigned to the executor after review.
- Matching the main app's typed-input, settings, error, or accessibility content-first layouts: the tuner intentionally targets the ordinary full-screen face layout; the README explicitly excludes typing/settings sizing and the design identifies normal conversation sizing.
- Live blinking, speaking mouth motion, and interaction with real conversation/audio/hardware: the tool intentionally renders static expressions with a closed mouth to choose a scale and contains no conversation or hardware control path. Those historical subsystems were not reviewed.

## Assessment

**Ready to proceed: Yes. Ready to merge from code-review perspective: Yes.** No Critical or Important issues found. The implementation meets the authorized separate-app value-selection workflow, with one optional accessibility layout refinement. Finish the pending full-window visual check, planned signed device installation, and handoff before claiming the overall delivery complete.

Review was read-only on the checkout: no source changes, git mutations, builds, test reruns, device operations, or subagents. `git diff --check 1868b1e be3d780` passed; worktree remained clean. Existing test evidence was inspected rather than independently rerun.
