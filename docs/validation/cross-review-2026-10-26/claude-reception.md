# Claude による codex-review.md の受領評価（receiving-code-review）

対象: `/private/tmp/cat-cross-review-20261026/codex-review.md`（I1/I2/I3/M1）。評価は worktree `/Users/goodapple/.codex/worktrees/b200/Cat_robot` HEAD `dbd04589` の現行ソースとヘッダ・仕様に照らして行った。コード・ソースは編集していない。各項目に「採否 / 根拠 / 最小の修正案 / 懸念・条件」を書く。

## I1 — 未準備状態の reset が旧短期記憶を復活させる: **採用（Important）**

根拠（コードで確認）:
- `ClaudeConversationService.reset()`（`CatRobot/Conversation/Services/Claude/ClaudeConversationService.swift:130-141`）は `memory = ShortTermMemory()`・`invalidateSession()`・`revision &+= 1` を行い、保存は `if prepared { try? await saveMemory(epoch:) }`（141）だけ。`prepared == false` のときは「reset があった」ことがどこにも残らない。
- `prepareMemory()`（288-299）は `if prepared { return }` で、未準備なら `restoreMemory`（301-323）がストアの snapshot を読み `memory = restored`（313）で上書きする。つまり reset → prepare の順になると、reset は無効化される。
- 到達経路: `ConversationViewModel.performVoicePreflight`（467-500）はマイク拒否（480-485）とモデル不可（490-494）で `prepareMemory()`（496）より前に return する。`startNewConversation()`（407-422）は `prepareMemory` を呼ばずに `dependencies.reply.reset()`（416）→ `MotionReplyGenerator.reset` → `OnDeviceFallbackReplyGenerator.reset`（54-57、primary と secondary へ）→ `ClaudeConversationService.reset()` に至り、`showNotice("新しい会話を始めました")`（419）は無条件。その後の文字入力は `streamReply`（107-127）冒頭の `try await prepareMemory()`（110）で旧 snapshot を復元する。ViewModel 側の `prepareMemory()` 呼び出し（496、584）はどちらも事前条件つきなので、起動直後にマイク拒否のまま「新しい会話を始める」→ 文字入力、は通常 UI で再現できる。
- 既存テスト: `ClaudeConversationServiceTests` の reset（132/149/475）と `ClaudeMemoryPersistenceTests`（103/152）はいずれも生成または準備の後に reset している。未準備 reset は未試験。

最小の修正案（挙動を保つ条件つき）:
- `reset()` で `prepared == false` の場合: 進行中の `preparation` があれば先に待つ（`if let preparation { _ = try? await preparation.value }`）→ epoch/forgetting の再確認 → `prepared = true` とし空の記憶を正とする → `saveMemory(epoch:)` を serializedStoreOperation 経由で実行（既存の storeTail 直列化を使うので、遅れて来る古い restore/save が上書きしない）。保存失敗は既存の `.unsaved` 系の persistenceState に乗せ、`startNewConversation` は `memoryState()` を読んでいる（420）ので表示に出る。
- `restoreFailed` 状態からの reset は「読めない旧 snapshot を捨てて空で始める」ことになる。利用者の明示操作なので妥当と考えるが、方針として明記する（別案: restoreFailed 中は reset を拒否して通知）。
- 回帰: (a) 旧 summary/turns を seed → prepare 前に reset → generate → instructions と保存 snapshot に旧内容が無く長期メモは残る。(b) 統合: マイク拒否 → 新しい会話 → 文字入力。(c) restore を途中で止めた状態での reset が、遅れて完了する restore に上書きされない。

懸念: `prewarm()`（98-105）も `prepareMemory()` を呼ぶため、会話画面表示時に prewarm が走る構成なら実機では `prepared` が早く true になり得る。再現性は「prepare 前に新しい会話を押せる窓」の長さに依存するが、コード上の欠陥としては確定。

## I2 — 校正の往復で draft が entry に戻ると最終プレビューが取り消される: **採用（Important、発生条件は限定的）**

