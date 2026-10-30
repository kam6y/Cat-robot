# /simplify — feature/idle-cat-life (6aa4050..c8dd4aa) — claude_sleep_zzz_1028, 2026-10-30

対象: Swift 本体・テスト・scripts/face-render harness の差分（3004 行）。spec docs/superpowers/specs/2026-10-30-idle-cat-life-design.md を優先し、
見た目・挙動・優先度・所有権を変えない範囲の cleanup のみ適用。4 観点（reuse / simplification / efficiency / altitude）の opus subagent が
独立に read-only review し、重複を除いて私が採否を決めて共有 worktree で単独編集した。commit なし。

## 採用して適用した指摘（A1–A14）

| # | 観点 | 指摘 | 適用した変更 | 根拠 |
|---|---|---|---|---|
| A1 | simplification / altitude / efficiency | 旧い周期まばたき（CatFaceView の `isAnimating` / `@State blink` / `blinkWhileAllowed` / `.task`）は全呼び出し元が `isAnimating: false` を渡すようになり死んでいる。新しい `Eye.blink` と `max(blink, eye.blink)` で 4 か所合成していた | `isAnimating`・`@State blink`・`blinksPeriodically`・`blinkWhileAllowed` を削除。`CatFaceCanvas` / `CatFaceRenderer` の `blink` と `CatFaceGeometry.eye(... blink:)` 引数を削除し `eye.blink` だけを使う。`animatableData` は `AnimatablePair<AnimationVector, CGFloat>`。呼び出し元 7 か所（ConversationView / OnboardingView / FaceSizePreview / Render.swift / FaceRenderingTests ×2 / #Preview）を機械的に更新 | `git grep isAnimating` で全呼び出し元が false。canvas blink は常に 0 なので `max(0, eye.blink) == eye.blink`。render 37 枚 + yawn 16 枚が変更前と同一 |
| A2 | simplification | ConversationView が CatFaceView と同じ preset fallback を二重に書き、`context.enabled &&` は `permitsLife` に含意 | `appearanceOverride: lifeContext.permitsLife ? lifeAppearance : nil`、`withAnimation(frame.duration > 0 ? … : nil)` | CatFaceView が `appearanceOverride ?? .preset(expression)` を持つ。runner は `permitsLife` 以外では duration 0 の frame しか出さない |
| A3 | simplification / altitude | MotionCoordinator の `startColumn(idlePitchLimit:)` は kind から導出でき、`requestDecorativeMotion(pitchLimit:)` は呼び出し元 1 つ・定数 2。`kind == .idle \|\| kind == .yawn` が 3 回、priority が 3 段ネスト三項 | 引数を削除し `let decorative = kind == .idle \|\| kind == .yawn`、`let pitchLimit = kind == .yawn ? 10 : 2`、priority は `switch kind`（Task の外で 1 回）。`requestDecorativeMotion` を `requestIdleFaceMotion` に inline | 5 つの startColumn 呼び出しすべてで `idlePitchLimit == (kind == .yawn ? 10 : 2)`。acknowledgement の fromPitch ±2 / cap 20 は不変 |
| A4 | simplification | yawn/idle の cancel 対（`.yawn → cancelIdleFaceMotion()`、`.idle → cancelAuto()`）が setConversationPhase / setIdleFaceDriven / service の 3 か所に貼られている | `private func cancelDecorativeMotion()`（switch autoKind）に集約 | 逐次 2 つの if は yawn cancel 後に autoKind が nil/.settling になるので switch と同値 |
| A5 | simplification / reuse | `CatFaceLifePlanner.yawn()` が両目への同じ代入を行ごとに書き、`release` は `.yawning` の yawn 0 と同値 | `CatFaceAppearance.updateEyes` を internal にして anticipation / shut で使用。`release = .yawning; release.yawn = 0` | yawning = sleepy + lid 1 + closed 1 + yawn 1。release = sleepy + lid 1 + closed 1 |
| A6 | simplification | planner の counter + threshold 対が 2 組（4 state） | `gestureIn` / `slowBlinkIn` の countdown 2 つ（`<= 0` で発火し再抽選） | 乱数の抽選はリセット時だけで順序不変。保留中の slow blink は負値で次の非 gesture 呼び出しに発火（従来と同じ） |
| A7 | reuse / simplification | 閉眼弧のフェード（0.9 → 1）が Renderer の `blinkArcStart` と Appearance.eye(_:) の生の 0.9 で二重定義 | `CatFaceGeometry.closedArcStart` / `closedArcVisibility(_:)` を 1 つ置き両方から呼ぶ | 同じ式 `min(1, max(0, (x - 0.9) / (1 - 0.9)))` |
| A8 | simplification | Runner: `suspend()` が context を丸ごと作り直す。`shouldYawn` が guard 前に `permitsLife` を含めて計算。neutral/sleepy 判定が 2 か所 | `enabled` を var にして `previous?.enabled = false`。`shouldYawn` を guard 後に。`FaceExpression.permitsIdleLife` を両方で使用 | 同値変形のみ |
| A9 | simplification | CatFaceShapes: `(u, v)` の lerp が `blinkingLids` の局所 `mix` と `closedLid` の inline で重複、`(u: CGFloat, v: CGFloat)` 型が 3 通りの書き方。`nose(yawn:)` の既定値未使用。`mouth()` の局所名が static の `yawnOutline` / `yawnTongue` を shadow。`yawnFangLeft.mirrored` を毎フレーム計算 | `LidPoint` typealias + static `mix`、`LidArc = [LidPoint]`。既定値削除。局所名を `placedOutline` / `placedTongue` / `placedFangs`。`yawnFangRight` static | 同じ式。render が同一 |
| A10 | reuse | `NormalizedPath.Command.mirrored` の 4-case switch が新規 `mapped` と同じ走査 | `var mirrored: Self { mapped(CatFaceSide.right.point) }` にして Command.mirrored を削除 | 点ごとの関数が同一。render が同一 |
| A11 | reuse | FaceRenderingTests の新テストが同じファイルの `rgbaPixels(of:)` と同じ RGBA デコードを 640×360 固定で再実装。CatFaceLifePresentationTests の `lowerMouthCoralPixels` が 3 つ目 | `rgbaPixels(of:)` を共有の `extension XCTestCase`（AccessibilityActivationSupport.swift）へ移し、両テストから使用。固定 640/360 を画像サイズに | 同じ色空間・bitmapInfo・配置 |
| A12 | reuse | CatFaceLifePresentationTests の `defer { window.isHidden = true }` が既存の片付け規約 `releaseWindow(_:)`（rootViewController も外す）を使っていない | `defer { releaseWindow(window) }` ×3 | 同ディレクトリの FaceConversationPresentationTests と同じ規約。superset |
| A13 | reuse | AnimationVector の補間（end − start → scale → start + delta）が CatFaceLifeTests と Render.swift で同じ 4 行 | `CatFaceAppearance.interpolated(toward:fraction:)` を「表情間の補間」extension に置き、両方から使用 | 同じ演算順。Shapes 末尾の「XCTest と harness の check が共有する」節と同じ前例 |
| A14 | reuse / efficiency | AppCoordinator の cue gate が `isConversationForeground && !isSleeping` を手書き（既存 `canRunConversation` と同一）。`allowsIdleFaceLife` が安価な phase 判定を最後に置き、先に String trim を実行 | `self.canRunConversation` を使用。phase 判定を guard の先頭へ | 同じ式・同じ結果 |

