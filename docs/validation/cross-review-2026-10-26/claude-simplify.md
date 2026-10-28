# /simplify 所見（claude）— range 29a6bbbc..dbd04589

- 対象: /Users/goodapple/.codex/worktrees/b200/Cat_robot（feature/look）の main merge-base 29a6bbbc3b9d83f847e0070204c5c8377e696da7..dbd04589ed780822b66720691f92131784012029。行番号はすべて HEAD dbd04589 の現行ファイルで確認した（codex の作業差分は見ていない）。
- 方法: /simplify の 4 観点（再利用 R、簡潔さ S、効率 E、修正の深さ A）をそれぞれ独立した subagent に読ませ、本書で重複を統合した。各観点の全文（根拠の詳細、「確認したが指摘しない点」、未確認範囲）は同ディレクトリの claude-simplify-details/findings-{reuse,simplification,efficiency,altitude}.md にある。
- 立場: 品質（再利用・簡潔さ・効率・修正の深さ）だけを見た。正しさのバグは探していない。コードは一切編集していない。
- 守る前提: 利用者が採用した顔の意匠（neutral-b / happy-b と画素一致）、カメラ前面を画面左固定・充電口右、BLE プロトコルのバイト列、firmware の安全動作（PWM 許可・トルク・タイムアウト）、実機で調整済みの数値（aim 8.5°、鮮度 1 s / 0.4 s、0.3 s 期限など）は、どの提案でも変えない。画素に触れ得る提案（C10、C24）は scripts/face-render の check による画素比較を採用条件にする。
- codex 側所見との干渉: I1（ClaudeConversationService）、I2（RobotCalibrationSession / RobotSettingsModel）、I3（Supervisor.cpp の SET_CAL 経路）、M1（BleTransport.cpp の Limits 書き込み）に触れる項目には「干渉」欄を付けた。これらは codex の修正が入るまで着手しない前提で書いている。

## 件数

- 元の所見: 簡潔さ 15 件（S1–S15）、再利用 12 件（R1–R12）、修正の深さ 10 件（A1–A10）、効率 6 件（E1–E6）。
- 統合後: C1–C30（高 1 / 中 12 / 低 17）。C1–C24 は R/S/A の統合、C25–C30 は E 由来。重大度は統合後の判断で、元の所見の重大度と異なる場合は理由を書いた。

## 重複対応表

| 統合ID | 元の所見 | 重大度 | 内容の要約 |
|---|---|---|---|
| C1 | S1 = R1 | 高 | FileLongTermMemoryStore が FileConversationMemoryStore の I/O を逐語で複製 |
| C2 | S3 = R3 ⊂ A1、A6 | 中 | 首・表情・look の後始末 7 か所、phase 転送 3 か所のコピー |
| C3 | S5 = R7 ≈ A5 | 中 | 姿勢 2 値のために RobotStatus 8 欄を 3 か所で組み直し、deci→度の変換が 6 か所 |
| C4 | S7 = A9 ⊂ R2、A8（静止フラグ）、A4（isActiveAtRest） | 中 | 静止・運用状態の述語と動作系優先度集合のインライン重複 |
| C5 | R4（linkReady）、A8（鮮度）、R5（0.4 s） | 中 | linkReady が MotionCoordinator.ready の写し、鮮度定数の散在 |
| C6 | R4（permitsCapture・熱）= A3 | 中 | 撮影可否の式と熱判定が ConversationCamera と FaceTrackingCoordinator で二重 |
| C7 | R5 | 中 | 時刻境界の ε を 2 形 28 か所で手書き |
| C8 | S9 ⊂ A2 | 低（最小案）／A2 は保留提案 | RobotControlMode の導出が 3 か所、配信経路が 2 本 |
| C9 | S2 | 中 | settling 経路で使われない MOVE と到達しない分岐 |
| C10 | S4 | 中 | capTailTaper が全表情で定数 1 のまま補間値として残存 |
| C11 | S6 | 中 | 本番から呼ばれない API・enum case・古いコメント 8 点 |
| C12 | R6 | 中 | 接続照合つき送信 Task の前置き 5 か所、AsyncStream 購読ループ 7 本 |
| C13 | A4 | 中 | アイドル PWM 停止の許可条件が 2 層 3 か所 |
| C14 | A7 | 低 | 画像貸し出しの全体取り消し 2 行組 5 か所 |
| C15 | A10 | 低 | ターン無効化の手書き 6 か所、欄が不揃い |
| C16 | S8 | 低 | 他の状態から導出できるフラグ（encryptedStatusReceived、started/finished） |
| C17 | S10 | 低 | 値 1 つのための包み型 RobotStatusPresentation |
| C18 | S11 | 低 | .interrupted と .unavailable を区別して運ぶが同じに扱われる |
| C19 | R8 | 低 | LiveClaudeSessionClient.snapshots が LiveReplyModelClient.snapshots の写し |
| C20 | R10 | 低 | 設定 URL・既定値・範囲・画面骨組みの重複 |
| C21 | R11 | 低 | run_robot_motion_device_test.sh が既存スクリプトの写し |
| C22 | R12 | 低 | テストの FaceFallbackReply / LookFallbackReply が FixedIntegrationReply と同一 |
| C23 | S12、S13、S14、R9 | 低 | firmware の小さな冗長（未使用引数、lastSaveOk_、値規則の再実装、calibration() の写し） |
| C24 | S15 | 低 | CatFaceShapes の de Casteljau・回転楕円の書き写し、未使用引数 |
| C25 | E1 | 中 | 記憶の要約（compact）が次の返答の直前に直列で走る |
| C26 | E2 | 低 | 補間フレームごとに 52 個の KeyPath 連結を組み直す |
| C27 | E3 | 低 | 未接続でも 50 ms 周期の main-actor ループが回り続ける |
| C28 | E4 | 低 | App.init の main thread で CIContext を作る |
| C29 | E5 | 低 | firmware: 約 1 kHz の loop ごとに NimBLE ホストロックを取って bond 数を数える |
| C30 | E6 | 低 | firmware: ほぼ変わらない calibration / limits を 20 ms ごとに setValue |

## 指摘（統合後）

### C1. CatRobot/Conversation/Services/Memory/FileLongTermMemoryStore.swift:13-79 — 既存の FileConversationMemoryStore の読み書き・削除をほぼ逐語で写している
- 元: S1、R1（両観点が独立に同じ結論）
- 重大度: 高
- 根拠: 新規の FileLongTermMemoryStore（80 行）の I/O 部分が base の FileConversationMemoryStore.swift と同形。上限付き読み込み（LongTerm :13-30 / Conversation :24-44）、原子的保存（:32-49 / :46-70）、接頭辞による clear（:52-65 / :72-85）、protectAndExclude（:67-73 / :87-93、一字一句同一）、isMissing（:75-79 / :95-99、同一）。違いはファイル名（facts.json / current.json）、一時ファイル接頭辞（facts- / memory-）、上限（262_144 / 1_048_576）、欠落時の戻り値（[] / nil）、デコード後の検証（schemaVersion==1 / validate(expectedCompatibilityID:)）の 5 点だけ。
- 挙動を保つ条件: 共通化はバイト列の読み書き・削除に限る。JSON の符号化・検証・エラーの写像（readFailed / tooLarge / writeFailed / deleteFailed、欠落は成功）は各 store に残す。各 store は actor のまま、await を挟まず同期で共通部を呼ぶ（FileConversationMemoryStore.swift:4-5 の「一時ファイル書き込みと確定の間に再入しない」性質を保つ）。2 つの store は同じディレクトリを共有する（ConversationComposition.swift:45-47）ので、clear は自分のファイル名と接頭辞に一致するものだけを消す。
- 修正案: `struct ProtectedJSONFile: Sendable { let directory: URL, name: String, temporaryPrefix: String, maximumBytes: Int; func read() throws -> Data?; func write(_ data: Data) throws; func clear() throws }` を Memory/ に置き、両 store は符号化・検証だけを持つ。約 45〜60 行減。保護属性・バックアップ除外・rename の方針が 1 か所に集まる。
- トレードオフ: 差分外の FileConversationMemoryStore にも手が入る。公開 API は変わらないので既存の両 store のテストがそのまま回帰確認になる。
- 干渉: I1 の修正は ClaudeConversationService とメモリ系テストに入る。ストア本体は触らない想定だが、メモリ系テストファイルを codex が編集中なら、本項の着手は I1 の commit 後にする。

