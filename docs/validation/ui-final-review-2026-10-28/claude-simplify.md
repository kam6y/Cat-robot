# Claude /simplify — UI 最終レビュー 固定差分（Phase 1、読み取りのみ）

- 対象: BASE `9ee8dacbe31e2bc3295eaa8f623049cc771bfb64` → HEAD `d3e2fb096179d64a62fc0a847bd723ad699a2af2`（21 commits）。範囲は `scope.json` の rangePaths。`scope.diff` を全体の範囲とし、`recent-changes.diff`（1d9e1d0 以降）を優先した。
- 行番号はすべて HEAD `d3e2fb0` のもの。worktree は clean、HEAD は `d3e2fb0` であることを確認した。
- 略記:
  - FCPT = `CatRobotTests/Face/FaceConversationPresentationTests.swift`
  - RPT = `CatRobotTests/RobotLink/RobotPresentationTests.swift`
  - AAS = `CatRobotTests/App/AccessibilityActivationSupport.swift`
  - Tuner = `tools/face-size-tuner/`
- 重要度:
  - Important（修正推奨）
  - Minor（直すと保守が楽）
  - Nit（任意）
  - Deferred（根拠不足のため保留）
- 検証の記号:
  - **[V]** Claude が HEAD で Read/grep して根拠を確認したもの
  - **[P]** 読んだ範囲では成り立つが、実行していないため推定を含むもの

## 実施内容（/simplify の起動と分担）

1. Skill `simplify` を起動した。引数は「READ-ONLY Phase 1、範囲 9ee8dac..d3e2fb0、報告のみ、子は read-only・opus」。
2. Phase 1: 4観点を1つのメッセージで並列に派遣した。
   - 観点は Reuse / Simplification / Efficiency / Altitude。
   - 4体とも Agent type は `Plan`（Edit・Write・NotebookEdit を持たない）、model は `opus`。
   - 各 brief では次の操作を明示的に禁止した:
     - `git checkout/stash/add/commit/reset/restore/switch`
     - `sed -i`、worktree へのリダイレクト
     - `xcodebuild`、`swift build`、`simctl`、device 操作
     - LocalAssets・鍵・実カメラ画像の読み取り
   - 各 brief に含めたもの:
     - requirements.md と specs/plans の参照先
     - HEAD の行番号で報告すること
     - 1d9e1d0 以降の優先対象
     - 再提起禁止リスト（下の N 節を参照）
     - `cleanup` と `correctness-incidental` の区別
3. 所要時間と件数（候補の数）:

   | 観点 | 所要 | 候補 |
   |---|---|---|
   | Efficiency | 約11分 | 4件 |
   | Reuse | 約11分 | 6件 |
   | Altitude | 約12分 | 5件 |
   | Simplification | 約14分 | 13件 |

   どれも承認待ちやツールの停止はなかった。
4. skill の Phase 2「apply the fixes」は、Codex の Phase 1 READ ONLY 指示に従って実施していない。代わりに次の作業をした:
   - 同じ行や同じ仕組みを指す候補を統合した。
   - Claude が HEAD で裏取りした。
   - 再提起禁止リストや、意図した挙動と矛盾する候補を除外した。
   - 本報告を作成した。
5. 製品ソース・テスト・プロジェクト・index・HEAD は一切変更していない。build・test・Simulator・device 操作もしていない。
6. 独立性: `codex-review.md` は本報告の保存まで開いていない。15:21Z の agmsg で Codex から受け取った c2e2c4b の動機（attachTuner を window から撮る形にした）は C3 の比較に反映した。これは差分の動機の説明であり、Codex の指摘を受け取ったものではない。

## 結論の要約

- **correctness の指摘: 0件。**
  - /simplify は bug hunt ではない。4観点のどれも、付随的な correctness の問題を観測しなかった。
  - 製品の hot path（顔のレイアウト、毎フレームの camera tracking、BLE snapshot、起動）に、新しい無駄はなかった。
- cleanup の指摘: 15件。Important 0、Minor 6（C1〜C6）、Nit 8（C7〜C14）、Deferred 1（C15）。
- 製品の挙動を変える提案はない。製品ソースに触れるのは C1、C9、C11、C12 だけで、どれも同じ値を同じ式で計算する等価な整理。
- 優先順: C1（tuner と本体の配置の式の複製）＞ C2・C3・C4・C5（試験の複製・字面依存）＞ C6（tuner の generator）＞ Nit。

