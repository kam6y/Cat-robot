# jpreprocess Pronunciation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the old two-word speech normalizer with an on-device Japanese pronunciation frontend, improving service names and `+` without losing unknown text.

**Architecture:** A pinned Rust jpreprocess adapter produces safe kana text through a narrow C ABI and static XCFramework. One Swift actor owns the dictionary and is awaited by the existing sentence speaker before synthesis. Unknown text remains intact; operational failures surface through the existing speech error path with no legacy normalizer fallback.

**Tech Stack:** Swift 6, Rust 1.90.0, jpreprocess =0.15.0, iOS 27, Xcode, Python 3 asset tooling, xcodeproj 1.27.0.

**Spec:** `docs/superpowers/specs/2026-10-28-jpreprocess-pronunciation-design.md`

## Global Constraints

- Keep Supertonic model, voice settings, Japanese language, 8 inference steps, and existing 60-second PCM limit.
- Native conversion accepts at most 2,000 Swift Characters and at most 32 KiB UTF-8; output sent to Supertonic must fit 2,000 Swift Characters. Reject excess, never truncate or bypass conversion.
- Preserve original captions, memory, sentence ordinal, one in-flight inference and at most one prefetched sentence.
- No network calls at runtime or in normal Xcode builds; source and asset preparation must be explicit and pinned.
- jpreprocess 0.15.0 dictionary archive SHA-256: `8a930bbc57bf4adcf521d53544c7dc9ab8ab3aa997a591b1b1608dc5539017b8`.
- Protect URL/email/backtick spans and punctuation; preserve unknown spans without calling old two-word replacements.
- Use the existing linked worktree and feature/jpreprocess-pronunciation branch; no push or merge is included.

## Review Focus

- Unknown ASCII, emoji, or detached diacritics in a Japanese sentence must never disappear; native coverage and preservation tests own this.
- `C++`, `1+2`, and URL/email plus signs must take different paths; native lexical tests own this.
- Cancellation while conversion is awaiting completion must prevent synthesis; speaker lifecycle tests own this.
- Expanded kana exceeding engine limits must fail before synthesis without speaking a prefix; service and speaker tests own this.
- A fresh checkout with missing/corrupt dictionary or wrong native architecture must give a useful build error; asset and generator contract tests own this.

---

### Task 1: Native pronunciation and C ABI

**Files:** Create `native/japanese-pronunciation/{Cargo.toml,Cargo.lock,rust-toolchain.toml,src/lib.rs,src/ffi.rs,include/CJPPronunciation.h,include/module.modulemap,tests/pronunciation.rs}` and `native/japanese-pronunciation/README.md`.

**Interfaces:**
- `Pronouncer::load(path: &Path) -> Result<Pronouncer, Error>` and `pronounce(&self, text: &str) -> Result<String, Error>`.
- C: `cjp_create(const char *dictionary_path, void **out_handle) -> int32_t`; `cjp_convert(void *handle, const uint8_t *input, size_t len, char **out_text) -> int32_t`; `cjp_string_free(char *)`; `cjp_destroy(void *)`. Success=0, invalid input=1, initialization/conversion failure=2, panic=3. Output pointer is null on failure; Rust owns returned strings until freed.

- [x] **Step 1:** Prepare a local, pinned Rust toolchain without changing shell profiles. Download official dictionary to temporary storage, verify archive checksum, inspect members, extract only normal files/directories. Record baseline Swift test result before product edits.
- [x] **Step 2:** Write real-dictionary Rust tests with a compilable stub returning input; confirm failures for literal `YouTube -> ユーチューブ`, `YouTuber -> ユーチューバー`, `+ -> プラス`, `C++ -> シープラスプラス`, `1+2 -> イチプラスニ`, and `3人 -> サンニン`. Cover case aliases and preserving URL/email/code, arbitrary unknown text, emoji, punctuation, composed/decomposed kana and detached marks. Use `JPREPROCESS_DICT` to require the real dictionary; missing assets fail, not silently skip.
- [x] **Step 3:** Implement the adapter using jpreprocess typed NJD. Split protected spans before analysis, retain original punctuation, canonicalize only known ASCII aliases, handle standalone plus without changing recognized C++. Check initial normalized surfaces against the input before preprocessing; preserve unsafe/unknown runs intact. Use pure kana pronunciation, never IPA/full-context labels. Keep structural regexes cached rather than compiling each sentence.
- [x] **Step 4:** Add C ABI tests for null arguments/output clearing, embedded NUL, invalid UTF-8, overlong input and valid create/convert/free/destroy. Implement checked lengths, explicit ownership and panic containment; no unwind crosses C.
- [x] **Step 5:** Run `cargo test --manifest-path native/japanese-pronunciation/Cargo.toml --locked` with the real dictionary. Expected: all native tests pass. Commit task source and lock only.

### Task 2: Reproducible assets and iOS linking

**Files:** Create `scripts/prepare_jpreprocess_assets.py`, `scripts/build_jpreprocess.sh`, `scripts/validate_jpreprocess_assets.py`, `scripts/test_jpreprocess_assets.py`, `CatRobot/Resources/jpreprocess-manifest.json`, `CatRobot/Vendor/JPreprocess/{LICENSE,COPYING,PROVENANCE.md,DEPENDENCY-LICENSES.txt}`; modify `scripts/generate_project.rb`, `scripts/test_generate_project.rb`, generated project, README.