### C2. CatRobot/Conversation/Integration/ConversationViewModel.swift:170-172 ほか — 首・表情・look の後始末 7 か所と phase 転送 3 か所をコピーしている
- 元: S3 = R3（最小案）、A6（phase 通知の 3 重化）、A1（TurnFeatures への集約案）
- 重大度: 中
- 根拠: `motion.stopAll(reason:)` + `faceExpressions.reset()` + `look.reset()` が :170-172、:294-296、:385-387、:411-413、:1608-1610。`faceExpressions.reset()` + `look.reset()` だけが :280-281、:310-311。`motion.setConversationPhase` + `faceExpressions.setConversationPhase` の組が :101-102（init）、:1546-1547（transition）、:1611-1612（publish → presentFailure）。表示（表情と look の setVisible）の組が ConversationAppCoordinator.swift:76-77 と ConversationComposition.swift:91-92。履歴では 468df75（表情）が 12 行、8de9d12（look）が 9 行を各サイトへ追加しており、次の機能も同じ約 10 か所を触る。さらに :1609 の `faceExpressions.reset()` は直後の :1612 `setConversationPhase(.failed(error))` の中でも実行される（FaceExpressionCoordinator.swift:72-75、phaseAllowsTurn が false → reset()）。
- 挙動を保つ条件: 各サイトの対象・停止理由・同期で走る位置（await より前）は据え置く（170: .userStop / 294, 1608: .playbackFailed / 385, 411: .newConversation / 280, 310: 首は呼ばない）。順序は stopAll → 表情 → look。look は phase を受けない（LookControlling に setConversationPhase がない）。publish 内の順序（停止とリセット → setConversationPhase(.failed) → presentFailure）、transition の .failed ケースが表示を書かないこと（:1593-1594）、clearNotice が .failed で走らないこと（:1548-1553）を保つ。heldExpression は :1609 と :1612 の間で読まれない。
- 修正案（最小、推奨）: `private func resetTurnPresentation(stopping reason: MotionCancellationReason?)` と `private func setRobotPhase(_:)`（A6 の announcePhase と同じもの）を VM に置き、7 か所と 3 か所を置き換える。:1609 の冗長な reset は外してよい。約 20 行減。
- 修正案（拡張、任意）: A1 の `@MainActor struct TurnFeatures { motion, expressions, look; replyTurnObserver; stop(motion:); setConversationPhase(_:); setVisible(_:) }` に集約すれば、表示の 2 か所も 1 行になり、4 つ目の機能は TurnFeatures にだけ足せば済む。ただし ConversationDependencies の 4 引数と ConversationAppCoordinator の初期化子が変わり、FaceExpressionIntegrationTests、LookIntegrationTests、AppCompositionTests などの依存構築を書き換える必要がある。
- トレードオフ: 最小案はテストへの影響なし（FaceExpressionControlling.reset() の呼び出し回数を数える spy は無い。ReplyPlaybackTestDoubles の resetCount は ReplyGenerating の reset）。拡張案は依存の組み立てが変わるのでテスト改修が要る。
- 干渉: I1 の修正が ConversationViewModel.startNewConversation（:407-422）に及ぶ場合、:411-413 と重なる。I1 commit 後に着手する。

### C3. CatRobot/Motion/MotionCoordinator.swift:604-629 — 角度 2 値を運ぶために RobotStatus の 8 欄を 3 か所で組み直し、deci→度の変換も 6 か所にある
- 元: S5 = R7（最小案）、A5（GestureTiming の引数を姿勢型にする案）
- 重大度: 中
- 根拠: GestureTiming.estimate（GestureTiming.swift:11-12）と `command(for:current:)`（MotionCoordinator :596-598）が current から読むのは yawDeci と pitchDeci だけ。それなのに :608-611（look_at_user の delta）、:621-623（restAfter）、:626-629（neutral）が flags/pingSeq/state/voltageCenti/rejectedCount/saveSeq を毎回写している。`FacePose(yaw: Double(yawDeci)/10, …)` の変換が FaceTrackingCoordinator.swift:192、MotionCoordinator.swift:266、606、730-731、GestureTiming.swift:11-12、RobotConnectionView.swift:135 の 6 か所にある。
- 挙動を保つ条件: 写している角度以外の欄は、3 つの値の使用先（:154-166 の estimate と command(for:current:)）でどれも読まれない。変換式は同じにする。
- 修正案（最小、推奨）: RobotStatus に `func with(yawDeci: Int16, pitchDeci: Int16) -> RobotStatus` と `var pose: FacePose` を足し、3 か所と 6 か所を置き換える。neutral は `current.with(yawDeci: 0, pitchDeci: 0)` になり削除できる。約 10〜12 行減。
- 修正案（拡張、任意）: A5 のとおり `struct RobotPose { yawDeci, pitchDeci }` を導入し、`GestureTiming.estimate(request:limits:from:origin:)` に変えれば isExpressive の分岐（GestureTiming.swift:9-13、22）と偽 status（:608-611）が消える。GestureTimingTests（8 件）の書き換えが要る。
- トレードオフ: 最小案はテストへの影響なし。FacePose は FaceTracking の型なので、拡張の置き場所は Motion 側か FaceTrackingTypes.swift。RobotProtocol と BLE の符号化には触れない。
- 干渉: なし。

### C4. CatRobot/RobotLink/RobotLink.swift:195-196, 487-488, 417 ほか — 静止・運用状態の述語と動作系優先度集合が 3 ファイルにインラインで重複している
- 元: S7 = A9（優先度集合）⊂ R2、A8（静止フラグ）、A4（isActiveAtRest）
- 重大度: 中（S7/A9 単体は低、R2 の述語群を含めて中）
- 根拠: 優先度集合 `.toolMotion, .motion, .tracking, .idleMotion, .automaticSettlement, .idlePowerOff` が RobotLink.swift:195-196（期限を 0.3 s で切る対象）と :487-488（STATUS 復旧時に捨てる対象）に二重。静止の判定 `flags.intersection([.moving,.gesture,.returning]).isEmpty` が RobotLink.swift:417、528、553（並び順だけ違う）、563、MotionCoordinator.swift:371、452、RobotCalibrationSession.swift:372 の 7 か所。`[.gesture,.returning]` が RobotLink.swift:520、530、MotionCoordinator.swift:347 の 3 か所。運用状態 `state == .idle || .active` が RobotLink.swift:415、573、MotionCoordinator.swift:451 の 3 か所。先例として、コマンド側の分類は b628ddd で `isMotionCommand`（RobotLink.swift:717-723）に共有済み。
- 挙動を保つ条件: OptionSet の `intersection(x).isEmpty` と `isDisjoint(with: x)` は同値。Optional の連鎖（`status?.isAtRest == true`）を保てば nil の結果も同じ。MotionCoordinator.swift:539 の `[.gesture,.moving]` は別の集合なので対象外。優先度は default を持たない網羅的 switch で書き、ケース追加時の分類漏れをコンパイルエラーにする。
- 修正案: RobotProtocol.swift:53-78 の隣に `RobotStatusFlags.motionInProgress`、`RobotStatusFlags.ownershipBlocking`、`RobotStatus.isOperational`、`RobotStatus.isAtRest`、`RobotStatus.isActiveAtRest`（C13 で使う）を、RobotTransport.swift:79 に `RobotCommandPriority.isMotionLane` を置く。行数はほぼ変わらない（拡張で約 10 行増、13 か所が短くなる）が、STATUS 契約の規則が 1 か所に集まる。`priority >= .toolMotion` のような順序依存の書き方は意図が読めなくなるので採らない。
- トレードオフ: ほぼなし。テストへの影響なし。各定義に「なぜその集合か」の doc コメントを付ける。
- 干渉: RobotCalibrationSession.swift:372 は I2 の修正対象ファイルにある。この 1 か所は I2 commit 後に置き換える。

### C5. CatRobot/FaceTracking/FaceTrackingCoordinator.swift:137-141 — linkReady が MotionCoordinator.ready の写しで、鮮度定数（STATUS 1 s、画像 0.4 s）が各層に直書きされている
- 元: R4（linkReady 部分）、A8（鮮度部分）、R5（0.4 s 部分）
- 重大度: 中
- 根拠: FaceTrackingCoordinator.swift:137-141 の linkReady は MotionCoordinator.swift:366-369 の ready から `resynchronizationID == nil` を除いたものと同じ式（`state==.connected && motionAvailable && connectionID != nil && statusReceivedAt.map{now-$0 < 1-ε}==true`）。STATUS の 1 s は RobotLink.swift:471、:571-572、MotionCoordinator.swift:366-369、FaceTrackingCoordinator.swift:137-141、:263（`received + 1`）に直書き。画像の 0.4 s は CameraSnapshot.swift:11-14 に isFresh があるのに、FaceTrackingCoordinator.swift:203、222、229、237、265、268 と CameraSnapshot.swift:13 に直書き。仕様は「画像 400 ms / STATUS 1 秒の鮮度」を 1 つの規則として扱う（docs/superpowers/specs/2026-10-24-face-tracking-design.md:121）。
- 挙動を保つ条件: 値と比較の形（`< limit − 1e-6`、`>= limit − 1e-6`）はそのまま関数に移す。鮮度の再検査を外してはいけない（RobotLink は 0.1 s 間隔でしか再発行しないので、外すとタイムアウトの境界がずれる。S 観点の非指摘に同旨）。FaceTrackingCoordinator.swift:199-204 の受信ガードに CameraSnapshot.isFresh を丸ごと流用すると境界が変わる（受信ガードは `completedAt <= now+ε`、isFresh は `capturedAt <= now`）ので、共有するのは定数と比較形だけ。MotionCoordinator は resync の条件だけを自分の側で AND する。RobotCalibrationSession.canEdit（:56-65）は鮮度を見ない別の条件なので置き換えない。
- 修正案: RobotTransport.swift:64 の隣に `RobotLinkSnapshot.statusFreshness`（1 s）、`isStatusFresh(now:)`、`isMotionReady(now:)` を置き、ready と linkReady の共通部にする。`FaceCapturePolicy.freshness = 0.4` を 1 か所で定義し、FaceTrackingCoordinator と CameraSnapshot から参照する。約 8 行減。
- トレードオフ: なし。
- 干渉: なし。