---

## Minor

### C1 [Minor / reuse・altitude] [V] tuner が本体の顔の配置の式を複製していて、2つを結ぶものがない

- **場所:**
  - `tools/face-size-tuner/Sources/FaceSizePreview.swift:10-15`
  - `CatRobot/Conversation/UI/ConversationView.swift:69-75`（`faceLayout`）
- **根拠:**
  - 次の3式が両方にあり、違うのは `CGFloat(scale)` と `Self.faceScale` だけ:
    - `let insets = proxy.safeAreaInsets`
    - `.frame(width: (proxy.size.width + insets.leading + insets.trailing) * …, height: (proxy.size.height + insets.top + insets.bottom) * …)`
    - `.position(x: proxy.size.width / 2, y: (proxy.size.height + insets.bottom - insets.top) / 2)`
  - 描画の3ファイルは tuner の pbxproj から本体のパスを参照していて、共有されている（`../../CatRobot/Conversation/UI`、generator `:19-21`）。共有されていないのは配置だけ。
  - 「80% の絶対枠・safe area の水平中央・画面の垂直中央」という定義は、本体の `:67-68` の説明にしか書かれていない。
  - 複製になった経緯: tuner の実装時は「本体の223入力を変えない」という制約があった（`docs/validation/2026-10-27-face-size-tuner.md:23`）。この制約は 7ac5bea で本体の `ConversationView.swift` を変えた時点で終わっている。
- **単純化の効果:**
  - どちらかの式（insets、中心、枠の基準）を変えても、もう片方は古いままになり、どの試験も落ちない。共通化すれば、この食い違いは起きなくなる。
  - tuner の画素試験 `testPreviewScalesBothAxesAroundTheSameCenterForEveryExpression`（Tuner `Tests/FaceSizeTunerTests.swift:46-55`）は、`render()`（`:144-149`）の `ImageRenderer` で描く。window が無く safe area は 0 なので、複製した式の inset の項は tuner 側では試験されていない。
  - 共通化すれば、FCPT の inset 付きの検査（`assertFaceFillsEightyPercentBox`、`:716-728`、左右の island insets）が tuner の配置も守ることになる。
  - 検証記録 `:16` の「通常会話画面と同じ safe area・位置・倍率の計算を使う」は、今は目視でしか裏付けられていない。共通化すれば、構造として保証される。
- **最小修正案:** 次のどちらか。
  - **(a) 推奨。** `CatRobot/Conversation/UI/` に小さなファイルを1つ足す。例: `extension View { func screenScaledFaceFrame(_ scale: CGFloat) -> some View }`。中身は GeometryReader と上の3式。
    - `faceLayout` は `catArtwork.screenScaledFaceFrame(Self.faceScale)` に、`FaceSizePreview` は `CatFaceView(…).screenScaledFaceFrame(CGFloat(scale))` にする。
    - `faceLayout` の `.overlay` 3つは、今と同じく全画面の GeometryReader（helper が返す view）に付ける。チップとメニューの位置は変わらない。
    - 新しいファイル名を tuner の generator `:21` の明示リストに足す。本体の generator は `**/*.swift` を glob するので（`scripts/generate_project.rb:24`）自動で拾うが、両方の pbxproj の再生成は必要。
  - **(b) 変更を最小にしたい場合。** `FaceSizePreview` の冒頭に「`ConversationView.faceLayout` の式の写し。変えるときは同時に変える」とコメントを足す。前例は `scripts/face-render/Stubs.swift` の冒頭。
  - **置き場所として `CatFaceView.swift` は避ける:** 採用済みの顔デザインのファイルで、macOS の描画ハーネス（`scripts/render_face.sh:21-25`）の入力でもあるため。
- **挙動のリスク:**
  - (a) では式は変わらないが、本体の通常の顔の経路を触る。FCPT 15件、tuner 5件、`scripts/test_generate_project.rb` の再実行と、main-app-80 のソースハッシュの記録の更新が要る。
  - (b) にはリスクがない。
  - どちらも今日の表示は変わらない。今の2式は一致している。

### C2 [Minor / altitude・simplification] [V] RPT が校正の深さを、fixture の `calibrationDepth` と字面の 2・3 の両方で書いている

