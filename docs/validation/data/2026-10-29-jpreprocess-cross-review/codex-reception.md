# Codex reception of Claude's independent /simplify review

Date: 2026-10-29. Frozen source: `feature/jpreprocess-pronunciation`, HEAD `eb41f9c37372892da8b1cda75811ac2d3b28e25e`, base `def7573e2cac602a90b9a321a5038afcd4151220`.

I read `superpowers:receiving-code-review` and the complete `claude-simplify.md`, then checked all S1–S19 and N1–N8 against current code and the accepted requirements. This is technical reception only: no source/index/HEAD/branch edits, Xcode, broad suite reruns, or subagents. Root remains the sole implementation writer.

## Concrete recommendation

- Fix the source-receipt issue S1/R2 and the common-punctuation gap S2/R1. S1 is deterministic developer-workflow breakage; S2 affects actual corrected speech input. S1 is not a production High-severity speech failure, although its small fix is worth taking now.
- S4, S5, and the one-line S6 are reasonable bounded simplifications. S4 needs the public-type adjustment described below. S7 can accompany S2; it is a representation choice rather than another bug fix.
- S3 is a verified available optimization, with the claimed storage mechanism confirmed. Its iPhone footprint benefit is still **needs-evidence**, and it is not a merge requirement. If selected, rebuild the three slices, check behavior/ownership, and measure the same physical-device preparation stage before making savings claims.
- Do not turn S8–S19 or the rejected N items into a mandatory expansion of this task. Several are reasonable optional polish; others would weaken contracts or create unnecessary coupling.

My initial verdict remains **With fixes** for the verified punctuation gap. There is no new requirement for a grammar parser, universal Unicode partitioning, a new fallback, or a new speech engine. Audio naturalness remains unverified by listening.

## Source and probe binding

At reception start, HEAD was the requested SHA, status was clean, and all 49 existing-file hashes matched `baseline-hashes.json`. The native adapter probe used here was compiled from this current frozen source during my initial review, not from Claude's old `17810a1` probe; affected source hashes were rechecked before repeating the cases below.

Fresh reception evidence saved under `codex-probe/`:

- `reception-current-outputs.txt`: current adapter outputs for every quoted S2 family, halfwidth Japanese punctuation, and N2 examples.
- `reception-node-outputs.txt`: pinned current dictionary's initial node surfaces/readings/mora counts, confirming S2's zero-mora boundary cause and the positive-mora N2 cases.
- `reception-legacy-regression-outputs.txt`: current iPhone/Bluetooth outputs around curly quotes, fullwidth brackets, and em dash.
- `reception-receipt-outputs.txt`: current validator fails a valid temporary receipt after adding only a generated target `.rs` file.
- `mmap_probe.rs`, `mmap-heap-outputs.txt`, `mmap-mmap-outputs.txt`, and `mmap-feature-evidence.json`: isolated compilation of the actual public API, real backing-type evidence, sample NJD output parity, and cached resolved `mmap` features on host and all three iOS architecture targets. No device performance measurement was performed.

## S1–S19

### S1 — Accept; fix now, developer reliability (same as R2)

**Code:** `scripts/validate_jpreprocess_assets.py:44` recursively collects matching extensions below the entire crate, including `target/`. The host command at `native/japanese-pronunciation/README.md:18` leaves Cargo's target directory at its default; `.gitignore` does not ignore this target directory.

**Verified effect/reason:** The current validator accepts an isolated valid receipt, then rejects it with `jpreprocess source changed` after only `target/debug/build/serde-123/out/private.rs` is added. Actual cached serde outputs have this filename. This confirms the causal issue without a shared-tree Cargo/Xcode run. It can stop the documented developer workflow, but does not imply that already-built production speech is incorrect.

**Recommendation:** Enumerate native input roots/files or prune generated directories, then add a fixture that generated target sources do not change the receipt. Redirecting and ignoring host Cargo output are useful complements. Prefer an explicit input whitelist over `git ls-files`: the latter makes validation depend on Git availability/index membership and can ignore an untracked native source while it is being developed.

### S2 — Accept narrowly; fix now, user-visible correctness (same family as R1)

**Code:** `native/japanese-pronunciation/src/lib.rs:215` omits the reported curly quotes, fullwidth bracket/brace/quote variants, and dash variants; it also omits the halfwidth Japanese delimiters in R1. At line 176, their zero-mora nodes force whole-run preservation.

