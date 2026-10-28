# coordinator / VM / inactivity 差分の read-only レビュー（round 1、2026-10-26 11:00Z 時点の worktree）

対象: ConversationAppCoordinator.swift / ConversationViewModel.swift の差分、Inactivity/ の新規 2 ファイル、Inactivity テスト 3 ファイル、
ViewState / Accessibility / AppRootView の差分。コード編集なし。

## 依頼された 4 観点の結論
1. onPhaseChange からの睡眠遷移の再入: 安全と判断。enterSleeping は transition(.idle/.listening/.paused) からしか起きない（busy phase は evaluate が .awake で早期 return）。
   - .listening: startCapture の transition 直後に同期で invalidateForSceneInactivity が走り generation が古くなる。captureTask はその後に作られるが
     transition〜captureTask 代入の間に await がないので、遅延した sceneBecameInactive → pauseConversation が必ず captureTask を cancel し recognizer.stop する。
     receiveRecognition は isCurrent で捨てる。resumeCapture 側は wantsListening=false で止まる。
   - .paused: pauseConversation 内の transition から再入しても、2 回目の pauseConversation は lifecycleTransitionTask に合流して return。
   - enterSleeping の invalidateActionTasksForSceneInactivity は「いま transition を起こした action 自身」も cancel するが、launchAction の末尾は
     completeConversationStartIfEligible の !Task.isCancelled で抜けるだけなので無害。
2. startCapture の復帰 / paused shutdown 競合: VM 側は lifecycleTransitionTask と generation で直列化されており問題なし。ただし coordinator 側の pauseTask の持ち方に穴がある（下記 I-1）。
3. action 取消と wake 競合: wake は launchAction(allowWhileSleeping:) 経由なので scene 変化や設定オープンで正しく捨てられる。二重タップは最初の 1 回だけ wake する（guard isSleeping と inactivity.wake() の間に await がない）。
   ただし wake 後の startConversation 中（.preparing）に来た次のタップは通常経路で pause になる（下記 M-1）。
4. settingsModel.applicationMode = .inactive: 整合している。openVoiceSettings で nil に戻し、close で再適用するので校正も可能。
   副作用が 1 つ: MotionCoordinator の idle 電源断は .conversation/.settings でしか許可されないので、sleeping 中は torque が切れない（下記 I-2）。

## Important
- I-1 pauseTask の所有権（enterSleeping と forwardPauseIfNeeded が同じ field を使い、完了時に無条件で nil にする）
  再現: scene inactive → すぐ active（コントロールセンター等）で forwardPause の pauseTask #1 が recognizer.stop 待ちのまま、active 復帰の updateInactivity で
  期限超過 → enterSleeping が pauseTask #2 を作って上書き。#1 が先に終わり pauseTask=nil。ここでタップ → wakeFromSleeping の await pauseTask?.value が
  nil で素通り → inactivity.wake() → startConversation が走り .preparing。その後に #2 の pauseConversation が本体経路で走ると新しい preflight を
  cancel して .paused に戻す。結果: state は awake なのに paused（タップが効かなかったように見え、次の前面復帰で勝手に聞き取りが始まる）。
  対処案: startTaskID と同じ ID 方式（pauseTaskID）で「自分が最後の pause のときだけ nil」にし、wakeFromSleeping は最新の pauseTask を待つ。
  enterSleeping で既に pauseTask が走っているなら新しい Task を作らず、その完了を待つ形でもよい。
  追加テスト案: inactive→active を pause 途中（recognizerStopGate）で行い、期限超過で sleeping、タップ → gate open → 最終状態が listening かつ startCount が 1 増えること。
- I-2 sleeping 中の首の電源: activeControlMode が .inactive なので MotionCoordinator.servicePowerOff の permitted（.conversation/.settings のみ）が偽になり、
  idle 動作と顔追尾を両方 off にしている利用者では、待機中ずっと torque が入ったまま（既定の idleEnabled=true では元から電源断しないので影響なし）。
  仕様の「首の自動動作を停止」は満たすが、長時間の待機で servo が通電し続ける。選択肢: (a) .inactive でも電源断を許可（scene inactive の短時間にも効く）、
  (b) 仕様として「待機中は現状維持」と明記、(c) 専用 mode。利用者判断を推奨。