- **場所:**
  - RPT `:275`、`:331`、`:352`、`:371`、`:479`（字面の `2`）
  - RPT `:384`、`:409`（`toShow: 3`）
  - RPT `:400`、`:412`（`toShow: 2`）
- **根拠:**
  - fixture は文字の大きさで深さが変わるので `calibrationDepth` を計算している（`:106-107` の説明、`:147-155`。標準なら 2、大きい文字で開くなら 3）。
  - `expectExitConfirmation`（`:224`、`:241`）と大きい文字で開始する試験（`:425`、`:439`、`:454`、`:463`）は `calibrationDepth` を使っている。
  - 上の場所はどれも `openCalibrationInSettings()` を既定の `.large` で開いた試験。今日の値は同じ。
  - 2つの大きい文字の試験は、ほぼ同じ手順を2度書いている（Simplification の S1）:
    - `:383-405` と `:438-458`: 詳細を開く → Stop・hidesBackButton・backLabel なし → 保存 → 調整項目へ戻る → draft・session → 確認付きの終了
    - 一覧の確認 `:353-360` と `:427-434`
    - 片方は `3`/`2`、もう片方は `depth + 1`/`depth` と書き方も違う。
- **単純化の効果:**
  - 深さは「校正が設定シート全体に積まれた・戻らなかった」ことの代理指標になっている。入口の経路が変わると、字面の箇所だけが別の理由で落ちたり、違う階層を固定したりする。
  - helper にまとめると、大きい文字の条件（ラベル、深さ、添付名）を1か所で直せる。
- **最小修正案:**
  - 字面を `sheet.calibrationDepth` と `sheet.calibrationDepth + 1` に置き換える。
  - 任意で、`expectLargeTypeCalibrationList(_:name:file:line:)` と `expectLargeTypeDetailRoundTrip(_:category:changed:namePrefix:file:line:)` の2つの private helper にまとめる。`file:line` は `expectExitConfirmation`（`:215-216`）と同じ形で渡し、添付名は prefix で区別する。
  - 置換は全部やっても値が同じ。helper 化は任意。
- **挙動のリスク:** 製品には影響しない。置換は今日の値と同じ。helper 化では失敗行が helper 側になるので、`file:line` を必ず渡す。

### C3 [Minor / reuse] [V] tuner の `attachTuner` が AAS の `settleRendering` を複製している

- **場所:**
  - Tuner `Tests/FaceSizeTunerTests.swift:126-137`
  - AAS `:177-183`
- **根拠:**
  - generator `:29` が AAS を tuner の試験 target へ入れていて、tuner の試験は AAS の `enableAccessibilityRuntime`、`waitUntil`、`releaseWindow`、`accessibilityElement` をすでに使っている。
  - c2e2c4b は `settleRendering(view)` を、次の inline 実装に置き換えた。目的は window 全体を撮ること:

    ```swift
    let target = view.window ?? view
    target.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    UIGraphicsImageRenderer(bounds: target.bounds, format: format).image { _ in
        target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
    }
    ```
- **Codex の依頼による比較（倍率だけでなく、描画の対象と待ち）:**

  | 項目 | 今の `attachTuner` | `settleRendering(view.window ?? view)` |
  |---|---|---|
  | drawHierarchy の対象 | `view.window ?? view` | 同じ（引数で渡す） |
  | 描画前の layout | `target.layoutIfNeeded()` | `view.layoutIfNeeded()`（同じ対象） |
  | 倍率 | `format.scale = 1` | `format.scale = 1` |
  | renderer の bounds | `target.bounds` | `view.bounds`（同じ対象） |
  | `afterScreenUpdates` | `true` | `true` |
  | 描画の待ち | なし | なし |
  | 返り値 | `UIImage`（その場で使う） | `UIImage`（`@discardableResult`） |

  - 行う処理は1行ずつ一致する。c2e2c4b の「window 全体を撮る」という意図は、引数に `view.window ?? view` を渡せば保たれる。
  - AAS の注意書き（`:173-175`）は scene に属さない fixture の window についてのもので、ここには当てはまらない。tuner の window は `UIWindow(windowScene:)` で作られている（`:66-67`）。
  - 標準の文字サイズの全画面撮影で顔が欠ける件（検証記録 `:38`、原因は未確定）は、この置換で良くも悪くもならない。処理が同じだから。原因の調査には別の切り分けが要り、この cleanup の範囲外。