### C6. CatRobot/Vision/ConversationCamera.swift:79-80, 90 — 撮影可否の式と熱判定を FaceTrackingCoordinator と二重に持っている
- 元: R4（permitsCapture・熱の部分）= A3
- 重大度: 中
- 根拠: 撮影可否 `conversationVisible && sceneActive && mode == .conversation && phase.permitsFaceTracking` が ConversationCamera.swift:79-80 と FaceTrackingCoordinator.swift:29-31（Environment.permitsCapture）で同一。61537a1 が FaceTracking を変えずに複製した。2 つは ConversationAppCoordinator.swift:84-87 から同じ引数で呼ばれる。熱の判定 `.serious || .critical` が ConversationCamera.swift:90 と FaceTrackingCoordinator.swift:121 に別々にあり、AppRootView.swift:114-118 が両方へ配っている。許可要求の重複排除も ConversationCamera.swift:51-66 と FaceTrackingCoordinator.swift:94-108 の 2 段（本番では FaceTracking の source が ConversationCamera そのもの、Composition:33-36）。同じ形の前例として 7aef684 では向きを Camera、FaceTracking、AppRootView の 3 か所から消す必要があった。
- 挙動を保つ条件: FaceTracking 固有の条件（trackingEnabled、hasStartedConversation を含む conversationVisible の値、linkReady、状態表示の優先順 :161-166、10 s の冷却 :127、:149-153）は FaceTracking に残す。共有するのは式と分類だけで、入力値は今と同じものを渡す。FaceTrackingCoordinator.setControlMode（:115-118）は環境の型を共有にしても「mode だけを更新する」形のまま書ける。
- 修正案: FaceTrackingCoordinator.Environment を `FaceCaptureEnvironment`（permitsCapture 付き）として FaceTrackingTypes.swift に移し、ConversationCamera も同じ型を受け取る。熱は `ProcessInfo.ThermalState.suspendsCapture` にする。許可要求の一本化は別段階にする（App が isAwaitingPermission を :115 と :161 で参照しており、FaceTracking の権限 Task を camera.permissionInProgress に置き換えると設定画面からの許可要求でも真になり判定が変わる。R/A 両観点が同じ理由で見送り）。
- トレードオフ: ConversationCameraTests と FaceTrackingCoordinatorTests で setEnvironment の呼び出し形が変わる。
- 干渉: なし。

### C7. CatRobot/RobotLink/RobotLink.swift:443 ほか 5 ファイル — 時刻境界の許容誤差 ε（0.000_001）が 2 つの形で 28 か所に手書きされている
- 元: R5
- 重大度: 中
- 根拠: 形 A「期限に達した」`now + ε >= deadline`（とその否定）が FaceTrackingCoordinator.swift:149、202、244、270、RobotLink.swift:267、443、458、462、474、601、MotionCoordinator.swift:699、746。形 B「d 秒経った」`now - t >= d - ε`（と `< d - ε`）が FaceTrackingCoordinator.swift:140、203、222、237、241、RobotLink.swift:467、471、572、MotionCoordinator.swift:368、423、428、720、721、837、FaceCapturePolicy.swift:97、CameraSnapshot.swift:13。
- 挙動を保つ条件: ヘルパーの中でも各形の算術をそのまま保てば結果はビット単位で一致する。2 つの形を 1 つにまとめると境界が変わるのでまとめない。`<` を `!(>=)` に置き換えられるのは NaN が入らない値に限る（該当箇所は clock.now 由来か isFinite 検査済み: FaceTrackingCoordinator.swift:200、CameraSnapshot.swift:12）。
- 修正案: RobotClock.swift に `RobotTime.tolerance`、`RobotTime.reached(_:now:)`、`RobotTime.elapsed(_:since:now:)` と、`RobotClock.hasReached` / `hasElapsed` を置く。行数はほぼ変わらないが ε の符号を取り違える余地がなくなる。C5 を先に入れれば FaceTrackingCoordinator.swift:140 と MotionCoordinator.swift:368 はそちらで消える。
- トレードオフ: FaceCapturePolicy と CameraSnapshot は clock を持たないので静的関数を使う。
- 干渉: なし。

### C8. CatRobot/App/ConversationAppCoordinator.swift:80, 175 — RobotControlMode の導出が 3 か所、配信経路が 2 本ある
- 元: S9（最小案）⊂ A2（単一経路化の案）。S 観点は A2 相当を「確認したが指摘しない」としており、観点間で見解が分かれる（後述）。
- 重大度: 低（S9 の最小案）。A2 の統合案は保留提案として記す。
- 根拠: `isVoiceSettingsClosed ? .conversation : settingsModel?.effectiveControlMode ?? .settings` が updateFaceEnvironment の :80 と updateRobotScene の :175 に同じ式で書かれ、RobotSettingsModel.swift:74-78（effectiveControlMode）が 3 つ目の導出。シート開閉も isVoiceSettingsClosed（AppCoordinator:20）と settingsOpen（RobotSettingsModel:22）の 2 つの bool。配信は、設定モデルのコールバック（notifyControlMode RobotSettingsModel:85 → ConversationComposition.swift:39-42 → motion.setControlMode と faceTracking.setControlMode）と、App からの直接呼び出し（AppCoordinator:175、180、184、195、:84-87 の setEnvironment(mode:)）の 2 本。:194 の settingsDidOpen() が経路 1 で通知した直後に :195 でもう一度 motion.setControlMode(.settings) を呼ぶ。faceTracking は mode を 2 つの入口（FaceTrackingCoordinator.swift:115-118 と :110-113）で受ける。
- 挙動を保つ条件（最小案）: 同じ式を同じ時点で評価するだけなので結果は変わらない。
- 挙動を保つ条件（A2 案）: 導出値は各ケースで同じになる（active でシート閉: .conversation、active でシート開: effectiveControlMode、inactive/background: setApplicationMode 経由で同値）。重複呼び出しは無害（MotionCoordinator.setControlMode は同値なら return :230、faceTracking の reconcile は冪等）。ただし呼び出し順を保つ必要がある: updateRobotScene では motion への mode 通知が link.setApplicationActive / resume / suspend より前（RobotLink.swift:158-162 は自動動作の収束が先に積まれている前提でキューを掃除する）。settingsModel が nil の構成（テスト約 20 件）ではコールバックが無いので、updateRobotScene 冒頭の明示的な motion 通知を残す。
- 修正案（最小、推奨）: `private var activeControlMode: RobotControlMode { … }` を置き、:80 と :175 で使う。テストへの影響なし。
- 修正案（A2、保留）: `controlMode` を scenePhase から 1 か所で導出し、`applyEnvironment()` が motion → camera/faceTracking の順で配る。RobotSettingsModel.onControlModeChanged を AppCoordinator 側へ向け、Composition:39-42 のクロージャと FaceTrackingCoordinator.setControlMode を消す。
- トレードオフ: A2 案は RobotSettingsModelTests、FaceTrackingAppIntegrationTests、RobotLifecycleIntegrationTests の mode 経路検証を App 経由に寄せる必要があり、S 観点は「face tracking の stopCapture → motion.setTrackingState(.disabled) → settle の順序が、:195 の motion.setControlMode や link.setApplicationActive / suspend の後ろへ移り得るので、読むだけでは最終状態が同じだと示せない」と判定した。A 観点は順序条件を満たせば同値と判定した。採るなら、RobotLifecycleIntegrationTests に「校正の開始・終了時の motion/link 呼び出し順」を固定するテストを先に足してからにする。
- 干渉: A2 案は RobotSettingsModel（I2 の修正対象）に触れる。最小案は触れない。

### C9. CatRobot/Motion/MotionCoordinator.swift:356-364, 779-811 — settling の経路で、使われない MOVE を組み立て、到達しない分岐を持っている
- 元: S2
- 重大度: 中
- 根拠: `settleOwnedAutomaticMotion` は :362 で `.move(yawDeci: status.yawDeci, …, speed: 10)` を作って `startTrackingCommand(…, settling: true)` に渡すが、settling 経路は :792-794 で `link.settleAutomaticMotion(replacing:token:expiresAt:)` を呼び、この関数は RobotLink.swift:181-185 で MOVE を自分で作るので渡された command は送られない。完了後も :800 で `clearAutomaticOwnership()` するだけで command は一度も参照されない。:357 の `let status = snapshot.status` はこの MOVE のためだけにあり、ownsAutomaticMotion（:344-348）が `snapshot.status?.flags… == true` を要求するので nil にならない。:797 の `else { throw RobotLinkFailure.notReady }` は到達しない（settling で呼ぶのは :362 だけで、そこでは automaticOwnerToken != nil が保証され、cancelAuto() はそれを消さない）。settling では :786 の `returning` と :805 の trackingReturnIssued 更新にも意味がない。
- 挙動を保つ条件: settling で実際に行っているのは autoToken / autoKind = .settling / lastTrackingAttemptAt の設定、settleAutomaticMotion の送信、成功時の lastTrackingWriteAt 更新と clearAutomaticOwnership()、finishAuto だけ。期限は現行どおり Task を作る前（呼び出し時点）に `clock.now + 0.3` で確定させてから渡す（Task の中で計算すると期限がわずかに延びる）。
- 修正案: 関数を 2 つに分け、`settling:` フラグと 3 か所の分岐をなくす。`settleOwnedAutomaticMotion(includingIdle:)` は guard → cancelAuto() → `startSettlement(replacing: owner, expiresAt: clock.now + 0.3)` だけにし、`startTrackingCommand` から settling 引数、settlingOwner、:792-797 の 3 分岐、:800 の if/else を除く。6〜8 行と 1 フラグが減り、tracking の送信経路が一本になる。
- トレードオフ: Task を組み立てる 5 行ほどが 2 つの関数に並ぶ。MotionCoordinatorTests の settle 系（link.settleAutomaticMotion の呼び出しを数えるもの）がそのまま回帰確認になる。
- 干渉: なし。

