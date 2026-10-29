# Fresh jpreprocess feature review

Reviewed 2026-10-29. Base `def7573e2cac602a90b9a321a5038afcd4151220`, head `eb41f9c37372892da8b1cda75811ac2d3b28e25e`, branch `feature/jpreprocess-pronunciation`.

This is the initial independent, read-only review under `superpowers:requesting-code-review`. No earlier reviewer conclusions were used as evidence. The checkout, index, HEAD, and branch were not changed. No subagents or Xcode builds were run. Mutual reception of the next independent report is pending and is not represented here.

## Strengths

- The separation is small and understandable: Rust owns dictionary analysis, the C interface documents allocation and serialization, one Swift actor owns the handle, and the existing speaker receives a single asynchronous normalization function. `JapanesePronunciationService.swift:26` retains initialization failure, reuses a prepared dictionary, and frees the native handle through ARC.
- `SupertonicSentenceSpeaker.swift:96` checks cancellation on both sides of conversion, preserves the original sentence for audit/events, and does not fall back to original synthesis when conversion fails. The controlled conversion test explicitly verifies zero synthesis, playback, and audit callbacks after cancellation.
- The frontend verifies normalized surface coverage and empty pronunciations before destructive NJD preprocessing. Real-dictionary cases cover emoji, unknown ASCII, detached marks, composed/decomposed kana, protected spans, C++, and arithmetic/service plus. My additional current-source probes preserved unknown/combining content as intended.
- Input and expanded-output limits are enforced before synthesis. The 1000/1001-cat fixtures test the actual expansion boundary, and the speaker test verifies that the over-limit case does not speak a prefix.
- Explicit dictionary acquisition, per-file hashes, static-library packaging, native source/artifact receipts, and build-time validation form a useful reproducible contract. The application keeps the existing engine, voice selection, 8 steps, and one-next-sentence playback structure.
- Tests use actual dictionary/FFI integration where it matters and lightweight injected converters in unrelated pipeline tests. No broad test rerun was needed to establish the findings below.

## Issues

### Critical (Must Fix)

None found.

### Important (Should Fix)

### R1 — Halfwidth Japanese delimiters disable correction for the entire known phrase

- **File:** `native/japanese-pronunciation/src/lib.rs:215` (`is_separator`), used at line 80; the resulting zero-reading punctuation node causes the whole-run return at line 178.
- **Verified reproduction:** Compiled the current source into an isolated host probe and loaded the pinned real dictionary. `+ボタンを押してね｡` returns exactly `+ボタンを押してね｡`, `｢+ボタン｣` returns exactly `｢+ボタン｣`, and `YouTube､Bluetooth` returns exactly `YouTube､Bluetooth`. Corresponding fullwidth punctuation inputs convert normally, e.g. `「+ボタン」` returns `「プラスボタン」`.
- **Cause/effect:** The retained-separator list contains `。`, `、`, `「`, and `」`, but omits their established Japanese halfwidth counterparts `｡`, `､`, `｢`, and `｣`. These are punctuation, not unknown lexical content. Letting them enter NJD makes a whole otherwise-known phrase fail the safe-reading test. The central plus/name correction therefore silently disappears in ordinary halfwidth-punctuation text, contrary to the punctuation-boundary contract. This also regresses the old iPhone/Bluetooth correction around these marks.
- **Fix:** Treat these four halfwidth delimiters as retained boundaries, preserving the original mark rather than normalizing it. Add real-dictionary assertions for the above inputs with expected `プラスボタンヲオシテネ｡`, `｢プラスボタン｣`, and `ユーチューブ､ブルートゥース`. Test priority: 6/10; it prevents a verified user-visible regression without broadening grammar handling.
- **Evidence:** `/private/tmp/cat-jpreprocess-cross-review-20261029/codex-probe/punctuation-outputs.txt` and `outputs.txt`.

### Minor (Nice to Have)

### R2 — The source receipt also hashes generated Cargo build output