- **最小修正案:** `let attachment = XCTAttachment(image: settleRendering(view.window ?? view))`。name と lifetime の2行はそのまま。
- **挙動のリスク:** 製品にはなし。行う処理は同じ。
  - **訂正（Codex の receiving を受けて）:** 当初は「同じ画素になる」と書いたが、撤回する。静的に確かめたのは処理が同じことまで。撮影には既知の不安定さ（標準文字の全画面で顔が欠ける件）があり、画素の一致は静的には断言できない。再実行して代表的な添付画像を見て確かめる。

### C4 [Minor / altitude] [V] `ConversationInstructionsTests` の否定の検査が、UI の文言を写した字面に依存している

- **場所:** `CatRobotTests/Conversation/Services/Claude/ConversationInstructionsTests.swift:16-17`
- **根拠:**
  - 2つの検査:
    - `XCTAssertFalse(ConversationInstructions.fixedPrefix.contains("ハードと接続中"))`
    - `XCTAssertFalse(ConversationInstructions.fixedPrefix.contains("ハードと未接続"))`
  - 文言の定義元は `ConversationViewState.swift:31-35` の `RobotConnectionStatus.message`。connected、disconnected、reconnecting の3つ。
  - 首→ハードの変更（b3250e7）で、この2行も手で書き換えている。
- **単純化の効果:** 「含まない」という検査は、文言が変わってこの試験の更新を忘れると、常に通る試験になってしまう。定義元を参照すれば、文言が変わっても追随する。reconnecting の検査も加わる。
- **最小修正案:**

  ```swift
  for status in [RobotConnectionStatus.connected, .disconnected, .reconnecting] {
      XCTAssertFalse(ConversationInstructions.fixedPrefix.contains(status.message), "\(status)")
  }
  ```

  enum は CaseIterable ではないので、3つを列挙する。
- **挙動のリスク:** なし（試験のみ）。

### C5 [Minor / reuse] [V] RPT の `openCalibrationInSettings` が、校正の読み取りに答える手順を打ち直している

- **場所:**
  - RPT `:162-166`（f85f74e で追加）
  - 既存の `CatRobotTests/RobotLink/RobotSettingsModelTests.swift:251-257`（`private func finishOpening(_:saved:)`、ファイル内で7回出現）
- **根拠:**
  - どちらも同じ手順:
    1. `drain`
    2. `.calibration` に `Data([0, 0, 0, 0, 2, 1])` を返す（`saved` が最後の byte）
    3. `drain`
    4. `.limits` に `Data([0xB0, 4, 0xE8, 3, 0x58, 2, 0x2C, 1])` を返す
    5. `drain`
  - `RobotTestDoubles.swift:157-170` の `finishPreparation` の末尾にも、同じバイト列がある。
- **単純化の効果:** プロトコルの fixture のバイト列が変わったとき、直す場所が1つ減る。
- **最小修正案:**
  - `finishOpening` を `RobotLinkHarness`（`RobotTestDoubles.swift`）の `func answerCalibrationRead(saved: Bool = true) async` に移す。
  - RPT `:162-166` と RobotSettingsModelTests の呼び出し元から使う。
  - RPT `:38-42`、`:55-58` は途中に assert があるか末尾の drain が無いので、そのままにする。
  - `finishPreparation` から呼ぶかは任意。
- **挙動のリスク:** なし。event と drain の並びは同じ。
- 変更されるファイル（RobotTestDoubles.swift と RobotSettingsModelTests.swift）は差分の外にある。範囲を広げたくなければ、RPT と RobotSettingsModelTests の重複を許容して見送ってもよい。

### C6 [Minor / altitude] [V]＋[P] tuner の project generator が、本体の generator の project 単位の設定を写していない

- **場所:**
  - `scripts/generate_face_size_tuner_project.rb:13-15`
  - `scripts/generate_project.rb:52`、`:56-63`
