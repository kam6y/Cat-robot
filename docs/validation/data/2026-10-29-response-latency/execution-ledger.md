# SDD ledger — plan: docs/superpowers/plans/2026-10-29-response-latency.md

User approved concrete design with ok. Inline root implementation, existing Claude consults/reviews. Base main7733e20, design408a5a0.

Pre-flight: Task1 produces candidate channel and prepareFirstSentence toggle, Task2 consumes them for paired replay; signatures agree. Task2 produces timing events/records, Task3 consumes them for evidence; raw original text kept separate from canonical spoken key.
Ruling: Full project suite runs after integrated runtime changes, while focused tests gate task1 — repeated green full suites without new changes add no evidence, per higher-priority task rules — cost if wrong: cross-feature regression is discovered at integration rather than task1.
Ruling: Existing test files host first TDD cases so no project regeneration is required to observe RED — existing public coordinator APIs reproduce missing preparation — no runtime tradeoff.
Task1: in progress.

Task1 RED: task1-red (2tests, expected3assertions); task1-contract-red (16tests, missing-preparation/validation failures, existing non-feature cases green). Implemented candidate transport/timer, owned synthesis/canonical confirmation and step cancellation. Pending GREEN.

Task1: complete (commits760106d..2052e1f, tests: python3 /private/tmp/cat-response-latency-20261029/run-tests.py task1-contract-green +5focused suites →40tests,0fail). Source hashes in task1-tested-hashes.json.
Ruling: Record the already-completed task verification instead of rerunning the same green command through task-done — no source change since passing40tests, higher-priority rule forbids unnecessary repeats — no loss of coverage.
Task2: in progress.

Task2 trace RED8tests/7assertion failures →GREEN45tests0fail. Paired summary RED10tests/13assertion failures →GREEN14tests0fail including4legacy. Reused existing device runner/summarizer rather than new wrappers; newstage-specific validation keeps historical stage behavior. Added physical replay fixture helper and isolated current-model smoke; pending compile/generator.

Task2: complete (commits2052e1f..8574958, tests: task2-device-compile25total/24pass/1physicalskip/0fail; previous tool-focused45pass; Python summary15pass; deterministic generation contractPASS).
Ruling: Extend the existing device runner and summarizer with stage-specific validation instead of adding duplicate wrappers — keeps old stages covered by4existing summary tests and new11latency tests — cost if wrong: a regression would affect shared reporting, guarded by both suites.
Task3: in progress; runtime code frozen pending verification/review.

Final review: fresh-code-review.md noCritical/Important per reviewer, one reportedMinor. Regraded reporting defect Important because aggregating heat/cooldown across modes can hide preparation-specific regression. Regression test_cooldown_and_heat_stay_with_their_own_mode observedRED9!=2; fixed two group_rows comprehensions.
Integration full-suite:861tests/2physicalskips, only ConversationRecoveryTests.testEmptyFinalShowsInlineRecoveryWhileCaptureKeepsRunning failed3assertions. Root cause: ConversationHarness.emit waits for provisionalTranscript==empty, already true before empty event consumed; test retries before async presentation arrives. Production recovery and new preparation path do not run together for this event. Added explicit observable error-presentation wait while retaining all original assertions. Pending focused+full rerun.
Final fix pass: reporting regressionRED9!=2→allPython29PASS; empty-ASR synchronization39recovery testsPASS, all originalassertionskept. Committed372d76f. No production Swift runtime changes after reviewed8574958. Full-suite rerun warranted by observed integrationfailure and testfix.

Physical attempt1 invalid:48rowsfailed/state2background, AVAudioEngine561015905. devicectl --activate returned0 but app did not stay foreground. Excluded all timings. User asked to keepunlockedCatRobotfront. Testharness now waitsforactive beforeaudio/setup/trials, reactivates audio pertrial (asexistingtrial did), preserves original failure instead of replacingwithresponseMismatch, stopsafterfirstfailedtrial. Only test-helper/setup changed; production runtime remainsreviewed/tested. New targeted compile and physicalretryrequired, no needrepeatfullsuiteforskip-onlyfixturecode.
Physicalattempt2:47successfulplaybackrows, lastpreparedchanged-longendedinactive(state1), finalbaselinewaitedforeground120s thenXCTSkip. Entire run excluded fromacceptance(missingpairandstate). Setuphypothesis: displayassertionwasacquiredbeforeforeground, lostaround2min. Re-acquire/renewonlytestdisplayassertionwhileactivebeforeeachtrial. Productionunchanged. Cloudsmokefirstshortindependenttestthenfreshpairedrun.

Physical attempt3 valid but performance gate FAILED: 48 successes, all foreground/nominal. Delayed/two/quoted/whitespace median improvement227–467ms; changed-long paired p95 +107.74ms exceeds100ms. Its worst pair decomposes enqueue+4.99ms, enqueue-to-final-synthesis+15.87ms, confirmed synthesis-21.26ms, synthesis-finish-to-PCM-start+108.14ms. Dominant residual is playback startup, not cancellation drain; no causal guarantee from text length or total synthesis/8. Claude consulted and root technically received. Narrow normalized candidate eligibility to16characters (tested successful range6–13) to cap speculative work; a conservative heuristic, not a latency bound. Existing gate unchanged; add16character changed-boundary fixture, require changed-long zero preparationStarted in final evidence. Regression test long pronunciation/no speculation/full confirmed speech observedRED1test3assertions before runtime change. New runtime requires focused+fullsuite and fresh signed54trial run, no retry-to-green.

