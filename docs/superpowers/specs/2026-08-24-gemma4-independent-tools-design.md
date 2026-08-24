# Gemma 4 Independent Tools Foundation Design

**Date:** 2026-08-24

**Base:** `29958332f4a3b0e5f90bfb45f06effc4d0d79666`

**Branch:** `feature/gemma4-independent-tools`

## Objective

Implement only the Apple Foundation Models and local-tool pieces that compile without LiteRT-LM. The result provides the content-tagging availability boundary, transactional local memory, three memory tools, a read-only current-date/time tool, and one shared 12-call budget. It deliberately does not create or integrate a Gemma reply session.

## Scope

Included:

- Keep `FoundationModelAddressClassifier` on `SystemLanguageModel(useCase: .contentTagging)`.
- Make `FoundationModelAvailabilityService` inspect that same content-tagging use case instead of the general reply model.
- Persist `MemoryFact` records as atomic JSON in Application Support, with complete file protection and backup exclusion.
- Stage remember/forget mutations per user turn and commit them as one batch only after an owner explicitly calls `commitTurn()`.
- Search committed plus current-turn staged facts with exact/substring matching and deterministic ordering.
- Require a nonempty, canonically normalized supporting quote that is an exact substring of the current normalized user text for remember/forget.
- Allow forget only for UUIDs returned by search during the current turn.
- Expose `rememberMemory`, `forgetMemory`, `searchMemory`, and `getCurrentDateTime` as Foundation Models `Tool` conformances using `@Generable` arguments and `String` outputs.
- Share one `ReplyToolCallBudget` across all four tools: calls 1 through 12 execute; call 13 throws before semantic validation or body execution.
- Return deterministic JSON from search and date/time tools.

Excluded:

- LiteRT-LM package changes, adapters, custom `LanguageModel`, model downloads, or Gemma reply generation.
- Passing tools to `LanguageModelSession`, the existing Apple classifier, or any compaction session.
- Reply/UI/lifecycle integration, speech, notices, live model inference, vision, context calibration, or acceptance runs.
- Changes to the blocked `feature/gemma4-foundationmodels-poc` worktree or comparison branch.
- Push, pull, fetch, PR creation, merge, rebase, or cherry-pick.

## Architecture

### Content-tagging availability

`FoundationModelAvailabilityService` owns a small model-purpose seam whose only live case is `contentTagging`. Both its default configuration and `FoundationModelAddressClassifier` construct `SystemLanguageModel(useCase: .contentTagging, guardrails: .default)`. Snapshot mapping remains injectable and deterministic in tests; no test invokes a live Apple model.

### Persistence and transaction boundary

`AtomicJSONMemoryPersistence` implements a synchronous `MemoryPersisting` boundary. It loads an array of `MemoryFact`, writes encoded data to a temporary sibling, applies complete protection and backup exclusion, and atomically replaces the destination. `LocalMemoryStore` is an actor that updates its in-memory committed snapshot only after persistence succeeds.

`MemoryToolContext` is a separate actor. `beginTurn(id:userText:)` snapshots committed facts, canonicalizes the user text with `precomposedStringWithCanonicalMapping`, clears the current-turn search authorization set, and resets the shared search-result allowance. Remember and forget mutate only an in-memory candidate. `commitTurn()` persists the complete candidate once and then returns accumulated `MemoryNotice` values; `rollbackTurn()` discards the candidate.

All-or-nothing behavior is required at both layers: a rejected mutation does not change the candidate, and a failed persistence operation does not change committed store state.

### Search behavior and allowance

Search considers committed records plus staged current-turn changes. A normalized exact fact match ranks before a substring match. Ties use `updatedAt` descending and then lowercase UUID string ascending. Empty query returns all candidates in that deterministic tie order.

Across one turn, searches may expose at most eight records. The returned JSON representation is also capped conservatively at 1,024 UTF-8 bytes. Since every model token consumes at least one encoded byte, the byte ceiling is a safe upper bound of 1,024 tokens without depending on the absent Gemma tokenizer. Both allowances are shared across repeated searches and reset only by `beginTurn`.

The shared search DTO is `MemorySearchResult(id: String, fact: String)`. Search JSON is a sorted-key array of those objects. The context evaluates each candidate prefix by encoding that exact DTO array, so the allowance and tool output use identical bytes.

### Foundation Models tools

The local Xcode 27 beta 5 SDK defines `Tool` with `Arguments: ConvertibleFromGeneratedContent`, `Output: PromptRepresentable`, and `call(arguments:) async throws`. Each arguments type is an `@Generable struct`, so Foundation Models provides its schema. Each tool returns `String`; search and date/time return sorted-key JSON.

The tool names and descriptions are fixed:

- `rememberMemory`: `Stage one concise, user-provided fact that will be useful in future conversations. The supporting quote must be copied exactly from the current user message.`
- `forgetMemory`: `Stage deletion of specific memory IDs returned by searchMemory in this user turn. The supporting quote must be copied exactly from the current user message.`
- `searchMemory`: `Search local committed and current-turn staged memories. Returns only memory IDs and fact text.`
- `getCurrentDateTime`: `Read the device's current local date, time, ISO weekday, time zone, and UTC offset. Use only when current time context is needed.`

Memory tools call `budget.consumeCall()` immediately upon entry, before semantic validation or context work. Semantic errors return short rejection strings and do not mutate storage. Budget exhaustion throws `ReplyToolCallLimitExceeded`. Decode errors occur before `call(arguments:)` in the framework and therefore remain an integration-layer rollback concern outside this goal.

Tool-facing strings are fixed for deterministic tests:

- Remember success: `Remember staged: <fact>`.
- Empty remember input: `Remember rejected: fact and supporting quote are required.`
- Remember quote mismatch: `Remember rejected: supporting quote must match the current user text.`
- Forget success: `Forget staged: <count> memory item(s).`
- Empty forget ID list: `Forget rejected: provide at least one memory ID.`
- Forget quote mismatch: `Forget rejected: supporting quote must match the current user text.`
- Unsearched forget ID: `Forget rejected: search for every memory ID in this turn first.`
- Invalid UUID string: `Forget rejected: every memory ID must be a UUID.`
- Nonpositive search limit: `Search rejected: limit must be positive.`

### Date/time

`LiveCurrentDateTimeProvider` reads `Date.now`, a Gregorian calendar, and `TimeZone.autoupdatingCurrent` on every call. It emits an ISO-8601 value, local date/time, ISO weekday (Monday 1 through Sunday 7), timezone identifier, and UTC offset seconds. `CurrentDateTimeTool` has no cache, persistence, network access, memory dependency, notification, or clock mutation.

## Validation

- Use `/Applications/Xcode-beta.app` (`Xcode 27.0`, build `27A5237l`) without changing global `xcode-select`.
- The connected iPhone 16 Pro (`00008140-000610311A90801C`) is only a unit-test runner; no live model inference is permitted.
- Baseline on this exact commit: 237 tests, 228 passed, and nine pre-existing `SpeechAudioConverterTests` crashed on the iOS 27 beta 6 device with `Audio sample data must be 16-bit signed integers`.
- Every new behavior follows red/green TDD and its targeted XCTest bundle must finish with zero failures.
- Final validation runs all tests except the unchanged `SpeechAudioConverterTests`, an Xcode beta generic-device build, the deterministic project-generator contract, and a clean-worktree check.