- **根拠 [V]:**
  - 本体の generator は次を設定している:
    - `project.root_object.attributes["LastUpgradeCheck"] = "2660"`
    - project 単位の `ENABLE_USER_SCRIPT_SANDBOXING`、`IPHONEOS_DEPLOYMENT_TARGET`、`SWIFT_STRICT_CONCURRENCY`、`SWIFT_VERSION 6.0`
  - tuner の generator はどれも設定していない。その結果、tuner の pbxproj は次のようになっている:
    - `LastUpgradeCheck = 1600;`（`:194`）
    - project 単位の `SWIFT_VERSION = 5.0;`（`:388`、`:472`）
  - target 単位では 6.0 で上書きされている（`:295`、`:325`、`:417`、`:498`）。実際の build 設定は変わらない。
- **[P]:** Xcode 27 が tuner の project で「推奨設定へ更新」を出す可能性がある。未確認。確かめるには、Xcode 27 で開いて Issue navigator を見るか、再生成後の project 単位の設定を本体と diff する。
- **単純化の効果:** 2つの generator の規約が揃い、tuner を開いたときの不要な更新提案（仮説）と、project 単位の Swift 5.0 という紛らわしい値が無くなる。
- **最小修正案:**
  - tuner の generator `:13` の後に2文を足す: `LastUpgradeCheck = "2660"` と、project の build configurations への同じ4設定の merge。
  - Altitude の観点からは、共通の ruby module（`xcodeproj_support.rb`）へ切り出す案も出た。これは提案しない。本体の generator には契約試験（`scripts/test_generate_project.rb`）があり、本体の pbxproj が byte 単位で同一になるかの確認が要る。一度きりのツールのためには、費用が利益を上回る（Reuse の観点も同じ判断）。
- **挙動のリスク:** tuner の pbxproj の再生成だけで済む。本体には影響しない。tuner の試験5件を再実行する。

---

## Nit

### C7 [Nit / altitude] [V] tuner の試験が AAS を共有していることが、どこにも書かれていない

- **場所:**
  - generator `:29`
  - AAS `:1-9`（冒頭）
  - Tuner `README.md:23-24`
- **根拠:**
  - AAS は `import Accessibility/UIKit/XCTest` だけで、CatRobot に依存しない。だから tuner でもビルドできる。
  - しかし冒頭の説明には「CatRobot の型を参照しない」という条件が書かれていない。
  - README は共有している描画の3ファイルと Stubs を挙げるが、AAS は挙げていない。
  - 本体の通常の検証では tuner をビルドしないので、本体の試験のために AAS に `@testable import CatRobot` や本体の型への参照を足すと、誰かが tuner をビルドするまで壊れていることに気づかない。
- **最小修正案:** AAS の冒頭と tuner の README に、1行ずつ注記を足す。
- **挙動のリスク:** なし。

### C8 [Nit / efficiency・reuse] [V] RPT の `attach` が画面倍率で描いていて、f85f74e で追加した約21か所すべてに及ぶ

- **場所:**
  - RPT `:532-538`（helper 自体は基点のコード 6988cd1f）
  - 新しい呼び出し元: `:225`、`:269`、`:278`、`:292`、`:332`、`:361`、`:372`、`:397`、`:435`、`:451`、`:467`、`:499`
- **根拠:**
  - `UIGraphicsImageRenderer(bounds: view.bounds)` は format を指定していないので、画面の倍率になる（iPhone や Simulator では約3x）。
  - 同じファイルの多くの呼び出しは、直前の `waitUntil(settling:)` で同じ view を scale 1 で描き終えている（例: `:322`→`:332`）。
  - 前回の T2 で、FCPT は `settleRendering` の画像を使う形にしてある。
- **単純化・効率の効果:**
  - 1回の実行で約21枚の全画面描画が 3x から 1x になり、PNG の encode も小さくなる。画素数はおよそ 1/9。
  - 実行時間への影響は測っていない（分析上の推定）。
- **最小修正案:** `attach` の中身を `XCTAttachment(image: settleRendering(view))` にする。描画の対象は今と同じ `view`（host の view またはダイアログの view）。window にはしない。待ちは足さない。
- **挙動のリスク:**
  - 製品には影響しない。
  - 証拠の画像が 1x になる。校正の画面は小さい日本語の文字を目視する証拠なので、読みにくくなるという実際のコストがある。
  - `settleRendering` は描く前に `layoutIfNeeded()` を1回多く呼ぶ。`afterScreenUpdates: true` があるので実質は同じ（[P]）。
  - 目視の証拠として 3x が要るなら、見送るのが妥当。

### C9 [Nit / reuse] [V] `CameraTrackingSettingsPane` の識別子に、列挙と文字列リテラルが混在している

