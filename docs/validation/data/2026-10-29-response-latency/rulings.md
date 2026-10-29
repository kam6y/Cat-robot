# 実装時とレビュー受領時の判断

- Ruling: Full project suite runs after integrated runtime changes, while focused tests gate task1 — repeated green full suites without new changes add no evidence, per higher-priority task rules — cost if wrong: cross-feature regression is discovered at integration rather than task1.

- Ruling: Existing test files host first TDD cases so no project regeneration is required to observe RED — existing public coordinator APIs reproduce missing preparation — no runtime tradeoff.

- Ruling: Record the already-completed task verification instead of rerunning the same green command through task-done — no source change since passing40tests, higher-priority rule forbids unnecessary repeats — no loss of coverage.

- Ruling: Extend the existing device runner and summarizer with stage-specific validation instead of adding duplicate wrappers — keeps old stages covered by4existing summary tests and new11latency tests — cost if wrong: a regression would affect shared reporting, guarded by both suites.

- Final: Ruling: preparationDiscarded includes rejected hints with no native synthesis — retain existing event semantics and document started as the actual attempt count — cost if wrong: naive discard/attempt rates misrepresent wasted synthesis.

- Final: Ruling: 16characters is a conservative eligibility heuristic, not a100ms causal guarantee — retain empirical unchanged gate and16character mismatch fixture — cost if wrong: other devices/workloads may regress, and longer useful overlap is excluded.

- Final: Ruling: physical cooldown is request-precondition time assigned to the next trial, not causal heat per mode — record raw waits and temperatures without energy claims — cost if wrong: repeating intensive benchmarks can incur long waits unlike normal conversations.

- Final: Ruling: fixed replay improvement is conditional, realcloud0/3reuse — keep current model/voice and report no demonstrated general conversation gain; ASR/boundary/acoustic assessment uncollected — cost if wrong: typical replies may see no benefit.

- Final: Ruling: physical latency requires measurement — final54rows pass the same100ms gate after eligibility narrowing and external cooling — cost if wrong: three repetitions cannot establish population or other-device latency.

- Final: Ruling: hardware memory/thermal/auditory cannot be inferred from source review — preserve measured footprint/thermal/cooling, leave listening/acoustic assessment unverified — cost if wrong: callback results do not establish perceived quality or sustained energy.

- Final: Ruling: integrated suite/evidence were pending at review — final862total860PASS2physicalskip and source-bound evidence now completed — cost if wrong: later source changes require new relevant verification.

- Final: Ruling: prior jpreprocess/native correctness outside repeat review — assets/receipt and current integration checked, noRust/dictionary change — cost if wrong: inherited unrelated defects remain unaudited.

- Final: Ruling: generated GUID spelling excluded — deterministic project contract and logical membership reviewed — cost if wrong: nonfunctional generator churn can obscure review.

- Final: Ruling: model/voice/effort/VAD/ASR/memory-order/LLM-tool speculation excluded by user-selected scope — preserve them — cost if wrong: dominant first-token/1.2s/ASR/tool delays remain.

- Final: Ruling: reuse passing checks rather than rerun for documentation-only changes — source263hashes unchanged and no newruntime issue — cost if wrong: checks unrelated to changed content add no new coverage.

- Final: Ruling: publish only feature branch per user's branch request — no main merge/push or unsolicited PR — cost if wrong: user still chooses integration later.