### C10. CatRobot/Conversation/UI/CatFaceAppearance.swift:23, 263 / CatFaceShapes.swift:176, 198-210, 218-238, 264, 267 — capTailTaper が全表情で定数 1 のまま、表情ごとの補間値として残っている
- 元: S4
- 重大度: 中
- 根拠: `Eye.capTailTaper` の既定値は 1（Appearance :23）で、どのプリセット（:84-220）も書き換えていない。docs/design/face-expression-2026-10-26/visual-comparison.md:274 にも「既定値 0 → 1、全表情が Round 7 の尾」とある。`guard tailTaper > 0 else { return ellipse }`（Shapes :206）は到達しない。`1 + taper * (x - 1)`（:233-234）は常に x。AnimationVector に補間されない 2 成分（左右の目）が入っている（Appearance :263）。同種として Shapes :264 `lerp(0.995, 0.995)` と :267 `lerp(0.535, 0.535)` は定数を補間しているだけ。
- 挙動を保つ条件: taper = 1 を代入した式に置き換えるので描画パスはビット単位で同じになるはず（`stretchLow = lerp(2.75, 2.25)`、`stretchHigh = lerp(0.75, 0.5)`、`right.u = 0.995`、`upper = 0.535`）。採用条件として、scripts/face-render の check で neutral-b / happy-b との画素一致を確認する。
- 修正案: Eye から capTailTaper を除き animatedKeyPaths からも除く。`litRim(frame:roundness:)` と `capTailFill(frame:ellipse:roundness:)` から taper 引数と :206 の guard を除き、:233-234 を定数式に、:264 と :267 を定数にする。約 8 行と 1 フィールド、2 引数、到達しない分岐 1 つが減る。
- トレードオフ: 尾を表情ごとに変える余地がなくなる（現行仕様では不要）。Tests と scripts/face-render は capTailTaper を参照していない。
- 干渉: なし。ただし画素比較の実行は xcodebuild 系の負荷を伴い得るので、実行時機は codex（iOS 検証の所有者）と合わせる。

### C11. 複数ファイル — 移行・削除の後に残った「本番から呼ばれない API」
- 元: S6
- 重大度: 中（1 つずつは小さいが 8 点でプロトコルや型の表面を広げている）
- 根拠（CatRobot/ の本番コードからの呼び出しが 0 件であることを grep で確認）: `RobotMotionControlling.updateTrackingTarget`（RobotMotionControlling.swift:50, :68、MotionCoordinator.swift:338-340。本番は setTrackingState。呼ぶのは MotionCoordinatorTests:232, :518 と MoveHeadToolTests:36 の fake）。`LookControlling.isCurrent`（LookControlling.swift:7, :19。プロトコル経由はテストの GatedLookHandoff LookToolTests.swift:225 だけ）。`ConversationDependencies.live(voiceSettings:)`（ConversationDependencies.swift:88-91。本番は ConversationComposition.live()。呼ぶのは VoiceSettingsIntegrationTests:65）。`RememberToolProvider`（ConversationToolProvider.swift:9-11。テスト専用）。`RobotCalibrationExit.cancelNavigation`（RobotSettingsModel.swift:8。RobotCalibrationView :45, :50-51 は .save と .restore しか渡さず、:118 で即 return、:129 は到達しない）。`ConversationListeningSemantic.symbol` と `ConversationAccessibility.listeningSymbol`（ConversationAccessibility.swift:16-23, :41。唯一の利用者 ListeningControl がこの range で削除済み）。`MotionTraceResult.interrupted`（MotionCoordinator.swift:8。record されない）。古い説明: MoveHeadTool.swift:45「Production tracking input remains nil until the camera work in plan 4.」、ClaudeConversationService.swift:268「Gemma 版から移植」。
- 挙動を保つ条件: 本番の呼び出しがないので実行時の挙動は変わらない。LookCoordinator.isCurrent と reset は内部メソッドとして残す（reset は VM がプロトコル経由で使う）。
- 修正案: プロトコル要件と Noop・fake の実装を外す。テストは `setTrackingState(.following(...))`、`ConversationComposition.live(...).dependencies`、テスト側に置いた provider に置き換える。`.cancelNavigation` は enum の case と :118、:129 を外す。symbol / listeningSymbol は削除。古いコメントは削除か現状に合わせる。
- トレードオフ: テストの書き換え数か所（RobotSettingsModelTests.swift:88、ClaudeConversationServiceTests:20、RememberToolTests:31 など）。
- 干渉: `.cancelNavigation` の削除は RobotSettingsModel.closeCalibration（:116-144）に触れ、I2 の修正箇所と重なる。この 1 点は I2 commit 後に、codex と同じファイルを同時に編集しない形で行う（codex が I2 の中で一緒に外すのが最も安全）。ClaudeConversationService.swift:268 のコメントも I1 の修正箇所の近傍。

### C12. CatRobot/Motion/MotionCoordinator.swift:448-449, 517-518, 644-645, 790-791, 875-876 ほか — 接続照合つき送信 Task の前置きが 5 か所、AsyncStream の購読ループが 6 ファイル 7 本で同じ形
- 元: R6
- 重大度: 中
- 根拠: `try Task.checkCancellation(); guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }` が上記 5 か所。`for await e in stream { guard …; self?.receive(e) }` 型の購読ループが FaceTrackingCoordinator.swift:71-82（2 本）、MotionCoordinator.swift:115-120、RobotSettingsModel.swift:34-39、RobotCalibrationSession.swift:302-307、ConversationCamera.swift:39-44、RobotLink.swift:236-241。
- 挙動を保つ条件: 前置きは「checkCancellation の後に接続照合」の順を保ち、do の内側で throw する（cycleFailed :521 と strengthWasCancelled の分岐 :654-657 はこの catch 経路に依存）。購読側の所有者はすべて deinit で Task を取り消している（FaceTrackingCoordinator:85、MotionCoordinator:133、RobotSettingsModel:42、RobotCalibrationSession:50、ConversationCamera:47、RobotLink:80）。AsyncStream は Task 取り消しで nil を返して反復が終わるので、`guard let self` 型と `isCancelled` 型を 1 つにまとめても終了時機は変わらない。
- 修正案: MotionCoordinator に `private static func requireConnection(_ link:, _ connection:) throws` を追加。購読は `AsyncStream.observe(by: owner) { owner, e in … }` の MainActor 拡張にまとめる（weak owner、isCancelled 確認、handle 呼び出し）。約 25 行減。
- トレードオフ: 共有の拡張が 1 つ増える。AppRootView.swift:81-85 の SwiftUI `.task` は対象外。
- 干渉: 購読ループの置き換えは RobotSettingsModel と RobotCalibrationSession（I2 の修正対象）に及ぶ。この 2 ファイルは I2 commit 後にする。

### C13. CatRobot/Motion/MotionCoordinator.swift:831-833, 843-845 / RobotLink.swift:562-563 — アイドル時の PWM 停止の許可条件が 2 層 3 か所にあり、fix のたびに 3 か所すべてへ足されてきた
- 元: A4（C4 の述語の上に載る）
- 重大度: 中
- 根拠: `!idleEnabled && !trackingEnabled && status.state == .active && 静止フラグ` が MotionCoordinator.swift:831-833（予約）、:843-845（Task 開始時）、RobotLink.swift:562-563（書き込み直前の canSend）。履歴: 178e3a6 で coordinator の 2 か所へ idleEnabled、34b05f7 で link へ idleEnabled、77e840d で 3 か所すべてへ trackingEnabled。
- 挙動を保つ条件: 3 つの確認時点はそのまま残し、共有するのは条件の定義だけ。再試行の違いも変えない（Task 先頭の guard は戻るだけで、:849-852 は link が notReady を返したときにだけ restSince を進める）。
- 修正案: `RobotPreferences.allowsIdlePowerOff { !idleEnabled && !trackingEnabled }` と `RobotStatus.isActiveAtRest`（C4）を置き、MotionCoordinator:831 と :843 は `preferences.allowsIdlePowerOff, atRest, snapshot.status?.isActiveAtRest == true`（ready を含む atRest は残す）、RobotLink:562 は `preferences.allowsIdlePowerOff, snapshot.status?.isActiveAtRest == true` にする。
- トレードオフ: なし（定義の移動だけで、テストは変わらない）。
- 干渉: なし。

### C14. CatRobot/Vision/ConversationCamera.swift:71-72, 83-84, 92-93, 152-154, 222-223 — 画像の貸し出しを全体で取り消す処理を呼び出し側ごとに 2 行ずつ書いている
- 元: A7
- 重大度: 低
- 根拠: `validSnapshotID = nil` と `finishPending(.failure(x))` の組が 5 か所。どれも 22f9796 が既存の finishPending の隣へ 1 行ずつ足したもの。仕様では「Global invalidation clears that lease」という 1 つの概念（docs/superpowers/specs/2026-10-26-look-design.md:24）。
- 挙動を保つ条件: 置き換えるのは id を指定しない全体取り消しの 5 か所だけ。id 指定の :128、:134、:141、:199 には入れない（:141 の取り消しは遅れて届くことがあり、受け渡し済み画像の validSnapshotID まで消してしまう）。エラーの種別は LookTool.swift:48-54 で文言が分かれるので引数として保つ。
- 修正案: `private func revokeSnapshots(_ error: CameraSnapshotError) { validSnapshotID = nil; finishPending(.failure(error)) }` にまとめる。
- トレードオフ: なし。
- 干渉: なし。

