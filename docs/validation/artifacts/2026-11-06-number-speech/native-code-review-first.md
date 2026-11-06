# Independent first code review — issue 24

Scope: BASE `b050575f88b6f14f520f3ee968c42c0ad6021e3c` → HEAD `812bbbf010cf9178562df00ad3592dbb716b1726`, tree `434b28fea2b21f73a52e4c13cd585989eff933b6`. Fixed diff SHA256 `0873d43729bf3314a25a68be55e1299ad1cf74f87428f491a78d81fe0cf0c21b` verified. Read all changed implementation/test/documentation paths and immediate Swift/C ABI/sentence-speaker boundaries. No other reviewer or Claude findings were read. No agents were dispatched. Checkout/index/HEAD unchanged.

For independent reproductions I compiled the fixed Rust source into `independent-native-review/libcjp_pronunciation.rlib` using the task's Rust 1.90.0 and existing compiled dependency rlibs (read-only), then compiled a private CLI. It loads the actual bundled dictionary. All writes/build outputs are under this report's adjacent `independent-native-review/` directory. Observed outputs are preserved in `independent-native-review/reproductions.txt`. This was not a full-suite rerun.

## Strengths

- Library ownership is real: NJD generates quantity surfaces and phonetic readings, and ID mode invokes the dictionary on actual one-character inputs. There is no digit-reading lookup table, fabricated sentence context, new dependency, or whole-sentence kana conversion.
- Maximal identifier/protected-span handling is reused. Grouped decimal and Latin-tail cases are consumed atomically in the quantity path, avoiding particularly damaging partial rewrites.
- Swift still owns input/output limits, cancellation checks, native handle ownership and explicit operational errors; normalization changes only the speech input. The added 900-digit ID expansion test counts pauses toward the output limit.
- Tests exercise real dictionary results and Swift/C ABI integration, not only mocked spelling. Diagnostic literals and actual pipeline inputs are distinguished; documentation correctly separates generated PCM from human sound-quality acceptance.

## Issues

### Critical (Must Fix)

None found in this fixed scope.

### Important (Should Fix)

1. **Explicit IDs that resemble phone numbers bypass the required per-digit pauses.** `native/japanese-pronunciation/src/numbers.rs:208` (phone dispatch before labelled dispatch).
   - Trigger: `IDは0123456789`.
   - Observed: `アイディーはゼロイチニーサンヨンゴーロクナナハチキュー`, with no digit separators. In contrast, `IDは1234567890` receives separators between every digit. The same conflict occurs for an explicit ID containing a phone-shaped hyphenated token.
   - Effect: ordinary zero-prefixed ten/eleven-digit identifiers silently return to the uninterrupted reading that motivated the ID audibility change. Explicit source semantics lose to a shape heuristic; the current happy-path ID tests all start with nonzero digits.
   - Fix: let explicit ID/number intent select per-digit treatment before generic phone-shape inference, while retaining standard whole-phone pronunciation for genuine phone contexts. Keep the label policy centralized and add actual-dictionary regression cases for zero-leading explicit IDs versus unlabelled phones. Test priority: 8/10.

2. **Semantic conversions validate the wrong right edge, so ranges and invalid numeric chains are partly rewritten.** `native/japanese-pronunciation/src/numbers.rs:187`, `:231`, `:262`, `:266`.
   - Triggers/observed outputs: `7:30〜8:30に集合` → `七時三十分〜8:30に集合`; `7:30,000` → `七時三十分,000`; `25%〜30%` → `ニジューゴパーセント〜30%`; `3.14:1.59` → `サンテンイチヨン:1.59`.
   - Effect: common time/percentage ranges get inconsistent treatment, and malformed numeric expressions no longer retain their complete original representation. The second operand is rejected because of its left boundary after the first operand was already transformed. For Time/Percent, the initial check examines the suffix after the first identifier instead of after the complete accepted span. Decimal/Phone also lack a consistent numeric-colon right-boundary check.
   - Fix: validate boundaries at the complete proposed span end before committing any semantic style, including unit/percent/clock extension. Apply the conservative whole-expression retention policy consistently. Add range/chain composition cases, not only isolated `7:30` and `25%`. Test priority: 8/10.

3. **Common explicitly labelled version forms are still read as decimal quantities.** `native/japanese-pronunciation/src/numbers.rs:249`.
   - Triggers: `バージョン：3.14`, `バージョンは3.14`, `Ver: 3.14`.
   - Observed: all replace `3.14` with `サンテンイチヨン`; e.g. `バージョン：サンテンイチヨン`.
   - Effect: the new decimal path changes version strings even when the immediately preceding prose explicitly identifies the meaning. A colon or the normal Japanese particle defeats the guard, despite the documented version-preservation policy. This is not a request to infer arbitrary unlabeled versions.
   - Fix: recognize the existing explicit version labels through ordinary delimiters/particles, using one bounded context rule analogous to the ID policy. Add colon, fullwidth-colon and Japanese-particle variants alongside the existing whitespace regression. Test priority: 7/10.

