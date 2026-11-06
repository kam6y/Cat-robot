# Neutral clarification history Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Codex implements as the single writer, paired with Claude through agmsg; a fresh independent reviewer checks the completed branch.

**Goal:** 中立判定の元発話と正常完了した聞き返しを保存し、次の返答に文脈を渡す。

**Architecture:** `ConversationMemoryManaging` に既存の `recordExternalTurn(prompt:response:) async` を公開する。VMの固定発話経路で、完了確認後・再録音前に同APIを待つ。Claudeの保存・session無効化・削除世代の既存実装を使う。

**Tech Stack:** Swift 6、SwiftUI、XCTest、既存Claude SDK 0.2.3、Xcode 27.2。

**Spec:** `docs/superpowers/specs/2026-11-06-neutral-history-design.md`

## Global Constraints

- main `7c03f69` からの専用ブランチ。Codexが単一writer、Claudeはペア確認と後段のsimplify。
- 宛先判定・15秒・肯定/否定のルール、schema、依存、モデル、Smart Turn、エフォート設定を変えない。
- 実API・実音声収録・実ロボット試験を通常のunit suiteへ混ぜない。実機接続が利用可能なら通常署名アプリを更新する。
- Swift変更後は生成器とdeterministic contractを実行し、関連XCTestと全体XCTestで検証する。

## Review Focus

- キャッシュ済みセッションに、固定聞き返しの文脈が欠けたまま残らない。
- 読み上げの途中・エラー・取消を、正常な固定返答の完了として保存しない。
- 保存中のpause後に、古いturnが録音を再開しない。
- 保存中のforget後に、古い履歴が書き戻されない。
- 保存失敗で文脈を捨てたり、聞き返しにLLM利用回数を加算したりしない。

### Task 1: Clarification history integration

**Files:**
- Modify: `CatRobot/Conversation/Domain/ConversationMemory.swift`
- Modify: `CatRobot/Conversation/Services/Memory/UnsupportedConversationMemoryManager.swift`
- Modify: `CatRobot/Conversation/Services/Claude/ClaudeConversationService.swift`（既存APIのコメントのみ）
- Modify: `CatRobot/Conversation/Integration/ConversationViewModel.swift`
- Tests: `CatRobotTests/Conversation/Integration/ConversationMemoryIntegrationTests.swift`
- Test support: `CatRobotTests/Conversation/Integration/ConversationFakes.swift`

**Interfaces:**
- `ConversationMemoryManaging.recordExternalTurn(prompt: String, response: String) async`。Claudeは既存実装、Unsupportedは明示no-op。
- private `speakAndResume` に省略可能な `memoryPrompt: String?`。中立の固定聞き返しだけが元発話を渡す。
- Test harnessにreply override、classifierの次結果変更を加え、実記憶サービスとVMをつなぐ。

- [x] 実VM/実記憶サービスの回帰テストで、`今日の天気はどう？`/`今の、ぼくに言った？`の保存と、次の`言ったよ`に渡るinstructionsを検証する。元発話を繰り返して置き換えるだけの修正は失敗させる。
- [x] 変更前のビルドとテストを実行し、保存/文脈が欠けるassertionのREDを確認する。
- [x] protocol/Unsupportedと固定発話の保存接続を最小変更で実装する。完了・取消・所有世代をawaitの前後で確認する。
- [x] 復元、読み上げ未完了/失敗/取消、保存待ちpause/forget、未保存と再試行、LLM利用回数0を実コンポーネントで検証する。
- [x] `ruby scripts/generate_project.rb`、`ruby scripts/test_generate_project.rb`、関連XCTestを実行してGREENにする。
- [x] 実装を固定し、Claude `/simplify` と独立 `requesting-code-review` を並行。初回報告保存後、双方の `receiving-code-review` と親の採否を記録する。
- [x] 必要な指摘だけを修正し、全体XCTest・通常署名ビルド・差分/入力ハッシュを確認して検証記録を保存する。
統合はこの検証済みコミットの作成後に、mainへのスカッシュとリモート反映を実行する。実行結果は `/tmp/cat-issue23-neutral-history-20261106/integration.json` と作業ledgerへ記録し、統合版の通常ビルド・実機更新は同ディレクトリの `main-normal/` に保存する。
