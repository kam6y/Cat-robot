# Independent Senior Code Review — issue #22

Review range: `04c3de85e9030135f261099c9055be56834f5626..e6cbe28ce2f44648fd6856d9ea030eeda11c54ff`.

This is the first independent report, saved before reading any Claude report. I reviewed the actual whole-branch git diff, current surrounding source, new and migrated tests, the design, plan, ledger, validation document, and supplied verification receipts. I used the `superpowers:requesting-code-review/code-reviewer.md` template. No subagents, builds, simulator/device activity, audio, network/paid APIs, or checkout mutations were performed.

### Strengths

- The implementation directly replaces the name fast path instead of layering another bypass over it. `AddresseePolicy.swift:33` removes name stripping and `wakeOnly`; both classification and reply generation now receive the complete utterance (apart from normal surrounding-whitespace trimming).
- Confirmation ordering is correct: filler/empty input is ignored, then a live pending affirmative uses the original utterance and a negative dismisses it, before fresh facing can accept a new question. `AddresseePolicy.swift:43` and the integration cases demonstrate that a facing negative is not turned into an answer request.
- The attention decision is separate from robot connection and tracking preferences. `ConversationComposition.swift:89` reads the camera directly with the current yaw correction. `ConversationCamera.swift:56` requires current listening ownership, valid authorization, an active physical generation, fresh capture time, and exactly one raw detection. Existing geometry supplies finite, bounded head yaw/pitch checks; no pupil inference or extra model is introduced.
- The camera keeps one event subscription. Observations update attention and are still forwarded with the tracking consumer's generation. The three demands are reconciled together, so stopping tracking or leaving listening does not stop an outstanding look request (`ConversationCamera.swift:176`, `:246`).
- Cache lifetime is conservative. Leaving listening clears it even if tracking holds the same physical session. The listening start timestamp rejects a delayed pre-resume frame, generation guards reject an old physical run, and latest captured time prevents a late older frontal frame from replacing newer no-face/turned-face evidence (`ConversationCamera.swift:87`, `:188`, `:199`).
- The permission extension preserves the existing start-owner protocol and only requests camera permission after voice preflight. Both camera and tracking permission waits are included in the inactive/foreground guard (`ConversationAppCoordinator.swift:54`, `:154`, `:183`, `:235`).
- Tests assert behavior: negative classifier bypass, full transcript preservation, no local name-only acknowledgement, 30-second continuation and 300-second hard deadline, pending negatives, stale and reordered observations, lifecycle invalidation, shared ownership, original tracking delivery, standalone permission, and live composition without hardware. Migrated transcript and look-start counts reflect intended changes rather than masking production failures.

### Issues

#### Critical (Must Fix)

None. Count: **0**.

#### Important (Should Fix)

None. Count: **0**.

#### Minor (Nice to Have)

None identified as an actionable defect. Count: **0**.

### Requirements and boundary assessment

