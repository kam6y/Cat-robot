# Task 0 report — Apple Services plan alignment

## Scope

Documentation only. Modified `docs/superpowers/plans/2026-08-12-apple-services.md`; no production or executable test files were added or changed.

## Changed sections

1. **Global Constraints / Expected domain contract** — kept the iOS 26 local converter architecture explicit; mapped synthesis-driver failures and overlapping `speak` rejection to `.speechSynthesisFailed`.
2. **Task 1, Steps 1 and 4** — awaited availability before XCTest assertions; added `@unknown default` fallbacks for nonfrozen availability reasons and `LanguageModelSession.GenerationError`.
3. **Tasks 2–7 test examples** — moved every async result out of XCTest autoclosures, replacing undefined async helpers with concrete locals, loops, and `do/catch`.
4. **Task 4, Steps 1, 2, 4, and 5** — changed `.pcmFormatOther` to `.otherFormat`; made reservation best-effort and tracked only on `true`; added explicit idempotent async release; documented the narrowly scoped `@unchecked Sendable` converter input-state box and its synchronous ownership invariant.
5. **Task 5, Step 3** — replaced `forEach(inputContinuation.yield)` with an explicit loop that discards each yield result; kept asset release out of per-turn stop and assigned it to explicit service teardown.
6. **Task 6, Steps 1 and 3** — added synthesis-failure and overlapping-speech expectations using `.speechSynthesisFailed`.

## Verification

```text
$ git diff --check
(no output; exit 0)

$ rg -n "XCTAssert[A-Za-z]+\\([^\\n]*(try )?await|await XCTAssert|XCTAssertThrowsErrorAsync|pcmFormatOther|forEach\\(inputContinuation\\.yield\\)" docs/superpowers/plans/2026-08-12-apple-services.md
(no matches)
```

The plan retains the installed iOS 26.5 SDK signatures and contains no compile path for the iOS 27-only Speech helpers.
