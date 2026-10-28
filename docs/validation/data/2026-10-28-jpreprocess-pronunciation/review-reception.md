# レビュー指摘の採否と最終検証

Independent final review def7573..17810a1: Critical 0, Important 0, Minor 0. Reviewed the entire final-review.md and its evidence. No code changes requested; all 28 tested hashes match.

Declined-to-judge rulings:
- Auditory correctness/naturalness: do not infer from string or PCM tests; actual listening remains pending and will be explicitly reported. Cost if wrong: perceived readings/intonation may be worse despite valid conversion.
- Physical startup/memory/latency/signed execution: parent owns device verification, currently retrying after installer-service disconnection. Do not claim a physical pass from Simulator. Cost if unresolved: hardware deployment/performance remains unverified.
- Universal ambiguous names/version strings/very large numbers/math: spec makes no universal guarantee. Preserve unknowns and tested supported cases; no new grammar engine. Cost: some unsupported forms retain current errors.
- Known portions in an otherwise unknown run: retain conservative whole-run preservation as explicitly designed; avoids silently deleting unknown text. Cost: known words in that run may remain uncorrected.
- Forged local receipts/raw invalid pointers: trusted build tooling and in-process C callers are documented preconditions; not a general security boundary. Cost: malicious local/in-process callers are not defended by the wrapper.
- Exhaustive license legal certification: pinned notices, provenance and bundling inspected, not a legal opinion. Current scope requires actual notices/provenance; no contrary evidence found.


Claude findings and decisions:
- P1 Important accepted: native RED reproduced Disney+ -> ディズニータス. Dictionary single-token known lexemes (C++) keep their lexical reading; other plus signs verbalize as プラス. Unknown identifiers still fail safe to their complete original run. Regression includes Disney+, Apple TV+, A+, A+B, x+1, g++, i++; existing preservation tests retained.
- P2 Important accepted: native RED reproduced +ボタンを押してね♪ unchanged. Explicit common punctuation boundaries preserve marks and allow neighboring known text to convert. Extended_Pictographic/general unknown grapheme splitting not added; old emoji/combining preservation contracts retained. Numeric range/time/math grammar expansion remains out of scope.
- P1/P2 GREEN: 16 native tests (12 pronunciation + 4 FFI), zero failures; pair-findings-red.log and pair-findings-green.log. Final XCFramework rebuilt before full Swift regression.
- P3 accepted as validation limitation: dictionary ambiguity can force less appropriate kana (辛いカレー -> ツライカレー); add service-plus and ambiguous/temperature/clock A/B fixtures. No unlistened blanket ヲ/archaic-kana substitutions. Cost: known dictionary/contextual reading limitations remain.
- P4 heap/mmap: measure first, no unproven memory optimization or new unsafe API in this fix pass. Report current file/bundle size and actual net physical footprint honestly; Rust allocation exhaustion is not a caught conversion error. Current readings use one retained dictionary.
- P4 URL suffix protection: inherited behavior, no URL-boundary redesign. Cost: adjacent Japanese without a boundary can remain uncorrected.
- P4 invalid output wording: clarify spec to distinguish pre-analysis unknowns (original retained) from failed/invalid generated output (speech error), consistent with user's prior no-fallback authorization. No runtime behavior change.
- Bounded app-host supplement: Claude found no issue with DEBUG + explicit env isolation and idle timer restoration. Playback failure's UI/audio interference hypothesis was NOT proven: isolated retry still got 561015905. Isolation is retained because it proves correct first dictionary preparation. Measurement now runs BEFORE model preparation to avoid large concurrent model allocator release (earlier net footprint was negative). Trial reactivates its owned audio session after warmup/cooldown and records application state/category/sample rate to diagnose remaining hardware behavior.


Final verification: code changes committed as 184aee7. full-suite-pair 847 total / 845 passed / 2 explicit physical-only skips / 0 failures. Physical foreground run 1 passed / 0 failures, 8 comparison pairs / 16 nonempty finite PCM WAV exports; production sentence speaker completed playback. The same signed app was relaunched in normal mode, process PID3477 confirmed. Exact source hashes (29) unchanged. Dictionary first preparation before model load: 60.0 ms, net process footprint +151,601,296 bytes (single Debug observation). Audio naturalness/accuracy remains unlistened; known dictionary misreadings retained in fixtures.

Corrected device-cause ruling: isolating the live UI corrected measurement contamination but did not eliminate playback error. The later failing run recorded UIApplication background state 2 and rejected activation 561015905. Activating the EXISTING test process without termination gave state 0 and the same test/signed source passed. Background launch explains this reproduction; no production PCMPlayer change was made. The background and failed measurements remain historical evidence.

Deferred minor: URL regex can protect adjacent Japanese text without whitespace, inherited from prior implementation. Dictionary mmap optimization/archaic-kana support remain optional and unsupported by an observed failure; neither is introduced in this pass. Generic ambiguity/time/temperature rules require separate design and listening evidence rather than blind substitutions.
