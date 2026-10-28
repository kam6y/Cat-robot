# Claude /simplify — UI整理 固定差分

- 対象: `9ee8dacbe31e2bc3295eaa8f623049cc771bfb64` → `90e98c2f011c027eeb88f2d6f29d080411515cb7`（`review.diff` の Swift 部分。製品 Swift の差分は `git diff 9ee8dac 90e98c2 -- 'CatRobot/*.swift'` と一致することを確認）
- 実施: `/simplify` を使い、reuse・simplification・efficiency・altitude の4観点を並列（読み取りのみ、モデル opus）で実施。各指摘は Claude が `git show 90e98c2:<path>` で行番号と根拠を再確認し、重複を統合した。
- `/simplify` の Phase 2（修正の適用）は依頼どおり実施していない。製品ソース・テスト・プロジェクトは一切編集していない。ビルド・テスト・Simulator・端末操作もしていない。
- 行番号はすべて固定 HEAD `90e98c2` のもの（作業ツリーの FCPT・RobotPresentationTests は Codex の追加試験で行がずれている）。
- 略記: FCPT = `CatRobotTests/Face/FaceConversationPresentationTests.swift`、RPT = `CatRobotTests/RobotLink/RobotPresentationTests.swift`、AAS = `CatRobotTests/App/AccessibilityActivationSupport.swift`
- 重要度: Important（修正推奨）／Minor（直すと保守が楽）／Nit（任意）

## 製品コード

### C1 [Important / altitude] 会話画面の3レイアウトが入力欄を2か所で作り、`prioritizesContent` の切り替えで入力欄が作り直される（Codex R1 と同根）

- 場所: `CatRobot/Conversation/UI/ConversationView.swift:55-62`（`layout(usesGlass:)`）、`:96`（`typedLayout` 内の `typedInput`）、`:142`（`contentFirstLayout` 内の `typedInput`）、切り替え条件 `:38-41`
- 根拠: `layout` は `contentFirstLayout` / `typedLayout` / `faceLayout` の3つを `if` で出し分け、`typedInput(usesGlass:)` は `typedLayout` と `contentFirstLayout` にそれぞれある。文字入力中に `prioritizesContent` が変わる（エラーカード、記憶カード、Dynamic Type のアクセシビリティサイズ境界）と、別の分岐に移るため `TypedInputView` の構造上の同一性が変わる。基点の `verticalBody` は if/else の後に `typedInput` を1か所だけ置いていたので、この回帰は今回の差分で入った。`typedLayout` の doc comment（`:84-85`）と spec「入力欄を切り替え候補に重複して作らず、カーソルを維持する」に反する。
- 影響: 下書き（`typedText` は状態にある）と `.task { isFocused = true }` によるフォーカスは戻るが、カーソル・選択範囲が失われ、キーボードが揺れる。Codex の `r1-red.log`（`testTypedEditorKeepsItsSelectionAcrossErrorAndMemoryCards`、12 assert 失敗）と同じ現象。
- 独立性についての注記: これは独立した発見ではない。Codex の R1 の概要（11:40:21Z の agmsg）は4観点の起動前に受け取っていて、altitude 観点への指示にも「3レイアウトによる view の同一性の入れ替わり」を確認対象として明示した。そのうえで、コード上の経路（2か所の `typedInput`、基点の1か所の構造、doc comment と spec の約束）を検証して確かめたもの。C1 と R1 は同一の指摘として扱い、修正の所有者は1つにする（二重に数えない）。
- R1 の試験の範囲外になりうる引き金: 文字入力中に Dynamic Type がアクセシビリティサイズの境界をまたぐ場合も、同じ分岐の切り替えが起きる。**→ 撤回。** `TypedInputView.swift:73-78` が基点から同じ境界で TextField を作り直しているので、R1 の範囲外。`claude-reception.md` の R1 の 3 を参照。
- 最小修正案: 外側を1つの構造に固定し、上側だけを切り替える。

  ```swift
  VStack(spacing: …) {
      upperRegion(usesGlass:)          // face / fit-or-scroll / cards をここだけで切り替える
      if state.displaysTypedInput { typedInput(usesGlass: usesGlass) }   // 同じ位置で1回だけ作る
  }
  ```

  水平16ptの余白は `faceLayout` には無いので、余白は上側の分岐の内側で付ける。入力欄を含む外側の構造に、分岐ごとに違う修飾子（水平16の有無、vertical 8／bottom 8 の違い）を if/else で付けると同一性がまた変わるので、外側では値で切り替える（例: `.padding(.horizontal, usesInset ? 16 : 0)`）。Codex が 11:42Z に示した案（入力とカードの経路を1つの VStack に統合し、上側だけ `prioritizesContent` で切り替える）と同じ方向で、賛成する。