- **場所:**
  - `CatRobot/App/CameraTrackingSettingsPane.swift:36`、`:38`、`:80`（文字列リテラル `"faceTrackingEnabled"`、`"faceTrackingStatus"`、`"faceTrackingYawCorrectionStepper"`）
  - 同じファイルの `:22`、`:25` は `ConversationSettingsIdentifier.cameraPermissionButton.rawValue` を使っている
- **根拠:**
  - `ConversationSettingsView.swift:4` の列挙の説明には「View は文字列リテラルではなくこの列挙から取る」とある。
  - 3つのリテラルは、基点の `RobotConnectionView` と `RobotCalibrationView` から移したもの。
  - 製品にも試験にも、これら3つを参照する箇所は無い（grep）。
- **最小修正案:**
  - 3つの case を `ConversationSettingsIdentifier` に足し、`.rawValue` を使う。
  - `ConversationAccessibilityTests.swift:167` が `allCases` の並びを固定しているので、そこに3つを追記する必要がある。
- **挙動のリスク:** なし。raw value は同じ。固定の試験の更新を忘れると、その試験が落ちる。

### C10 [Nit / simplification・altitude] [V] tuner の定数が、キー・丸め・ラベルで書き直されている

- **場所:**
  - Tuner `Sources/FaceSizeTuningModel.swift:15`、`:21`（`"faceScale"`）、`:40`（`(bounded * 200).rounded() / 200`）
  - `Sources/FaceSizeTunerView.swift:62`（`"85%に戻す"`）、`:91`、`:104`（`"0.5%小さくする"`、`"0.5%大きくする"`）
- **根拠:**
  - `baselineScale = 0.85`（`:6`）、`step = 0.005`（`:8`）がすでにある。
  - 同じ範囲の前例: `OnboardingSettings.completedKey`、`TrackingAimRows.defaultAimText`（`CameraTrackingSettingsPane.swift:70`、`:81`、定数から「8.5°に戻す」を作っている）。
- **単純化の効果:** step や基準値を変えたとき（例: 新しい 80% と比べたくなったとき）、丸めとラベルが黙ってずれることがなくなる。tuner の試験は識別子で操作するので、ラベルのずれは検出されない。
- **最小修正案:**
  - `private static let scaleKey = "faceScale"` を足す。
  - 丸めは `let perUnit = (1 / step).rounded(); (bounded * perUnit).rounded() / perUnit` にする。今の /200 と同じ浮動小数点の値になる。`/ step * step` にすると誤差が入る。
  - ラベルは定数から `%g` で作り、文言は今と完全に同じにする。
- **挙動のリスク:** ラベルの文言が1文字でも変わってはいけない。試験側の 0.85 などのリテラルは、固定の値として残す。

### C11 [Nit / simplification] [V] 校正の `sections(for:)` で、`.disabled(!session.canEdit)` が3回、同じ footer が2回ある

- **場所:**
  - `CatRobot/RobotLink/RobotCalibrationView.swift:213`、`:219`、`:228`（`.disabled`）
  - `:218`、`:227`（footer「左右はロボットと向かい合って見た方向です。」）
- **最小修正案:** `switch` を `Group { … }.disabled(!session.canEdit)` で包み、footer は `private static let facingNote` にする。
- **挙動のリスク:**
  - なし（[P]）。`Group` は子の Section それぞれに `.disabled` を渡す。`@ViewBuilder` の中の switch の型も変わらない。
  - `saveSection` は `sections(for:)` の外にあり、独自の disabled 条件を保つ。

### C12 [Nit / simplification] [V] `ConversationMemoryPresentation(state: memoryState).blocksConversation` が state の中に3回ある

- **場所:**
  - `CatRobot/Conversation/UI/ConversationViewState.swift:81`、`:89`（聞き取りチップのために今回の範囲で追加）、`:152`
  - `ConversationView.swift:199`
- **最小修正案:**
  - `ConversationViewState` に `var blocksConversation: Bool { ConversationMemoryPresentation(state: memoryState).blocksConversation }` を足し、4か所で使う。
  - `ConversationView:44/220/223` の他の `ConversationMemoryPresentation` 呼び出しは範囲外（範囲より前からある）なので触らない。
- **挙動のリスク:** なし。純粋な射影で値が同じ。入力欄の構造や修飾子の構造も変わらない。

