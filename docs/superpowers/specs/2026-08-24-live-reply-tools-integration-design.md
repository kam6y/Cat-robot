# Live Reply Tools Integration Design

**Date:** 2026-08-24

**Branch:** `feature/gemma4-independent-tools`

**Starting commit:** `c85da4cc640340f60187b289cd5184ae2eacb48f`

**Related foundation:** `docs/superpowers/specs/2026-08-24-gemma4-independent-tools-design.md`

## Objective

Make the already implemented `rememberMemory`, `forgetMemory`, `searchMemory`, and `getCurrentDateTime` tools usable from the normally launched Cat Robot app on the connected iPhone. The first live backend is Apple's on-device `SystemLanguageModel(useCase: .general)`. The design must keep the conversation, tool transaction, persistence, and UI layers independent from that concrete model so a later Foundation Models-compatible Gemma session can replace it without rewriting those layers.

This change covers typed and voice replies, a compact nonblocking memory-change notice, signed device installation, and normal app launch. It does not add LiteRT, a Gemma artifact, vision, context compaction, cloud memory, or a memory-management screen.

## Design Principles

1. **One model-independent reply lifecycle.** Turn ownership, tool budget, transactional memory, draft streaming, commit, rollback, and notices belong to a backend-neutral reply service.
2. **One backend replacement seam.** Apple-specific model construction and readiness live behind a `ReplySessionFactory`. A future Gemma implementation replaces that factory, not the ViewModel, UI, memory store, or tools.
3. **Foundation Models is the common runtime surface.** Both the current Apple model and the planned Gemma adapter use `LanguageModelSession`, `Tool`, `GenerationOptions`, and `Transcript`. No `SystemLanguageModel` or future LiteRT type may escape the Apple/future-Gemma factory implementation.
4. **Commit before observable success.** Draft text may be displayed while generation is active. Speech, durable transcript advancement, and memory notices begin only after the memory transaction commits.
5. **Failure is atomic and visible.** Cancellation, generation failure, tool-limit failure, invalid tool decoding, or persistence failure rolls back staged memory and the session turn. Memory initialization or persistence is never silently disabled.
6. **Preserve existing ownership.** The current MainActor ViewModel lifecycle generation, voice/typed turn IDs, classifier-before-voice-reply ordering, audio teardown, and reply reset behavior remain authoritative.

## Architecture

### Domain reply contract

Replace the string-only reply request/stream contract with explicit turn and commit semantics:

```swift
struct ReplyTurnRequest: Equatable, Sendable {
    let turnID: UInt64
    let userText: String
}

enum ReplyMemoryChange: Equatable, Sendable {
    case remembered
    case forgotten
    case updated
}

struct ReplyTurnCommit: Equatable, Sendable {
    let finalText: String
    let memoryChange: ReplyMemoryChange?
}

enum ReplyStreamEvent: Equatable, Sendable {
    case draft(String)
    case committed(ReplyTurnCommit)
}

protocol ReplyGenerating: Sendable {
    func prepare() async throws
    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error>
    func reset() async
}
```

`ReplyMemoryChange` is deliberately presentation-safe: it contains no fact, quote, UUID, or tool arguments. Multiple committed mutations in one turn collapse into one value. A mixed remember/forget turn becomes `.updated`. Search-only and date/time-only turns use `nil`.

The existing ViewModel turn ID is passed through unchanged for both typed and voice requests. A retry of the same logical turn must not reset the shared tool-call budget; a genuinely new ViewModel turn ID must reset it.

### Backend-neutral orchestration

`ToolEnabledReplyService` becomes the concrete live `ReplyGenerating` implementation. It is an actor and owns:

- one lazily initialized `LocalMemoryStore`;
- one `MemoryToolContext`;
- one shared `ReplyToolCallBudget`;
- one stable set of the four tools;
- one `ReplySessionFactory`;
- one current `ReplySessionClient`;
- the existing single-generation exclusion.

The service does not know whether its session uses Apple, Gemma, or another Foundation Models-compatible language model. It sees only the session/factory protocols below.

For every reply request, the actor performs this serialized sequence:

1. Reject overlapping generation with the existing `.modelBusy` error.
2. Ensure the persistent tool runtime and reply session are prepared.
3. Capture the session's pre-turn `Transcript` checkpoint.
4. Call `MemoryToolContext.beginTurn(id:userText:)`.
5. Call `ReplyToolCallBudget.beginTurn(id:)`.
6. Stream cumulative model snapshots as `.draft` events.
7. Require a nonblank final snapshot and check cancellation.
8. Commit memory and obtain `MemoryNotice` values.
9. Map those notices to at most one privacy-safe `ReplyMemoryChange`.
10. Emit exactly one terminal `.committed` event, then finish normally.

On any failure before step 10, the service must:

1. cancel/finish the active model stream;
2. call `MemoryToolContext.rollbackTurn()`;
3. restore the pre-turn session transcript through `ReplySessionClient`;
4. clear the generating flag only after cleanup finishes;
5. propagate the mapped recoverable error without emitting `.committed`.

