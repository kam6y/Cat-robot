# issue #22 顔の向きによる宛先判定の省略 — Claude `/simplify` 統合報告（初回・独立）

作成: claude_issue25 2026-11-06 / 読み取り専用。ソース・git・Xcode・実機は触っていない。codex の native-code-review.md と root-reception-draft.md は本報告保存まで未読。

## 1. 対象と実行の証跡

| 項目 | 値 |
|---|---|
| 固定差分 | `git diff 04c3de85 e6cbe28c`（base main 04c3de85e9030135f261099c9055be56834f5626 → reviewHead e6cbe28ce2f44648fd6856d9ea030eeda11c54ff, branch codex/issue-22-gaze-addressing） |
| 保存先 / SHA-256 | `claude-frozen.diff` 2935 行、`0c006756845a18c68747f7d1a260d646aed111f63e0dc0dde1790fcd3b8c4c1b` |
| freeze.json 整合 | code/test/project パッチ SHA `7b47dddc45e7a5907d60a0b66026c284bc333d8b51894b6773e1a6c1f0660c72` == freeze.testedPatchSha256（再計算で一致） |
| pbxproj/xcscheme | 4 agent とも `project-semantic-check.json`（追加は FacingAddressingTests.swift のみ）を信頼し内容は読み飛ばし |
| 起動 | Skill `simplify` を `04c3de85..e6cbe28c --report-only` で実際に起動し、Phase 1 として Agent tool で 4 件を同一メッセージで並行 dispatch。全て `subagent_type: Plan`（読み取り専用）、`model: opus`、報告のみ・編集禁止。Phase 2（修正適用）は意図的に未実施（報告のみ、単一 writer は codex） |
| 角度 / task id / 使用量 | reuse（hand-back 11:5x、id は圧縮前の転記で欠落・transcript 参照）／ simplification `ad0f1ede4bb213fe4` 185,782 tok, 45 tool, 692 s ／ efficiency `a0358cd70af854457` 138,698 tok, 27 tool, 515 s ／ altitude `a675142f94496193c` 156,114 tok, 38 tool, 550 s |
| 角度別報告 | `claude-simplify-{reuse,simplification,efficiency,altitude}.md`（hand-back を圧縮転記、[V]/[P] は agent 自身の表記） |
| 追加の確認 | 統合時に私が code で再確認したもの: S1（base で `speakAndResume` 呼び出し 2 箇所 :984/:1038 → HEAD 1 箇所 :1017）、S5/A1（`isFacingScreen:` init 引数は :685 宣言と :773 使用のみ）、S6（:39 残存）、S7a/b/c（各テスト本文を比較）、S9（README :11, :279-280）、A2（`FaceTrackingTypes.swift:82-83` の doc）、A3（settings pane :41-43/:78/:83）、E1 の遷移点（VM :750 `.listening`, :982 `.classifying`, :1086 `.thinking`）、E3 のリセット箇所（Camera :97/:112/:137） |

## 2. 設計上の前提（記録済み判断。本節は評価対象ではなく、各所見の「衝突」判定の基準）

- **D-head**: 頭の向き（Vision rev3 yaw/pitch）のみ。瞳の視線・話者識別・新モデル・新設定なし（spec :5, :9。利用者回答「顔がこちらを向いていれば十分」）。
- **D-30s**: 直前返答から 30 秒・最大 5 分の engagement を維持。顔での受理は開始点を更新（spec :15。利用者回答「今の30秒ルールを残す」）。
- **D-route-time**: 宛先を決める時点で同期的に読む。撮影後 0.4 秒未満の最新観測のみ。発話中の「一度向いていた」は保持しない。古いイベントで新しい否定を上書きしない（spec :17。approach review で OR 蓄積・境界時刻案は却下済み）。
- **D-listening-only**: カメラへの attention 需要は `environmentPermitsCapture && phase == .listening` の間だけ。追尾／look と物理セッションを共有（spec :9, Camera :92）。
- **D-single-face**: 複数人は通常分類。単一の有効な顔に既存 `selectFace` と同じ yaw 中心 `-左右補正`・左右 30°・上下 25°（spec :16）。
- **D-revoke**: 権限・設定・背景・一時停止・待機・高温・失敗・中断・世代変更・終了で失効。復帰には新しい観測（spec :19）。
- **D-permission**: マイク/音声準備後に既存のカメラ権限要求を共有。追尾の要求を先に、追尾オフなら camera を直接（spec :20）。
- **D-strict/floor**: `recordAttention` の `completedAt <= clock.now` は厳密比較（追尾側の +1 µs 許容と非対称）、`capturedAt >= attentionStartedAt` の下限（diff check :25 で指摘、codex がテスト付きで維持）。