### C13 [Nit / altitude] [V] 80% という値が、試験の helper 名と説明の文言に焼き込まれている

- **場所:**
  - FCPT `:716`（`assertFaceFillsEightyPercentBox`、呼び出し元 `:22`、`:135`、`:141`、`:149`）
  - FCPT `:720`（`* 0.80` が2回）、`:727`（"80% box"）
  - `ConversationView.swift:7`、`:67`（説明の「80%」）
- **根拠:**
  - 7ac5bea の 85→80 の変更では、1つの値のために製品3行と試験8行を触っている（helper の改名を含む）。
  - tuner はこの値をまた変えるために存在する。
- **最小修正案:**
  - helper 名から数字を外す（例: `assertFaceFillsNormalBox`）。
  - 期待値は FCPT の `private static let expectedFaceScale: CGFloat = 0.80` 1か所にまとめる。
  - 製品定数から独立させるという意図（検証記録 `:50`）を守り、`ConversationView.faceScale` は読まない。
  - 説明の文言は「`faceScale` の枠（現在 80%）」程度にする。
- **挙動のリスク:** なし。値を変えるときの変更が、製品1行と試験1行になる。

### C14 [Nit / efficiency] [V] FCPT の聞き取りチップの試験が、既存の `normal` / `normal-flipped` と同じ描画を繰り返している

- **場所:**
  - FCPT `:12-28`（`testListeningChipSitsAtTopLeadingAndClearsWhenSpeaking`、b3250e7 で追加）
  - FCPT `:131-142`（`normal` / `normal-flipped`）
- **根拠:**
  - どちらも `.listening` を左右の island insets、852×393、`.large` で描く。
  - `normal` の `caption = "前の返事"` は描かれず、VoiceOver の custom content だけに渡る。そのため layout は同じ（[P]: 描画結果の一致は実行して確かめていない）。
  - `listening-chip-cleared`（`:25-27`）は、`speaking-long`（`:146`）にも入れられる。チップの条件は phase、memory、sleep だけで決まる（`ConversationViewState.swift:89`）。
- **効果:** 1回の実行で、window の作成・settle・PNG の encode・アクセシビリティの木の待ちが3回減る。
- **最小修正案:**
  - チップの位置の検査（`:15-21`）を `normal` と `normal-flipped` の closure に移す。
  - `speaking-long` に `XCTAssertNil(… "statusChip.listening")` を足す。
  - `:12-28` を削除する。
- **挙動のリスク:**
  - 製品には影響しない。
  - 要件名の付いた独立の試験（「聞き取りチップは左上」）が無くなり、失敗したときの特定が少し弱くなる。この試験は要件の可読性のために置かれた可能性が高い。見送りも妥当。

---

## Deferred

### C15 [Deferred / efficiency] [V]＋[P] tuner の `setScale` に「値が変わらないときは何もしない」という guard がない

- **場所:** Tuner `Sources/FaceSizeTuningModel.swift:19-22`
- **根拠 [V]:** 正規化した値が今と同じでも、毎回 `@Published` に代入し、`UserDefaults` に書く。「85%に戻す」を 85% で押したときは、確実に1回無駄になる。
- **[P]:** step 付きの `Slider` が drag 中に同じ値を何度も set するかは確かめていない。そうであれば、指の動きのたびに書き込みと view の無効化が起きる。
- **保留の理由:** 開発用のツールで、確実に起きるのは無害な1回だけ。頻繁に起きる経路は未確認。
- **提案（採るなら）:** `let value = Self.normalized(value); guard value != scale else { return }`。既存の tuner の試験は、どれも値が変わる遷移なので影響しない。

---

## N: 検討したが提案しないもの（再提起禁止リストに当たるもの、効果が乏しいもの、根拠不足のもの）

- **N1（Simplification S2、Reuse R6）:** 試験で `"calibrationCategory.*"` と `"statusChip.listening"` をリテラルで書いている箇所。
  - RED 試験は機能が無い状態でもコンパイルできるよう、文字列の識別子で書くという取り決めがある。
  - RPT `:9` のリテラルは表示順も固定している（`:309-310`）。`allCases` にすると、並べ替えに黙って追随してしまう。
