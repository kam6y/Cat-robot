# jpreprocess whole-branch code review

Reviewed range: `def7573e2cac602a90b9a321a5038afcd4151220..17810a158442d6f3be2f31e77c1092db7d6b2466`.

One fresh review using `superpowers:requesting-code-review/code-reviewer.md`. Reviewed the actual changed executable source, tests, generated-project changes, preparation/build tooling, plan, specification, and ledger rulings. The checkout, index, HEAD, and Xcode derived data were not changed. No subagents or broad test reruns were used.

## Strengths

- Native preservation is checked before destructive NJD preprocessing: detached voicing marks retain the original run; normalized source coverage and nonempty readings are checked before `njd.preprocess()` (`native/japanese-pronunciation/src/lib.rs:94`, `:119`, `:140`). Unknown text therefore does not depend on reconstructing already-discarded nodes. Protected spans are copied directly.
- The C boundary documents ownership and serialized access, clears outputs on failure, bounds byte input, checks UTF-8, and contains Rust panics (`native/japanese-pronunciation/src/ffi.rs:11`, `:28`, `:50`). Swift owns the handle through one actor and frees each returned string with `defer` (`CatRobot/Conversation/Services/Speech/JapanesePronunciationService.swift:12`, `:69`). Initialization failure is retained rather than retried for every sentence.
- The speaker has required async conversion injection and a cancellation check immediately after conversion, before audit callbacks and synthesis (`CatRobot/Conversation/Services/Supertonic/SupertonicSentenceSpeaker.swift:96`). Existing one-ahead prefetch, voice selection, model parameters, and playback ordering remain intact. The cancellation regression blocks conversion, stops the speaker, releases conversion, and asserts zero synthesis/playback (`CatRobotTests/Conversation/Services/SupertonicSentenceSpeakerTests.swift:79`).
- Input and expanded-output limits reject the complete sentence. Service tests exercise the exact 2,000-character output boundary and expansion failure; the speaker test verifies that expansion failure never reaches synthesis (`CatRobotTests/Conversation/Services/JapanesePronunciationServiceTests.swift:57`; `CatRobotTests/Conversation/Services/SupertonicSentenceSpeakerTests.swift:106`). The deleted legacy normalizer has no fallback call path.
- Asset preparation validates the pinned archive, restricts extraction to expected regular files, verifies extracted file hashes, and publishes the dictionary only after verification. Native packaging checks actual device/simulator architectures; ordinary builds validate source/artifact receipts and dictionary checksums without downloading or compiling Rust (`scripts/prepare_jpreprocess_assets.py:19`; `scripts/build_jpreprocess.sh:26`; `scripts/validate_jpreprocess_assets.py:12`, `:58`). Generated-project inspection found the intended native link, resource, service/test, and validation additions, with removal of the old normalizer and otherwise regenerated identifiers.

## Issues

### Critical — Must Fix

None found.

### Important — Should Fix

None found.

### Minor — Nice to Have

None requiring a code change identified.

## Evidence checked

- `full-suite.log`: 847 executed, 2 explicitly skipped physical-device tests, 0 failures, `TEST SUCCEEDED`.
- `native-final-all.log`: real-dictionary and FFI test results; 14 tests passed across the two integration suites.
- `assets-final.log`: 7 tests passed. `asset-validation-final.log` and `generator-swift.log`: successful asset and deterministic-project checks.
- Independently hashed all 28 entries in `tested-source-hashes.json` against the reviewed checkout: zero mismatches. `git diff --check` passed and checkout status was clean.
- Compiled a temporary host probe against the existing tested native library, without changing repository source. It confirmed preservation for `前qqqq後`, `前YouTube😀後`, `あ\u{3099}`, `a\u{0301}`, `漢\u{0301}`, and unknown identifier examples; `C++を使う` produced `シープラスプラスヲツカウ`. The temporary source and executable are `review-probe.rs` and `review-probe` beside this report.
- An attempt to independently extract the xcresult summary encountered a local TestReport write-permission error; the existing full-suite text log supplies the counts above. No test-result success was inferred from that failed extraction.

## Recommendations

Complete the already-running physical-device verification and update the measurement-only validation document and task-4 checkboxes with actual outcomes. Keep generated audio evidence separate from listening approval; this review does not establish improved perceived pronunciation or naturalness.

## Declined to judge

- Auditory correctness/naturalness of the generated Supertonic speech: no listening evidence was available to this reviewer; explicitly pending in the plan and documentation.
- Physical-device startup, memory increase, cold/warm latency, and signed-build execution: the parent owns the device run, which had not completed when this source review concluded. Simulator results do not establish these properties.
- Universal readings for ambiguous names, version-like numeric strings, very large numbers, and every mathematical expression: deliberately outside the specification's reading guarantee; no promise of universal normalization is introduced by the reviewed code.
- Converting the known Japanese portions of a run that also contains unknown text: whole-run preservation is an explicit accepted design choice, and the reviewed preservation behavior follows it.
- Resistance to deliberately forged local native-build receipts or invalid raw pointers supplied by an in-process C caller: the build workflow and C ABI have explicit trusted-tool/caller preconditions; these are not claimed security boundaries.
- Exhaustive legal verification of all third-party notice text: provenance records, notice presence, and app bundling were inspected; this review does not certify every upstream license reproduction.

## Assessment

**Ready to merge? Yes, from the code-review perspective.**

The implementation matches the authorized complete replacement and the five stated review priorities, with behavioral tests covering the principal failure and cancellation paths. No code revision is requested by this review; remaining device measurements and listening status must still be reported accurately before claiming the overall implementation task fully verified.