## 3. 所見（重複統合済み。[V]=code で確認、[P]=機構は確認・効果/頻度は未測定）

### Important

- **C1 [V 機構 / P 効果] 聞き取りを離れるたびに AVCaptureSession を停止・再構築（efficiency E1）** — D-listening-only と衝突。`Camera :92-98` の需要切替、`:177` reconcile、`:187-192` stopPhysical。`.accept`/`.classify` のどちらでも VM は `.classifying`(:982) か `.thinking`(:1086) へ遷移するので、追尾 generation も look pending も無い session（= 首ハード未接続・追尾オフの全 session）では、分類器が「別の相手」と判定して即 `.listening` に戻る場合でも `AppleFaceCaptureSource.stopOnQueue`（blocking stopRunning）→ `configure()`（新 AVCaptureSession/DeviceInput/format 走査/RotationCoordinator :187-264）→ blocking `startRunning()` を 1 往復する。差分自身のテスト `ConversationCameraTests.testListeningCapturesWithoutTrackingOrLook`（listening で starts=1、thinking で stops=1）がこの挙動を固定している。効果: 1 発話あたり stop+configure+start 1 回（faceCapture serial queue、main actor 外）と warm frame の喪失。再構築直後は新 frame + Vision が届くまで顔の証拠が無く、本来 bypass できた発話が分類器（Apple Intelligence 非対応端末では有料 Haiku）へ落ちる可能性 [P]。TV や同席者がいる部屋では聞こえた文ごとに往復する。代替: (a) 需要を `environmentPermitsCapture` にする（再構築 0、ただし thinking/speaking 中もカメラ on = 判断が避けたもの）、(b) 需要を `.classifying` まで延ばす（却下発話・言い直しの再構築だけ消え、thinking/speaking では解放される。ただし attention リセット `clearAttention`+`attentionStartedAt = now` を listening 入りの edge に分離しないと `testLeavingListeningRequiresFreshObservation…` と「古い frame で復活しない」が崩れる）、(c) 短い linger timer（Task 追加）、(d) 差分外: `AppleFaceCaptureSource` で configured session を stop/start 越しに再利用（割当・設定は消えるが startRunning は残る）。測定なし。判断は codex／利用者。

### Minor