### C2 [Minor / simplification・altitude] 右上メニューとチップの位置関係が、重複した修飾子と別表記の数値で結ばれている

- 場所: `ConversationView.swift:76` と `:100`（`.overlay(alignment: .topTrailing) { menuButton.padding(.trailing, 12).padding(.top, 4) }` が同一）、`:93-94` と `:139-140`（`.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)` が同一）、`:108` の `.padding(.trailing, 44 + 4)` と `:154` の `.padding(.trailing, 12 + 44 + 8)`
- 根拠: `:108` と `:154` はどちらも「メニューの右余白12＋ボタン44＋間隔8＝64pt」のクリアランスだが、`:108` は typed レイアウトの水平余白16を手で引いた値になっている。メニューの44pt（`:169`）と右余白12（`:76`、`:100`）を変えると3か所の計算をやり直す必要がある。`contentFirstLayout`（`:128-132`）は `HStack { chips; Spacer; menuButton }` でこの依存を持たない。
- 最小修正案: `private var topTrailingMenu: some View { menuButton.padding(.trailing, 12).padding(.top, 4) }` と `static let chipMenuClearance: CGFloat = 12 + 44 + 8` を1か所に置き、typed では `chipMenuClearance - 16` と書く（またはメニュー寸法を `menuSize` / `menuTrailing` / `chipGap` に分ける）。スクロール修飾子は小さな `ViewModifier` か `extension View` にまとめる。C1 の修正で外側の構造を1つにすれば、メニューの重ね方も1か所に集約できるので、C1 と同時に直すのが自然。3レイアウトの配置自体は spec で決めたものなので変えない。

### C3 [Minor / simplification] 字幕・状態表示の削除後、どこからも使われない表示用の派生値が4つ残っている

- 場所: `CatRobot/Conversation/UI/ConversationViewState.swift:109`（`displayedCaption`）、`:110`（`displayedProvisionalTranscript`）、`:112`（`displayedMicrophoneStatus`）、`:113-120`（`microphoneSymbol`）
- 根拠: HEAD の `git grep` で、`displayedProvisionalTranscript` / `displayedMicrophoneStatus` / `microphoneSymbol` は定義以外の参照が0件。`displayedCaption` はテストだけが読む（`CatRobotTests/Vision/LookCoordinatorTests.swift:156,163`、`CatRobotTests/Conversation/Inactivity/ConversationIdlePresentationTests.swift:12`）。基点では削除された `statusHeader` / `transcriptContent` が唯一の利用者だった。特に `displayedCaption` の `isLooking ? "見ています"` は、spec で `.looking` チップへ移した旧字幕の規則で、`LookCoordinatorTests:156` は製品が出さなくなった表示を固定している。
- 最小修正案: 4つを削除する。`LookCoordinatorTests:156` は `statusChips` に `.looking` が含まれることの確認に、`:163` は `caption`（または `accessibleReply`）の確認に、`ConversationIdlePresentationTests:12` は `statusChips == [.sleeping]` か `accessibleReply == nil` の確認に置き換える。格納値の `caption` / `provisionalTranscript` / `microphoneStatus` / `activityStatus` は spec（「値は保存と VoiceOver のために残す」）どおり残す。`displayedActivityStatus` は `ConversationAccessibility.swift:94`（`ConversationAnnouncementPolicy`）が使っているので残す。
- 範囲の注記: 修正は `changed-files.txt` に無いファイル（`LookCoordinatorTests.swift`、`ConversationIdlePresentationTests.swift`）に及ぶ。

### C4 [Minor / simplification] `ConversationAccessibility.assistantStatus` を製品が読まなくなった

- 場所: `CatRobot/Conversation/UI/ConversationAccessibility.swift:34`（宣言）、代入 `:43`、`:56-80`（9か所）
- 根拠: 唯一の製品側の読み手は基点の `ConversationView` の `.accessibilityValue(accessibility.assistantStatus)` で、今回の差分で削除された。HEAD の参照は定義とテスト `CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift:44` だけ。spec の VoiceOver 節は、マイクの状態を顔ボタンの `microphoneValue` で伝えるとしていて、`assistantStatus` は使わない。活動状態の通知は `ConversationAnnouncementPolicy` 側にあり、この値に依存しない。
- 最小修正案: プロパティと10か所の代入を削除し、2つ目の switch は `microphoneValue` だけを決める形にする。`ConversationAccessibilityTests:44` を削除する。
- 範囲の注記: `ConversationAccessibility.swift` は `changed-files.txt` に無い（読み手を消したのは今回の差分だが、残骸は範囲外のファイルにある）。`ConversationAccessibilityTests.swift` は変更ファイルに含まれる。

