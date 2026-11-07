# Independent whole-branch review — issue #28

Reviewed base `b59f0b9dc93d97ee79204e824961bafdd390cb19` through fixed head `07363aaae506ebe153b7580c7efbae7610e5ef46`, tree `35f35475071401f49cc1d5ca642e9cc770cf11d9`.

This is my first independent report. I did not read the Claude Navigator, simplify, or reception reports, dispatch reviewers, edit the checkout, or execute builds, tests, or device commands. The review used the supplied code-reviewer guidance, spec, plan, ledger rulings, readable diff, immediate production/test dependencies, author-maintained HTML, actual SVG manifest, and recorded verification evidence.

## Strengths

- `CatRobot/Vision/ConversationCamera.swift:57`: the sole production behavior change removes the exact-count gate while preserving eligibility, requested attention, current physical capture, authorization, freshness, and the existing selector. It adds no dependency or parallel selector implementation.
- `CatRobot/FaceTracking/FaceTrackingGeometry.swift:12`: validation and facing checks occur before ranking. A larger/nearer turned-away face, malformed geometry, nonfinite angles, or unknown head pose cannot win over or reject another eligible face. Correction and yaw/pitch bounds remain unchanged.
- `CatRobotTests/Conversation/Integration/FacingAddressingTests.swift:84`: literal multi-face observations pass through the real `ConversationCamera` and real conversation VM. Assertions check both zero classifier calls and the complete reply prompt. The cases include both face orders, two facing faces, a larger central turned-away face, the corrected yaw window, and malformed geometry beside a valid face.
- Freshness is explicitly exercised for multiple faces at 0.399/0.400 seconds (`FacingAddressingTests.swift:114`). The live-composition cases cover disconnected hardware, disabled tracking, and revocation after teardown (`:283`). Existing tests retain pending affirmative/negative precedence, filler handling, 30-second/300-second windows, lifecycle invalidation, old generations, heat/permission/interruption, and capture sharing. The unchanged generation admission and `clearAttention` lifecycle operate on the complete observation regardless of face count (`ConversationCamera.swift:187`, `:249`).
- README, FR-CONV-2, the new spec, and the superseded-spec note correctly explain the any-person criterion and absence of speaker identification. The restored HTML embeds six diagrams and requires no external executable resource; its address diagram, examples, and face notes otherwise match the new behavior.

## Issues

### Critical

None found.

### Important

None found.

### Minor

1. **The confirmation detail retains the old single-face condition.**
   - File: `docs/application-flow.html:45`, the “聞き返した後” → “別の発話” row.
   - It says `顔が1人・こちら向きなら返答。そうでなければ再判定…`. When a fresh unrelated question replaces pending clarification, multiple detected faces with at least one eligible facing face also bypass classification: `AddresseePolicy.swift:50` consumes the same newly broadened camera result.
   - Effect: readers can infer that confirmation follow-ups still require exactly one visible person, contradicting the new feature and adjacent notes. This is a documentation defect, not a production routing defect.
   - Fix: replace that condition with wording such as `有効でこちら向きの顔が1人以上なら返答。` while preserving the yes/no precedence and fallback description. Update the authoritative generation source if retained, and refresh the HTML digest/evidence mapping for the changed artifact. No app rebuild is justified by this text-only fix.

## Verification evidence inspected

- Confirmed checkout HEAD/tree equal the frozen candidate and observed a clean `git status --short`. `git diff --check b59f0b9..07363aa` reported no whitespace errors.
- Independently hashed the actual HTML as `40000a65dbe2357ab9efbf02bf14d4a8ef102c7c45af9d37ae77db99131c793f`; full/readable diff hashes match `review-source.json`. Every embedded SVG hash matches the supplied manifest, including the rendered “1人以上” address node.
- Read baseline/RED/focused/full receipts and the GREEN result summaries. They record baseline 54 pass, expected RED in the three expanded methods, focused 94 pass, and full 1,004 pass with zero failures/skips. GREEN build/focused/full receipts share input digest `4e99d6b42c5cf3684b7e1d02c9e74ee51f6504aa95490d88f9033973a4f8494f` and patch digest `c0adc6f415321c3f063a2289bde60b4c5244829cc7689b2235262261e68e87cc`; the ledger maps that input to this commit. The hardware/paid classes were explicitly excluded.
- Read the diagram verification receipt recording offline operation, six diagrams, navigation, keyboard, examples, zoom, print, mobile overflow, and no JS errors/external requests. Those are recorded browser observations, not my own browser execution.
- Confirmed that production changes are limited to `ConversationCamera.swift`; no native change requires a repeat native build. I did not personally rerun XCTest or verify physical two-person behavior.

## Recommendations

Correct the small confirmation-row wording before finalizing the HTML. Preserve the fixed tested app input and complete the already-planned signed preview, actual multi-person user confirmation, and final integration gates. No production change is requested by this review.

## Declined to judge

- Matching the speaking person to the facing person: explicitly excluded by the accepted any-person requirement; another person's speech being accepted is intended behavior, not a defect.
- Actual Vision behavior with two people, camera positioning, and normal signed-device operation: require the pending physical/integration gate; synthetic observations and simulator receipts do not establish physical acceptance.
- Unchanged speech, numeric pronunciation, history, and issue #27/#29 behavior, including unrelated restored map sections: outside this review's changed behavior and immediate boundaries; no judgment of those prior findings is implied.
- Correctness of the pair's other review opinions and final review reception: excluded to preserve independence of this first report.

## Assessment

**Ready to merge from code review: Yes, with one non-blocking documentation correction recommended.** No Critical or Important defect was found; the one-guard implementation meets the accepted behavior and preserves its immediate safety and ownership boundaries.

**Ready to complete integration now: No.** The normal signed preview and real multiple-person user confirmation remain pending, followed by the planned final-main/squash/device/push/issue checks. This review is not evidence that those gates have passed.