### C15. CatRobot/Motion/MotionCoordinator.swift:210-212, 280-282, 437-439, 240-241, 425, 563 — ターンの無効化を 6 か所で手書きしており、消す欄がそろっていない
- 元: A10
- 重大度: 低
- 根拠: 3 行の組（`turn?.valid = false; turn?.pending.removeAll(); turn?.waitingSince = nil`）が :210-212、:280-282、:437-439。waitingSince を除く 2 行だけが :240-241、:425、:563。
- 挙動を保つ条件: waitingSince が影響するのは finishCycle（:554）を経た次サイクルの previousWait（trace 値 :510）だけで、無効化されたターンは新しいサイクルを始めない（:477）ので、6 か所すべてで waitingSince を消しても観測できる差はない。:425 と :563 の `turn?.id == active.turn` の条件は呼び出し側に残す。
- 修正案: `private func invalidateTurn()` に 3 行をまとめ、6 か所から呼ぶ。
- トレードオフ: なし。
- 干渉: なし。

### C16. CatRobot/RobotLink/RobotLink.swift:60, 289, 383, 513, 666 / Conversation/Integration/SentenceReplyPlayback.swift:102-103, 114, 118 — 他の状態から導出できるフラグを別に持っている
- 元: S8
- 重大度: 低
- 根拠: `encryptedStatusReceived` は常に `preparation ∈ {.notify, .calibration, .limits, .ready}` と一致する（preparation の代入は :286, :339, :344, :367, :387, :394, :401, :663 だけで、後戻りは .gatt と .none だけ。true になる :383 は :387 で .notify に移るのと同じブロック、false に戻る :289 と :666 も .gatt / .none にする場所と同じ）。SentenceReplyPlayback の started / finished は `startedOrdinals.count == 1`（挿入直後）と `!finishedOrdinals.isEmpty` に等しい。
- 挙動を保つ条件: 上記のとおり、すべての代入箇所で対応が成り立っている。
- 修正案: RobotLink は stored をやめ `private var encryptedStatusReceived: Bool { switch preparation { case .notify, .calibration, .limits, .ready: true; default: false } }` にする（代入 3 か所が消える）。SentenceReplyPlayback は 2 つの var を削除し `if startedOrdinals.count == 1 { … }` と `guard !finishedOrdinals.isEmpty` にする。
- トレードオフ: なし。状態の組が一致しなくなる余地がなくなる。
- 干渉: なし。

### C17. CatRobot/RobotLink/RobotSettingsModel.swift:205-218 — 1 つの値を作るためだけの包み型 RobotStatusPresentation
- 元: S10
- 重大度: 低
- 根拠: stored property は status 1 つだけで、使われ方は常に `RobotStatusPresentation(snapshot:).status`（AppRootView.swift:41, :83）。static の `announcement(from:to:)` は `old == new ? nil : new?.message` の 1 行で、この型と関係のない RobotConnectionStatus の比較に使われる（ConversationView.swift:32）。
- 挙動を保つ条件: 写像する内容（connected / connecting・preparing・reconnecting / それ以外）を変えない。「値の射影で余計な更新を止める」意図（:205 のコメント）は enum 値の比較だけで保たれる。
- 修正案: ConversationViewState.swift の RobotConnectionStatus に `init(snapshot: RobotLinkSnapshot)` を足し、announcement は ConversationAnnouncementPolicy（ConversationAccessibility.swift:88-）の末尾に 1 行で取り込む。型が 1 つ減る。
- トレードオフ: RobotStatusPresentationTests（10 か所）の書き換え。
- 干渉: RobotSettingsModel.swift は I2 の修正対象。I2 commit 後にする。

### C18. CatRobot/FaceTracking/FaceTrackingTypes.swift:33-34 / Vision/ConversationCamera.swift:215-220 / FaceTracking/AppleFaceCaptureSource.swift:267-287 — .interrupted と .unavailable を区別して 2 層運んでいるが、どこでも同じに扱われている
- 元: S11
- 重大度: 低
- 根拠: 最終利用者の FaceTrackingCoordinator は :213 で `case let .unavailable(id), let .interrupted(id):` と同じに扱う。ConversationCamera は :215-224 で同じ後始末をしたうえで :218-219 の if/else で種類を写し直すだけ。AppleFaceCaptureSource は `fail(generation:interrupted:)` の Bool を 5 か所（:135, :273, :295, :308, :336）と通知の組（:267-268）で運び、違いは DEBUG ログ（:284）だけ。
- 挙動を保つ条件: 本番で種類によって分岐している箇所はない。
- 修正案: FaceCaptureEvent を observation と unavailable(generation:) の 2 つにする。ConversationCamera :217-220 は 1 行に。AppleFaceCaptureSource は Bool を外し、ログが要るなら通知名を文字列で渡す。
- トレードオフ: CatRobotTests の `.interrupted` 参照 3 か所（FaceTrackingCoordinatorTests、FaceCapturePolicyTests）の書き換え。将来、中断と失敗を分けた表示を作るならそのとき戻す。
- 干渉: なし。

### C19. CatRobot/Conversation/Services/Claude/ClaudeSessionFactory.swift:104-121 — LiveClaudeSessionClient.snapshots が既存の LiveReplyModelClient.snapshots の写し
- 元: R8
- 重大度: 低
- 根拠: ClaudeSessionFactory.swift:104-121 は base の FoundationModelReplyService.swift:114-140 と同形（streamResponse の各要素で checkCancellation → content を yield、エラーは写像して finish、onTermination で cancel）。違いは GenerationOptions とエラー写像関数だけ。ConversationSessionFactory.swift:10-15 の prewarm と snapshots は FoundationModelReplyService.swift:3-6 の ReplyModelClient と同じ要件で、13 行目のコメントにも「同じ契約」とある。
- 挙動を保つ条件: options と写像関数を引数にすれば出力もエラーも同じ。LanguageModelSession は Sendable（ClaudeSessionFactory.swift:87）。`ConversationSessionClient: ReplyModelClient` の精緻化にしても既存の準拠型（テストの 6 型を含む）はそのまま通る。
- 修正案: `LanguageModelSession.contentSnapshots(to:options:mapError:)` を作り、2 つの Live クライアントは 1 行で呼ぶ。約 12 行減。
- トレードオフ: 差分外の FoundationModelReplyService にも手が入る。既存テストで回帰確認。
- 干渉: I1 は ClaudeConversationService 側。ClaudeSessionFactory は別ファイルだが同じ Claude 系なので、I1 commit 後にする。

### C20. CatRobot/RobotLink/RobotConnectionView.swift:98-100 ほか — 設定 URL を開く処理・既定値・範囲・画面骨組みの重複
- 元: R10
- 重大度: 低
- 根拠: 設定 URL を開く処理は base の AppRootView.swift:120-123 に openSettings() があるのに、ConversationSettingsView.swift:111-113 と RobotConnectionView.swift:98-100 に同じものが追加されている。RobotConnectionView.swift:12-31 と RobotCalibrationView.swift:11-35 は画面骨組み（GeometryReader、ScrollView、padding(20)、systemGroupedBackground、`isAccessibilitySize || width < 650` の切り替え、inline タイトル、toolbarBackground の 2 回指定）が同じ。ConversationModelSettings.swift:53-56 の既定値（.opus5_5 / .low / 300）は ConversationModelConfiguration の既定値（同ファイル :25-27）と同じ値。FaceTrackingGeometry.swift:19 の `(0...20)` は RobotPreferences.swift:13 の trackingYawCorrectionRange と同じ範囲で、RobotCalibrationView.swift:72, 74 の "0°"、"20°"、"8.5°" も RobotPreferences の定数の直書き。
- 挙動を保つ条件: 呼ぶ API、参照する値、修飾子の並びはすべて同じ。
- 修正案: `OpenURLAction.openSystemSettings()`、既定値は `ConversationModelConfiguration()` から、範囲と表示値は RobotPreferences の定数から参照する。画面骨組みの `RobotSettingsPage(title:){…}` は使うのが 2 画面だけなので得が小さく、任意。
- トレードオフ: 小さい。
- 干渉: なし（RobotCalibrationView の表示定数は I2 の対象外の行）。

### C21. scripts/run_robot_motion_device_test.sh:12-66 — 既存の run_supertonic_integration_device_test.sh の骨組みを写している
- 元: R11
- 重大度: 低
- 根拠: 新規の 77 行は base のスクリプトと RUN_ID と結果ディレクトリの用意（:12-18 / :10-17）、build-for-testing（:19-26 / :20-24）、Python による xctestrun の書き換えと request.json の出力（:31-52 / :25-43）、test-without-building・xcresulttool・devicectl によるコピー・終了コード（:54-66 / :45-57）が同形。違いは変数名の接頭辞（ROBOT_ / SUPER_）だけ。
- 挙動を保つ条件: 意図的に違う 3 点（dirty 判定 `git status --porcelain` と `git diff --quiet HEAD`、xctestrun の選び方、結果の検証方法）は引数として残し、どちらかに揃えない。
- 修正案: `scripts/lib/device_test.sh` に `rewrite_xctestrun` と `run_and_export` を置き、両スクリプトから source する。新規スクリプトは約 25 行減。
- トレードオフ: 既存スクリプトにも手が入り、通しの確認は実機でしかできない（claude は実機操作をしないので、採用する場合の検証は codex／利用者側）。
- 干渉: なし。