## Medium
- M-1 wake 直後の連打: inactivity.wake() 後は isSleeping=false なので、startConversation の .preparing 中に来た 2 回目のタップは toggleListening → pause。
  眠っている猫は連打されやすい。wake action の進行中フラグでタップを無視するか、wake 後 .preparing のタップを no-op にする案。
- M-2 enterSleeping は viewState.showsTypedInput を閉じない。文字入力パネルを開いたまま眠ると、送信不可のパネルが待機画面に残る。enterSleeping で viewModel.hideTypedInput()。
- M-3 retryMemory（保存の再試行）が launchAction の sleeping ガードで無反応になる。forget 失敗からの復旧以外は聞き取りを始めないので allowWhileSleeping でよい
  （復旧経路の resumeListeningIfNeeded はガード済み）。

## Low / 確認済み事項
- L-1 evaluate の境界が `clock.now >= deadline` で、他所の `>= limit − 1e-6` と流儀が違う。ContinuousClock 起点でも Task.sleep は不足側に出ないはずだが、
  万一早く起きても evaluate が再アームするので自己修復する。統一するなら epsilon を足す。
- L-2 .failed は evaluate で .awake・timer なし → エラー画面では眠らない（設計どおりなら spec に一言）。notAddressed/ambiguous の分類中は sleepy→awake→sleepy と表情が往復する（許容範囲）。
- L-3 タップで pause するときも recordActivity を呼ぶ（spec の「明示タップ」に一致）。
- L-4 ViewState.faceExpression の sleepy は isLooking/held より先に評価されるが、対象 phase が idle/listening/paused なので実害なし。
- L-5 ConversationIdlePresentationTests は FaceExpression.sleeping（claude_sleep 担当）が入るまで実行時に失敗する（rawValue 比較なのでコンパイルは通る）。
- L-6 AppRootView の onChange(phase) 撤去と VM callback 一本化を確認。initial の updateFaceEnvironment は beginConversation → updateRobotScene で担保されている。
- L-7 ConversationIdleClock（ContinuousClock 起点）は worktree にまだ見当たらない（Inactivity/ には Settings と Inactivity のみ）。配置後に再確認する。

## 追記（I-1 の再追跡、codex の問いへの回答）
現在のコードで「wake が後続の pause に潰される」スケジュールは組めなかった。I-1 は Low（所有権の衛生とテストの待ち精度）に格下げする。
追跡したスケジュール: listening で t0+599 に inactive → forwardPause の Task A が pauseConversation 本体経路で cleanup（recognizer.stop 待ち）に入る
→ t0+601 に active → updateInactivity が sleeping → enterSleeping が Task B を作り pauseTask を上書き → scenePhaseDidChange の続きは guard で何もしない
→ B は次の yield で必ず走り、pauseConversation は lifecycleTransitionTask（A の cleanup）に合流する。A の cleanup が先に終わっていた場合は
phase == .paused の早期 return で no-op。どちらでも B が「後から本体経路で pause する」ことはない。
→ タップ C は launchAction 経由で pauseTask（B）を待つ。B と A は同じ cleanup の完了で同時に再開し、残る仕事は pauseTask = nil だけ。
A が先に nil にして C が B を待たずに進んでも、B に残る処理はないので startConversation は潰されない。
よって所有権の穴は「waitForOperations / await pauseTask が最後の pause を正確に待てない」ことに限られ、挙動上の失敗にはならない。
pauseTaskID 方式の補強と、codex が予定する回帰テスト（inactive→active / pause 待ち / 期限超過 / tap の順）で十分。

