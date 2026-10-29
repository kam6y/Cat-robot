# Review reception and decisions

Scope: base7733e20 → reviewed runtime8574958; reporting/test synchronization fixes372d76f. Both independent reports were read fully and checked against actual code/tests. No further fresh review seat is needed.

## Material findings

- Fresh reviewer minor / Claude I1: per-mode cooldownSeconds and hotEnds incorrectly summed outer rows after the grouping variable changed. Regraded Important for evidence because it hides mode-specific heat/cooldown differences. Regression fixture baseline2s/nominal vs prepared7s/serious observed RED9!=2. Both comprehensions fixed to group_rows in372d76f; all29Python tests pass. Claude independently confirmed the three-file fix and marked I1 resolved.
- Integrated suite found a pre-existing empty-ASR test race: harness.emit waited for transcript==empty, true before consumption; assertions/retry ran before error presentation. One focused rerun passed, confirming scheduling dependence. The test now awaits actual error presentation and retains every original assertion.39recovery tests and full861tests pass (859pass/2explicit physical skips). No production ASR/recovery changes.

## Claude minor dispositions

- M1 local preparation name shadows model-preparation property: deferred naming-only cleanup. Ownership is explicit in the cancellation handler and verified with uncooperative inference gates. Cost if wrong: maintenance readers may confuse the two tasks; no observed runtime effect.
- M2 paired baseline is the same final build with only prepareFirstSentence disabled, not a literal7733e20 binary. Both modes share input edge trimming, accepted-input audit timing, per-step cancellation and notice tracing. Record this in validation; do not attribute shared changes to preparation.
- M3 firstSentence now includes final flush, so one-sentence traces gain this milestone. New reports use request/firstCandidate/speechEnqueued/PCM callbacks and do not compare this milestone blindly to old traces.
- M4 75ms means shorter real candidate→confirmation windows receive no preparation. Measure the real smoke windows and retain this conditional benefit. Do not shorten the guard on host results alone.
- M5 replay deliberately inserts700–900ms tails. Label its result as a controlled overlap comparison; three cloud turns prove wiring, not conversation-latency distribution or NFR acceptance.
- M6 real SDK tool auditing is not independent of TaskLocal tracing. If no tool span appears, state no observed span rather than proving no tool call. Nonempty real spans support propagation for those calls only. No new production diagnostic API is added merely for this test.

## Rulings on fresh review exclusions

- Actual hardware speed and100ms regression gate: executor-owned pending physical acceptance; no code-review verdict substitutes for measurement. Cost if ignored: shipping an unproven optimization.
- Memory/thermal/auditory results: memory/heat will be recorded, while subjective listening/acoustic latency remain unverified unless a person assesses them. Cost: callback timing does not establish subjective quality.
- Full-suite and evidence completeness: full861tests now passed; evidence is being written after physical results. Never label unfinished physical work complete.
- Prior jpreprocess behavior: unchanged Rust/dictionary/native API remains outside repeat review; current asset/native receipt verified and actual Swift/native integration tests pass. Cost: inherited unrelated defects are not audited again.
- Generated GUID spelling/order: accepted generator output after deterministic logical contract and fresh review of source/resource membership. Cost: none observed; spelling alone is not application behavior.
- Alternative model/voice/effort/prompts/VAD/memory/tool-execution policies: excluded by user-selected scope. Cost: server first-token and1.2s segmentation delays remain.

## Physical setup failures

Initial physical run device-latency-1 is excluded completely: UIApplication state2/background and AVAudioEngine561015905 prevented actual playback in both modes. Its benchmark error label incorrectly overwrote the underlying failure with responseMismatch; the test-only fixture now preserves the original failure, waits for foreground, reactivates audio before each trial and stops after a failed trial. Production runtime remains unchanged. User asked to keep the unlocked app displayed; valid hardware comparison is pending.

## Physical gate investigation and eligibility ruling