**Verified effect/reason:** Fresh current-adapter runs return `“YouTube”を見よう`, `［YouTube］を見よう`, `YouTube—見よう`, `YouTube―見よう`, and `“+ボタン”を押してね。` unchanged. The current pinned dictionary exposes quote/bracket/dash nodes with mora count zero. Current `“iPhone”` and `［Bluetooth］` are also unchanged. The original Swift normalizer's ASCII boundary expression would correct those iPhone/Bluetooth words, so the report's blanket statement that this is not a regression is too broad.

**Recommendation:** Retain a narrow set of common punctuation variants as original-character boundaries and add independent real-dictionary assertions for their surrounding corrections. Fold in `｡､｢｣` from R1. An exhaustive Unicode P*/S* audit test is not necessary to fix the demonstrated contract; it would require explicit exclusions for identifier/linguistic symbols and risks turning a targeted frontend into a Unicode policy project. Do not adopt blanket category splitting or source-position remapping.

### S3 — Needs-evidence for adoption; mechanism/API accepted, optimization nonblocking

**Code/API:** `src/lib.rs:35` uses `SystemDictionaryConfig::File.load`. Pinned upstream `jpreprocess/src/dictionary/mod.rs:27` calls Lindera's filesystem loader; `lindera-dictionary/src/dictionary.rs:83` selects `use_mmap=false`. `jpreprocess/src/lib.rs:165` publicly re-exports `Dictionary`; `Dictionary::load_from_path_with_options(path, true)` compiles with current dependencies. Cached resolved fingerprints show `default,mmap` on host, device arm64, Simulator arm64, and Simulator x86_64.

**Verified effect/reason:** An isolated real-dictionary probe switches `vals_data`, `words_idx_data`, and `words_data` from `Data::Vec` to `Data::Map`, totaling **43,208,821 bytes (about 41.2 MiB)**. Both modes produced identical initial/preprocessed sample readings for YouTube, C++, 3人, and 私は猫です. `Data::Map` owns an `Arc<Mmap>`, and `with_dictionaries` moves the dictionary into the tokenizer; mapping lifetime therefore follows the owned frontend. The `dict.da` trie and matrix are still deserialized into owned structures, as the report says.

**Recommendation:** This is a technically valid change without a new dependency and with the same single dictionary object. Do not equate mapped-byte totals with an observed process-footprint reduction. The existing +144.6 MiB Debug observation does not isolate those allocations. Physical-device A/B preparation measurement, focused behavior/initialization checks, and rebuilt asset receipts are needed if root elects to include it. No unmeasured performance blocker is established.

### S4 — Accept with a public-type adjustment; low-priority simplification

**Code:** `src/lib.rs:98` and line 156 both tokenize, require one node, check the expected surface, and require positive mora count. Their different expected-surface expressions are intentional.

**Effect/reason:** A helper can make that common invariant explicit and prevent drift between plus-lexeme recognition and contextual Latin recovery. However, the proposed `Option<Node>` signature is not directly available through the crate's current direct dependencies: `jpreprocess` re-exports `NJD`, not `NJDNode` (the latter belongs to transitive `jpreprocess-njd`).

**Recommendation:** Prefer a helper returning `Result<Option<jpreprocess::NJD>, Error>` constrained to exactly one known node, then consume its sole node for recovery. This avoids adding a direct dependency just to name the node. Preserve the expected-surface parameter, pre-preprocess checks, error propagation, and C++/unknown-identifier tests. This is worthwhile cleanup, not a current output bug.

### S5 — Accept; low-priority maintenance improvement

**Code:** Alias names are duplicated at `src/lib.rs:26` and line 134, with `_ => "Bluetooth"` as the last replacement arm.

**Effect/reason:** Today's four-name set is consistent. A future regex-only alias addition could silently map to Bluetooth, so a single canonical-name table removes a real maintenance trap without adding vocabulary.

**Recommendation:** Generate the cached alternation from escaped table entries and select the canonical entry with `eq_ignore_ascii_case`. Keep the current ASCII word boundaries and protected-span-first order. Do not change the accepted alias set or introduce a general case-search engine.

### S6 — Accept the one-line mapper reuse; low priority