Cancellation that arrives before memory commit rolls back. Once memory commit and the terminal committed event have completed, a later TTS or audio failure does not undo a semantically successful reply or its memory change.

### Replaceable session boundary

The backend seam is intentionally small:

```swift
protocol ReplySessionFactory: Sendable {
    func prepare() async throws
    func makeSession(
        tools: [any Tool]
    ) async throws -> any ReplySessionClient
}

protocol ReplySessionClient: Sendable {
    func prewarm() async
    func transcript() async -> Transcript
    func restoreTranscript(_ transcript: Transcript) async
    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error>
}
```

These protocols live in the service layer, where importing `FoundationModels` is appropriate. Domain, integration, memory, and UI code do not refer to `SystemLanguageModel`, LiteRT, or Gemma.

`AppleSystemReplySessionFactory` is the only Apple reply-backend implementation. It:

- owns `SystemLanguageModel(useCase: .general, guardrails: .default)`;
- checks general-model readiness during `prepare()`;
- creates a `LanguageModelSession` with exactly the four supplied tools;
- provides Cat Robot and tool-use instructions;
- restores a failed turn by replacing or resetting its session to the captured `Transcript` without changing the persistent tool runtime.

A future `GemmaReplySessionFactory` may download/verify a model and create a Foundation Models-compatible Gemma session. It must implement the same two protocols. Adding it must require only changing live composition (or selecting a factory), with no changes to `ToolEnabledReplyService`, `ConversationViewModel`, `ConversationView`, `LocalMemoryStore`, `MemoryToolContext`, or the four tools.

### Generation policy and instructions

The live session receives all four tools and uses:

- tool calling mode `.allowed`, never `.required`;
- temperature `0.5`;
- maximum response tokens `256`;
- no reasoning/thinking UI or reasoning-output exposure.

When compiling for an OS target where the explicit iOS 27 tool-calling option requires availability handling, the iOS 27 runtime path must set `.allowed` explicitly. The project deployment target is not changed solely for this integration.

The backend instructions retain the existing Cat Robot personality and add concise rules:

- remember only stable, user-provided facts likely to help later;
- copy `supportingQuote` exactly from the current user text;
- do not remember temporary observations, guesses, assistant claims, summaries, or image-only conclusions;
- search before replacing or deleting a potentially conflicting fact;
- use current date/time only when the question requires a current or relative temporal reference;
- never infer the current date, weekday, or timezone from model knowledge;
- do not call a tool when the answer does not need one.

Tools are attached only to the reply session. The Apple content-tagging classifier and any future compaction-only session remain tool-free.

### Preparation and composition

`ReplyGenerating.prewarm()` becomes throwing `prepare()` so reply-backend readiness and memory-store initialization can be reported rather than silently ignored.

`ConversationDependencies.live()` constructs:

```text
AppleSystemReplySessionFactory
        ↓
ToolEnabledReplyService
        ↓
ReplyGenerating dependency
```

The memory store is resolved lazily through `LocalMemoryStore.applicationSupport()` and retained for the process lifetime. Session reset creates a new session through the same factory and reattaches the same four tools, budget actor, context actor, and persistent store.

`FoundationModelAvailabilityService` continues to represent Apple `.contentTagging` classifier availability. Reply-backend readiness belongs to `ReplySessionFactory.prepare()`. This separation allows a future Gemma factory to own download, verification, and warmup without changing classifier behavior.

## ViewModel and UI Flow

Typed and voice paths both pass their existing `turnID` and the accepted user text to `ReplyGenerating`.

While consuming events:

- `.draft(text)` updates the existing caption only;
- `.committed(commit)` records the final text, publishes an optional transient memory notice, and enables the existing speech path;
- normal stream completion without `.committed` is a generation failure;
- a thrown error clears the uncommitted draft before publishing the recovery UI.

Voice ordering remains:

```text
speech recognition → Apple content-tagging classifier → tool-enabled reply → memory commit → speech
```

Typed input continues to bypass address classification and directly uses the same tool-enabled reply service.

### Memory notice

Add one optional transient notice to `ConversationViewState`. The ViewModel maps the committed `ReplyMemoryChange` to short Japanese text:

- remembered: `記憶しました`
- forgotten: `記憶を削除しました`
- mixed/updated: `記憶を更新しました`

The notice:

- appears as a compact top overlay/banner;
- never shows fact text, supporting quotes, IDs, or tool arguments;
- never enters the model transcript or caption;
- does not accept input, steal focus, stop speech, or block typed/voice actions;
- has an accessibility label and respects Dynamic Type/reduced transparency;
- replaces an existing notice if a newer committed mutation arrives;
- disappears automatically using a ViewModel-owned cancellable task;
- is absent for search, date/time, rollback, and failed commit.

The exact display duration is presentation detail, not a domain contract.

## Error and Cancellation Semantics

Add a recoverable memory/tool-runtime error presentation rather than silently falling back to tool-free replies. The UI may offer the existing retry and typed-input recoveries as appropriate.

The following all produce no terminal commit event, no speech, and no notice:

- persistent store initialization failure;
- model/session preparation failure;
- model generation or tool decoding failure;
- `ReplyToolCallLimitExceeded` on call 13;
- empty final response;
- ViewModel cancellation, scene inactivity, pause, or shutdown before commit;
- memory persistence failure.

The service finishes async rollback and transcript restoration before its stream terminates. `onTermination` cancellation must cancel the forwarding task, but synchronous termination callbacks alone are not considered sufficient cleanup.

No production log may contain user facts, supporting quotes, search results, tool arguments, or raw prompts.

## Test Strategy

All behavior is implemented with red/green TDD and deterministic fakes. Live inference is not the primary correctness test.

### Reply-service tests

Cover:

- exact four-tool registration and one shared budget/context runtime;
- `.allowed` tool mode and 256-token policy on the iOS 27 path;
- draft events followed by exactly one committed event;
- memory commit before the terminal event;
- aggregated remember, forget, and mixed notice mapping;
- search/date-only success without notice;
- generation failure after staged mutation rolls back store and transcript;
- cancellation after a draft rolls back before stream termination;
- 13th tool call does not execute the body and rolls back;
- persistence failure restores the checkpoint and emits no commit;
- reset creates a new session while retaining persistent memory/tool actors;
- same turn ID does not reset the budget; a new ID does.

### ViewModel/integration tests

Extend the existing fakes and harness rather than creating a second conversation stack. Cover both typed and voice paths:

- drafts update caption but never start speech;
- committed final text starts speech;
- committed mutation publishes one notice without blocking speech;
- search/date-only commits publish no notice;
- reply error/cancellation clears the uncommitted draft and produces no speech/notice;
- Apple classifier still precedes voice reply;
- pause/background/shutdown await transaction cleanup;
- existing lifecycle, recovery, latency, clarification, and typed-input behavior remains green.

### UI and composition tests

Cover:

- banner visibility, generic private text, accessibility, Dynamic Type, and noninteractive behavior;
- live composition uses `ToolEnabledReplyService` with `AppleSystemReplySessionFactory`;
- classifier availability remains `.contentTagging` and independent of reply preparation;
- no LiteRT/Gemma dependency or type is introduced.

### Validation and device deployment

Before installing:

1. deterministic project-generator contract passes;
2. focused reply, memory, tool, ViewModel, composition, and UI tests pass on the connected iPhone;
3. the full device regression excluding the unchanged `SpeechAudioConverterTests` class passes;
4. a signed Debug device build succeeds using `/Applications/Xcode-beta.app`;
5. static scope and privacy checks pass;
6. an independent review finds no unresolved Critical or Important issue;
7. the tracked worktree is clean.

Install the signed app over the existing `com.kamby.CatRobot` bundle without uninstalling it, preserving Application Support data. Re-enumerate the current Xcode and CoreDevice identifiers, install with `devicectl`, launch with `--terminate-existing`, and confirm the process starts normally. Do not consume stochastic live tool prompts during automated validation; the user will perform the hands-on typed and voice usability test.

## Files and Ownership

Expected new or materially changed areas:

- Domain: reply turn request, event, commit, and memory-change contracts.
- Services: backend-neutral tool-enabled reply service, session protocols, Apple session factory/client, error mapping.
- Integration: dependency composition and typed/voice event consumption.
- UI: transient memory notice state and view.
- Tests: reply service, integration fakes/harness, composition, view state/UI.
- Generated Xcode project/scheme only through the existing generator when new files require it.

The persistence and tool implementations remain the source of truth; do not duplicate their validation, allowance, authorization, normalization, or budget logic in the reply service or ViewModel.

## Explicit Non-Goals

- LiteRT or Gemma dependency/model installation in this change.
- Gemma model download, integrity verification, context calibration, compaction, or vision.
- Cloud memory, embeddings, fuzzy search, sync, or a memory-management screen.
- Passing tools to the content-tagging classifier.
- A second extraction/classification model call for deciding tool use.
- Tool-call debug UI, raw tool arguments/results, or private prompt logging.
- Push, PR creation, merge, or changes to the blocked/comparison worktrees.

## Acceptance Criteria

The change is complete only when:

1. A normally launched signed device app uses `ToolEnabledReplyService` with `AppleSystemReplySessionFactory`.
2. Both typed and classifier-approved voice turns can invoke all four tools through `LanguageModelSession` with `.allowed` tool calling.
3. Memory mutations commit before speech and produce one privacy-safe nonblocking notice; search/date-only turns do not.
4. Every pre-commit failure/cancellation rolls back memory and restores the pre-turn transcript.
5. Restarted app instances load committed facts from Application Support.
6. The reply lifecycle, memory/tool layers, ViewModel, and UI contain no Apple concrete model or future Gemma/LiteRT dependency.
7. A future Gemma backend can be introduced by implementing and composing a new `ReplySessionFactory`/`ReplySessionClient`, without changing the shared lifecycle or UI layers.
8. Fresh focused and regression tests, signed build, install, launch, review, and clean-worktree checks pass.
9. The existing blocked worktree and comparison branch remain untouched, and no push/PR/merge occurs.