- **C2 [V] `speakAndResume` が単一呼び出しになり引数・分岐が死んだ（simplification S1）** — `VM :1121-1176`、呼び出し :1017。base では wakeOnly「なあに？」(:984) と聞き返し(:1038) の 2 箇所、HEAD は聞き返し 1 箇所で常に `memoryPrompt` 非 nil・`.clarifying`・`.none`。既定値 :1123-1124、`if let memoryPrompt` の nil 側 :1162、`.arm/.refresh` 腕 :1168-1172 が到達不能。`EngagementUpdate.none` の生産者はここだけで、`generateReply` の `.none: break`(:1104) は base 時点から到達不能。簡素化: 聞き返し専用関数 + `EngagementUpdate = {arm, refresh}`（:1104 の腕削除が必要）。約 12 行。挙動差なし。付記: 口の動き処理（`.started → .small`, `.willSpeak → nextWordPose()`）の統合テストが wakeOnly 経路と共に消え、`ConversationViewModelTests :601` は `generateReply` 経由。
- **C3 [V] README の呼び名前提が残る（S9）** — `README.md:11`「呼びかけがない発話は…分類します」は名前付き発話も分類される今は誤り（:10 と矛盾）→「それ以外の発話は…」。`:279-280` の手動確認は「猫ちゃん、短く自己紹介して」「名前を呼ばずに話し」で組まれ、顔の経路を一度も通らない → 画面を向いて話す（省略）／顔を背けて話す（分類）／30 秒内外、に差し替え。
- **C4 [V] 左右補正 UI が追尾専用の文言のまま（altitude A3）** — `CameraTrackingSettingsPane.swift:41-43, :78, :83`（header「顔追尾（ハードの接続が必要）」、accessibility「顔追尾の左右補正を微調整」、追尾専用 footer）。`ConversationComposition.swift:89` は同じ `preferences.trackingYawCorrection` を顔判定に使い、ハード無しでも効く。差分はカメラ節 footer・Info.plist・onboarding を更新したがこの節は未更新。ハード無し・カメラがずれた利用者に補正の手掛かりが無い。文言のみ、key 改名はしない。
- **C5 [V] 削除済みパーサ由来のテスト名（reuse 付記 / S6）** — `AddresseePolicyTests.swift:39-61` `testWakeNameDoesNotMatchLaterTextOrConcatenatedWord`。呼び名コードが無い今、pending/engagement/facing 無しの非 filler 入力は全て classify なので固有の検証が無く、名前が存在しない概念を指す。`testNamesAloneDoNotBypassClassifier`(:5) が残る意図を既に担う。削除か :5 のループに統合。
- **C6 [V loop / P 頻度] `captureFailed` を listening 入りごとにリセット（efficiency E3）** — `Camera :97`。持続失敗（他 app がカメラ保持で `wasInterrupted` 連発、`configure` が `unsupportedConfiguration`）では非 ignore 発話ごとに configure→start→fail→stop を繰り返す。追尾 on でも、追尾側が自分の `captureFailed` を立てて `camera.stop()` した後は次の listening 入りが attention 単独で再始動する。base のリトライ契機は追尾 eligibility の立ち上がり・`start(generation:)`・`captureSnapshot` のみ。対案: 環境 edge（scene active・権限変化・高温回復・追尾開始）でのみリセット、または cooldown。反論（altitude N3）: 「新しい owner 要求が共有 latch を消す」既存パターン（:112, :137）に沿っており特例ではない。リスク: 環境 edge 無しに解消した一過性失敗からの復帰が遅れる。設計判断寄り。
- **C7 [V] テスト harness の重複と層の混在（reuse R2/R4, simplification S8）** — `FacingAddressingTests.swift:269-300` `FacingCameraHarness` は `ConversationCameraTests.swift:219-239` `CameraHarness` のほぼ写し（差は phase `.listening`/`.thinking`、常時 `camera.start(generation:)`、`emit`）。`:6-23` は純同期の `AddresseePolicy` 単体テストが `@MainActor` 統合ファイルに置かれている。新ファイルは policy/camera/app/composition の 4 層混在。簡素化: :6-23 を `AddresseePolicyTests` へ、camera テストを `ConversationCameraTests` へ（`CameraHarness(phase:)` + `emit`）、新ファイルは app/composition のみ。副作用: `FacingCameraHarness` が常に追尾需要を立てるため、その 11 件は追尾オフ経路を一度も走らない（追尾オフは `ConversationCameraTests :6` と `FacingAddressingTests :247` のみ）。テストのみ、project 再生成の可能性。
- **C8 [V] look ターンで warm session を 0.1 秒前に捨てる（efficiency E2）** — D-listening-only の帰結。`LookIntegrationTests.swift:69-73` が look 開始で starts=1/stops=1、0.1 秒 look 遅延（`LookCoordinator.swift:44-49`）後に starts=2 を期待。listening→thinking で attention session が停止し、`captureSnapshot` が新 generation を冷起動。look の configure/startRunning は blocking stopRunning の後ろに並ぶ。base も look は冷起動だったので、追加コストは無駄な teardown と直列化（0.1 秒を超えれば snapshot 待ち、未測定）。C1(a) のみが解消（warm session なら `fulfillSnapshotIfFresh` が `frameCache` から応答）。

### Nit