**Code:** `SupertonicSentenceSpeaker.swift:29` catches `CancellationError` separately, then maps every other pronunciation-service error directly to `.speechSynthesisFailed`. `SupertonicErrorMapper.swift:5` already maps every non-Supertonic error to that same value.

**Effect/reason:** Replacing only the final catch with `SupertonicErrorMapper.map(error)` is equivalent for all current service errors and improves consistency. Keep the explicit cancellation branch. A generic async wrapper shared across the three closures is unnecessary abstraction for this small duplication.

### S7 — Accept as optional alongside S2; low priority

**Code:** `src/lib.rs:215` is a long literal membership match. `c.is_whitespace() || SEPARATORS.contains(c)` has the same character-membership meaning if the set is transcribed exactly.

**Effect/reason:** A named string makes supported variants easier to inspect while adding S2/R1 cases. It is not inherently faster than the compiler's `matches!` representation. Keep the numeric-separator exception in `convert_plain` and preserve an independent expected list/fixtures in tests so a production-list omission is detectable.

### S8 — Defer; bounded allocation and readability tradeoff, no defect

**Code:** `src/lib.rs:64` gathers numeric grouping ranges; line 72 gathers scalar indices for predecessor/successor checks. Group-range boundary checks use slices; decimal neighbor checks use the scalar vector.

**Effect/reason:** An iterator with lookahead can avoid the vector, but the two data structures serve different jobs and are correct now. Inputs are bounded by the existing Swift character and native byte limits. No measured hot path or correctness failure justifies another traversal rewrite in this pass. Preserve grouping/list distinctions if changed later.

### S9 — Defer; plausible micro-optimization, not required simplification

**Code:** `src/lib.rs:90` allocates output and visits identifiers for every run. Replacement at lines 94/116 accepts both plus forms; the identifier replacement at line 112 intentionally accepts ASCII `+` only because that regex's lexemes are ASCII.

**Effect/reason:** A no-plus borrowed fast path could avoid work. A `Cow` return also changes helper lifetimes/signatures, and blindly merging all replacement forms can obscure lexical handling. The bounded frontend has no measured bottleneck here. A narrow no-plus fast path is optional; leave C++ recognition, unknown-identifier preservation, and fullwidth-plus semantics intact.

### S10 — Accept simple `retain`; defer internal mora mutation

**Code:** `src/lib.rs:183` collects pronunciation strings, then allocates a second string to filter U+2019. A mutable result followed by `retain(|c| c != '’')` preserves exactly that operation and the output guard.

**Effect/reason:** The deeper alternative is possible: upstream `Pronunciation::to_pure_string` calls `Mora::Display`, which checks `is_voiced` at `pronunciation/mora.rs:89`; `moras_mut` exists. Changing all flags would suppress markers, but needlessly mutates phonological data and may trigger copy-on-write just to format output. Prefer the shallow string change and retain the allowed-output validation.

### S11 — Decline removing these guards in this pass; accessor refactor deferred

**Code:** `JapanesePronunciationService.swift:43` returns from synchronous actor-isolated `prepare` only with `.ready`, and `src/lib.rs:56` is redundant under today's guarantees that each nonempty retained/converted piece contributes output.

**Effect/reason:** The reachability observation is correct. These cheap checks explicitly enforce important contracts if later preprocessing or preparation code changes. Replacing the Swift state access with a returning accessor is optional, but deleting safety assertions merely because current code implies them is not a useful task requirement. Preserve cancellation positions and sticky initialization failure.

### S12 — Accept optional local constants; retain early validation

**Code:** Swift has two 2,000-character checks and a 32,768-byte check; `SupertonicEngine.swift:57` separately enforces its own limit. Rust already has one `MAX_INPUT_BYTES` definition (`src/lib.rs:9`), reused by `ffi.rs:59`; those are not separate literal runtime constants. The header occurrence is documentation.

**Effect/reason:** Naming the repeated Swift contract values is reasonable, but a cross-language limit-generation system or new generic module is disproportionate. Keep Swift's character, byte, and NUL checks before dictionary preparation; native status 1 currently maps to `.conversionFailed` in the wrapper, so removing them would change error type and failure order.

### S13 — Defer optional test cleanup; no coverage defect

