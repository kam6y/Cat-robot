# Large Number Speech Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read large Japanese quantities naturally without replacing surrounding Japanese or misreading identifiers as quantities.

**Architecture:** Keep the current protected spans and maximal identifier scanner. Recognize conservative large standalone numeric spans in the native frontend, run only those spans through pinned NJD, selecting library kanji surfaces or standard numerical pronunciation, and preserve Japanese outside them. Compare fixed raw/kana/kanji synthesis inputs with the same production engine before accepting sound quality.

**Tech Stack:** Rust1.90.0, jpreprocess0.15.0/NAIST dictionary, existing C ABI/Swift actor, pinned Supertonic, XCTest, native/C ABI tests, Python asset checks.

**Spec:** docs/superpowers/specs/2026-11-06-large-number-speech-design.md

## Global Constraints

- Base main `b050575f88b6f14f520f3ee968c42c0ad6021e3c`; branch `codex/issue-24-japanese-number-speech`; root is the single source writer.
- Preserve full Japanese surface outside targeted numerical spans; no new prompt, voice/model/steps/speed/thread settings or dependency version.
- Keep URL/email/backtick/maximal-Latin/unknown-Unicode protection and existing byte/character/cancellation/failure contracts.
- Target5+ digit integers, strict comma grouping, 万/億/兆/京 forms. Use NJD surfaces for quantities and standard pronunciations for decimal/%/phone; one explicit-ID label rule selects genuine digit-sized library calls; clock uses 時/分 notation and library numeral spelling. No app-owned reading tables. Preserve ambiguous notation and small counters/years.
- Native source changes require all3 architecture slices and matching validated build receipt. Do not edit sources during a build/test run; bind every result to actual input/native artifacts.
- Use public fixed examples only. Distinguish generated PCM, observable playback and human listening; do not upload user history or audio to external services.
- Full suite excludes the two hardware/paid classes; explicitly run only local pronunciation device stage for audio. Finish with normal app installed/started and main squash/non-force push, as authorized by the same-workflow request.

## Review Focus

- A malformed grouping or grouped decimal must never turn into a partially changed number.
- Number extraction must not steal a suffix from Latin/Unicode identifiers, URLs, code, phones or colon/slash-separated dates/times.
- Numeric output expansion must obey2000 characters without dropping digits or silently falling back after operational failure.
- The same C ABI/native artifacts must be the ones linked by the Swift and device tests after the3-slice rebuild.
- Correct literal readings/finite PCM are insufficient for quality: compare large-unit/counter speech and verify the retained small-number/date/time/phone cases by listening.

---

### Task 1: Targeted numerical reading with real dictionary and listening validation

**Files:**
- Modify: `native/japanese-pronunciation/src/lib.rs`, `native/japanese-pronunciation/tests/pronunciation.rs`, `native/japanese-pronunciation/README.md`
- Create if it improves focus: `native/japanese-pronunciation/src/numbers.rs` (numeric span admission/boundary logic only)
- Test/diagnostic: `CatRobotTests/Conversation/Services/JapanesePronunciationServiceTests.swift`, `CatRobotTests/Device/SupertonicIntegrationDeviceTests.swift`
- Document: `README.md`, `CatRobot/Vendor/JPreprocess/PROVENANCE.md`, issue24 validation/review records
- Rebuild ignored: `CatRobot/LocalAssets/JPreprocess/CJPPronunciation.xcframework`, `native-build.json`

**Interfaces:**
- Consumes existing `Pronouncer::pronounce(&str)`, protected ranges, IDENTIFIERS, `JPreprocess::text_to_njd`, `NJD::preprocess`, and `JapanesePronunciationService.normalize`.
- Produces the same API and original display/memory text, with exact large-number speech strings such as `百五十万円` and `三億五千万`; no new public preference/API.

