# Main Refactoring Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline with the explicitly requested agmsg Claude pair. Codex owns Git, generation and all test execution. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mainの現役実装へ処理を集約し、責務・文書・旧ブランチを整理する。

**Architecture:** SentenceSpeechSpeakingを返答の依存境界とし、比較実験用の再生経路を除く。ConversationViewModelから表示と所有権付き計測を分離し、非同期の順序を保って失敗処理を共有する。

**Tech Stack:** Swift 6 / SwiftUI / XCTest、Ruby xcodeproj 1.27.0、Python unittest、PlatformIO native。

**Spec:** `docs/superpowers/specs/2026-10-28-main-refactor-design.md`

## Global Constraints

- 基点69c2a22、作業場所b200/Cat_robot、branch feature/main-refactor。ユーザーは設計確認なしの実装を明示。
- iOS 27、固定依存、顔80%、設定・記憶互換、表示/VoiceOverとハード安全動作は維持。
- generation/turn/capture照合、cancel/awaitの順番、未確定/確定後の記憶境界を維持。
- 製品Swiftファイル変更後はscripts/generate_project.rb経由で生成。pbxproj手編集禁止。
- Claudeは割当ファイルのみ。Git/build/実機/LocalAssets操作はしない。テスト時は両者凍結。
- 旧実装の削除を理由に現役の失敗/停止テストを失わない。構造を写すだけの新規テストは書かない。
- 未コミット変更・LocalAssetsがある古いworktreeは保持。削除前に参照bundle検証。force removal/history rewrite禁止。

## Review Focus

- 背景移行/割り込み/停止に遅れて届く認識や再生イベントが新ターンを変えない。
- 文と文の間は口を閉じ、全体再生の完了まで聞き取りを再開しない。モーション解放は1回。
- 古い所有者からの計測cancelで新しいターンのtraceや指標を終了しない。
- 記憶保存失敗/確定後の読み上げ失敗/生成途中の中断で、現在の保存と回復契約を保つ。
- Git整理でdirtyな作業、local-only assets、先端が動いたremoteブランチを失わない。

---

### Task 1: 未使用の音声実装とテスト専用storeを整理（Codex）

**Files:** Delete `CatRobot/Conversation/Services/AppleSpeechSynthesizer.swift`, its test file; modify `AppleServiceCompositionTests.swift`; move `Services/Memory/InMemoryConversationMemoryStore.swift` to `CatRobotTests/Conversation/Services/`; regenerate project.
**Interfaces:** 現役のSpeechSpeaking/Apple認識/AFM型は維持。InMemoryConversationMemoryStoreはtest module内部だけ。

- [x] production参照がないことをrgとcompositionで確定する。
- [x] 削除・移動・旧composition assertionの整理を行う。
- [x] generatorと関連AppComposition/AppleServiceComposition/ClaudeMemoryPersistence testsを実行。
- [x] Claudeが差分を読み、コミットする。

### Task 2: 現役の文再生に一本化（Codex）

**Files:** `ReplyPlaybackCoordinator.swift`, `SentenceReplyPlayback.swift`, `ConversationDependencies.swift`, `ConversationComposition.swift`; related integration fakes/tests, motion/face/look tests, `SupertonicIntegrationDeviceTests.swift`, current speaker tests; delete `LegacySupertonicSpeaker.swift` and obsolete legacy suite after moving relevant checks.
**Interfaces:** `ReplyPlaybackCoordinator.init(reply:speaker:motion:)`, speaker is `any SentenceSpeechSpeaking`; `ConversationDependencies.speaker` also that type; remove ReplyPlaybackMode/replyPlaybackMode. Keep `SentenceSpeechSpeaking.speakSentences(from:prefetch:)` and single speak. `ReplyPlaybackUpdate` current sentence events remain.