### C5 [Nit / reuse] 再接続チップの文言が既存の状態文言と重複している

- 場所: `ConversationViewState.swift:46`（`case .robotReconnecting: "首を再接続中"`）
- 根拠: 同じファイルの `RobotConnectionStatus.reconnecting.message`（`:34`）と同じ文字列で、こちらは VoiceOver の通知（`ConversationAccessibility.swift:122`）が今も使う。隣の `.sleeping` は `ConversationViewState.standbyStatus` を再利用している。
- 最小修正案: `case .robotReconnecting: RobotConnectionStatus.reconnecting.message`。ただし両者は表示範囲が違う（`RobotConnectionStatus.reconnecting` は connecting/preparing も含む）ので、文言を別々に変える可能性があるなら現状のままでもよい。

### C6 [Nit / altitude、要相談] 設定のシステムのナビゲーションバーを隠して自前で描くため、進んだ先ごとに表示を戻す必要がある

- 場所: `CatRobot/App/ConversationSettingsView.swift:94`（`.toolbar(.hidden, for: .navigationBar)`）、`:99`（カテゴリ詳細で `.toolbar(.visible, …)`）、`CatRobot/RobotLink/RobotConnectionView.swift:71`（校正で `.toolbar(.visible, …)`）
- 根拠: 現在の遷移先は2つ（`:95` と `RobotConnectionView.swift:68`）で、どちらも戻している。今は正しいが、今後の遷移先で戻し忘れると戻るボタンが消える。特に校正はスワイプで閉じられず「完了」も無効なので、影響が大きい。
- 案: システムのバーを残し、左に見出し「設定」（`.isHeader`）、`.confirmationAction` に「完了」を置く（基点の配置）。ただし横向き393ptでの高さとガラスのボタンの見た目を理由に自前のヘッダーにした可能性がある。Claude は寸法を確認していないので、修正は必須にしない。採るなら確認画像で高さを比べてから。

## テストコード

### T1 [Minor / reuse・simplification] スクロールビュー探索の補助がファイル間で複製され、「最も右のスクロール＝詳細列」の式が3か所にある

- 場所: `allScrollViews(in:)` が FCPT:602 と RPT:155 に同じ内容の private 関数として重複。最も右のスクロールを選ぶ `.max { $0.convert($0.bounds, to: v).minX < $1.convert(…).minX }` が FCPT:598（`detailScrollView`）、FCPT:517-519（`scrollThroughDetail` 内で `detailScrollView` を呼ばずに再記述）、RPT:88 にある。
- 最小修正案: `allScrollViews(in:)` と `detailScrollView(in:)` を AAS（共有の `@MainActor extension XCTestCase`）へ移し、FCPT:517 は `try XCTUnwrap(detailScrollView(in: view), "\(name) has no scrollable detail")`、RPT:88 は `detailScrollView(in: host.view)` にする。差分より前からある `firstScrollView`（FCPT:680）と `scrollView(in:)`（RPT:159）は `allScrollViews(in:).first` に置き換えてもよい（任意）。

### T2 [Nit / reuse] 倍率1の描画の手順が `settleRendering` と同じ形で複製されている

- 場所: FCPT:557-561（`settingsColumnEdges`）、FCPT:688-691（`capture`）、元の実装は AAS:167-172（`settleRendering`）
- 最小修正案: `@discardableResult func settleRendering(_ view: UIView) -> UIImage` にして画像を返し、`settingsColumnEdges` は `settleRendering(view).cgImage`、`capture` は `let image = settleRendering(view)` を使う。あわせて、`settingsColumnEdges`（FCPT:526 で呼ぶ）は直前の `capture`（FCPT:521）と同じ画像をもう一度描いているので、撮った画像を渡せば1回減る。

### T3 [Nit / reuse] 校正の試験が設定の fixture を手で組み直している

- 場所: RPT:66-74（`ConversationSettingsView` を suite の UserDefaults・各設定・記憶・利用量 spy から組み立てる）。FCPT:467 の `SettingsFixture` と `view(_:)`（FCPT:501）が同じものを作る。
- 最小修正案: `SettingsFixture` を共有のテストファイルへ移し、`camera` / `face` を省略できるようにして RPT から使う。`SettingsFixture` 自身の suite（FCPT:480）は `RobotLinkHarness.defaults` で代用できる可能性がある（任意）。RPT の scene の無いウィンドウはシートを出さないので、そのままにする。