**Code:** The repeated `prepare: {}, normalize: { $0 }` count is indeed 15. `ControlledPronunciation` at `SupertonicSentenceSpeakerTests.swift:270` can be expressed with `ConversationTestGate.wait/waitUntilEntered/open` (`ConversationFakes.swift:182`) plus the desired returned string. Normal-path service tests construct three full dictionary instances; the reuse/failure-path tests intentionally need isolated service state.

**Effect/reason:** A test-only explicit identity-converter helper or shared gate is reasonable. Production must continue requiring a normalization argument. Gate reuse must remain cancellation-uncooperative until released, so the post-await cancellation assertion retains its force. Shared normal-path service state and Rust table helpers are optional readability/runtime tradeoffs; no measured test-runtime problem requires them, and path/initialization tests should stay independent.

### S14 — Accept missing dependency declaration as polish; defer phase abstraction

**Code:** `scripts/generate_project.rb:143` omits imported `prepare_supertonic_assets.py`; the Supertonic phase includes it at line 125. The app disables build-script sandboxing and the phase is always out of date, so this currently causes neither a sandbox denial nor missed invalidation.

**Effect/reason:** Adding the imported helper to declared inputs makes the contract more accurate. The two phase blocks are similar but have different resource setup and file-input enumeration; a generic phase factory for two uses is optional. I did not reproduce the other seat's warm-host timing and do not treat it as a performance guarantee. Keeping always-run integrity checks is consistent with accepted asset reliability requirements.

### S15 — Defer shell rewrite; retain actual architecture verification

**Code:** `scripts/build_jpreprocess.sh:39` removes the known target tree if present and renames a completed package. Equivalent carefully quoted shell operations are possible; Python is already required by the rest of this script.

**Effect/reason:** Removing this small heredoc does not fix behavior, remove a dependency, or establish measurable efficiency. It is optional style. Keep the `lipo` verification at line 27: `validate_framework` inspects Info.plist architecture declarations, whereas this verifies the actual library slices. Preserve fail-closed packaging and receipt generation order.

### S16 — Defer; product/test coupling outweighs six duplicated lines

**Code:** Device `writeWAV` at `SupertonicIntegrationDeviceTests.swift:177` and `PCMPlayer.swift:21` both build/fill an AVAudioPCMBuffer. The test explicitly selects noninterleaved Float32 format and a speech-service failure; the player uses standard format and `.invalidPCM`.

**Effect/reason:** A shared buffer helper is possible, but would expand production audio surface to support one test-file operation and must preserve format/error differences. This is not a pronunciation or playback defect. Do not change production audio solely to satisfy this low-value reuse suggestion.

### S17 — Defer cosmetic ternary; decline removing test-host isolation

**Code:** `CatRobotApp.swift:9` compiles the environment check only in Debug and skips live composition only for the explicit speech test host. The live view-model paths call both speaker preparation and audio-session activation (`ConversationViewModel.swift:500`, line 503; also line 591/594).

**Effect/reason:** A compile-time-safe helper/ternary can remove the duplicated `.live()` text, but offers little value. A fresh service instance in the test isolates its dictionary measurement only; it does not isolate the concurrently live scene or AVAudioSession. The dedicated explicit-env Debug host is an accepted current constraint and was part of obtaining meaningful cold/device evidence. Keep it. The separate background/foreground device prerequisite does not make host isolation unnecessary.

### S18 — Defer; preserve current evidence schema

**Code:** `SupertonicIntegrationDeviceTests.swift:165` repeats the same cold measurement and before/after samples in each record, while line 128 also stores a top-level preparation record.

**Effect/reason:** This costs a small amount of JSON and makes individual fixture records self-contained. Removing it changes the evidence schema and consumers/document references for little practical benefit. Do not rewrite historical result data as part of simplification. A future schema revision can deduplicate deliberately.

### S19 — Decline the stated three-way duplication; optional two-way helper not needed

**Code:** `JapanesePronunciationService.swift:13` and its test's line 6 compute a bundled `dictionary` URL. `ConversationComposition.swift:69` computes the general resource directory only to build the **Supertonic** root/manifest at lines 70–71; it never computes a dictionary URL.

**Effect/reason:** The cited third dictionary-path duplicate does not exist. A shared property could remove the two remaining expressions, but makes the resource-location test depend on the same production calculation and introduces no needed functionality. No change is necessary for this item.

