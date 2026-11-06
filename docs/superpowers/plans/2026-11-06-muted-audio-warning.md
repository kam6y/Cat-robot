# Muted Audio Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Codex is the single writer, pairs with Claude via agmsg, and requests one fresh whole-branch reviewer after implementation.

**Goal:** 再生音量0を会話画面の警告チップで知らせ、音量を上げると消す。

**Architecture:** 既存audio controllerのvolume getter/KVO→値を持たないaudio event→VMの現在値再読取→既存status chipを使う。初期snapshotとactivate成功後の通知で初回/復帰を覆う。音量に応じた音声制御は加えない。

**Tech Stack:** Swift6、AVFAudio、Foundation KVO、SwiftUI、XCTest、Xcode27.2。

**Spec:** `docs/superpowers/specs/2026-11-06-muted-audio-warning-design.md`

## Global Constraints

- 最新main ce72201からの専用branch、既存の隔離worktreeを利用する。
- ユーザー訂正により消音モード検出は不要。再生音量0のみ。表示「音量が0です」、speaker.slash.fill、既存の警告style/AXを使う。
- volume eventは表示更新だけ。音量変更・マイクpermission/activate・pause/resumeを起こさない。
- schema/依存/モデル/Smart Turn/effort/issue23の履歴処理は変更しない。
- 普通のテストはライブcompositionを抑制し、実音声/ロボットの専用2クラスを明示除外する。

## Review Focus

- 最初から0、背景/設定/route変更後でも現在の出力音量を反映する。
- KVOの重複・循環参照・破棄漏れがなく、複数購読の取消が他の購読を消さない。
- 音量の通知だけで進行中の会話/読み上げ/録音を中断しない。
- shutdown中に遅れて返る音量の読み取りで表示を復活させない。
- 他の警告と大きい文字/狭いviewportでもchipがメニューや入力欄に重ならない。

### Task 1: Volume-to-chip integration

**Files:**
- Modify: `CatRobot/Conversation/Domain/ConversationTypes.swift`（event）
- Modify: `CatRobot/Conversation/Domain/ConversationServices.swift`（async getter）
- Modify: `CatRobot/Conversation/Services/AppleAudioSessionController.swift`（driver/KVO/getter/activate notification）
- Modify: `CatRobot/Conversation/Integration/ConversationViewModel.swift`（初期snapshot/変更処理、shutdown guard）
- Modify: `CatRobot/Conversation/UI/ConversationViewState.swift`（表示flag/chip）
- Tests: `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`、`ConversationFakes.swift`
- Tests: `CatRobotTests/Conversation/Services/AppleAudioSessionControllerTests.swift`
- Tests: `CatRobotTests/Conversation/UI/ConversationViewStateTests.swift`
- Tests: `CatRobotTests/Face/FaceConversationPresentationTests.swift`
- Docs: README/索引/検証記録。

**Interfaces:**
- `AudioSessionControlling.outputVolume: Float { get async }`。Apple controllerはnonisolated同期getterで満たす。
- `AudioSessionDriving.outputVolume: Float { get }`、`observeOutputVolume(_ handler: @escaping @Sendable () -> Void) -> NSKeyValueObservation`。
- `AudioSessionEvent.outputVolumeChanged`。callback値をevent payloadにせずconsumerで現在値を再取得。
- `ConversationViewState.isAudioOutputMuted: Bool = false`、`ConversationStatusChip.audioOutputMuted`。

- [x] 初期音量0で、実VMの `statusChips` に警告が出る回帰を書き、新しい型を参照せずchip title配列を比較し、実装前の期待する断定のREDを確認する（型エラーは数えない）。
- [x] 初期snapshotからflag/chipへつなぐ最小実装でGREENにする。
- [x] 実行中の0↔正の変更、会話への副作用なし、停止中/typedの表示、shutdown待ち読み取りの回帰をRED→GREENで実装する。
- [x] 制御可能なKVO sourceを下位境界だけに用い、実controllerの監視・activation後通知・複数購読/破棄をRED→GREENで確認する。
- [x] 大きい文字/他の警告が並ぶ実SwiftUIの配置とAXを確認し、生成器・deterministic contract・関連XCTestを成功させる。
## Whole-branch review and integration

- [x] 差分固定後、Claude `/simplify` 4角度と独立requesting-code-reviewを並行、初回報告が双方保存されてから相互receiving-code-reviewを行う。
- [x] 合意した小変更を検証し、最終84関連・3表示・983全体、入力hashと通常署名preview/実機手操作を確認した。

統合は上記検証済みコミットの作成後、同じ許可済みworkflowでmainへスカッシュし、統合版の実機更新とpush/remote一致確認を実行する。結果は `/tmp/cat-issue26-muted-audio-20261106/integration.json` と `main-normal/normal-verification.json` に保存する。