- **N2（S7）:** 校正の `detail: RobotCalibrationCategory?` を `isPresented` にする案。
  - 状態の数は減らず、push の仕組みが `item:` から `isPresented:` に変わる。
  - polish の段階で、ダイアログと選択が戻らない件の不安定さを抱えていた経路なので、利益に対して危険が大きい。
- **N3（S11）:** 校正 fixture の後片付けを `addTeardownBlock` にまとめる案。後片付けの時期が変わる。polish で途中の throw に対応するために入れた構造なので、触らない。
- **N4（S12）:** FCPT の `firstScrollView` と `allScrollViews(...).first` の重複。前回 T1 の任意部分として残したもの。
- **N5（S13）:** tuner の `CATROBOT_SOURCE_REVISION` / `CatRobotSourceRevision`。実機への配布では、ビルド成果物の revision を照合する運用がある（`docs/validation/2026-10-24-face-tracking.md:25` など）。不要とは言えない。
- **N6（Efficiency F4）:** RPT の `capture()` で、fit する view の `-bottom` が page-0 と同じ画像になりうる件。helper は基点のコードで、`contentSize` を実行で確かめていない。
- **N7（S5）:** `ConversationViewStateTests.swift:31-36` の phase のループ。memory が `.ready` という別の条件で、`.failed` も含む。完全な重複ではなく、効果も小さい。
- **N8（Reuse R5）:** tuner の `visibleBounds` と、`FaceRenderingTests` の `rgbaPixels` / `> 24` の閾値の共通化。移す先がアクセシビリティ用の support file で、差分の外のファイルにも触れる。
- **N9:** scene に属する window の hosting が3か所にある（FCPT `hostInScene`、RPT `:128-139`、tuner `:64-72`）。settle の待ち（200ms と 300ms）と frame が違い、統合すると T4/T5 の待ちに触れる。
- **N10:** `.toolbar(.visible, for: .navigationBar)` の3つ目のコピー（`RobotCalibrationView.swift:62`）。C6 系の判断に従う。
- **N11（記録のみ）:**
  - `microphoneStatus` には製品からの読み手が無く、試験だけが読む。spec で格納値を残すと決めているので、提案しない。
  - 次の2点は範囲より前からある効率の観察:
    - `RobotCalibrationView` の body は BLE snapshot のたびに再評価される。`canEdit` が `currentSnapshot` を読むため（`RobotCalibrationSession.swift` は変更なし）。
    - `ConversationSettingsView` の `.task` は、`memory.load()` と `usage.summary()` を順に待つ。
- **N12:** tuner の generator と本体の generator を共通の ruby module にする案（C6 の項を参照）。
- **再提起禁止リストのとおり除外したもの:**
  - polish で決めたこと:
    - 行の寸法の複製と、220pt の項目列
    - チップの領域を確保しない
    - ナビゲーションバーを残す
    - 大きい文字の詳細ではシステムの戻るを隠す
    - ハード
  - 前回の cross-review の判断:
    - C6（独自の header）
    - T3（fixture の共有）
    - T4/T5（待ちの短縮）
    - T6（private AX harness）
    - スクロールの修飾子を inline のまま残す
  - 意図した挙動:
    - tuner の 85% の基準
    - 80% の絶対枠
    - 中心の基準
    - 50〜100% を 0.5% 刻み
    - tuner は本体へ書き込まない
    - yaw の補正はカメラの設定に置く
    - 字幕を描かない

## 制限

- build・test・Simulator・device は実行していない。すべての主張は HEAD の静的な読み取りに基づく。性能の効果は分析上の推定で、測定していない。
- 過去の試験結果（839/837/2、FCPT 15/15、tuner 5/5）や iPhone へのインストールは、今回あらためて実行した証拠ではない。
- pbxproj は、tuner の参照の確認と project 単位の設定の確認に必要な範囲だけを読んだ。本体の pbxproj の差分の大半は `predictabilize_uuids` による UUID の入れ替わりと判断したが（Altitude）、全行は精査していない。
- 画像の証拠（xcresult の添付、docs の画像）は開いていない。tuner の標準文字サイズの全画面撮影で顔が欠ける件の原因は、未確定のまま扱った（C3）。
- 実機の VoiceOver の読み上げ、物理キーボード、BLE、カメラは確認していない。
- 子レビュアーの候補は、Claude が [V] の範囲で裏取りした。[P] の箇所には、確かめ方を書いた。
