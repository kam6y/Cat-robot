# Targeted final fix-diff receiving verification

## Scope and identity

This is a targeted reception of the fixes to my original three Important findings, the agreed bounded cleanup, and the user-selected ID paragraph representation. It is not another whole-branch review.

- Base HEAD remains `812bbbf010cf9178562df00ad3592dbb716b1726`.
- Fixed diff: `final-fix-review.diff`, SHA256 `fdaacfbb613453e1288a0768397cdae6d4e86781fe3f238c7300cf19af4d9cf0`. Independently hashed the file and the current tracked `git diff` against the base; both match.
- Declared input digest: `c919e40823159289f385cf685b1f1e5f45400650904393706ca16f515f17d1cf`, from `final-fix-review.json`. I did not independently rerun the complete input-manifest generator.
- Native receipt SHA256: `2ee2883ca23745dc8729e88a780264d32a270c3b1d3faa4de42e657fe555d0ca`, independently matched to `CatRobot/LocalAssets/JPreprocess/native-build.json`.
- No source/index/HEAD changes, test execution, builds or agents. The two earlier review reports remain unchanged. Read existing native result logs, changed tests and the immediate unchanged upstream chunking boundary.

## Original Important findings

### I1: Explicit IDs losing digit boundaries to phone-shape inference — resolved

`native/japanese-pronunciation/src/numbers.rs:25` introduces typed `SourceLabel` values. The single source-label capture distinguishes Identifier, Telephone and Version before number rendering changes the source spelling. At `:226`, Identifier intent is handled before the generic phone-shape branch at `:233`; a zero-leading or hyphenated explicit ID therefore selects Digits. A genuine telephone label and a valid unlabelled phone retain whole-span NJD Phone treatment. Non-phone telephone-labelled sequences retain the existing per-digit fallback.

The new native regression covers `IDは0123456789`, `IDは090-1234-5678`, `電話は090-1234-5678`, and an unlabelled phone. Swift adds a representative zero-leading ID and telephone case across the bundled native boundary. With the final selected ID representation, the expected output has paragraph separators rather than the earlier commas; this is the deliberate human-selected change, not a missing fix.

### I2: Partial conversion at extended semantic-span boundaries — resolved for the reported mechanism

`numbers.rs:142` checks the suffix at the completed `range.end`, including after a clock's minute field or a percentage's percent sign. Shared slash/range/numeric-colon guards apply there, with explicit style-dependent extra guards. `finish_span` returns the recognized range even when its style is rejected. `number_span` then consumes that range instead of reclassifying the numeric prefix as Quantity.

The native regression includes the original time range, comma chain and decimal-colon examples, plus `12345%〜67890%` to catch the dangerous Quantity fallback, phone-colon, slash-separated clocks and fullwidth clocks. Positive `7:30。` and Japanese-comma-separated percentages protect ordinary punctuation. The latter uses the actual library result `サンジュッパーセント`; there is no app-owned pronunciation correction. Swift covers the time-range preservation case.

The quantity scanner's existing invalid adjacent-unit and grouped-percent limitations are separately deferred Minor issues; they are not falsely presented as fixed by this semantic-edge change.

### I3: Explicit version delimiters/particles bypassing preservation — resolved

`SOURCE_LABEL` at `numbers.rs:32` accepts the existing explicit version labels and ordinary folded colon/whitespace/Japanese particles. `semantic_span` rejects Version at `:210`; the Quantity path also requires `label.is_none()` at `:124`, preventing version integers from falling through. Fullwidth punctuation is folded in the bounded source context, while original text ranges remain intact.

The native regression covers `バージョン：3.14`, `バージョンは3.14`, `Ver: 3.14`, and `バージョン 12345`; Swift covers the fullwidth-colon form. This addresses the originally demonstrated labelled forms without introducing general version inference.

## Bounded cleanup reception

