# Natural Japanese Speech Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for inline implementation. Track completed steps here; do not repeat completed checks without a new change or failure.

**Goal:** Implement the user's natural-sounding C comparison on main while retaining dictionary-based Latin/+ correction.
**Architecture:** Preserve nontarget text exactly; normalize only complete Latin terms through the existing validated dictionary path. Protected ranges and speech pipeline APIs stay intact.
**Tech Stack:** Rust1.90/jpreprocess0.15, Swift/XCTest, existing native packaging.
**Spec:** docs/superpowers/specs/2026-10-29-natural-japanese-speech-repair-design.md

## Global Constraints

- Work on main as explicitly requested; no latency branch merge.
- Preserve Japanese/numeric/punctuation/combining text outside Latin targets. Keep safe known-term correction, plus/C++, unknown identifiers and protected URL/email/code.
- Retain dictionary/cancellation/error/input and expanded-output guards. Preserve model/voice/steps/speed/threads and memory/playback ordering.
- Never commit private history or its full generated transcript. Local diagnostic comparison is separate from accepted device evidence.

## Review Focus

- Unicode Latin words/fullwidth forms must not be corrected in partial fragments; Japanese combining marks outside them remain exact.
- Unknown identifier plus and C++ must not be corrupted by symbol replacement.
- Unknown Latin or emoji next to a known term must not delete text or disable correction elsewhere.
- Spoken-length expansion limit must remain effective after Japanese conversion is removed.
- Source receipts and packaged native library must correspond to the tested source, not cached old behavior.

### Task1: Targeted native normalization and regression tests

**Files:** native/japanese-pronunciation/src/lib.rs, tests/pronunciation.rs, tests/ffi.rs.
**Interfaces:** existing Pronouncer.pronounce/C ABI signatures unchanged, Japanese preserved and known Latin/+ corrected.
- [x] Add literal C-matching mixed-sentence/Japanese-preservation/Unicode-Latin behavior cases and run before implementation: expect current full-kana failures.
- [x] Apply only complete Latin-term correction in convert_plain/convert_run; keep dictionary validation and protected spans. Remove obsolete full-Japanese separator/number machinery only where unused.
- [x] Update old full-kana expectations to targeted surface-preserving expectations; run all native/FFI tests. Expected: zero failures, original protection/error assertions retained.

### Task2: Swift integration, packaging and acceptance

**Files:** existing JapanesePronunciationServiceTests.swift and SupertonicSentenceSpeakerTests.swift, native receipts/provenance, docs/validation/2026-10-29-natural-japanese-speech-repair.md and docs/README.md.
**Interfaces:** native output flows through unchanged Swift speaker; tests pin C output and real Latin expansion limits.
- [x] Add/update real dictionary mixed-language expected outputs and output-limit case using actual symbol expansion through the shared post-normalization guard; run red/green against rebuilt library without bypassing validation.
- [x] Rebuild native3targets and validate receipts/assets; run focused Swift and then full suite once; run relevant Python and project contract. Expected zero failures, physical-only skips explicit.
- [x] Use an external current-source synthesis probe for C-like output; run signed physical reproduction/playback if available, then restore normal app. Keep model/voice/steps unchanged.
- [x] Request one fresh whole-fix review; receive materially, fix regressions with tests; rerun affected checks only.
- [x] Save source proof, verification, comparison/limitations and reviewer decisions; clean working tree and commit main repair. Do not publish private data.