### C22. CatRobotTests/Face/FaceExpressionIntegrationTests.swift:42-49 / Look/LookIntegrationTests.swift:205-212 — FaceFallbackReply と LookFallbackReply は既存の FixedIntegrationReply と同じもの
- 元: R12
- 重大度: 低
- 根拠: どちらも base の CatRobotTests/Device/SupertonicLatencyFixtures.swift:18-26 の `FixedIntegrationReply(text:)` と同じ（固定文字列を 1 回 yield して finish、stablePrefix は true）。Device/ のファイルも CatRobotTests ターゲットに含まれる（generate_project.rb:77 で再帰追加、#if なし）。
- 挙動を保つ条件: 出力、finish の扱い、no-op の各メソッドが同じ。
- 修正案: 151 行目と LookIntegrationTests の 29 行目を `FixedIntegrationReply(text: "…")` に置き換え、private 型 2 つを消す。16 行減。
- トレードオフ: Device 用 fixture への依存が増える。必要なら FixedIntegrationReply を共有のテストダブルのファイルへ移す。
- 干渉: なし。

### C23. firmware/lib/catneck/ — firmware の小さな冗長（未使用引数、lastSaveOk_、値規則の再実装、calibration() の写し）
- 元: S12、S13、S14、R9
- 重大度: 低（4 件まとめても低。I3/M1 の修正と同じファイルなので後回し）
- 根拠:
  - S12: `Supervisor::onCommand` は `(void)source;`（Supervisor.cpp:77）で引数を捨てており、`enum class Source`（Supervisor.h:39）はこの引数のためだけにある。呼び出し 6 か所（Console.cpp:60, :69, :79、BleTransport.cpp:189, :199, :209）とテスト（test_supervisor.cpp:68, :333）が毎回値を渡している。
  - S13: `saveCalibration()` は bool を返す（Supervisor.cpp:226-239、ヘッダ :73 も「結果を返す」）のに、Console は `onCommand(SaveCal)` の後で `lastSaveOk()` を読み直す（Console.cpp:69-70）。このために `lastSaveOk_` と accessor があり、`lastSaveOk_ = ok; saveError_ = !ok;`（:235-236）と同じ事実を 2 フラグで持つ。
  - S14: `acceptMotionRequest` は常に true（:334-338）で 5 か所の呼び出し（:103, :109, :129, :140, :147）が戻り値を使わない。`handleStop`（:342）は 1 行 wrapper で呼び出しは :86 だけ。`bool ignored = false; applyJointTargets(..., &ignored);` が 4 回（:324-325, :382-383, :439-440, :514-515）。`calibration()`（:578-586）は `currentBlob()`（:527-537）と同じ deci 変換と invert ビットの組み立てを書き直している。BleTransport.h の `name()`（:30）と `droppedEvents()`（:32）に呼び出し元がない。
  - R9: 速度 % の丸めが Gesture.cpp:134 と Supervisor.cpp:11-14（無名名前空間の clampSpeedPercent）で同じ写像。ゲインの範囲判定が Supervisor.cpp:16-18、Axis.cpp:87-92、SerialParser.cpp:243-246 の 3 か所。Axis.cpp:55-75 の手書きの飽和分岐 2 組は同ファイルの clampAbs（:10-20）と同種。cal の deci↔度の変換が Supervisor.cpp:61-62 / 145-146 と 530-533 / 580-583。Console.cpp:57-62 は Supervisor.cpp:78-82 の「Boot 中の停止要求は記憶する」判定の再実装。
- 挙動を保つ条件: 値・呼び出し順序・PWM の許可・トルク・タイムアウト・Status/Notify のバイト列は同じまま。Console は :57-63 で Boot を先に弾き `filled.saveCal.req` は 0 にならない（:66-67）ので、`saveCalibration(req, now)` を直接呼んでも同じ。SerialParser 側のゲイン検査は残す（ここで弾いた入力は Supervisor に届かず rejectedCount が増えない。Console の Boot 検査 :112-115 も ERR BOOT か ERR RANGE かで出力が違う）。calibration() は currentBlob() から写しても値は同じ（isDirty() はすでに currentBlob() を呼ぶ）。
- 修正案: `onCommand(const Command&, uint32_t nowMillis)` にして enum と `(void)source;` を削除（呼び出し 8 か所から引数が 1 つ減る）。Console.cpp:69-70 を `if (supervisor_.saveCalibration(filled.saveCal.req, nowMillis))` にして lastSaveOk_ / lastSaveOk() / :235 を削除。acceptMotionRequest を void、handleStop を削除して :86 で enterState(Idle) を直接呼ぶ、`applyJointTargets(float, float, bool* saturated = nullptr)`、`calibration()` は `const CalBlob b = currentBlob(); return {b.yawOffDeci, b.pitchOffDeci, b.invert, !isDirty()};`、BleTransport の accessor 2 つを削除。Config.h（または Axis.h）に `clampSpeedPercent`、`gainInRange`、`clampRange(v, lo, hi, bool*)` を inline で置き、Supervisor に `applyCalibration(yawOffDeci, pitchOffDeci, invert, bool*)` を置く。Console.cpp:59-61 の if を外す（「ERR BOOT」の出力と SaveCal 前の return は残す）。合わせて約 30 行と宣言 3 つ。
- トレードオフ: test_supervisor.cpp の `lastSaveOk()` 5 か所（:808, :818, :832, :841, :867）を saveCalibration() の戻り値か `status().flags & StatusFlags::SaveError` に置き換える。再ビルドと PlatformIO の host テスト（test_supervisor、test_serial_parser、test_axis）が必要。経路ごとに挙動を変える予定が設計書にあれば Source は残す（現行 spec には見当たらない）。
- 干渉: I3（Supervisor.cpp:143-153 の SetCal 経路、applyCalibration 相当の場所）と M1（BleTransport.cpp:205-213）の修正と同じファイル・同じ関数の近傍。firmware の簡素化は I3/M1 の修正と host テストが commit された後に、同じ host テストを回帰確認として行う。

### C24. CatRobot/Conversation/UI/CatFaceShapes.swift:363, 524-527, 558-560, 222-227 — 同じ幾何計算の書き写しと、使われない引数
- 元: S15（R 観点も capTailFill の写像再導出を認識したが、画素再検証の手間を理由に見送っている）
- 重大度: 低
- 根拠: ひげの中心線を t = 0.5 で分割する de Casteljau（:525-527）と `mid`（:558-560）は同ファイルの `splitCubic`（:248-257）と同じ計算。`nose(appearance:)`（:363）は appearance を読まない（呼び出しは :578, :620 と CatFaceView.swift:113）。`capTailFill` の点関数 `p`（:224-227）は `EyeFrame.ellipse` の回転楕円の点関数（:79-81）と同じ式。
- 挙動を保つ条件: splitCubic の `a + (b - a) * 0.5` と `(a + b) / 2` は浮動小数の最下位ビットで違うことがある。描画は変わらない見込みだが、face-render の check と unmirroredShapeNames の許容誤差（1e-4）の中に収まることを画素比較で確認するのを採用条件にする。nose は引数を外すだけなので同じ。
- 修正案: `let (head, tail) = splitCubic([root, c1, c2, tip], at: 0.5)` として q1/r1/m/r2/q3 を取り、mid を削除（約 7 行減）。`static func nose()`（または static let）。回転楕円の点は EyeFrame の static helper にまとめ 2 か所から使う。C10 と同じ変更単位で行い、画素比較は 1 回で済ませる。
- トレードオフ: 採用済みの意匠は変わらない前提だが、画素一致の確認が必要。
- 干渉: C10 と同じ。

### C25. CatRobot/Conversation/Services/Claude/ClaudeConversationService.swift:171-174 — 前の往復だけで決まる要約が、次の返答の直前に直列で走る
- 元: E1
- 重大度: 中（遅延が出るのは記憶が 12,000 文字に達するターンだけ。採否は「状態と Haiku 1 往復分の無駄が増える」こととの秤量なので、利用者判断を推奨）
- 根拠: `generate` は先頭で `candidate.characters >= budget.compactionTriggerCharacters`（12,000 文字 :6）を判定し、超えていれば `compact(candidate)`（:250-266、`factory.summarize` の await = Haiku 1 往復、出力上限 2,400 トークン ClaudeSessionFactory.swift:50-58）を終えてからセッション作成と返答ストリームへ進む。経路は音声→返答のホットパス（ConversationViewModel.swift:1096 → SentenceReplyPlayback.swift:62 → MotionReplyGenerator.swift:20 → OnDeviceFallbackReplyGenerator.swift:69 → ClaudeConversationService.swift:121 → :172）。そのターンは最初の字幕と発話が要約の生成時間ぶん遅れる。要約の入力は「この発話より前の memory」だけ（:168、:257-259）で今回の発話に依存しないので、前の往復を保存した時点（:192-198）で計算を始められる。
- 挙動を保つ条件: 前の往復の保存直後と次の generate 開始時とで memory が同じなら compact の入力は同一。memory を変える経路（reset :137-139、recordExternalTurn :151-153、forget :396 / :413）はすべて revision か operationEpoch を進めるので照合キーにできる。キーが一致したときだけ先行結果を使い、不一致や先行失敗のときは今と同じく :172 で同期的に compact を呼ぶ（成功時・失敗時とも同じ入力・判定・失敗処理）。圧縮結果の memory 反映と invalidateSession() の時期は次の generate 内のまま。
- 修正案: `precompaction: (revision, epoch, Task<ShortTermMemory, Error>)?` を持ち、saveMemory 後（:198 の後）に閾値超過なら先行 Task を開始、:171-174 でキー一致なら先行結果を使う。reset / recordExternalTurn / forgetConversation で cancel して nil。任意で restoreMemory の末尾（音声 preflight 中）でも開始すれば、起動直後に復元した記憶が閾値超過のケースも解消する。
- トレードオフ: 先行計算のあとに reset・forget・端末内モデルの往復・アプリ終了が来ると Haiku 1 回分の利用料が無駄になる。compactionStarted / compactionFinished のトレース印が前のターン側に付き、遅延集計スクリプトの見え方が変わる。状態が 1 つ増え invalidate 条件のテストが要る。計画書 docs/superpowers/plans/2026-10-11-claude-conversation-engine.md:2300 の「超えたら次の返答の前に要約」とは、要約を始める時刻だけが変わる。
- 干渉: I1 の修正と同じファイル・同じ generate / reset 経路（reset の prepare 待ち、operationEpoch、storeTail）。採用するなら I1 commit 後に、I1 で入ったテストを回帰確認に使って行う。