- [x] **Step 1: Record baseline and write RED tests before production changes.** Existing native22 tests must pass. Record real C ABI and direct NJD outputs. Add Swift exact synthesis-input/expanded-limit tests first and run against the old bundled library. Expected: large numeral assertions fail because raw notation is returned; numeric expansion does not yet trip the limit. Then add native behavioral cases, watch the same failures with the real dictionary. Include malformed grouping, grouped decimals, ID/leading-zero/phone/date/time, protected/unknown Unicode and small-quantity regression cases.
- [x] **Step 2: Prepare and execute fixed same-voice comparison fixtures.** Extend the existing physical pronunciation diagnostic with clearly labelled fixed candidate inputs (raw/current frontend/kana/kanji), reuse the existing runner, never present literal candidates as actual frontend output. Expected: real device exports finite WAVs and actual processed input traces; ask the user which large-number candidate sounds natural and whether control cases remain natural. Continue independent implementation/verification while awaiting listening feedback.
- [x] **Step 3: Implement conservative numeric spans and reading.** Reuse the original identifier/protection logic; validate complete grouping before conversion, exclude non-quantity contexts, invoke NJD before checking number pronunciations, share the final kana validation only where equivalent. Expected: native and C ABI tests green with all existing natural-Japanese/Latin/protection cases preserved.
- [x] **Step 4: Rebuild native3 slices and verify Swift/device integration.** Run native test/fmt, build/receipt validation, relevant Python asset checks and focused Swift tests through a private source-bound driver. Expected: real library inputs match exact readings, long grouped numerals remain whole before upstream chunking, original display/memory is unchanged, expansion limits and failure/cancel paths hold. No project membership change means unchanged generator/project receipts can be reused after source-hash/contract checks.
- [x] **Step 5: Accept listening result and run the full suite once source is final.** If the selected numerical style differs or control speech is worse, revise only the demonstrated source and repeat affected RED/GREEN/quality steps. Run the full XCTest suite through `task-done` before source commit, append verified-patch→commit mapping. Expected: all unit tests green, source/native-artifact identity stable, physical comparison and normal speaker playback documented. Do not repeat unchanged tests solely for ledger bookkeeping.

## Whole-branch review and integration

- [x] Freeze the tested source; ask Claude for actual read-only `/simplify`4 angles and request one fresh native code reviewer. Preserve independent first reports before exchange. Review only changed paths and their integration boundaries, not an unrelated audit.
- [x] Mutually receive findings using `receiving-code-review`; verify rather than blindly adopt. Fix Important/Critical with reproducing RED→GREEN and appropriate full verification; record minor deferrals and explicit scoped rulings. Documentation-only corrections do not need prose tests or an unchanged full-suite rerun.
- [x] Obtain the relevant real-device audio confirmation and record native/source/assets identity. The selected ID paragraph inputs/chunks were confirmed in the real production speaker path.
- Post-commit gate: install/launch the normal final-main signed app with no XCTest plugins/test flags before publishing. This replaces a redundant normal feature-preview install: the diagnostic already verifies the accepted audio, and the squash must have an identical full tree. The final-main build still verifies source revision, native receipt, model assets, signature and live process.
- Post-commit gate: fetch fresh main, squash one commit, prove merged source identity, build/install/launch the normal final-main app, non-force push and verify remote/issue closure. Preserve feature branch and host worktree; archive/remove only this plan's owned execution workspace. Actual completion hashes, device PID, remote and issue state are recorded after the commit in task-private `integration.json`; this committed snapshot does not pre-claim those outcomes.

## Final verification ruling

Task1 completed with a source-bound verification command over the actual final full-suite result (1003 passing, zero failures/skips), native30 passing, matching three-slice receipt and the accepted listening/real-production evidence. Tests and final review ran while the input was frozen. The command rechecked the current input digest and artifacts; an identical full run was not repeated only for ledger order. Candidate HEAD812bbbf plus the final working patch is identified by digest c919e408…; the final feature commit and equal-tree squash mapping are recorded after commit. The ID nine-digit case is a disclosed, human-selected exception to S1, whose definition remains unchanged.