**Interfaces:**
- `prepare_jpreprocess_assets.py --root PATH --manifest PATH` downloads the fixed archive and creates `PATH/dictionary/` after hash/type/path checks.
- `validate_jpreprocess_assets.py --root PATH --manifest PATH` validates pinned dictionary files and `PATH/CJPPronunciation.xcframework` supported-platform slices; exit 0 for complete resources, nonzero with a concrete reason otherwise.
- `build_jpreprocess.sh` builds the task-1 static library for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`; packages XCFramework under `CatRobot/LocalAssets/JPreprocess/` with C module `CJPPronunciation`.

- [x] **Step 1:** Write Python tests using tiny controlled archives: valid extraction, corrupt checksum, traversal, link member, missing/changed dictionary file, wrong/missing XCFramework slice. Run `python3 -m unittest discover -s scripts -p test_jpreprocess_assets.py`; expect failures before implementation.
- [x] **Step 2:** Implement archive preparation and manifest validation; download once and record exact extracted dictionary checksums. Build XCFramework with pinned Cargo.lock and target SDKs; copy fixed-version license notices. No install/download is hidden in Xcode generation.
- [x] **Step 3:** Add generator contract assertions that app links native library, both app/test can import its C module as needed, dictionary folder and licenses are resources, validation runs before sources, and no dynamic Rust framework is embedded. Run Ruby contract to see failure, then update generator and regenerate.
- [x] **Step 4:** Run Python asset suite, real asset validation and `ruby scripts/test_generate_project.rb`. Expected: passes and deterministic generated project. Commit scripts, manifest, licenses, project and documentation; ignored assets remain local.

### Task 3: Swift service and complete replacement

**Files:** Create `CatRobot/Conversation/Services/Speech/JapanesePronunciationService.swift` and `CatRobotTests/Conversation/Services/JapanesePronunciationServiceTests.swift`; delete `SpeechPronunciationNormalizer.swift`; modify `SupertonicSentenceSpeaker.swift`, `SpeechVoiceSettingsTests.swift`, `SupertonicSentenceSpeakerTests.swift`, `ReplySentenceStreamBufferTests.swift`, and other speaker test construction sites.

**Interfaces:**
- `actor JapanesePronunciationService`: `static let shared`; `init(root: URL)`; `func prepare() throws`; `func normalize(_ original: String) throws -> String`. Actor-isolated native handle is created once, destroyed once and never used concurrently; failed initialization is retained. Return original only for intentional unknown/protected spans from native results; operational failures throw.
- Speaker designated initializer adds required `normalize: @escaping @Sendable (String) async throws -> String`. Production convenience initializer awaits shared service preparation/normalization; test callers explicitly inject identity or controlled converter. `onInput(original, spoken)` is emitted only after successful conversion.

- [x] **Step 1:** Add service tests with real bundled assets for kana conversion, original/protected content, missing dictionary failure, repeated preparation, input/output limits and NUL rejection. Add speaker tests asserting converted text reaches synthesize, conversion failure causes zero synthesis/playback, original audit remains intact, cancellation after blocked conversion causes zero synthesis, and expansion error never speaks a prefix. Establish RED before implementation.
- [x] **Step 2:** Implement actor ownership and FFI wrapper with cancellation checks. Replace the synchronous legacy call with awaited injection and post-await cancellation check. Map native/service failures to existing `speechSynthesisFailed`; do not convert cancellation into another error.
- [x] **Step 3:** Remove old normalizer and relocate its meaningful protection/alias coverage into real frontend tests. Update stream buffer test to assert raw sentence preservation only; protection across splits is verified using new frontend. Explicit identity injection keeps unrelated pipeline tests light and preserves their behavioral assertions.
- [x] **Step 4:** Regenerate project, run generator contract, then relevant service, speaker, sentence-playback, voice-settings, face-playback and motion-playback suites. Expected: all selected tests pass. Confirm tests prove no legacy fallback by making conversion throw and observing no synthesize call. Commit task changes.

### Task 4: Whole-app verification and device evidence

**Files:** Create `docs/validation/2026-10-28-jpreprocess-pronunciation.md`; modify `CatRobotTests/Device/SupertonicIntegrationDeviceTests.swift` only if needed for a small explicit pronunciation stage; update docs index and README with real build/use instructions.

**Interfaces:** Consume task-3 production speaker and task-2 prepared assets. Record exact source revision, native/dictionary version, test results and device outcome.

- [ ] **Step 1:** Run the complete Simulator app test suite with explicit existing device-only skips. Run full native and asset suites after final changes; read failures and fix actual regressions without weakening assertions.
- [ ] **Step 2:** Build signed iPhone app. Produce short original/new Supertonic audio samples for plus, YouTube, counters and a natural greeting with the same F1/steps settings, capturing actual normalized strings. Record audible assessment only where listened to; otherwise label pending. Measure cold/warm frontend latency, native/dictionary app size and device memory when available.
- [ ] **Step 3:** Perform the required fresh whole-branch code review using requesting-code-review; resolve material findings with focused regression tests and appropriate suite validation. Record limitations and decisions in validation document.
- [ ] **Step 4:** Install/launch on the connected iPhone and verify the running app if available. Preserve all original response text and report any unverified hardware/audio outcomes. Commit final docs/tests after validation. Do not push/merge without a new request.