- **File:** `scripts/validate_jpreprocess_assets.py:46` (`native.rglob("*")`). The host command documented at `native/japanese-pronunciation/README.md:18` does not redirect Cargo's default target directory.
- **Verified reproduction:** An isolated fixture with a valid source/artifact receipt passes. Adding only `native/japanese-pronunciation/target/debug/build/serde-123/out/private.rs` causes `native_sources()` to include that file and `validate_receipt()` to fail with `jpreprocess source changed; rebuild with scripts/build_jpreprocess.sh`. The cached real serde/serde_core builds both contain `out/private.rs`, so this is representative build output.
- **Effect:** Running the documented native host tests after preparing assets can invalidate an otherwise-current native receipt even when tracked native inputs are unchanged. A receipt generated after those tests can also depend on local, host-specific generated files. The build remains fail-closed, so this is a developer-workflow problem rather than incorrect shipped speech.
- **Fix:** Hash explicit native input roots/files (`src`, `tests`, `include`, Cargo manifests/lock/toolchain, build script), or prune `target` and other generated directories. Redirecting/ignoring native Cargo output in the documented test command would also avoid checkout pollution. Add a small fixture assertion that adding a generated target `.rs` file does not change source hashes. Test priority: 4/10.

## Validation and coverage assessment

- Independently compared current files to the frozen baseline: all 49 existing-file SHA-256 entries match; HEAD is the requested `eb41f9c`. The deleted old normalizer remains deleted. Final working-tree status is clean.
- Independently compared the 29 files in `tested-source-hashes-pair.json` with the checkout: no mismatches. The recorded exact-source Swift log reports 847 tests, 2 physical-only skips, zero failures; the recorded native log reports 16 tests; asset tests report 7. These are inspected prior-run evidence, not suites executed by this review.
- Fresh isolated compilation used the current `src/lib.rs` and `src/ffi.rs` with cached pinned dependencies. Two focused probe batches exercised punctuation variants, C++/mixed-width plus, numeric grouping, protected/unknown sequences, emoji/variation selectors, and combining marks. Results are saved under `codex-probe/`. The receipt fixture used the current validator without writing Python bytecode to the checkout.
- Inspected service, speaker, stream/playback integration, generator contracts, and device-trial code. Strong lifecycle/boundary tests are already present. Findings R1 and R2 identify concrete missing cases; I found no reason to add broad mock-heavy or implementation-mirroring tests.

## Recommendations

Fix R1 with narrow separator cases and regression assertions. R2 is a small tooling cleanup that can be addressed independently. Keep the existing fail-closed conversion and conservative unknown-run behavior; this review does not recommend a new fallback, grammar parser, dictionary, or engine.

## Declined to judge

- Auditory naturalness and whether the saved PCM sounds better: no samples were listened to in this review; string/finite-PCM success does not establish it.
- Universal grammar, clock-expression verbalization, and contextually ambiguous kanji readings: these are explicitly outside the accepted guarantee; the fixed ambiguity examples are documented rather than hidden.
- Recovering only known fragments inside an unknown/emoji run: the accepted policy permits preserving the entire run, and the probes confirm preservation.
- Japanese immediately following an unspaced URL being protected by the inherited URL expression: preserving the existing protected-range behavior is an explicit constraint.
- Release/App Store distribution size, long-session memory behavior, mmap optimization, and multi-device performance guarantees: the available measurement is a clearly labeled single Debug/device observation; no broader guarantee is made.
- Independent legal certification of all transitive license obligations: provenance and bundled notices were inspected for integration, but a legal opinion or a complete license-text audit is outside this code review.

## Assessment

**Ready to merge? With fixes.**

The architecture, error/cancellation path, bounds, and real-dictionary validation are sound on inspection and focused probes. R1 is a verified user-visible gap in the promised punctuation handling and should be corrected before merging; R2 is a nonblocking source-receipt precision issue. Audio improvement remains unverified by listening.