### Minor (Nice to Have)

1. **Consecutive magnitude characters evade atomic malformed-unit preservation.** `native/japanese-pronunciation/src/numbers.rs:94`.
   - Trigger/observed: `1万万2` → `一万万2`; `1万億円` → `一万億円`.
   - Effect: after consuming one trailing unit the scanner treats the following unit as ordinary Japanese, converting a valid-looking prefix of malformed notation. Impact is limited to malformed/unusual input, but contradicts the explicit unit-chain preservation contract.
   - Fix: reject/consume contiguous invalid magnitude chains as a whole rather than accepting the first unit. Cover repeated/increasing adjacent units, as well as the already covered digit-separated `1万2億` case. Test priority: 4/10.

2. **A valid grouped percentage never reaches the percentage reading path.** `native/japanese-pronunciation/src/numbers.rs:126` and `:262`.
   - Trigger/observed: `1,500,000%` → `百五十万%`.
   - Effect: grouping chooses Quantity before the complete span can be classified as Percent, leaving the original `%` despite the promised standard percent pronunciation. The basic `25%` fix does not compose with the grouped-number feature. Large percentages are uncommon, so this is a lower-priority gap; no acoustic failure for this exact input is claimed.
   - Fix: once a complete valid grouped integer is identified, allow an immediately attached percent to select the library's whole-span percent treatment; verify actual NJD output before choosing the implementation. Preserve grouped decimals under the existing conservative policy. Test priority: 5/10.

## Recommendations

- Resolve the three Important admission/precedence issues with small real-dictionary RED→GREEN tests and one representative Swift integration case where useful. Avoid expanding this into a general number parser or adding custom numeral readings.
- Keep first reports immutable. Rebuild the three native slices and validate receipts after any production Rust fix; rerun affected checks and the required final suite against the resulting source identity.
- Sound quality remains a separate acceptance gate. The parent supplied a fresh human update during this review: quantity waveform variation is accepted, but the paused-ID audio may skip digits even though the submitted synthesis string contains all nine. This is an unresolved acoustic result, not evidence that this Rust function dropped digits. Do not claim the final ID listening gate has passed.

## Declined to judge

- Full current 1001-test suite success: still running at dispatch; prior 1000-test results and focused 44/native 27 results are reported evidence, not independently rerun here. I do not promote prior-candidate success to current-candidate success.
- Final ID audio intelligibility/digit omission: human reports a possible failure; I inspected text conversion, not the audio/model internals. It remains a completion gate for the executor, not an invented source-level diagnosis.
- Large-quantity waveform variation with identical input: user has accepted this variation per the parent's update; no seed/rate/model workaround is requested or reviewed.
- Bare unlabelled identifiers versus quantities: impossible to infer universally; the explicit conservative contract is reasonable. No arbitrary-ID heuristic requested.
- International/space-separated/parenthesized phone formats: explicitly outside the narrowly selected Japanese phone scope. The current shape heuristic also accepts unusual 3-group lengths; I did not assert a defect without a demonstrated meaning/reading failure.
- Mixed kanji/Arabic quantity forms such as `1千万円`, exponent notation, and grouped decimals: documented conservative non-targets; retaining them is acceptable.
- Oversized unit coefficients such as `100000000京` producing `一億京`: tested and observed, but no unsupported model character or digit deletion occurred. This is unusual notation; the literal digit cap versus magnitude-value wording should be explicitly ruled on by the executor rather than silently claimed as a universal numeric-value cap.
- Leading plus forms: `+1500000` becomes `プラス百五十万`, `+3.14` becomes `プラスサンテンイチヨン`. This differs from the broad signed-notation retention wording but retains meaning and the established plus pronunciation. I did not require a functional rollback; executor should clarify the intended policy.
- Decimal temperatures: `3.14℃` becomes `サンテンイチヨン℃`, while `25℃` remains unchanged. The temperature-preservation wording is broader than the implemented decimal policy; no acoustic regression was demonstrated, so executor should rule on/document this boundary.
- All-zero clock field uses the fixed orthographic `零`: a single spelling fallback is not a pronunciation table or an independent numeral decomposition algorithm; no defect raised.
- Per-digit dictionary-call cost: work is bounded by the existing input limits, and each call is part of the agreed genuine-input policy. No new timing/cancellation guarantee was assumed or benchmark claim invented.
- Existing URL/email/backtick grammar, speculative speech lifecycle, actor scheduling, C ABI contracts, dependency internals and issues 22/23/25/26: inspected only as immediate boundaries and unchanged by this patch; no unrelated inherited audit performed.
- Final signed-device install, squash/push and issue closure: subsequent integration work, not implemented source defects. They remain executor responsibilities.

## Assessment

**Ready to merge? No — with fixes and completion gates.**

There are 0 Critical, 3 Important and 2 Minor code findings. The core library-backed approach is sound, but ordinary ID/version/range contexts expose gaps in the new admission logic. After fixes, source-bound final tests and accepted ID audio are still required; the running full suite and unresolved human ID listening result must not be represented as passed.
