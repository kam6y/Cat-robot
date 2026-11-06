# エフォート設定 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan. The requested execution method is pair programming with Claude in tmux 8:2 through agmsg.

**Goal:** issue #25の「エフォート」4段階選択を既存の設定経路に追加する。

**Architecture:** `ConversationEffort` を拡張し、既存のUserDefaultsとセッション作成を使用する。SDKの `fixedEffort` に各値を直接渡す。

**Tech Stack:** Swift 6、SwiftUI、XCTest、ClaudeForFoundationModels 0.2.3。

**Spec:** `docs/superpowers/specs/2026-11-06-effort-settings-design.md`

## Global Constraints

- 選択肢は `low`、`medium`、`high`、`xhigh` の順。既定は `low`。
- 保存キー `conversation.claude.effort` を維持し、変更は次に作成するセッションに適用する。
- 依存更新、`max` の追加、タイムアウトや出力トークン数の変更はこのissueに含めない。
- Xcodeプロジェクトは `scripts/generate_project.rb` で生成する。

## Review Focus

- 既存のlow/medium設定と新しいhigh/xhigh設定の保存・復元。
- 未知の保存値はlowへ戻ること。
- SDKへの変換と全選択モデルの対応。
- 設定変更が進行中のセッションを変更せず、次のセッションに適用されること。
- 表示名と適用タイミングの説明が一致すること。

### Task 1: 設定・表示・SDK変換

**Files:** `ConversationModelSettings.swift`、`ClaudeSessionFactory.swift`、`SettingsPanes.swift`、READMEと対応する3つの既存テストファイル。

**Interfaces:** `ConversationEffort`、`claudeEffort(for:)`、`ConversationModelSettings.configuration` は既存の型とシグネチャを維持する。

- [ ] 変更前の設定・factory・serviceテストを実行する。
- [ ] 4値の保存・復元、SDK変換、次のセッションへの適用を既存テストに追加し、追加値が未対応で失敗することを確認する。
- [x] enum、表示名、SDK変換、Pickerと説明文、READMEを更新する。
- [x] `ruby scripts/generate_project.rb` と `ruby scripts/test_generate_project.rb` を実行する。
- [ ] 関連テストとSimulator全体テストを実行し、agmsgでClaudeに差分レビューを依頼する。
- [x] 検証結果を記録し、変更を作業ブランチにコミットする。

## 実行結果と検証限界

設定コードを直接実行する検証は、実装前の `unsupported effort high` での失敗から、実装後の4値保存・復元成功を確認した。アプリ・XCTestのビルドと生成契約は成功。Claudeによる方針・テスト・最終差分のレビューも完了し、Critical・Importantの指摘はない。

SimulatorのXCTestは変更前・実装後とも起動待ちで停止し、専用デバイス、サービス再起動、Xcode 27.0の同一バイナリ起動でも実行結果を取得できなかった。上記の未チェック項目はXCTest実行の確認が未完了であることを表す。全体テストは未実行。詳細は `docs/validation/2026-11-06-effort-settings.md` に記録し、この検証限界を明示した変更を作業ブランチに保存する。