根拠（コードで確認）:
- `preview()`（`RobotCalibrationSession.swift:92-119`）は `draft = values`（99）を同期で更新し、送信は 100 ms のスロットル後（110）。送信失敗は `catch { }`（117）で握りつぶす（`expiresAt: now + 0.3` で期限切れもあり得る）。
- `hasNewChanges`（54）は `draft != entry?.values` のみ。ロボットに適用済みの値との比較はない。
- `RobotCalibrationView.swift:44-45`: 戻る操作で `hasNewChanges == false` なら確認なしに `onClose(.restore)`。`RobotSettingsModel.closeCalibration`（116-144）は `hasNewChanges == false` のとき save/restore を飛ばし `session.cancel()`（136）→ `invalidatePreview()`（278-285）で未送信の A プレビューの Task を cancel しトークンを `link.invalidate` する。
- よって「A → B（送信済み）→ A（スロットル中 or 送信失敗）→ 戻る」で、ロボットは B のまま、画面は A（entry）かつ `entry.saved` なら「保存済み」表示。設計 6.3（`docs/superpowers/specs/2026-10-23-ios-robot-link-design.md:197`「entry snapshot の適用値をプレビューし直す」）の約束に反する。
- 既存テスト `RobotSettingsModelTests`（73/131/205 の `.restore`）は編集なし or 変更ありの経路で、往復後の等値は未試験。

最小の修正案:
- セッションに「適用がずれている可能性」のフラグを持つ: プレビュー送信が成功したら `appliedValues = values`（117 の catch の前、116 の直後）。`var appliedMayDiffer: Bool { appliedValues != entry?.values || 未完了の previewTask がある }`。
- `closeCalibration` の条件を `session.hasNewChanges || session.appliedMayDiffer` にし、`.restore` では既存の `restoreEntry()`（147-168: SET_CAL 送信 + Calibration Read + 一致確認）を使う。`.save` で draft == entry なら `save()`（entry 値の SET_CAL + SAVE_CAL）で収束する。未編集の退出（プレビューを一度も送っていない）は従来どおり読み書きなし。
- 回帰: ManualRobotClock + 実 RobotLink harness で B を書き、スロットルを進めずに `preview(A)` → `closeCalibration(.restore)`。画面が A の書き込みと Read 一致まで残り、SAVE_CAL が出ないこと。最終プレビューを期限切れにした場合も同じ。

懸念: 戻る操作の確認ダイアログを「適用ずれあり」でも出すかは UI 判断。出さずに restore を自動で走らせる（失敗時のみ既存の警告）なら設計 6.3 と整合する。

## I3 — 波形再生中の SET_CAL がサーボ指令を一段で反転させる: **採用（契約欠陥として。重大度は Important〜Minor の境界、最小修正で対応）**

根拠（コードで確認）:
- `Supervisor.cpp:143-153`: SET_CAL は `setCalibration` を即時適用し（145-146）、`phase_ == Playing` では `reapplyJointTargets()` を意図的に飛ばす（150、コメント 148-149）。
- `applyGestureSample`（478-493）は毎 tick `jointToServo` で変換して `planner.reset(servo)`（490-491）。Planner の S 字を通らない。ピッチ反転（invert bit1）が +20° 保持中に入れば、次 tick で約 −20° へ: 40°/20 ms ≒ 2000°/s（`Config.h:16 kPitchAbsVel = 120`、`kTickSeconds = 0.02`）。
- 仕様の食い違い: firmware 設計 `2026-10-23-xiao-firmware-ble-design.md:271` は SET_CAL を「どの状態でも受理 … 変更は Planner を通して S 字で反映」と約束する。iOS 設計 `2026-10-23-ios-robot-link-design.md:180` は「途中の反転・角度上限変更が波形標本の変換を直接変えるため、校正の専有と静止待ちは必須」とクライアント側の責務を記す。つまり firmware の契約（S 字）と実装（Playing 中は直接変換）が一致しておらず、守っているのはアプリの `canEdit`（`RobotCalibrationSession.swift:56-65`、`status.flags.contains(.gesture) == false`）だけ。
- 到達性: アプリは校正中に自動動作を止めるので通常は起きない。しかし BLE Calibration 特性 Write（`BleTransport.cpp:195-203`）とシリアル `CAL` は常時受理する外部インターフェースで、firmware 側の既存前例（`setGain` は静止中以外を拒否、`Supervisor.cpp:195-201`）と比べても SET_CAL だけが無防備。
- 同種: `SetLimits`（157-172）も Playing 中は標本ごとの飽和に任せる（169）。角度上限を現在の標本より小さくすると同じく一段の跳びになる。

