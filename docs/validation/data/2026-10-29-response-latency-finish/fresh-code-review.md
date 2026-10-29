# Fresh independent code review

Reviewed base `2fa4ae7b15ee5398a735764cd1186465e0d2ddcd` through frozen head `3472b95ddf4d9b332357ec2baae53fd02e9cc620` in `/Users/goodapple/.codex/worktrees/b200/Cat_robot`. Scope: the supplied runtime/test/script/project diff, adjacent ownership and normalization code, design/plan, and the validation narrative. This was a read-only review: no repository edits, builds, tests, private conversation/audio access, or delegation. Historical test counts below are reported evidence, not tests independently executed by this reviewer. Applied the requested `superpowers:requesting-code-review` reviewer template.

### Strengths

- Confirmation remains the authority for playback. `SupertonicSentenceSpeaker.swift:123-145` waits for committed input, normalizes it again, validates before trimming, compares the canonical strings, and only then consumes validated PCM. Both paths use the voice captured once for the operation. Auditing happens at actual committed playback rather than at hint synthesis (`:77`).
- Mismatch and cancellation have explicit ownership and draining. Every exit after starting the local preparation task cancels/joins it as appropriate; replacement synthesis starts after that join. The engine actor also serializes native inference. Added denoise-step checks in `Helper.swift:631` and the check before the vocoder shorten cooperative cancellation without changing arithmetic or inference settings.
- Parser exposure adds a hint without altering committed-prefix decisions. The channel keeps its capacity-two committed queue, discards pending hints on commit/failure, offers at most one hint, and retains failure precedence. The separate snapshot producer still observes upstream failure while speech backpressure blocks enqueueing.
- The gated mismatch and stop tests exercise an intentionally uncooperative inference, asserting no overlap, no premature playback, and no stale PCM on the next turn (`SentenceReplyPlaybackTests.swift:68-155`). Reuse, original text preservation, normalized output limits, protected/unstable prefixes, and upstream failure have substantive behavioral coverage.
- Paired benchmark modes share the same build and fixed replay schedule; order alternates. The summary rejects missing/duplicate pairs, mixed source identities, changed voice/inference settings, missing sentence callbacks, and playback before confirmation. The historical narrative accurately limits callback timing versus acoustic timing, three-repeat p95, and the cloud smoke's zero reuse.

### Issues

#### Critical (Must Fix)

None found in the reviewed range.

#### Important (Should Fix)

1. **Current normalization baseline has not yet met the physical acceptance gate.**
   - References: `CatRobotTests/Device/ResponseLatencyDeviceBenchmark.swift:24`, `:63-64`; `CatRobot/Conversation/Services/Supertonic/SupertonicSentenceSpeaker.swift:116`; `docs/validation/2026-10-29-response-latency.md:3-5` and `:94`.
   - Mechanism: preparation eligibility counts normalized Swift characters. The merged normalizer now preserves kanji and numbers, whereas the historical accepted run used expanded kana. Therefore the same 16-character guard admits a different input/workload population. The sole explicit maximum-eligibility fixture remains 16 katakana characters. Neither its historical timing nor the old 54-trial acceptance proves current kanji-heavy/mixed input cancellation and startup behavior. The narrative still describes the old source as the final build and says subsequent changes were documentation-only.
   - Impact: enabling the optimization by default without current evidence would bypass the plan's measured <=100ms immediate/miss regression gate. This is an unfulfilled acceptance/evidence requirement, not a demonstrated runtime regression or a request to undo the Japanese repair.
   - Fix: retain the current normalizer; add current mixed/kanji-heavy eligible boundary and delayed-hit fixtures with explicit normalized-count/attempt expectations, run fresh same-build paired physical trials and the current-model smoke, and record current source/native provenance. Clearly label the old 54-trial data as historical and separate it from current acceptance. If the new gate fails, narrow eligibility/stability and revalidate before making the configuration default. Root has acknowledged this gate and plans that work; it is not waived by this review.

#### Minor (Nice to Have)

1. **The 75ms stability reset is not directly covered by the new behavioral tests.**
   - References: `CatRobot/Conversation/Integration/SentenceReplyPlayback.swift:101-111`; `CatRobotTests/Conversation/Integration/SentenceReplyPlaybackTests.swift:68`; `CatRobotTests/Device/ResponseLatencyDeviceBenchmark.swift:23`.
   - Mechanism: the changed-candidate integration test waits until synthesis has already started before revising input. The physical punctuation fixture revises at 200ms, after the 75ms window. Parser tests cover punctuation grouping, but do not execute the timer. I searched the test tree for punctuation/extension/stability candidate tests; there is no `testPunctuationExtension...` at this frozen head.
   - Impact: a future regression that stops cancelling/restarting the pending timer on a candidate change within the first 75ms could waste the operation's one preparation attempt; current tests would still cover post-start cancellation but would miss that distinct trigger. No current malfunction was demonstrated.
   - Suggested fix: add a focused timing-controlled test that offers a complete ending, extends its punctuation before 75ms, and verifies no synthesis of the first candidate and one preparation of the revised candidate only after a fresh stability interval. Keep playback unconfirmed until the assertion completes. Prefer a deterministic timing seam if one can be added without disproportionate runtime abstraction.

### Recommendations

- Resolve the current-source physical acceptance/evidence issue before squash merge and push. Do not describe a same-build preparation toggle as a comparison against the literal old main binary.
- Preserve the present cancel-and-drain and confirmed-input revalidation paths when applying simplifications. Eliminating the second normalization or joining only after starting replacement inference would change the safety contract.
- Avoid generalizing the old zero-hit cloud smoke into ordinary-conversation speedup. Keep fresh smoke results distinct from controlled paired replay and from a production latency distribution.

### Declined to judge

- Pronunciation quality and naturalness of the restored Latin-only correction: the normalizer was read to establish eligibility/input behavior, but its complete language-quality audit is outside this latency diff and no audio was accessed.
- Acoustic onset, actual ASR-boundary-to-speech measurements, and broad ordinary-conversation benefit: this review executes no physical/voice tests; callback replay and a small text-prompt smoke do not establish those behaviors. The existing report explicitly identifies these limits.
- Long-duration thermal/energy behavior: short paired runs cannot establish it, and no such measurements were performed here.
- A hard cancellation deadline inside an individual ONNX call: the implementation intentionally checks between native denoise calls; the spec expressly does not promise a mathematical bound. Actual current-input regression remains subject to the Important gate above.
- Unrelated memory/ASR/robot business logic and complete native pronunciation implementation correctness: unchanged by the reviewed latency range; relevant call ordering/ownership was inspected, but this is not a whole-application audit.
- Independent build/project-generation and test-pass certification: prohibited by this read-only assignment. Project additions and scheme references were inspected; the executor must supply current checks and provenance.

### Assessment

**Ready to merge? With fixes.**

**Reasoning:** No concrete Critical or Important runtime safety defect was found in the reviewed cancellation, parser, queue, or reuse paths. Merge readiness remains conditional on current kanji-preserving physical acceptance and an accurate current-versus-historical evidence record; old all-kana success does not satisfy that condition. The timer-reset coverage suggestion is nonblocking.