### C26. CatRobot/Conversation/UI/CatFaceAppearance.swift:260-290 — 補間フレームごとに 52 個の KeyPath 連結と配列を組み直している
- 元: E2
- 重大度: 低
- 根拠: `animatedKeyPaths` は計算型の static var（:260）で、参照のたびに目 24 項目 × 2 側とひげ 2 項目 × 2 側を `side.appending(path:)` で連結（計 52 回、毎回ヒープ確保）し、flatMap / map / + で配列 5 本を作る。これを `animationVector` の get（:285）と set（:287）が毎回呼び、呼び出し元は CatFaceView.swift:81-88 の animatableData。補間が走るのは表情切り替え（CatFaceView.swift:30、0.25 s）、文の境界の口（ConversationViewModel.swift:672-675、0.14 s）、neutral のまばたき（CatFaceView.swift:57-60、3.5 s ごとに 0.22 s）。
- 挙動を保つ条件: 同じ順序・同じ KeyPath 列を 1 回だけ作って使い回すだけなので、値・順序・補間結果は変わらない。
- 修正案: `static let` にする。SWIFT_VERSION 6.0 / SWIFT_STRICT_CONCURRENCY=complete（project.pbxproj:1207-1208）では非 Sendable の KeyPath 配列の素の static let は並行性検査で止まる見込みなので、`nonisolated(unsafe)` を付けるか（リポジトリに前例なし）、57 本をリテラル KeyPath（`\.leftEye.widthScale` など、Swift 6 では `& Sendable` と推論）で列挙した static let にする。未ビルド。
- トレードオフ: nonisolated(unsafe) を 1 か所導入するか 57 行の列挙を書くかのどちらか。AnimationVector の配列演算（:242-257）によるフレームごとの確保は残る。
- 干渉: C10（capTailTaper の除去）で animatedKeyPaths の内容が変わるので、C10 → C26 の順に同じ変更単位で行い、画素比較は 1 回で済ませる。

### C27. CatRobot/Motion/MotionCoordinator.swift:121-128 — 首の接続と無関係に、起動時から 50 ms 周期の main-actor ループが回り続ける
- 元: E3
- 重大度: 低
- 根拠: init は無条件に `while !Task.isCancelled { sleep(0.05); tick() }` を開始し、止めるのは deinit だけ（生成は CatRobotApp.swift:7 → ConversationComposition.swift:30-31 の起動時）。オンボーディング中も首を持たない利用者の会話中も、前面にいる間は毎秒 20 回 main actor が起こされる（UIBackgroundModes が無いので背景では止まる）。`snapshot.state != .connected` のとき tick() と service() の分岐はすべて何もしない（active は ready 中にしか作られず切断時に :413-415 → :283 で破棄。service() の各分岐 :474、:476-477、:679、:689、:697、:831 は atRest / ownsTracking / ownsIdle を要し、いずれも ready 前提 :342-372）。接続状態の変化はリンク観測 Task（:115-120 → refreshLinkState → receive）が別途届ける。
- 挙動を保つ条件: タイマーを回すのは `snapshot.state == .connected` の間だけにする。ready ではなく .connected で判定するので、再同期中や STATUS が古い間は今と同じく tick が続く。.connected への遷移は必ず receive を通るので、そこで再開すれば接続中のタイミング（50 ms 粒度）は変わらない。
- 修正案: `updateTimer()`（.connected でなければ cancel、未起動なら起動）を init の :121-128 の代わりに呼び、receive(_:) の :402（snapshot = next）直後でも呼ぶ。
- トレードオフ: 切断中は 50 ms 周期の安全網が無くなる（上記のとおり不要）。タイマーを前提にした単体テスト（ManualRobotClock の進め方）の見直しが要る。
- 干渉: なし。

### C28. CatRobot/Vision/CameraFrameCache.swift:15 — カメラを使わない起動でも、App.init の main thread で CIContext を作っている
- 元: E4
- 重大度: 低（生成コストは未計測。Instruments の App Launch で実測してから採否を決める）
- 根拠: CameraFrameCache の格納プロパティ `context = CIContext(...)` は FaceCaptureWorker の frameCache 初期化（AppleFaceCaptureSource.swift:92）で作られ、AppleFaceCaptureSource.init（:21）→ ConversationComposition.swift:33 → CatRobotApp.swift:7 の順で起動ごとに 1 回、最初の画面が出る前の main thread で同期的に起きる。使うのは「見て」の静止画変換（:34）だけ。
- 挙動を保つ条件: 同じオプションの context を最初のスナップショット変換より前に capture queue 上で 1 回作れば、変換結果も鮮度判定の時刻関係も変わらない。最初のフレームで作ると初回 look の鮮度余裕を食うので避ける。
- 修正案: context を `CIContext?` にして `mutating func prepareContext()` を足し、FaceCaptureWorker.init で `queue.async { frameCache.prepareContext() }`（起動直後に main 以外で作る）か、configure（AppleFaceCaptureSource.swift:187）の冒頭で呼ぶ（初回のカメラ起動時に作る）。snapshot() は `guard let context else { throw CameraSnapshotError.unavailable }`。
- トレードオフ: 前者は起動時の CPU 消費自体は残り main thread を塞がなくなるだけ。後者は初回のカメラ起動が 1 回だけその分遅くなる。
- 干渉: なし。

### C29. firmware/src/platform/BleTransport.cpp:227-228（:110-113）— 約 1 kHz の loop ごとに、NimBLE のホストロックを取って bond 数を数えている
- 元: E5
- 重大度: 低
- 根拠: loop() は `delay(1)`（main.cpp:104）で約 1 kHz で回り毎回 `ble.poll(now)`（main.cpp:80）を呼ぶ。poll の末尾 `supervisor_->setPairOpen(pairOpen(nowMillis))`（:228）は `NimBLEDevice::getNumBonds()`（:111）→ ble_store_util_bonded_peers → ble_store_iterate に入り、bond 数 + 1 回の ble_store_read がそれぞれ ble_hs_lock() / ble_hs_unlock() を取る（NimBLE-Arduino 2.5.1 nimble/host/src/ble_store.c:26-41、:567-591。別 worktree 9b35 の .pio で確認）。毎秒およそ 1,000 ×（bond 数 + 1）回のホストロックが単一コアの ESP32-C3 で NimBLE ホストタスクと競合する。pairOpen_ を読むのは 20 ms tick 内の Supervisor::status()（Supervisor.cpp:567）だけで、接続受け入れ（:151、:177）は pairOpen(millis()) をその場で呼ぶのでキャッシュに依存しない。
- 挙動を保つ条件: tick ブロック内で status()（main.cpp:94）の直前に同じ now で計算すれば、BLE の STATUS / Notify のフラグは今と同一（今も同じ iteration 内で直前に計算した値が使われる）。windowOpen_ の期限処理（:227）も pairOpen() 自体が経過時間を見るので tick 粒度で足りる。bond 数をキャッシュする案は採らない（NimBLE 側で bond が消える経路がある）。
- 修正案: poll から :227-228 を外して `void BleTransport::updatePairState(uint32_t now)` に移し、main.cpp の tick ブロックの :94 の直前で呼ぶ。
- トレードオフ: tick 間にシリアルの STATUS コマンド（Console.cpp:133-137）が来た場合だけ PAIR_OPEN が最大 20 ms 古くなる。
- 干渉: M1 の修正（BleTransport.cpp:205-213）と同じファイル。M1 commit 後。

### C30. firmware/src/main.cpp:96 → firmware/src/platform/BleTransport.cpp:231-241 — ほぼ変わらない calibration / limits を 20 ms ごとに作り直して setValue している
- 元: E6
- 重大度: 低
- 根拠: 毎 tick（50 Hz）`supervisor->calibration()` と `supervisor->limits()` を作り、encode して setValue を 3 特性ぶん呼ぶ。calibration() は isDirty() → currentBlob() で lround を 4 回実行（Supervisor.cpp:527-539、:578-586。ESP32-C3 は FPU なし）。同じ tick で status() も isDirty() を計算する（:563）ので blob は毎 tick 2 回組まれる。calibration と limits が変わるのは SetCal、SetLimits、GAIN、SAVE のときだけ。
- 挙動を保つ条件: 前回 setValue したバイト列と memcmp し、違うときだけ setValue すれば GATT Read が返す値は常に同一。初期値の zeros（:97-100）を比較用バッファの初期値にそろえれば起動直後も同じ。
- 修正案: BleTransport に readStatus_ / readCal_ / readLimits_ の比較用バッファを持ち、memcmp で差があるときだけ memcpy + setValue。calibration() の計算自体を省くなら Supervisor に設定変更の世代カウンタを足す（任意）。
- トレードオフ: 比較用バッファ 3 本（約 30 バイト）が増える。効果は CPU と critical section の回数の削減だけで、体感への影響は小さい。
- 干渉: I3（Supervisor.cpp）と M1（BleTransport.cpp）の修正と同じファイル。両方の commit 後。C23 の calibration() / currentBlob() 統合と同じ変更単位にできる。