- C4: shared `fold_width` is the same FF01–FF5E mapping. The Latin path still checks original eligibility and special combining-mark behavior before calling it. Source offsets are still original UTF-8 offsets.
- C5: `preprocessed_number` is used only by numeric spelling/reading. `known_single_word` and `convert_run` retain their pre-preprocessing node/surface/unknown-word checks and recovery. The unsafe broad helper substitution warned about in the reciprocal report did not happen.
- C8: source context now uses a UTF-8-safe suffix slice bounded to 64 characters; the cheap phone-prefix guard precedes split allocation. The remaining redundant phone prefix check is harmless and not a reason to reopen cleanup.
- No wholesale quantity-regex rewrite, unit-table policy merge, reading cache or equal-text waveform reuse was introduced.

## Accepted ID representation and immediate integration

At `native/japanese-pronunciation/src/lib.rs:143`, each actual digit is still passed individually to `read_number`. The only rendering change is a leading and trailing double newline and double newlines between those genuine NJD readings. Hyphen handling is unchanged. There is no handwritten production reading list, fabricated context, or model/rate/seed change.

The unchanged upstream `chunkText` in `CatRobot/Vendor/Supertonic/Helper.swift:334` splits on paragraph breaks, trims empty paragraphs, and preserves each short nonempty paragraph as its own chunk. The unchanged inference loop at `:705` synthesizes each chunk and inserts its normal 0.3-second inter-chunk silence. Thus the production representation actually invokes the existing library chunking behavior; it is not merely adding punctuation that the model may ignore.

The added Swift test uses the real `SpeechTextAudit` upstream functions, requires 11 chunks for the selected nine-digit fixture, and checks prefix, each digit in order, and suffix. The exact normalized-string assertions and retained 900-digit output-limit test complement that chunk test. Paragraph separators count toward the 2000-character output limit before the speaker trims outer whitespace. Display/memory source text, cancellation/error/ownership boundaries and the existing 60-second synthesis-duration limit are unchanged.

The device diagnostic retains three independent synthesis realizations, records repetition and candidate provenance, and does not deduplicate equal text. The literal paragraph candidate matches the production representation for the selected fixture, but its diagnostic metadata continues to identify it as a fixed comparison candidate. A real production confirmation remains required; matching text alone does not certify audibility across every run.

## Evidence, deferred items and limitations

- Read the existing `native-id-chunks-green.log`: 26 pronunciation tests and 4 C ABI tests pass, with zero failures. This is inspected recorded evidence, not a test run I performed. The parent reports preceding intended REDs and all three rebuilt slices; matching receipt identity was checked here, not a repeat build.
- Final source-bound Swift/full-suite results and final real-production/device confirmation were pending at dispatch. I do not claim they pass or substitute earlier-candidate results.
- The user selected paragraph-separated ID candidate C after being shown approximately 5.4 seconds synthesis and 17.4 seconds playback for the nine-digit example. That explicit tradeoff is documented in the spec and native README. **This ID case does not meet the original S1 2.5-second target; S1 itself remains unchanged.** It must be reported as an accepted exception, not S1 success.
- The user accepted large-quantity waveform variation. Prior ID omissions were acoustic despite complete input; no claim of Rust digit deletion is made. Acceptance of candidate C is not an independently observed final signed-app playback result.
- The two original Minor issues (adjacent malformed magnitude strings and grouped percentages) remain explicitly documented/deferred. This targeted pass does not silently upgrade or close them.
- Very long IDs can exceed the existing synthesis-duration limit even below the text-character limit. The new documentation acknowledges this; this pass adds no new guarantee for arbitrary long ID playback or native mid-call cancellation.

## Scoped verdict

**Unresolved Critical: 0. Unresolved Important: 0 within this targeted fix-diff review.**

The original three Important findings are resolved, and no new actual Important defect was identified in the changed mechanisms. Accept the fix pass from code review, with the two documented Minor deferrals. Overall completion/merge readiness still depends on final source-bound Swift/full verification and real production/device confirmation. Do not report the selected ID case as satisfying S1.
