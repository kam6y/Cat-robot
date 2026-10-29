# Fresh whole-fix review

Reviewed base `7733e201cf0bf7d9feeea7352a11d4e82b8c2d03` and the uncommitted repair in `/Users/goodapple/.codex/worktrees/b200/Cat_robot`. This is one read-only review following the supplied code-reviewer instructions. I read the complete review package and captured diff, the named spec/plan, actual native implementation/FFI/tests, Swift service/speaker/tests, downstream engine preprocessing, packaging/receipt code, and subsequent public README/provenance/spec changes. No builds, tests, network, private history, private JSON, audio, repository mutations, or subagents were used.

## Strengths

- The change directly addresses the reported regression: `convert_plain` copies nontarget Japanese text rather than passing it through whole-sentence NJD pronunciation (`native/japanese-pronunciation/src/lib.rs:68–85`). The literal mixed-language tests check the user-selected behavior rather than only testing that some output exists.
- Candidate eligibility is checked before width folding. Accented letters, attached combining marks, foreign scripts, compatibility numerals, and halfwidth Japanese voicing receive useful regression coverage (`native/japanese-pronunciation/tests/pronunciation.rs:268–308`). Unknown candidates retain their original surface, and dictionary coverage is checked before preprocessing can discard silent nodes.
- Existing C ABI ownership/error handling, actor serialization, cancellation checks, protected-span handling, and downstream output-length rejection remain intact. The speaker still normalizes before synthesizing and retains the original sentence for playback bookkeeping.
- The inspected `native-build.json` agrees with the SHA-256 values of current `src/lib.rs`, both changed native test files, and both packaged static libraries. The inspected native-source SHA-256 is `18a63c6635e39262e130ba9dbf5ab68f3bafecc11a6690d75f2ed3677307e06c`. The build script compiles all three targets before packaging, and normal receipt validation rejects source or artifact mismatches (`scripts/build_jpreprocess.sh:13–48`; `scripts/validate_jpreprocess_assets.py:62–72`).

## Issues

### Critical

None found.

### Important

1. **Typographic internal word connectors still allow partial rewriting of an unknown foreign term.**

   - **Evidence:** `native/japanese-pronunciation/src/lib.rs:35–37` recognizes only ASCII/fullwidth hyphen, period, and apostrophe as internal connectors. U+2010 HYPHEN (`‐`), U+2011 NON-BREAKING HYPHEN (`‑`), and internal U+2019 apostrophe (`’`) are neither in that connector set nor in the letter/number base. Consequently, `YouTube‑zzqx` is scanned as separate `YouTube` and `zzqx` candidates; lines 73–74 convert the known prefix without allowing the unknown suffix to veto conversion of the complete word. The same split occurs for `YouTube‐α` and internal typographic apostrophes. This is a static trace from the scanner and the already-covered `YouTube` conversion, not a claimed runtime reproduction.
   - **Impact:** Ordinary typographic variants of a foreign compound or identifier can be spoken as a partially rewritten hybrid. The otherwise conservative behavior for unknown complete terms changes with the hyphen glyph. This affects the repair's core guarantee that Unicode words/identifiers are not rewritten in fragments, including the spec's treatment of internal hyphens as part of a word (`docs/superpowers/specs/2026-10-29-natural-japanese-speech-repair-design.md:18–21`).
   - **Fix:** Distinguish the maximal scanning alphabet from the eligible conversion alphabet. Include ordinary typographic internal hyphens/apostrophes when gathering a complete candidate, while retaining the ASCII/fullwidth-only eligibility rule so these noneligible complete candidates remain unchanged. Keep quote wrappers and Japanese dash punctuation as boundaries. Add literal cases for unknown compounds using U+2010/U+2011, internal U+2019, and existing curly-quote wrappers to prevent over-grouping.

### Minor

1. **The output-limit tests exercise symbol expansion but omit the planned dictionary-word expansion case.**

   - **Evidence:** `CatRobotTests/Conversation/Services/JapanesePronunciationServiceTests.swift:82–85` and `CatRobotTests/Conversation/Services/SupertonicSentenceSpeakerTests.swift:115–120` use only repeated `+`. That goes through the numeric/symbol branch (`native/japanese-pronunciation/src/lib.rs:75–79`), bypassing the Latin dictionary path whose expansion the plan explicitly asks to check (`docs/superpowers/plans/2026-10-29-natural-japanese-speech-repair.md:36–37`).
   - **Impact:** The shared Swift guard is visibly correct, so this is not evidence that the current limit is broken. It is a small coverage/plan gap: successful dictionary expansion near the threshold is not directly coupled to the rejection/no-synthesis assertions.
   - **Fix:** Retain the plus cases and add a real dictionary expansion already established by the native fixtures. For example, repeating `5G ` 500 times should produce 2,000 characters of `ゴジー `; 501 repetitions remain within the original-input limit but expand to 2,004 characters and should be rejected before synthesis.

## Recommendations and verification limits

Address the connector boundary finding and add targeted regression coverage, then rerun affected native tests and rebuild/revalidate artifacts because the native-source receipt will change. The executor should complete the already-planned Swift integration/full-suite and acceptance checks before claiming the repair is complete.

The supplied package reports native RED evidence and final 21 passing native tests (17 pronunciation + 4 FFI). The executor subsequently reported three packaged slices and receipt validation passing. I did not independently execute those checks. My hash inspection establishes agreement of the inspected files with their receipt; it does not independently prove how the libraries were compiled. Focused Swift GREEN was still running in the latest executor update; full-suite and device verification remained pending. Neither those checks nor subjective naturalness are marked passed here. Their pending state is not counted as a code defect.

## Declined to judge

- Final perceived naturalness, pronunciation omissions, and physical playback quality: these need the executor's authorized listening/device work; this reviewer was expressly prohibited from reading audio, and string correctness cannot establish acoustic quality.
- Previously unsupported model glyphs and arbitrary-kanji coverage: the explicit executor ruling retains the existing engine validation error (`SupertonicEngine.swift:58–60`) and excludes a model change; this review does not claim that every preserved Japanese string can be synthesized.
- Downstream Supertonic emoji removal, compatibility decomposition, and symbol replacement: these are unchanged vendor preprocessing behavior (`CatRobot/Vendor/Supertonic/Helper.swift:86–175`); the repair's exact-preservation promise is evaluated at the pronunciation frontend boundary, not as a claim that vendor model preprocessing is lossless.
- The unmerged latency branch's normalized 16-character gate: it is absent from this repair and explicitly reserved for revalidation if rebased later.
- Extending existing URL/email/backtick recognition to additional markup or URL conventions: the contract explicitly retains the existing protected-span behavior; no parser redesign is included, and no new regression in the existing protection path was found.

## Assessment

**Ready to merge? With fixes.**

The main Japanese-surface repair is narrow and preserves the surrounding speech pipeline, but the maximal-term scanner still has a concrete Unicode connector gap that undermines its central no-partial-rewrite guarantee. Fix that boundary issue, consider the small dictionary-expansion coverage addition, and finish the pending verification before treating the repair as accepted.