## N1–N8

For these items the decision applies to the proposed change; “Decline” agrees with the report's choice not to implement it.

### N1 — Decline parallel preparation

**Code/effect/reason:** `SupertonicSentenceSpeaker.swift:26` prepares the model before the shared dictionary. Parallelizing two one-time loads could overlap work, but can also overlap allocation peaks and perform dictionary work after a model failure. No production startup-latency defect is established, and the 60 ms single Debug observation is not a guarantee of savings. Preserve current sequencing rather than add initialization concurrency.

### N2 — Decline speculative unknown-kana repair; no demonstrated failure

**Code/effect/reason:** Current-dictionary node inspection gives `ザ/ズ/ゾ/ゾ` each positive mora count 1, and `ぴよぴよ`/`りん` counts 4 and 2. The adapter preserves the first string and returns `ピヨピヨリン` for the second. The alleged zero-mora unknown-kana case is not reproduced. Even for a future true unknown, whole-run preservation is explicitly accepted; it is not automatically a bug requiring guessed readings.

### N3 — Decline blanket Unicode-category separators

**Code/effect/reason:** `convert_plain` currently has explicit retained boundaries and numeric exceptions, while unknown runs remain intact. Unicode symbol/category splitting could break emoji graphemes, identifiers, plus lexemes, or meaningful numeric symbols. S2/R1 calls for narrow punctuation fixes, not a general Unicode parser. Keep unknown/combining preservation and tests.

### N4 — Decline removing canonical aliases

**Code/effect/reason:** `ALIASES` canonicalizes the four explicitly required case variants before dictionary lookup; the real-dictionary tests require lowercase/uppercase YouTube, iPhone, and Bluetooth support. The current public dictionary/tokenizer path performs exact normalized-surface lookup, not a canonical case-insensitive spelling search. Trying only lower/upper variants cannot reconstruct mixed-case dictionary spellings. S5 improves the existing small alias table; it should not remove it.

### N5 — Decline removing voicing-mark/source-coverage protections

**Code/effect/reason:** `src/lib.rs:124` protects unattached marks before upstream normalization, whose fold drops voiced/semi-voiced markers that do not compose. Lines 149/176 verify coverage and initial readings before NJD can remove unknown/silent material. The fixed constraints explicitly require preservation here. Removing these checks would weaken a proven contract for no useful simplification.

### N6 — Decline removing Swift byte/NUL validation

**Code/effect/reason:** `JapanesePronunciationService.swift:40` validates before `prepare`; `NativePronouncer.normalize` maps native nonzero status to `.conversionFailed` at line 73. Removing Swift byte/NUL validation changes `.invalidInput` into a later failure, potentially after loading a missing/expensive dictionary. Keep native defensive validation as well as the early Swift rejection, including its grapheme-count limit.

### N7 — Defer skipping/reordering Latin recovery

**Code/effect/reason:** `src/lib.rs:150` first checks source coverage; lines 156–168 then attempt exact isolated Latin recovery; lines 170–178 decide whether remaining zero-pronunciation nodes require preservation. The recovery fixes an actual contextual tokenizer choice tested by `iPhoneとBluetooth`. An optimization could avoid recovery when another unrecoverable node already determines preservation, but must preserve numeric exceptions and error precedence. No measured need justifies reordering this in the current pass; S4 is the more useful clarity improvement.

### N8 — Defer `withUTF8` copy optimization

**Code/effect/reason:** `JapanesePronunciationService.swift:69` creates one bounded byte array and keeps it alive through the synchronous FFI call. A `String.withUTF8` implementation could be correct if it ensures contiguous UTF-8 storage and limits the pointer lifetime to that closure; it is not universally allocation-free. The copy is at most 32 KiB and no bottleneck is demonstrated. Prefetch does not hide every first-sentence conversion, but that does not make this unmeasured micro-optimization necessary.

## Verification limits and closing state

No implementation fixes were applied by this reviewer. All referenced behavior changes remain proposals for root. No complete Swift/native/asset suite was rerun. Current-source focused probes establish the punctuation and receipt defects and API/storage facts only; they do not establish auditory quality, Release memory behavior, or physical-device mmap savings. Frozen-source integrity and a clean working tree are rechecked after saving this report.