- **Routing-time freshness:** `beginClosingCapture` awaits recognizer stop and its consumer without transitioning out of listening. `performTurn` reads fresh attention only after those waits (`ConversationViewModel.swift:892`, `:912`, `:959`). It transitions to classifying/thinking only after making that decision. Thus camera attention is not necessarily stale merely because speech finalization is slow, and old observations still fail the query if no new frame arrives. The decision is synchronous on MainActor, so the environment cannot change between the query and policy evaluation.
- **Turning away after speaking:** Latest valid no-face/turned-face observations revoke facing. The implementation intentionally evaluates current orientation rather than retaining a historical facing vote. This may send that turn through normal classification, but is a documented conservative choice, not a lost-response guarantee or an implementation departure.
- **Permission ordering and foreground ownership:** Inactive during camera permission clears camera eligibility while retaining the active start. Foreground before result does not duplicate the start. Background/settings cancels the start, and completion of the old permission wait invokes resume only if the current foreground state is eligible. Tracking-enabled and absent paths share these ownership checks; denial does not fail conversation.
- **Shared ownership and failure:** Listening is a demand independent of tracking/look. Heat, failed/interrupted capture, invalid environment, lost authorization, and shutdown stop the physical session and clear evidence. Capture failure falls back to classification; the next new listening demand can retry. Ending one owner does not revoke another owner's capture.
- **Ordering and malformed observations:** Empty, multiple, turned, and malformed pose frames cannot grant attention. Invalid timestamps clear usable attention; retained ordering state and the start-time/generation checks block previously accepted older frames. A malformed timestamp is not treated as trusted chronology. The production worker emits observations serially from a single queue.
- **Engagement:** The unchanged engagement model retains the 30-second soft and 300-second hard windows. Fresh facing re-arms the hard deadline like the removed explicit wake; a follow-up accepted only through engagement refreshes the soft deadline. The new tests distinguish these cases. Expired confirmation is cleared before routing.
- **Privacy and integration:** Attention stores only face metadata. The existing explicit look pipeline remains the image-producing path. Camera purpose copy now explains the additional local use. Thermal updates and live coordinator/camera wiring are present.
- **Project churn:** I read the generated project/scheme changes at the semantic level and the supplied semantic check. New test membership is the intended addition. UUID regeneration alone is not a defect.
- **Plan deviations:** The ledger's full-suite-before-source-commit ruling is adequately bound by the source digest and receipt mapping. Current-at-routing evidence, single raw detection, listening-only capture, and accepting a fresh facing new question during pending confirmation are explicit builder decisions in the spec and are reasonable for the stated user requirements.

### Verification evidence and limits

- HEAD was verified as the requested frozen head before review and again afterward; `git status --short` was empty.
- Independently recomputed the driver-defined digest over tracked app, test, and project paths: `e9f1628fbeeff11ba440eb82746b35ef5dd598ed241c2422c997877b598661f2`. It matches `freeze.json`, the successful `final2/build-receipt.json`, and `final2/full-receipt.json`.
- `final2/full-summary.json` reports **996 passed, 0 failed, 0 skipped**, with successful build/test receipts. Two hardware/paid test classes were explicitly excluded. These are inspected receipts, not tests rerun by this reviewer.
- `git diff --check BASE..HEAD` passed. The packaged review diff contains a header and expanded context; the actual git range was the authoritative review input.
- Host tests do not prove real camera pose accuracy, frame latency under load, repeated physical capture startup cost, or end-to-end spoken response time. The planned normal-device check remains valuable and must not be represented as already established by these tests.

### Recommendations

No code fix is required by this review. Finish the planned normal-device behavior check and record actual observations separately from installation/launch success.

For future regression coverage, an integration test using the real `ConversationCamera` dependency plus a gated recognizer stop could explicitly prove that a frame expires or is replaced during speech finalization. The code ordering and unit freshness tests currently support the intended behavior; this is optional additional coverage, not an identified failure.

### Declined to judge

- Real-world Vision accuracy across lighting, glasses, distance, and head pose: cannot be established through read-only host source/receipts; requires the planned physical-device check.
- Measured end-to-end latency, camera startup latency/power, and the broader S1/24-hour endurance acceptance targets: no new measurements are available here, and hardware/audio/network execution was expressly excluded from this review. The documentation's latency-target wording is not accepted as measurement evidence.
- Pupil gaze, identifying the speaking person, and associating an off-camera voice with the one visible face: explicitly excluded product capabilities; head direction alone is the user's requested signal, and the limitation is documented.
- Comprehensive inherited memory, SmartTurn, audio, motion, and network behavior unrelated to this diff: outside this issue review. Their touched transcript and capture integration points were reviewed for regressions; no broader audit is implied.

### Assessment

**Ready to merge? Yes.**

**Reasoning:** The frozen implementation meets the clarified head-facing and preserved 30-second requirements, with correct fallback, confirmation priority, ownership, and invalidation boundaries. No Critical, Important, or Minor defect was identified; the supplied successful verification is bound to the reviewed source, while physical accuracy and latency remain explicit validation limits.