## 見送った指摘（S1–S12）と理由

| # | 観点 | 指摘 | 理由 |
|---|---|---|---|
| S1 | efficiency | `lifeAppearance` が `@State` なので keyframe ごとに ConversationView 全体の body が再評価される（毎分 40–60 回）。runner を `@Observable` にして顔の小さな wrapper view だけが読む構造へ | 構造変更で、presentation テストを root 側でしか走らせられない。影響は未計測で小。必要なら別タスクで |
| S2 | efficiency | `@State private var faceLife = CatFaceLifeRunner()` が ConversationView の init ごとに runner を生成して捨てる | 約 1 µs の小さな確保。optional 化は読みにくさの方が勝つ |
| S3 | efficiency | yawnBlend が 1 の間も `raised()` で描かれない口の path を作り直す。舌 clip の nested drawLayer | 前者は `drawingPoints` の点列（yawning の check）が変わる。後者は ±1 px の描画差の可能性。あくび中 1.2 秒だけの微小コスト |
| S4 | altitude | `idleFaceDriven` は本番で true しか設定されず、Coordinator 内蔵の 4–10 秒 idle scheduler は本番で到達不能。flag と scheduler を撤去し旧テスト 3 件を移植 | 顔 planner なしで動く既存契約（テスト 3 件）を変える。codex 指示「追尾優先仕様の再設計は不要」。必要なら別タスクで |
| S5 | altitude | AutoKind に profile（caps/speed/lane/ownership）を持たせ、`automaticOwnerKind` で `ownsYawn` の side channel を置き換える | 状態機械のリファクタで、MotionCoordinatorTests を私は実行できない。部分的に A3/A4 で対応 |
| S6 | altitude | idle life の許可条件が ViewState / ConversationView / AppCoordinator の 3 層に分散。AppRootView の overlay（held/looking/inactivity）を coordinator 側へ寄せる | AppRootView と coordinator の構造変更。cue 時の再判定自体は spec の「reject ineligible cues immediately」に沿う。A14 で canRunConversation のみ適用 |
| S7 | altitude | `blinkingLids` が `CatFaceAppearance.sleepy.leftEye.lid` を読み、`eye.lid > 0 && eye.lid < 1` は fade と重複 | root が 100 段 tween で検証済みの幾何。分岐条件を変えると lid 0/1 で取る経路が変わり画素リスクがある |
| S8 | reuse | `blinkingLids.splitEdge` は既存 `splitCubic` と同じ de Casteljau（t 0.5） | 数式は同一だが tuple ↔ CGPoint 変換のコードが置き換える 5 行と同程度の長さ |
| S9 | reuse | `yawnTongue` を `closedWithMirror()` で書く | 頂点列が変わり `drawingPoints` と IoU の再測定が必要。形状は固定の指示 |
| S10 | simplification | `play()` の onFrame 前後 2 重の cancel 検査 | onFrame の再入に対する防御。安価で、doc comment の generation 説明と一致 |
| S11 | simplification | `CatIdleNeckCue` を enum（`.glance(yaw:pitch:)` / `.yawn(pitch:)`）に | テストが使う API の変更。見た目の利点のみ |
| S12 | simplification | harness の `runYawn` / `runSleeping` の共通化、4 か所の `min(max(yawn, 0), 1)` の集約 | 1 行の clamp と dev 専用コード。価値が小さい |