- **C9 [P] `recordAttention` の採否ガードが `FaceTrackingCoordinator.receive` :185-190 の写し（reuse R1 / S4 / altitude N7）** — D-strict/floor と衝突。差は厳密比較 vs +1 µs、下限 `attentionStartedAt` vs 0、不正 frame で cache 消去 vs 無視。共有 helper `FaceObservation.isTimely(now:notBefore:)` にすると許容パラメータが要り利得が薄い上、差分外の `FaceTrackingCoordinator` に触る。altitude の判断: 各 consumer で検証するのが正しい深さ（追尾側は fake に直結、camera の検証に依存できない）。保留推奨。
- **C10 [V] `hasFreshFacingFace` の `eligible`/`attentionRequested`/`physicalGeneration != nil` は `latestAttention != nil` が含意（reuse R5 / S2 / altitude N7）** — 全ての失効入力が `reconcile()→stopPhysical()→clearAttention()` を通る（:166, :107, :99-101, :84/:77）。残すべきは live `source.authorization == .authorized`（`FacingAddressingTests :174` が `refreshAuthorization()` 前の `.denied` を検証）。`isSnapshotValid` :157-160 と同じ防御的書式なので一貫性のため維持も妥当。
- **C11 [V] `recordAttention` の `eligible`・`capturedAt.isFinite`・`completedAt.isFinite` は冗長（S3）** — `eligible` は呼び出し側 `generation == physicalGeneration` :249 が含意、`capturedAt.isFinite` は `CameraSnapshot.isFresh`（`CameraSnapshot.swift:12`）内、`completedAt.isFinite` は `capturedAt <= completedAt <= now` から従う。`testMalformedFutureAndStaleTimestampsCannotGrantFacing` :127 の全ケースは引き続き拒否。
- **C12 [V] `ConversationHarness.init(isFacingScreen:)` が未使用（S5 / altitude A1 / reuse 付記）** — `ConversationFakes.swift:685, :773`。全 16 ファイルの構築箇所で未指定、全テストが `harness.attention.isFacingScreen` を使う。引数を削除し `{ attention.isFacingScreen }` 固定。
- **C13 [V] 書き換えで生じた重複テスト（S7。a/b/c とも本文比較で確認）** — (a) `ConversationLatencyTests :55` は `:21` の真部分集合（facing fast path の selected/caption/speech のみ、「なあに？」経路が消えた）。(b) `FacingAddressingTests :58` の「今日どう？」反復は `ConversationRecoveryTests :157` と同一（pending at 0、facing「今日どう？」at 3、replies/classifier 同じ、Recovery は follow-up も検証）。(c) `ConversationViewModelTests :202` `testEngagedFollowUpAlsoSkipsClassifier` は `FacingAddressingTests :25`（同じ流れ + `.notAddressed` + 61 秒期限）に包含。Latency :55 削除、Facing :58 を「いいえ」のみ、VM :202/Facing :25 の一方。
- **C14 [V] camera テストが `selectFace` の境界（30°/25°・yaw 補正）を再検証（reuse R6）** — `FacingAddressingTests` の `testCameraFacingUsesExistingHeadBoundsAndCurrentYawCorrection` 等。`FaceTrackingGeometryTests` が既に境界を担う。「同じ関数を使っている」1 ケースで十分。
- **C15 [P] 権限テストが `FaceAppHarness`（`FaceTrackingAppIntegrationTests.swift:6-36`）の流れを再構築（reuse R3）** — `testAppRequestsCameraAfterVoicePreparationWithTrackingAbsentAndHandlesInactivePrompt`。private harness のため共有には可視性変更が要る。
- **C16 [V] phase 規則の置き場と古い doc（altitude A2）** — `Camera :92` の `environmentPermitsCapture && phase == .listening` は `FaceCaptureEnvironment`（`FaceTrackingTypes.swift:82-93`）の外にあり、同 doc「Face tracking and explicit image requests evaluate the same rule from the same values」が第 3 の需要を反映していない。`var requestsListeningAttention` を environment に置き doc を更新（純移動）。
- **C17 [V] 同じ規則の 5 重記載（S10）** — 0.4 s、30°/25°、単一顔、fallback 一覧、pending 優先、30 s/5 min が validation :7-16、design :13-20、plan :13-28、README :10、requirements :35/:224 に反復。repo 慣例は要約 1 文 + 設計へのリンク（`docs/validation/2026-10-28-face-facing-gate.md:5`）。定数変更で 4〜5 文書が drift。

## 4. 記録済み設計判断と衝突する提案（採否は codex／利用者）

| 所見 | 衝突する判断 | 要点 |
|---|---|---|
| C1 (a)(b)(c) | D-listening-only | (a) は thinking/speaking 中もカメラ on。(b) は「聞き取り中のみ」の字面を変えるが根拠（返答中は撮らない）は保てる。(c) は Task 追加。(d) は差分外。 |
| C8 | D-listening-only | C1(a) 以外では解消しない。 |
| C6 | D-listening-only の付随（listening 入りでの latch リセット） | 既存パターン準拠 vs 持続失敗での毎発話リトライ。 |
| C9 | D-strict/floor | 共有 helper 化は許容の非対称を失うか、パラメータ化で利得を失う。 |

D-head、D-30s、D-route-time、D-single-face、D-revoke、D-permission と衝突する提案は 4 角度とも無し（代替案は全て検討済みで却下、§5）。

## 5. 検討して却下（N。4 角度の統合、重複除去）