最小の修正案（採用済みの直接波形は変えない。速度制限の再設計はしない）:
- `phase_ == Playing` の間は SET_CAL（と SET_LIMITS の角度上限）を「受理して保留」する: `pendingCal_` に保持し `acceptMotionRequest`/`noteAccepted` は従来どおり（契約「どの状態でも受理」を維持）。波形終了の `finishGesture()`（504-517）または `handOverFromWaveform()` の直後に保留値を適用し、`reapplyJointTargets()` で S 字に乗せる。保留中の `saveCalibration`（226-239）は保留値を先に適用してから persist するか、保留中は拒否するかを決めて明記する（Calibration Read の値と不一致を作らないため）。
- 代替（より単純だが契約変更）: Playing 中は `onRejected()` で拒否。`setGain` と同じ型だが、仕様 271 行の「どの状態でも受理」を改訂する必要がある。
- 回帰: host の Supervisor シミュレーション（`test_supervisor.cpp`）で `look_up` の保持区間に入り、`setCalCmd(0, 0, 2)` と別途オフセット変更を送り、連続 tick のサーボ角差分が `kPitchAbsVel * kTickSeconds`（2.4°/tick）＋許容内であること、波形終了後に校正が適用されていることを確認。角度上限縮小も同じ枠で 1 件。

懸念: 実機での力・速度は未計測（codex と同じ立場）。アプリ経路だけ見れば発生しないため、優先度は I1/I2 より下でもよい。

## M1 — Limits 特性の不正 Write が片軸だけ変える: **採用（Minor）**

根拠（コードで確認）:
- `Supervisor.cpp:157-172`: `yaw_.axis.setLimits(...)` を先に適用し（159）、`pitch_.axis.setLimits` が負の角度で false（`Axis.cpp:51-53`）を返すと `onRejected(); return;`（163-166）。yaw の `limits_` は既に書き換わり、`applyPlannerVelocities()`（168）は走らない。
- `Axis::setLimits`（49-77）の失敗経路は負の角度だけ（速度は u16 で非負、超過は飽和）。
- 特性経路 `decodeLimitsWrite`（`Protocol.cpp:156-165`）は長さのみ検査。コマンド経路（`Protocol.cpp:108-111`）だけが `NegativeAngleLimit` を弾く。`BleTransport.cpp:205-213` は復号成功なら即 `onCommand`。

最小の修正案:
- `Supervisor` の SetLimits で両軸を変える前に `yawAngDeci >= 0 && pitchAngDeci >= 0` を検査して `onRejected()`（Axis の失敗条件はこれだけなので部分適用が消える）。または `decodeLimitsWrite` に負角度の検査を入れて特性経路で復号失敗にする（コマンド経路は既存の個別エラーを保つ）。
- 回帰: Supervisor 直叩きで `SetLimits(yawVel 500, pitchVel 0, yawAng 0, pitchAng -1)` → 両軸の limits 不変、`rejectedCount` +1。軸を入れ替えた逆ケースも 1 件。

## 総括
- 採用: I1、I2、I3（最小修正）、M1。却下・保留: なし。
- 推奨する修正担当（提案）: I1 は会話/記憶の担当（codex が実装してきた領域）、I2 は RobotLink/校正（codex）、I3/M1 は firmware（codex）。私は /simplify の指摘側の担当範囲（顔・ハーネス・look/顔追尾の簡素化）を持つのが自然。いずれも双方の評価を突き合わせてから着手。
- 未検証: 実機での力・速度、BLE バックプレッシャー下の実時間、prewarm のタイミングによる I1 の再現窓。