### T4 [Minor / efficiency] `scrollingIn:` を渡しても、スクロールを始める前に timeout（2秒）を使い切る

- 場所: AAS:56（`waitUntil(timeout: timeout, …)`）、`scroll()` は AAS:60 で初めて評価される
- 根拠: 画面外の部品は最初の待ちでは見つからないので、毎回約2秒と、50msごとの全画面 `drawHierarchy`（AAS:155、:167-172）約40回を消費してからスクロールに入る。RPT:88-89 の校正ボタン（コメントで右列の下にあると明記）が該当する。FCPT:57、:65 の右列の下の部品も、最初に画面外なら同じ。
- 最小修正案: `scroll` があるときは最初の待ちを短くする（例: 300ms。列の切り替えが済む程度）か、settle 後に1回だけ探してからスクロールに入る。全 timeout はスクロールしない経路だけに使う。

### T5 [Minor / efficiency] fixture の配置ごとに200msの固定 sleep がある

- 場所: FCPT:429（`hostInWindow`）、FCPT:457（`hostInScene`）
- 根拠: 基点の `render` は同期だった。`renderConversation`（約29か所、表情のループを含めて約38回）と `hostInScene`（約11回）、直接の `hostInWindow` を合わせて約50回で、1回の実行あたり約10秒の固定待ちになる。
- 最小修正案: `hostInWindow` は `_ = try await waitUntil(settling: host.view) { measurement.insets != nil }` にする（直後の `XCTUnwrap(measurement.insets)`、FCPT:431 と同じ条件）。`hostInScene` も settle しながら safe area かレイアウトの条件を待つ形にする。固定の待ちが別の不安定さを隠している可能性があるので、置き換えた後に数回続けて実行して確かめる（実行は Codex 担当）。

### T6 [Nit / altitude、記録のみ] 試験の補助が非公開のアクセシビリティ記号に依存し、使えないときに黙って続く

- 場所: AAS:18-24（`dlopen("/usr/lib/libAccessibility.dylib")` と `_AXSApplicationAccessibilitySetEnabled` / `_AXSSetAutomationEnabled` の `dlsym`）。KVC で `accessibilityCustomContent` を読む（AAS:136）、`collectionView(_:didSelectItemAt:)` を直接呼ぶ（AAS:106）も同じ系統。
- 根拠: iOS の更新で記号が消えると `"unavailable"` を返すだけで、後の「not reachable」で分かりにくく失敗する。
- 最小修正案（任意）: `enableAccessibilityRuntime()` が `"unavailable"` のとき、呼び出し側で `XCTFail`（または `XCTSkip`）して原因を明示する。UI テストのターゲットへ移す根本的な案は差分の範囲を大きく超えるので、今回は採らない。

## 見送ったもの

- `provisionalTranscript` は話している間ずっと書き込まれ（`ConversationViewModel.swift:798`）、`AppRootView` / `ConversationView` の body を再評価させるが、今は誰も表示しない。書き込みは基点からある動作で、spec は値を残すとしている。描画（Canvas）は再実行されないので見送る。C3 で `displayedProvisionalTranscript` を消せば、読み手が無いことは明確になる。
- `ConversationView` の `state.statusChips`（計算プロパティ）を1回の描画で数回読む: 小さな配列で、コストは無視できる。
- `isAwaitingTapToResume` を5か所で設定・解除している（`ConversationViewModel.swift:165, 302, 330, 1333, 1626`）: spec が列挙した「true／false にする出来事」と1対1に対応している。`transition(to: .paused)` に集約すると、spec が求める「文字での会話を挟んでも保持する」を満たせないので、altitude の指摘にはしない。
- `RobotReconnectIndicator` を `AppRootView` の `@State` に置き、`bufferingNewest(1)` の stream（`RobotLink.swift:85`）から更新している: spec はチップ専用の判定を snapshot から作ると決めている。`.connected` が間引かれる理論上の可能性はあるが、`.connected` は通常ある程度続く状態なので、構造変更は提案しない（正しさの問題は Codex の review 側の範囲）。
- `needsInitialConversationStart` という名前は、実際には「最初に active になるまで `recordActivity()` を遅らせる」だけなので名前が大げさ。動作は正しく、名前だけの話なので見送る。
- `CameraTrackingSettingsPane` の `openSystemSettingsButton`: 基点では ConversationSettingsView と RobotConnectionView に重複していたものを1つに統合しており、重複は減っている。
- `OnboardingSettingsTests` の準備の繰り返し、`ConversationActions` の no-op の組み立て: 共有できる既存の補助が無く、小さい。