N1 closure seam は `ConversationDependencies` の既存流儀（`now`/`clarificationDelay`/…）と一致。protocol 化・recognizer 経由のサンプリングは D-route-time と衝突。N2 attention を別 object にするのは不可: `events()` は単一 AsyncStream（`bufferingNewest(1)`）で第 2 consumer を持てず、cache 妥当性は camera 私有状態（`physicalGeneration`, `eligible`, `stopPhysical`）に依存。N3 需要判定を coordinator 側へ移すと `== .listening` を 1 層上で繰り返し順序依存を増やす。N4 facing は `EngagementWindow` に畳めない（pending 分岐の非対称、arm vs refresh、返答成功後にのみ arm）。pending 分岐の fall-through 化は非等価（engaged+pending+非 yes/no は classify、`AddresseePolicyTests:116`）。N5 yaw 補正は composition closure で呼び出し時読取（stepper 即時反映、追尾側 :193 と同じ）。`faces.count == 1` を `FaceTrackingGeometry` へ移すのは誤り（追尾は複数顔から順位付け）。N6 権限は既に単一 owner（`FaceTrackingCoordinator(source: camera)` → `permissionTask` で重複排除、OS prompt 1 回）。camera-first 並べ替えは D-permission と衝突し行数も減らない。`isAwaitingCameraPermission` の OR は camera 無し／追尾無しの構成（`FaceTrackingAppIntegrationTests:22-24`, `RobotLifecycleIntegrationTests:32-34`, `FacingAddressingTests:219`）と Task wrapper の隙間に必要。N7 `attentionStartedAt`・`latestAttentionTime`・`attentionRequested` は導出不可／必要（`testLeavingListeningRequiresFreshObservation…` :138、不正 frame 後の高水位維持。後者は `FaceCapturePolicy.acceptsFrame` の単調増加により実機では到達困難、コメント程度）。N8 `route(isFacingScreen: = false)` 既定値は 18 箇所の domain テスト、dependency 既定値は 2 箇所に有用。N9 `isFacingScreen || !wasEngaged ? .arm : .refresh` は旧第 2 `route()` 呼び出しの置換で最小。N10 `ConversationTestAttention` box は最小形（closure が `self` 前に構築）。N11 残る名前言及は load-bearing（`ClaudeAddressClassifier.swift:29, 36` の prompt、`ConversationInactivityTests:17` "ExplicitWake" = tap-to-wake、`ConversationViewState.swift:203` 汎用文言、テストの「猫ちゃん/ねこ、」は通常テキスト）。N12 3 つの目的文言は別 surface、Info.plist は単独で成立必要。N13 `/tmp` パス・UDID は repo 慣例。N14 新フィールドは `@ObservationIgnored`、`recordAttention` は O(1)、`selectFace` は query 時の方が安く現行補正に必須。N15 composition/harness closure は app 寿命 object のみ捕捉、循環なし。N16 不正 frame での `latestAttention = nil` は fail-closed として維持。N17 差分は wake-name 走査と第 2 route 呼び出しを削除し、per-turn 仕事を減らしている。

## 6. 角度外の付記（simplify の対象外、correctness／codex 向け）

- requirements S1（`2026-10-11-…requirements.md:35`）の編集は要約の重複だけでなく基準を弱めている:「話し始める」→「話し始めることを目標とする」、起点「呼びかけから」→「発話終了から」。意図的なら設計書に理由が要る。
- C1 の派生: 再構築直後の listening で fresh frame が間に合わない場合、無料の bypass が有料分類に変わる [P]。定常でも 1/3 s 間隔 + Vision + main actor hop の処理が ~67 ms を超えると 0.4 s を割り、routing 時に stale 扱いになるケースがある [P、未測定]。
- 全角度で pbxproj/xcscheme は未読（semantic check 依存）。利用者向け文言の正確さは判断していない。

## 7. 証拠の限界と読み方

- 何もビルド・実行していない。全主張は HEAD e6cbe28c と base の読解。C2 の簡素化は :1104 の腕削除を伴わないと switch が非網羅になる。C10/C11 は全ての失効経路が `reconcile()`/`stopPhysical()`/`clearAttention()` を通ることに依存（`ConversationCamera.swift` 内の全 writer を agent が追跡、私は未再追跡）。
- C1/C6/C8 のコストは操作回数であり、configure/startRunning/stopRunning・初回 frame 到達・Vision per-frame・電力・熱・privacy indicator の点滅は未測定。実機観察が無いと Important の実効は確定できない。
- C13 は setup/assertion 比較で、coverage 測定ではない。
- 本報告は simplify（品質）であり correctness review ではない。

## 8. まとめ

Important 1（C1、D-listening-only と衝突、効果未測定）、Minor 7（C2〜C8）、Nit 9（C9〜C17）、角度外 3。統合を止める所見は無い: C1 は記録済み判断の帰結で、維持するなら「追尾オフでは発話ごとに session を再構築する」と validation に明記すれば十分。確実に拾う価値があるのは C2（死んだ引数）、C3（README の矛盾と手動確認）、C4（補正 UI 文言）、C5（削除済みパーサのテスト名）、C12（未使用引数）。テスト整理（C7/C13/C14）は任意。
