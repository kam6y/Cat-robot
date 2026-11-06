# issue #22 — root technical reception and dispositions

Frozen reviewed implementation: e6cbe28ce2f44648fd6856d9ea030eeda11c54ff, base04c3de85. Both first reports were saved independently before exchange. Root read receiving-code-review before evaluating suggestions; source claims were checked against the actual code/old requirements and test receipts. Native focused reception is separate from its first report and revises the missed S1 wording judgment transparently. No second whole-branch review or extra cleanup agents were requested.

## Adopted and corrected

- Original requirements S1 was inadvertently changed from a binding 2.5-second criterion to an utterance-end target. Native reception correctly grades this Important; restored the exact base row, verified equality. No latency measurement or acceptance pass is claimed.
- Claude C3 / S9: README still described name presence as the classifier condition and its manual test omitted camera/facing/window expiry. Changed the rule to “それ以外の発話”, and manual steps to camera authorization, facing/name-free response, averted-head continuation within30s, then normal classification after30s. A response alone is explicitly not proof of bypass; internal trace is distinct.
- These are Markdown changes only. Code/test/project digest remains e9f1628fbeeff11ba440eb82746b35ef5dd598ed241c2422c997877b598661f2, matching the successful full996 receipt. No prose-mirroring tests or redundant unchanged full-suite run were added.

## Technical rulings

| Finding | Decision and reason | Retained cost / limit |
|---|---|---|
| C1/E1, C8/E2 | Keep listening-only attention demand. Stop/reconfigure/start counts are real; no latency/power regression was measured. Retaining through classifying needs separate capture/query demand and listening-entry invalidation; retaining through replies broadens camera use. This is a deliberate lifetime choice, not an established production defect. | Cold start and temporary lack of fresh evidence after each routed utterance without another owner; fallback classification remains. |
| C6/E3 | Keep one retry at a new listening owner, consistent with tracking/look ownership. It is not an immediate retry loop and enables recovery without opening settings. | Persistent capture failure incurs a bounded attempt per new utterance; backoff could be future measured optimization. |
| C9/R1/S4 | Keep short validation checks at each consumer. Tracking tolerance/floor/rejection differ from attention. Shared helper would add policy parameters or change another consumer. | Small duplicated guard chains; future changes must preserve both contracts. |
| C10/C11 | Keep explicit ownership, eligibility, live authorization and finite-value guards. Removing implied guards saves little and weakens the visible contract against future writers. | A few redundant constant-time checks. |
| C14 | Reject blanket removal of camera validation tables: consumer wiring/cache revocation can fail while leaf geometry tests still pass. | Some boundary cases overlap leaf tests. |
| C15 | Reject simple replacement by FaceAppHarness. Camera-without-tracking and tracking-without-camera exercise distinct permission-wait branches. | Some setup remains duplicated. |

## Deferred minor cleanup (no behavior change requested)

- C2: specialize the remaining clarification helper and remove its unused defaults/engagement arms; preserve neutral-memory and clarification-mouth behavior if refactored later.
- C4/A3: explain in settings labels/footer that yaw correction also applies to facing without hardware. Control remains present; this is discoverability, not absent functionality.
- C5/S6: rename/fold the former wake-parser-oriented domain test.
- C7/R2/R4/S8 and C13/S7: share or relocate test harnesses/policy cases and prune overlapping scenarios while preserving owner conditions.
- C12/S5/A1: remove the currently unused optional facing closure from the test harness; do not invent a test to justify it.
- C16/A2: mention attention in the environment comment or move the one listening predicate; a new abstraction is optional.
- C17: shorten repeated prose with links while retaining required spec/plan constraints.

These minor polish suggestions were not included in the important-fix pass. No production or test code changed after frozen verification.

## Explicit rulings on native declined scope

- Hardware pose accuracy across lighting/glasses/distance is not established by host tests. Signed app installation and normal process launch were verified, and the user answered “質問への返答があった” after the face-facing/name-free question. This is a speech/response sanity check, not measured angle accuracy or proof of the internal route. Cost: environmental recognition limits remain unmeasured.
- End-to-end latency, first-frame startup, power and24-hour endurance targets were not measured and are not claimed as passing. Original S1 remains binding. Cost: these performance targets remain separate physical acceptance work.
- Pupil gaze and voice-to-visible-person association are excluded capabilities: user says head direction is sufficient; raw multiple detections fall back. Cost: one visible face does not identify who spoke off camera.
- No comprehensive re-audit of inherited memory/SmartTurn/audio/motion/network functionality was added; touched integration paths and the full996 suite were checked. Cost: unrelated inherited defects are not newly ruled out.

The ledger also records the procedural ruling: full-suite task-done runs before the source commit, then exact digest and commit mapping are appended. This avoids a duplicate unchanged full-suite run; the base..base initial ledger entry needs that explicit mapping (which is present).

## Remaining completion steps

Claude reciprocal reception is saved as claude-reception.md, agrees with doc fixes and deliberate tradeoffs, retracts the equivalent permission-fixture claim and narrows duplicate-geometry claims. The request to document restarts even for rejected utterances and define both digest scopes was adopted. Indicator flicker and cold-start performance remain unobserved; an extra hardware scenario is deferred rather than reported as measured. Root will include this record without a new review cascade, record final source identity, squash one commit into fresh main, normal-build/install/launch that main revision, then non-force push and verify remote hash / issue closure. No integration completion is asserted by this reception document.