- [x] Migrate test-only speakers to a shared test-only channel adapter and port behavioral assertions to sentence start/finish, leaving production unchanged while preparing tests.
- [x] Add/retain assertions for stable-prefix revisions, no early unstable-prefix speech, overlapping cancellation, speech failure, empty reply, duplicate starts, memory and motion boundaries. Retired per-part phase/trace assertions are replaced with actual sentence-path semantics.
- [x] Remove mode and legacy produce/play implementation; use SentenceReplyPlayback(prefetch:true) directly.
- [x] Move legacy speaker invalid-PCM/synthesis failure checks onto SupertonicSentenceSpeaker and remove retired implementation. Keep preprocessing audit.
- [x] Device fixed stage measures current mode; voices/lifecycle and result schema stay supported.
- [x] Regenerate project; run all playback/current speaker/domain/trace/motion/face/look and memory tests; inspect failures rather than weakening checks.
- [x] Claude reviews diff and test coverage; commit.

### Task 3: ViewModelの表示・計測・失敗責務を整理（Claude、検証Codex）

**Files:** `ConversationViewModel.swift`, `ConversationViewState.swift`, `ConversationErrorPresentation.swift`; new `VoiceTurnLatencyRecorder.swift`; relevant ViewState/latency/recovery tests.
**Interfaces:** `ConversationViewState.enter(_:caption:)` owns default mouth/activity values; keep explicit caption/recoveries and field preservation. `ReplyFailurePolicy` derives typed fallback and session-reset decisions. `VoiceTurnLatencyRecorder` owns active generation/capture/turn, trace and latency token; API begin/selectPath/recordFirstCaption/recordSpeechStarted/noteASRActivity/cancel for matching owner. Detailed internal parameter shapes are Claude decisions recorded in ledger before editing.

- [x] Claude fixes exact file ownership/API in agmsg. Codex owns the single VM initializer change removing mode in Task 2; coordinate before editing that file.
- [x] Write meaningful recorder ownership/cancellation and ViewState preservation tests before extraction; existing integration tests continue to cover lifecycle sequencing.
- [x] Apply phase/latency/failure extraction. Remove unread microphoneStatus and only its obsolete assertions. Preserve provisionalTranscript and current activity overrides.
- [x] Consider capture/pause reset helpers only if they remove duplicated policy without erasing current cancel/await and reset differences; record omissions/reasons.
- [x] Codex runs latency/trace/ViewState/accessibility/recovery/auto-resume/memory/idle tests, then reviews diff and commits.

### Task 4: 現在の文書へ整理（Codex）

**Files:** README, `docs/README.md`, `docs/architecture.md`, completed old plans/specs/evidence, intermediate face render archives, tracked `.superpowers` artifacts.
**Interfaces:** Keep adopted face image paths used by rendering, current safety specs and unresolved acceptance records. Historical links target immutable baseline 69c2a22.

- [x] Produce exact deletion manifest and count/size report; Claude checks it against active references.
- [x] Remove obsolete sources of documentation; add current architecture/index and explain historical recovery from Git.
- [x] Update stale branch-retention rule and live speaker/benchmark documentation.
- [x] Check local Markdown links and script references; execute renderer geometry/reference checks and generator contract.
- [x] Commit documentation cleanup and its manifest summary.

### Task 5: 全体レビュー・検証・main統合（Codex＋Claude）

- [x] Freeze all sources and run whole CatRobot suite, FaceSizeTuner tests, Python, both project generator contracts, native firmware/ServoDriver checks and face renderer.
- [x] Fresh-context reviewer audits full range using requesting-code-review; Claude reviews Codex changes and Codex reviews Claude changes. Apply receiving-code-review to findings.
- [x] Fix verified important defects with meaningful reproductions; rerun only affected checks plus required final suite if code changes.
- [ ] Record exact counts, removed-test reasons, evidence/source hashes and actual limitations; commit; integrate to main normally after confirming main has not moved. No force push.

### Task 6: 不要branch/worktreeの整理（Codex、Claude確認）

- [x] Archive all initial refs in verified git bundle and a manifest at `.worktrees/archive-2026-10-28/` under the primary checkout; preserve archived task records needed from clean worktrees.
- [x] Freeze exact deletion candidates, protecting main/current branch, dirty branch names and LocalAssets worktrees; Claude checks classifications.
- [x] Remove eligible clean worktrees normally; keep any refused paths. Delete corresponding local historical branches only after bundle verification. No reset/clean/force-remove.
- [x] Compare remote refs with frozen OIDs immediately before deleting obsolete branches. On changed OID, retain and report.
- [ ] Verify main/working tree, remaining refs/worktrees and backup restoration instructions; record final outcomes.