## 観点間で見解が分かれた点（codex の受領時に判断材料にしてほしいもの）

1. **制御モード配信の一本化（C8）**: A 観点は A2 として高で指摘したが、S 観点は同じ機構を「確認したが指摘しない」とした。理由は、コールバック経路（RobotSettingsModel → Composition:39-42）を App 側に寄せると、face tracking の stopCapture → motion.setTrackingState(.disabled) → settle の順序が、:195 の motion.setControlMode や link.setApplicationActive / suspend の後ろへ移り得て、読むだけでは最終状態の同一性を示せないこと。A 観点は「motion への通知を link 呼び出しより前に置く」条件付きで同値と判定した。本書では S9 の最小案（式の共通化）だけを採用候補にし、A2 は「順序を固定するテストを先に足す」ことを条件とする保留提案にした。
2. **ターン後始末の集約の深さ（C2）**: S/R は private helper 2 つ（最小）、A は TurnFeatures への集約（依存の組み立てが変わる）。同じ機構なので最小案を先に入れ、4 つ目のターン付随機能が実際に増える時点で A1 に進めるのが安全。
3. **顔の幾何の整理（C10、C24、C26）**: R 観点は capTailFill の写像再導出を「画素再検証の手間 > 6 行の削減」として見送った。S/E 観点は指摘した。本書では「画素比較を採用条件にし、3 件を 1 つの変更単位にまとめて比較を 1 回で済ませる」形で残した。採用済みの意匠を守る優先度が高いので、不採用でも異論はない。
4. **要約の先行計算（C25）**: 効率の指摘だが、状態と無駄な API 呼び出しが増えるので、簡潔さの方向とは逆。遅延が実際に問題になっているか（遅延集計スクリプトの compaction 印の分布）を見てから決めるのがよい。
5. **鮮度の再検査（C5）**: S 観点の非指摘「MotionCoordinator.ready と linkReady の鮮度再検査を外してはいけない」と、R4/A8 の「式を共有する」は矛盾しない。共有するのは式だけで、検査は残す。本書の C5 はその前提で書いた。

## 採否と担当の提案（codex の受領結果と突き合わせるための叩き台。確定ではない）

前提: codex が I1/I2/I3/M1 の修正とテストを commit するまで、claude はコードを編集しない。iOS の検証（xcodebuild）は codex が所有しているので、claude 担当の編集も検証は codex 側で回すか、時機をそろえて直列に行う。firmware の host テストも同様。

| 段階 | 候補 | 条件 | 担当案 |
|---|---|---|---|
| 0（進行中） | I1 / I2 / I3 / M1 | codex の修正とテスト | codex |
| 1（I と干渉しない、トレードオフなし） | C3 最小、C4（RobotCalibrationSession:372 を除く）、C5、C7、C9、C13、C14、C15、C16、C8 最小 | MotionCoordinator / RobotLink / FaceTracking / ConversationCamera / RobotProtocol / RobotTransport / SentenceReplyPlayback / ConversationAppCoordinator。既存テストで回帰確認 | claude |
| 2（I1/I2 commit 後） | C1、C2 最小、C6、C11（.cancelNavigation は codex が I2 内で外すのが最も安全）、C12 の残り 2 ファイル、C17、C19、C4 の残り 1 行、C25（採用する場合） | I1/I2 で入ったテストを回帰確認に使う | claude（C11 の .cancelNavigation と C25 は codex 案も可） |
| 3（画素比較つき） | C10 → C26 → C24 を 1 単位 | scripts/face-render の check で neutral-b / happy-b と画素一致 | claude が編集、check の実行は codex と時機をそろえる |
| 4（I3/M1 commit 後、firmware） | C23、C29、C30 | PlatformIO host テスト（test_supervisor、test_serial_parser、test_axis）で回帰確認。実機書込はしない | claude（または codex） |
| 保留・判断待ち | C2 拡張（A1）、C8 拡張（A2）、C3 拡張（A5）、C18、C20、C21（実機でしか通し確認できない）、C22、C27、C28（実測が前提） | 利用者の判断、または必要になった時点 | 未定 |

## 確認したが指摘しない点（4 観点の要約。全文は claude-simplify-details/ の各ファイル）

- GestureTiming が firmware の Gesture.cpp / Config.h の定数を写している点: 重複をなくすには所要時間を返す仕組みが要り BLE プロトコルが変わる。意図した写し。
- MotionCoordinator の多種類のトークンと世代番号、自動動作の所有権を coordinator と link の snapshot.automaticWrite で二重に持つ点: それぞれ独立した非同期操作や間隔判定を守っており、一本化は推測的な再設計になる。
- firmware の fitGesture 3 か所（Supervisor.cpp:125、435、445）: SET_LIMITS 受信時に当て直す形にすると、1 回の接近中に上限が狭まってから広がったとき振幅が一致しない。安全動作優先。
- firmware の保留キュー（Supervisor.cpp:96-111、130-135）と app の canSend: 前者は安全とプロトコルの契約、後者は app の方針で、責務が別。
- SerialParser の GAIN 範囲検査と Supervisor::setGain の重複: Supervisor 側は onRejected で rejectedCount を数えるので片方に寄せると Status が変わる。
- AppleFaceCaptureSource の回転角 4 通りの switch（:247-253）: 左固定でもセンサの取り付け角は機種で違うので、両横向き対応の名残ではない。
- MoveHeadTool の repeats 事前検査（:22）: MotionCoordinator の :151 と重複して見えるが、未接続時の文言と trace が変わる。
- FaceTracking の権限 Task を camera.permissionInProgress に置き換える案: 設定画面からの許可要求でも isAwaitingPermission が真になり、ConversationAppCoordinator.swift:115 と 161 の判定が変わる。
- ClaudeConversationService.generate :191 の `epoch == operationEpoch`: :188 との間に await がないので常に真だが、`!Task.isCancelled` の再検査には意味があり、削れるのは条件 1 つだけ。
- RobotCalibrationSession の direction UUID と directionToken の打ち消し 3 行: helper にまとめられるが、効果に対して確認範囲が広い（I2 の対象ファイルでもある）。
- 7aef684 のカメラ左固定、aim の調整連鎖（最後は利用者設定 FaceTrackingGeometry.project:28）、bda8e8c の ServoDriver 層での修正、OnDeviceFallbackReplyGenerator.swift:131 の cancelTurn(.fallback)、LookCoordinator の再確認 4 か所、Planner.cpp（特例分岐なし）: いずれも適切な層での修正と判断。
- 効率面で見送ったもの: CameraFrameCache の 1 枚保持、フレームごとの VNDetectFaceRectanglesRequest 生成（3 fps）、カメラ開始ごとの AVCaptureSession 作り直し（支配的なのは startRunning）、LookCoordinator の 0.1 s 待機（仕様）、RobotLink の 100 ms 監視（期限管理に必要）、STATUS の 4 観測者配信、ClaudeLanguageModel / LanguageModelSession の都度生成（SDK 0.2.3 では executor は Configuration ごとに再利用）、返答ストリームの 4 層中継、UserDefaults JSON の読み書き、Canvas の全体再描画（口の補間は 0.14 s だけ、分割は画素検証が要る）、highlightDrop の二分探索（まぶたのある表情の補間中だけ）、Planner の二分探索（意図的）、待機中の 50 ms MOVE（設計どおり）。

## 未確認の範囲（4 観点の和集合）

- 4 観点ともパッチファイルを 1 行ずつは読んでいない。HEAD dbd04589 の現行ファイルを読み、追加行かどうかは `git diff -U0` の hunk、履歴は `git show` / `git log -S` で確認した。
- ios-tests.patch（12,965 行）は、テストダブルの重複と実時間 sleep の grep、上の判断で参照した箇所だけ。1 行ずつのレビューはしていない。
- scripts.patch（2,270 行）: face-render の各 Swift ファイルは関数一覧のみ、generate_project.rb の差分と README は未読（Gemma 参照の grep と test_generate_project.rb:155 の確認のみ）。
- iOS 製品コードで観点によって未読のもの: ConversationViewModel の差分 hunk と引用範囲の外、ConversationSettingsView :61 以降、RobotConnectionView / RobotCalibrationView / RobotCalibrationSession の一部（E/A 観点）、CoreBluetoothRobotTransport :120 以降、RobotProtocol :80 以降の encode / decode、TypedInputView、OnboardingView、ConversationErrorPresentation、ClaudeAuthConfiguration、ConversationInstructions、ClaudeErrorMapper、ConversationMemoryCompatibility、FoundationModel* の小さな差分、AppleSpeech 系と Supertonic 系、CatFaceShapes :575 以降、Info.plist と entitlements。
- firmware で観点によって未読のもの: Planner.cpp と Gesture.cpp の本体、Axis.cpp、Protocol.cpp / .h、SerialParser.cpp、NvsStorage、ServoDriver、SerialTransport、BleTransport.h、tests_host/、firmware/test/ の本文、tools/*.py（定義一覧のみ）。
- 外部挙動は実測していない: SwiftUI が Animatable の get / set を呼ぶ頻度、CIContext の生成コスト、FoundationModels が executor を作る時期（SDK コメントに依拠）、NimBLE の挙動（別 worktree 9b35 の .pio にある NimBLE-Arduino 2.5.1 / ESP32Servo 3.2.1 のソースで確認）。
- 指示どおり読んでいないもの: LocalAssets、API キー、実カメラ画像、claude-integration.json、バイナリ（AppIcon など）。ビジュアル履歴 PNG も再レビューしていない。