## 変更ファイル（17、+176 / −239、commit なし）

- CatRobot/Conversation/UI/: CatFaceView.swift, CatFaceRenderer.swift, CatFaceShapes.swift, CatFaceAppearance.swift, CatFaceLife.swift, ConversationView.swift, ConversationViewState.swift, OnboardingView.swift
- CatRobot/App/ConversationAppCoordinator.swift
- CatRobot/Motion/MotionCoordinator.swift
- CatRobotTests/: Face/FaceRenderingTests.swift, Face/CatFaceLifePresentationTests.swift, Face/CatFaceLifeTests.swift, App/AccessibilityActivationSupport.swift
- scripts/face-render/Check.swift, scripts/face-render/Render.swift
- tools/face-size-tuner/Sources/FaceSizePreview.swift

## 検証（私の側で可能な範囲）

- `scripts/render_face.sh check`: build（Shapes / Appearance / Renderer / View + harness）と幾何検査 OK（9 preset × 4 pose、yawning 契約を含む）。
- `scripts/render_face.sh preview`: 37 枚を /private/tmp/cat-idle-life-20261030/baseline と画素比較 → 36/37 同一、curious-closed は既知の harness 丸め 410 px ±1（変更前と同じ）。
- `scripts/render_face.sh yawn`: 16 枚（yawning 峰・部分 yawn・neutral→yawning 補間・blink-neutral 50/80/90/100・比較/重ね/差分）を round-4 の scratch 出力と画素比較 → 16/16 同一。docs/design/idle-cat-life-2026-10-30/renders/round-4 の 5 枚とも同一。
- `xcrun swiftc -parse`: 編集した app / test / tools の 11 ファイルすべて構文 OK（型検査と XCTest 実行は root の xcodebuild に委ねる）。
- 未実施（root 担当）: full suite、MotionCoordinatorTests / CatFaceLifeTests / CatFaceLifePresentationTests / FaceRenderingTests、FaceSizeTuner build、実機。

## codex 独立 review（Critical/Important/Minor 0、merge 可）の照合（receiving-code-review）

- 同意: 読んだコードと一致する。face eligibility（`permitsLife` + cue 時の coordinator gate）と runner の generation token、yawn の「最初の write まで前 owner を保持」（`requestYawnMotion` が `cancelAuto()` のみで `clearAutomaticOwnership()` を呼ばず、`startColumn` が send 後に owner を書く）、実 yaw 保持（`fromYaw = currentYaw`、目標 yaw = 現在値）、最新 camera 状態の保持（`setTrackingState` が yawn の early return より前に `trackingState` を更新）、return-to-center の再 arm（`trackingReturnIssued = false`）はいずれも確認できた。私の変更はこれらの経路の式を変えていない。
- 補足（codex の scope 外、正しさではなく品質）: 上の A1（死んだ周期まばたき）と A3/A4（yawn の special case の散在）は codex review では扱われていないが、挙動には影響しない。
- 反証なし。codex の「物理 servo の滑らかさ・主観的好みはコードだけでは判定不可」にも同意。

## Codex による相互検証と最終レビュー

Codex は receiving-code-review で採用 A1–A14 を実コードと照合し、変更を受け入れた。独立サブエージェント idle_merge_review も初回の全feature差分（6aa4050..c8dd4aa）と、Claude が固定した17ファイルの簡素化差分をそれぞれ read-only でレビューした。双方とも Critical / Important / Minor は0件。A1 の全呼び出し元が false、A3 の acknowledgement の初期pitch±2°と送信上限±20°、A6 の乱数呼び出し順、キャンセル後の所有権、A11/A12 の描画検査とwindow解放を個別に確認した。S1–S12 は計測前の最適化または構造・幾何への影響があるため見送りを支持し、未解決の正しさの問題はない。

初回レビューで対象外とした物理サーボの反応は今回も未観察。主観的な好みは利用者の「いい感じ」を維持する前提とし、簡素化前c8dd4aaと最終版を別々にビルドして通常37枚・あくび16枚を比較したところ、53枚すべてPNGファイル単位で一致した。Claude側の古いbaseline比較にあったcuriousの差は、この直前コミットとの比較では発生していない。

mainへスカッシュした内容で全テスト、署名付きiPhone build、FaceSizeTuner build、プロジェクト生成契約が成功。詳しい結果は merge-results.json、検証対象253ファイルの識別子は merge-source-hashes.json に保存した。