Eligibility verification: focused28PASS; full-suite-eligibility862total/860PASS/2explicitphysicalskips/0FAIL, final263sourcehashes unchanged; allPython29PASS. Runtime fix and boundary/long attempt assertions verified in full simulator compile; final signed physical comparison pending.

Final: minor (deferred): local preparation task name shadows model-preparation property; ownership tested, readability cost remains.
Final: minor (deferred): excluded long hint is normalized before length rejection and confirmed input is normalized again; preserves validation, costs redundant normalization.
Final: Ruling: preparationDiscarded includes rejected hints with no native synthesis — retain existing event semantics and document started as the actual attempt count — cost if wrong: naive discard/attempt rates misrepresent wasted synthesis.
Final: Ruling: 16characters is a conservative eligibility heuristic, not a100ms causal guarantee — retain empirical unchanged gate and16character mismatch fixture — cost if wrong: other devices/workloads may regress, and longer useful overlap is excluded.
Final: Ruling: physical cooldown is request-precondition time assigned to the next trial, not causal heat per mode — record raw waits and temperatures without energy claims — cost if wrong: repeating intensive benchmarks can incur long waits unlike normal conversations.
Final: fixed long-candidate regression exposure — testLongPronunciationWaitsForConfirmationWithoutSpeculativeInference RED→GREEN, fullsuite860PASS/2skip; finalphysicalgatepending.

Physical run4 incomplete:42rows/allplaybacksuccess/allforeground; XCTestrun failed modelBusy at existing600s serious/critical cooling timeout before43rd trial. Initial220s and mid250s cooling completed; final600s wait not attached to a trial record, so raw per-mode cooldown sums exclude this unfinished wait. Not a failed performance verdict and not accepted data. User explicitly replied wind cooling; fresh54trial run5 authorized on unchanged91ceca4/263hashes with external cooling. Do not combine rows across runIDs or rerun until lucky.

Final physical run5:54/54successful foreground rows, XCTest1PASS/0FAIL/0skip; unchanged100ms gatePASS. Same91ceca4/263sourcefiles. Initial30s cooldown only, alltrialthermal fair before/after. Median delayed391.79ms/two224.48ms/quoted439.31ms/whitespace402.38ms improvements. Worst immediate/miss pairedp95+62.39ms; boundary+53.72ms; long0attempts,boundary3attempts;12positivehits/noresynthesis. Fresh run after user windcooling, no cherrypicking/combining. Final-cloudsmokeinprogress.

Final cloud2:3actualmodel/voiceplaybacksuccess,1XCTestPASS/0FAIL/0skip;0reuse/noobservedfirstCandidate,observedexpressspanthird;alloriginalsmatch. Normal app process1799confirmed,noSUPERenv. Fullfinal263hashesstillmatch.
Final: Ruling: fixed replay improvement is conditional, realcloud0/3reuse — keep current model/voice and report no demonstrated general conversation gain; ASR/boundary/acoustic assessment uncollected — cost if wrong: typical replies may see no benefit.

Final review exclusions (received before physical work; final executor rulings):
Final: Ruling: physical latency requires measurement — final54rows pass the same100ms gate after eligibility narrowing and external cooling — cost if wrong: three repetitions cannot establish population or other-device latency.
Final: Ruling: hardware memory/thermal/auditory cannot be inferred from source review — preserve measured footprint/thermal/cooling, leave listening/acoustic assessment unverified — cost if wrong: callback results do not establish perceived quality or sustained energy.
Final: Ruling: integrated suite/evidence were pending at review — final862total860PASS2physicalskip and source-bound evidence now completed — cost if wrong: later source changes require new relevant verification.
Final: Ruling: prior jpreprocess/native correctness outside repeat review — assets/receipt and current integration checked, noRust/dictionary change — cost if wrong: inherited unrelated defects remain unaudited.
Final: Ruling: generated GUID spelling excluded — deterministic project contract and logical membership reviewed — cost if wrong: nonfunctional generator churn can obscure review.
Final: Ruling: model/voice/effort/VAD/ASR/memory-order/LLM-tool speculation excluded by user-selected scope — preserve them — cost if wrong: dominant first-token/1.2s/ASR/tool delays remain.
Final: Ruling: reuse passing checks rather than rerun for documentation-only changes — source263hashes unchanged and no newruntime issue — cost if wrong: checks unrelated to changed content add no new coverage.
Final: Ruling: publish only feature branch per user's branch request — no main merge/push or unsolicited PR — cost if wrong: user still chooses integration later.
Task3: complete (runtime91ceca4; full862total860PASS/2explicitphysicalskips; Python29PASS; physical54PASS/same100ms gatePASS; currentmodel3PASS/0reuse; normalPID1799confirmed; source263matches; findings/decisions/rawdata archived in docs/validation/data/2026-10-29-response-latency; docs/index/plan completed).