## round 2（hasPendingSpeech 実装の最終レビュー、11:15Z 時点）
- 確認: provisional-only の停滞で pending が無限になる解析は正しい。receiveRecognition → scheduleSegmentationFlush(1.2 秒) → flushSegmentation の nil 分岐 →
  synchronizeCaptureTimingWithSegmenter は hasActivity=true で早期 return し再アームも通知もしない。以後 ASR が止まると segmenter.hasActivity が立ったまま。
  codex 案（flushDelay: finalizedSegments が空なら hardRemaining、確定があれば min(silence, hardRemaining)）で解消する:
  20 秒到達の flush → utteranceIfReady が reset → nil → synchronize（hasActivity=false）→ onPhaseChange（pending=false）→ evaluate。
  後続 provisional は firstActivity 基準の hardRemaining で再アーム、final 到着で 1.2 秒。UI の provisional 表示は従来どおり残る。
  注意: UtteranceSegmenterTests / ConversationViewModelTests に provisional-only の flushDelay=1.2 を固定した試験がないか確認。テストは flushSegmentation(at:) を直接呼ぶ形で 20 秒の実スリープを避ける（既存の新テストと同じ）。
- 再入（pending false 通知）: 通知箇所はすべてメソッド末尾。receiveRecognition の空 final 分岐は presentUnrecognized 直後に return、synchronize は終端、
  transition は状態更新後。false 通知で同期的に enterSleeping → invalidateForSceneInactivity が走っても、呼び出し側に無効化後の処理は残らない。
  flushSegmentation の nil 分岐は segmentation task 自身の中で synchronize（自身を cancel）するが終了直前なので無害。
- 前面復帰時の古い segmenter.hasActivity: 無害。pauseConversation は segmenter を reset しないが、evaluate の保留は phase == .listening のときだけ効き、
  .paused / .preparing では評価されない。復帰後は startCapture が segmenter = UtteranceSegmenter() にしてから transition(.listening) するので、
  listening に入った時点で pending=false の通知が出る。
- finishClosingCapture は通知しないが（captureIsClosing=false にする）、直後の performTurn の transition が通知するので抜けはない。
- 軽微: pending 中の evaluate は timer を張らないので、5 分境界が発話中に来ると sleepy 表示は次の通知（final/flush/phase）まで遅れる。発話後は
  addressed なら reset、notAddressed なら listening 復帰で再評価されるため実害なし。
- 重要な問題は上記の provisional-only 以外に見当たらない。

## 判定（11:20Z、codex の依頼による明記）
| 指摘 | 判定 |
|---|---|
| I-1 pauseTask の所有権 | 再追跡で失敗スケジュールを再現できず、codex の回帰（inactive→active / pause 待ち / 期限超過 / tap）PASS。変更不要。 |
| I-2 sleeping 中の servo 通電 | 仕様「首の自動動作を停止」は満たす。既存の保持挙動を維持（新しい電源断は入れない）。 |
| M-1 wake 直後の連打 | 通常のタップ一時停止の挙動を維持（.preparing 中のタップは従来どおり pause）。変更なし。 |
| M-2 文字入力パネル | sleeping 中は UI 側で非表示（ConversationView: showsTypedInput && !isSleeping、Menu の文字入力/新しい会話も disabled）。下書きは保持し起床後に復元。 |
| M-3 保存の再試行 | 回帰 RED（unsaved → ready にならない）を確認後、retryMemory を allowWhileSleeping に修正。 |
| round 2 provisional-only の無限保留 | UtteranceSegmenter.flushDelay を「確定なしなら hardRemaining」に修正（単体 RED 1.2 != 20/15 → 修正、Mac 12 件 PASS）。worktree の差分で確認済み。 |

最終結論: 新しい待機仕様（最後の呼びかけから 5 分で sleepy、10 分で sleeping、タップのみで起床、両時間を設定可能）とその coordinator / VM / inactivity 実装に、
claude が確認した範囲で重要な未解消問題はない。残るのは全体試験の結果待ちと、claude_sleep 担当の FaceExpression.sleeping 到着後の表示確認のみ。
