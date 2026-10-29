# Finishing ledger — feature/response-latency
User requested actual Claude /simplify, fresh requesting-code-review, reciprocal receiving-code-review, current-model/voice unchanged, then squash merge main and push.

- [x] Merge natural Japanese repair from main, both docs index items preserved. 3472b95.
- [x] Freeze base2fa4ae7 / head3472b95; actual Claude /simplify started with four review agents; fresh independent reviewer dispatched.
- [x] Existing Python suite29/29 passes (python-final.log).
- [x] Receive both reports fully, exchange reports, evaluate suggestions with source evidence; root sole writer.
- [x] Apply accepted behavior-preserving simplifications/important fixes; add current kanji/mixed boundary and hit coverage.
- [x] Full Swift suite and current source proof (baseline focused41/41, native/TTS asset validation, deterministic Ruby project contract PASS).
- [x] Physical paired gate (<=100ms regression, delayed reuse+improvement), real-model smoke, restore normal app.
- [ ] Current durable evidence + accepted/deferred/rulings; commit, squash merge, verify identical source and remote push main.

Decisions: no new model, voice, speed, steps or ASR changes. No broad refactor. Old physical evidence is historical all-kana only; cannot accept current kanji-preserving runtime from it. Baseline toggles first-sentence preparation on same current runtime. Old plan's no-main-merge constraint is superseded by explicit user instruction; no extra approval question.

Physical coverage added: changed-kanji-boundary (16 characters, all supported common kanji, one speculative attempt) and delayed-mixed (Latin-only conversion, requires hit). Total expected66 rows across11 fixtures×2 modes×3 repetitions. No production source changes while reviews pending.

Integrated full baseline:863 total,861passed,2 physical-only skip,0fail. All263 captured source hashes match after run. Baseline includes two added device fixture cases. No concurrent Xcode processes remain.

Reciprocal receptions complete: Claude + fresh reviewer both technically evaluated the other report. Root accepted bounded cleanup after reviewing both reports/receptions. Refactor76a8a9b: common same-task tool trace, common sentence commit loop, hint fallback, single trim, typed callback names, policy names, safe optional binding/direct snapshot. Existing focused94/94 PASS after edits; full-final running on same263 sources. Native runtime unchanged vs repaired main receipt. Settings evidence corrected: declared fields are not engine telemetry; actual production call sites recorded in inference-source-check.json.

Final host validation: full-final863total/861pass/2physicalskip/0fail; all263 source hashes unchanged since capture. Current clean runtime76a8a9b321bee6a1d46296153d13bbdb9be443b1. Latest origin/main remains2fa4ae7. Signed physical paired run device-paired-1 started after all Xcode simulator jobs completed; no source edits until it finishes.

Current paired runE863AB87-4D5A-4FC3-8F05-2242608451ED on76a8a9b COMPLETE:66/66 foreground/state0 successes, XCTest1pass0skip0fail, all11 fixture acceptance gates PASS,5 required-hit fixtures15/15 hits/no first resynthesis. Max pairedp95 regression14.66ms (katakana boundary); kanji16 boundary -19.92ms p95, long0attempts. Delayed medians -228.58..-505.63ms. No hot ends, negligible cooldown, current native receipt/source263 unchanged. Cloud smoke same build now running.

Current cloud run:3/3 foreground successes, XCTest1pass0skip0fail; claude-haiku-5-5/low/F1,0candidate attempts/0reuse. This validates wiring only, not ordinary-conversation speedup. Normal app restored after tests with noSUPER environment and PID proof (normal-launch-check.json). Important acceptance/evidence gate now met, all reports/receptions read, accepted refactors verified, existing minor timer-reset test gap deferred explicitly. Preparing durable evidence and user-authorized squash integration.
