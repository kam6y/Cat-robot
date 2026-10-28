# claude 最終照合（read-only）— review-fixes.diff の R1 / R2 / R4 と C1 / C2 / C4 / C6 / C7

- 日付: 2026-10-26。対象: /private/tmp/cat-idle-review-20261026/review-fixes.diff（固定 scope からの修正だけ、14 ファイル、1094 行）。作業先 /Users/goodapple/.codex/worktrees/b200/Cat_robot（HEAD f6eeedad、未コミット）。
- 照合: diff 全文を読み、現行ワークツリーの該当箇所を再読。final-source.json の hash と現行ファイルの SHA-256 は diff 内の 13 ソースファイルすべて一致（README.md は final-source.json に無いので比較対象外）。C9 の 2 ファイルも私が報告した hash（Measure b4f8282e…、Render 1af6fb55…）のまま。
- 実行していないもの: XCTest / xcodebuild / 実機。テストの GREEN は Codex の r1/r2/r4-green.log の報告に依る。全体 suite は照合時点で実行中（full.log にまだ Test Case 行なし）。
- 編集していない。

## 判定: 採否合意からの逸脱なし、読解上の回帰なし

| ID | 判定 | 照合内容 |
|---|---|---|
| R1 | 合意どおり | 監視条件を `isConversationForeground` だけにし、`beginConversation` で `inactivity.recordActivity()`。`hasStartedConversation` はカメラ/追尾の環境（updateFaceEnvironment）と `completeConversationStartIfEligible` に残る。マイク拒否は `publish(.failed)` → `onPhaseChange` → `updateInactivity` → `setMonitoring(true)` で武装され、R2 により failed が計時対象なので「拒否直後・未入力」も寝る。`startNewConversation` は `recordActivity` → `hasStartedConversation = false` → `updateInactivity` の順で監視が途切れない。回帰 2 本（文字専用 299/300/600 + 下書き保持 + 起床後の再送信、未入力で 300/600）は私が reception で求めた 2 ケースを覆う。音声経路の計時起点が preflight 完了時から明示開始時に数百 ms 早まるのは仕様「明示タップ/開始から」の読みどおりで、ManualRobotClock のテスト期待値には影響しない。 |
| R2 | 合意どおり | `evaluate` は busy phase（preparing / classifying / thinking / speaking / clarifying）を網羅列挙し `.failed` を `.paused` と同じ扱い（網羅 switch なので phase 追加時はコンパイルで止まる）。表示は `faceExpression` の既存規則（sleepy は idle/listening/paused）を維持し、テストが failed + sleepy = `.sorry` を固定。休眠入りは既存の pause 経路で `transition(.paused)` が errorMessage / recoveries を消す（VM:1568-1569 相当）。cleanup 中の同期再入は `audioDeactivateGate` の回帰で「cleanup 完了までは awake、完了後に 1 回だけ sleeping、startCount 1→2 で起床 1 回」を固定。 |
| R4 | 合意どおり | `enterSleeping` の先頭で `viewModel.clearCaptionForStandby()`（caption のみ。typedText / showsTypedInput は不変）。`sceneBecameInactive` には入れていないので背景遷移の字幕保持は従来どおり。`displayedCaption` の sleeping 分岐は表示契約として維持（codex-reception の判断どおり）。回帰は寝入り時 caption ""、起床後も ""、下書きと入力欄の表示を確認。 |
| C1 | 合意どおり | `pauseConversationForScene()` に 4 手順（start intent クリア、startTask cancel、invalidateForSceneInactivity、pauseTask 生成）を抽出。`forwardPauseIfNeeded` は guard と 2 つの旗を保持。`enterSleeping` は clearCaption → invalidateActionTasks → pause → updateRobotScene。`updateRobotScene` が Task 生成の後に来るが、Task は同期区間の終了まで走らないので順序の意味は同じ。 |
| C2 | 合意どおり | `onPendingSpeechChange` を新設し receiveRecognition 末尾 / synchronizeCaptureTimingWithSegmenter / presentUnrecognizedSpeechWhileListening の 3 か所を切替、coordinator は `updateInactivity()` だけに配線。`onPhaseChange` は transition / publish の 2 か所のみ。receiveRecognition の else 分岐は synchronize 後に return し二重通知を解消（この分岐は `segmenter.hasActivity == false` のときだけ入るので synchronize 内の guard を通り、通知は必ず 1 回出る）。VM 側の反転検出や didSet は入れていない。`.ignore` 経路の回帰（provisional 599 秒 → 完了発話 600 秒 → classifier / reply 呼び出しなしで sleeping）を追加。 |
| C4 | 合意どおり | `sleepyRange` / `sleepingRange` の static を setter・init・Stepper で共有。既定 5/10 は init の各 1 か所。`ConversationSettingsView.idleSettings` は必須引数になり、呼び出しは AppRootView（既に渡している。ファイル hash 不変）とカメラ fixture（専用 suite を渡し teardown で削除）の 2 か所だけ。正規化ペア関数は採らないとの判断どおり非対称の setter を維持。 |
| C5 | 合意どおり | `settingsDidChange()` を削除し、単体テスト 3 か所は `setMonitoring(true, phase: .paused)`（製品の close → setMonitoring と同じ経路）。製品・テストに残存呼び出しなし。 |
| C6 | 合意どおり | `displaysTypedInput` / `displayedProvisionalTranscript` / `microphoneSymbol` を ViewState へ移し View はそれだけを読む。`standbyStatus` を ViewState と Accessibility で共有。`ConversationListeningSemantic.wake`（「猫を起こす」「タップして会話を再開します」）で private 旗と三項を削除。`allowsTypedSubmission` の `!isSleeping` は判断どおり維持。影響テスト: ConversationIdlePresentationTests:35 は listeningAction "猫を起こす" を断言しており `.wake` で成立。ConversationAccessibilityTests:119 の `.resume` 断言は inactivity 既定（awake）の idle/paused/failed に対するもので影響なし。 |
| C7 | 合意どおり | `isConversationForeground`（前面・設定閉）と `canRunConversation`（+ !isSleeping）を監視条件・wake lock・顔可視・開始完了 guard・resume guard に適用。`launchStart` の最終 guard、`launchAction(allowWhileSleeping:)`、showTypedInput の guard は維持（helper 化しないとの判断どおり）。`onStateChange` は sleeping 進入だけに縮小。起床時の顔環境更新は、従来 `wake()` 内で同期に走っていたものが `startConversation` 最初の `transition(.preparing)` → onPhaseChange → updateFaceEnvironment と launchAction 末尾の updateFaceEnvironment に移る。その間に可視性へ依存する処理はない（カメラは phase.permitsFaceTracking で止まり、preflight 中に保持表情はない）ので観測差なし。Codex の GREEN（追尾 starts 2、effectiveControlMode .conversation）と整合。モード遷移順（E3）は変更しないとの判断どおり `updateRobotScene(.active)` の式は従来のまま。 |
| C8 | 合意どおり | `evaluate` で `now` を 1 回だけ読む。generation は維持。 |
| C10 | 合意どおり | 新規 inactivity テストの UserDefaults suite を teardown で `removePersistentDomain`。条件付き断言を無条件に。 |
| README | R3 の文書訂正 | 「認識途中の声は最大 20 秒の区切りまで待つ」を「未確定の認識は発話開始から最大 20 秒で区切る。音声認識の終了処理は既存の完了待ちを使い、別のタイムアウトは設けていない」に訂正。双方の R3 訂正と一致。 |

## 追加変更の要否
- 必要な追加変更は見つからなかった。
- 留意（変更不要）: `recordActivity()` を `beginConversation` で呼ぶ時点では `monitoring == false` なので `evaluate` は lastActivity を置くだけで、武装は直後の `completeConversationStartIfEligible` または最初の phase 通知で行われる。意図どおりだが、将来 `beginConversation` 直後に `updateInactivity()` を入れても二重武装にはならない（setMonitoring は等値でも evaluate するだけ）。

## 前回記録の修正
- claude-reception.md と claude-simplify-fixes.md の未確定な時刻表記（12:2x / 12:16Z / 12:35–12:45）を日付 2026-10-26 だけに改めた。