- device-latency-2 is excluded entirely:47rows, missing finalbaseline, last prepared row ended UIApplication state1, XCTest skipped after foreground timeout.
- device-latency-3 is valid48rows/allforeground/allnominal/one physical test passed, but performance acceptance FAILED for changed-long: paired p95+107.74ms versus100ms limit. It is diagnostic evidence, never a passed acceptance result.
- Worst-pair interval differences: request→enqueue+4.99ms; enqueue→confirmed synthesis start+15.87ms; confirmed synthesis-21.26ms; synthesis end→PCM started+108.14ms. Other changed-long pairs total+83.46/+4.60ms. Thus the dominant residual lies in playback startup; cancellation drain is only about16–25ms. No causal assertion that long inference alone caused108ms.
- Eligibility is narrowed to normalized canonical inputs≤16characters; longer confirmed speech still synthesizes in full. This is a conservative workload restriction around the6/13character inputs with demonstrated overlap, not a mathematical100ms cancellation/startup bound. Total synthesis time/8 includes non-denoising stages and cannot establish step time. Cost if wrong: another device/workload can still fail the empirical latency gate; this restriction can also miss useful longer candidates.
- Added behavioral regression catches speculative synthesis after a short original expands to a long normalized string, then checks both matching/different confirmed originals and full normal speech. Observed RED1test3assertions; focused28tests GREEN.
- Add16character changed-boundary replay and assert actual normalized fixture length plus1attempt; assert long fixture0attempts. Final device run uses54rows, unchanged100ms gate, newrunID. Three-pair p95 is the maximum, not a population estimate.
- Existing Claude consulted; its requested decomposition/boundary/long-fallback tests were accepted. Its suggested synthesis-duration/8 causal bound was declined as unsupported by available instrumentation; this limitation is recorded instead of fabricating a guarantee.

## Bounded follow-up through Claude -p

The existing agmsg pane did not return the later eligibility messages. User had explicitly authorized Claude -p as fallback. First bare invocation returned Not logged in because --bare deliberately excludes OAuth/keychain authentication; no credential was read/copied by executor. Retried with normal existing authentication in restricted mode, no tools/MCP/slash commands/session persistence; exit0 and report saved as claude-eligibility-review.md. This reviewed only the supplied nextPrepared/normalizedInput source and six-line guard, not the whole branch.

- No material correctness/ownership/cancellation bug found. Root checked that guard returns before creating candidate Task and falls back through regular validation; cancellation closes channel and check remains before play. TDD/fullsuite and device attempt assertions verify these boundaries.
- Minor/informational: preparationDiscarded can be emitted for a long hint even though preparationStarted is absent (same existing semantics as failed hint normalization). Accepted as documentation, no runtime change. Event counts describe rejected hints too; do not treat discard/attempt as wasted-synthesis rate.
- Minor/performance deferred: overlong hint is still normalized once before rejection, then confirmed text normalized again. Root leaves validation intact; original length cannot safely predict pronunciation expansion. Cost: redundant normalization on excluded hints, with no claim of a hard latency bound.

Physical run4 was aborted by unchanged600s thermal cooldown limit, not accepted as a performance verdict:42successful foreground rows,12missing, test modelBusy. Last incomplete600s cooling is not attached to any trial and is absent from per-mode totals. User explicitly answered wind cooling; run5 repeats the same54fixture/100ms contract on unchanged91ceca4 sources with changed physical cooling. Keep run4 raw data; do not combine/cherry-pick pairs across runs.

## Final executor acceptance

Final run5 BC6921D6-AE21-4C8F-8D06-99BCC65A5711 on91ceca4:54successfulforegroundrows,1physicalXCTestPASS/0FAIL/0skip, unchanged100ms gatePASS; delayed391.79ms/two-sentence224.48ms/quoted439.31ms/whitespace402.38ms median improvement. All trial temperatures fair before/after;0hot endings. Initial30.016s cooldown, no latercooldown. Positive12hits,0resynthesis. Boundary3attempts;long0attempts. Cooling was changed by user's explicit fan answer; invalid/incomplete run4 retained and not combined. Worst immediate/mismatch pairedp95+62.39ms. This is empirical conditional playback timing, not a guarantee acrossdevices or an acoustic measure.

Final cloud2 on same91:3successes, realselectedHaiku5.5/low/F1, full originaltextmatches,0reuse. No firstCandidate observed in all3; observedexpress span in third. Request→PCM1.401/2.293/1.876s. No matchedcloudcontrol, no broad real-world gain claim. Earlier3cloudsmokes also0reuse. ASR/voiceboundary andauditorychecks remain explicitlyunmeasured.

Normal app relaunched withoutSUPERenvironment, process1799confirmed. Final263sourcehashes match simulatorfull862test(860pass/2physicalskip)and signeddevice91. No materialreviewfindingremains. Naming and redundantnormalizationminorsdeferred; rejectedhint/discardsemantics documented. Main remains7733e20, feature publication next.
