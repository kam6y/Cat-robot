# claude による Codex 指摘 R1–R4 の受入評価（receiving-code-review）

- 日時: 2026-10-26。対象: /Users/goodapple/.codex/worktrees/b200/Cat_robot（feature/look、base=HEAD f6eeedad、未コミット差分）。
- 方法: codex-review.md を全文読み、各指摘を現行コードで追跡して裏取りした（行番号は現行作業ツリー）。コードは編集していない。XCTest・xcodebuild は実行していない（実行は Codex 担当）。
- 判定の凡例: 採用 = 指摘・重要度・対策とも妥当 / 修正採用 = 指摘は妥当だが対策または重要度を変える / 見送り = 根拠不足または設計と矛盾。

## R1 マイク拒否後の文字専用会話で監視が始まらない — 採用（Important のまま）

裏取り
- 監視条件は `hasStartedConversation && destination == .conversation && scenePhase == .active && isVoiceSettingsClosed`（ConversationAppCoordinator.swift:90-92）。`hasStartedConversation = true` は `completeConversationStartIfEligible` の中だけで、`viewModel.viewState.phase.permitsFaceTracking` が guard に入っている（:144-146）。
- `permitsFaceTracking` は `.preparing / .paused / .failed` で false（FaceTrackingTypes.swift:59-64）。
- マイク拒否は `publish(.microphoneDenied)` で `.failed`（ConversationViewModel.swift:488-492）→ guard 不成立。文字送信は `microphoneWasAllowed == false` なので音声再開せず `transition(to: .paused)` で終わる（:656-658）→ `launchAction` 末尾の `completeConversationStartIfEligible`（:423）でも guard 不成立。`onAddressedActivity` → `recordActivity` は `lastActivity` を更新するが `monitoring == false` なので `evaluate` は何もしない（ConversationInactivity.swift:76）。
- 既存テスト `testMicrophoneDeniedTypedTurnUsesOnlyTypedPreflightAndRetainsCaption` が `.paused` 終端を保証している（ConversationRecoveryTests.swift:292-328）ので、文字専用経路は正式サポート。
- 結論: 指摘どおり。文字専用の会話では sleepy / sleeping が一切起きない。

対策の評価
- Codex 案「監視対象の会話があること」と「音声開始が完了しカメラ追尾が許されること」を分ける、に同意。`hasStartedConversation` はカメラ/追尾の環境（:138）とマイク許可プロンプトの順序に結びついているので、その意味を変えず、別の旗（例: `hasConversationSession`）を `completeConversationStartIfEligible` のシーン guard の後・`permitsFaceTracking` guard の前で立て、`updateInactivity` の条件だけをその旗に替えるのが最小。`startNewConversation` は旗を保ったままでよい（既に `recordActivity()` で明示操作として扱っている :355）。
- 仕様「最後に受け付けた呼びかけ・文字送信・明示タップ/開始から計る」とも整合（開始が完了した時点で計時が始まる）。
- 回帰: `ConversationHarness(microphoneAllowed: false)` + coordinator、`beginConversation` → `showTypedInput` / `submitTypedText` → 299/300/600 秒で awake/sleepy/sleeping、`typedText` の下書き保持、`recognizer.startCount == 0` のまま、タップで起床して再び文字専用に戻ること。R2 とは独立（終端が `.paused`）。

## R2 終端の failed で待機タイマーが永久停止 — 採用（Important のまま。実装時の注意 2 点）

裏取り
- `evaluate` は `.idle / .listening / .paused` 以外を一律 `default` で `setState(.awake); return`（ConversationInactivity.swift:77-82）。`.failed` もここに落ち、タイマーを張らない。
- 失敗は `performVoiceFailureCleanup` の末尾で `publish` → `onPhaseChange(.failed)`（ConversationViewModel.swift:1308-1316, 1623-1629）。終端なので以後 phase の通知は利用者操作まで来ない。既存 `testSpeechFailureIsVisibleAndDoesNotResumeCapture` が failed のまま留まることを保証している。
- 副作用も指摘どおり: sleepy 中に呼びかけでない認識失敗が起きると `.awake` に戻る（`lastActivity` は変わらないのに表示だけ戻る）。
- 結論: 指摘どおり。仕様の「処理中は終わるまで待つ」は reply/classification/preflight/clarification を指し、failed は処理中ではない。

対策の評価
- 「忙しい phase を明示列挙し、終端エラーは cleanup 後に待機へ進める」に同意。`evaluate` で `.failed` を `.paused` と同じ扱いにするだけで、休眠入りは既存の `enterSleeping` → `sceneBecameInactive` → `pauseConversation` が担う。`pauseConversation` は `.failed` から通常経路で `transition(to: .paused)` に入り、`transition` が `errorMessage / recoveries` を消す（:1568-1569）ので、寝顔の下に死んだ回復ボタンが残ることはない。起床は `startConversation` が `.paused` から preflight をやり直す。
- 注意 1（再入）: 期限超過後に失敗が公開されると `publish` → `onPhaseChange` → `evaluate` → `setState(.sleeping)` → `enterSleeping` が **cleanup Task の実行中に同期で** 走る。`enterSleeping` の同期部分は `invalidateForSceneInactivity` と `startTask?.cancel()` で、実際の一時停止は新しい `pauseTask` に逃がしているので deadlock はしないが、`performVoiceFailureCleanup` の `failureCleanupTask = nil` より前に `invalidateForSceneInactivity` が走る順序になる。回帰として「sleepy 中（例: 700 秒）に speech failure を公開 → sleeping へ 1 回だけ入る・`startCount` が増えない」を入れること。
- 注意 2（表示）: `.failed` + sleepy は `faceExpression` の規則上 sleepy ではなく `.sorry` のまま（ViewState は sleepy を idle/listening/paused に限定）。仕様どおりなので変更不要だが、テストの期待値に書いておく。
- 「エラー情報を別の表示関心として保持」は今回は不要（寝たら消え、起床で再試行するのが既存の一時停止と同じ振る舞い）。

## R3 captureIsClosing を含む ASR 保留に 20 秒上限が効かない — 修正採用（指摘は正しい。対策の置き場所と優先度を変える）

裏取り
- `hasPendingSpeech = segmenter.hasActivity || captureIsClosing`（ConversationViewModel.swift:120）。`beginClosingCapture` は `captureIsClosing = true` にして `segmentationTask` を取り消し、`closingTask` で `recognizer.stop()` → consumer → `finishClosingCapture` を待つ（:857-887）。`captureIsClosing` が戻るのは `finishClosingCapture`（:911）か失敗 cleanup（:1309）か `pauseConversation`（:1405）だけ。
- `AppleSpeechRecognizer.stop()` は `analyzer.finalizeAndFinishThroughEndOfInput()`・`analysisTask`・`resultTask` を期限なしで待つ（AppleSpeechRecognizer.swift:688-707）。
- `evaluate` は `.listening && hasPendingSpeech` で sleepy/awake を置いて return し、見張りのタイマーを張らない（ConversationInactivity.swift:85-89）。
- 結論: 「20 秒で解放」は UtteranceSegmenter の provisional-only 経路にしか当てはまらず、finalization の遅延は無期限に待機を延ばす。指摘どおり。

対策の評価（ここが Codex 案と異なる）
- 単に旗を消す対応が不可なのは同意。さらに、`ConversationInactivity` に見張りを足して sleeping へ進めても目的を達しない: `enterSleeping` → `pauseConversation` は `oldClosing?.value`（= 止まっている `stop()`）を待つ（:1395-1430）ので、状態だけ sleeping で VM は listening のまま、マイク/カメラ/首の停止も起きない。背景遷移・設定・次ターンも同じ待ちに掛かる。つまり **finalization の無期限待ちは本機能以前から pause 経路全体の露出** で、本差分はその上に「20 秒で解放」という過大な約束を仕様に書いた、というのが正確な姿。
- 正しい置き場所は recognizer 側: `AppleSpeechRecognizer.stop()` の graceful finalization に期限を設け、超過したら既存の即時取消（`performImmediateCancellation` → `analyzer.cancelAndFinishNow()`、:714-731）へ切り替える。所有権は recognizer actor に閉じ、VM/coordinator は現状の `stop()` 完了待ちのままでよい。遅延結果は `runPhase.acceptsEvents` と `captureID` 照合で既に捨てられる。
- 範囲: これは本差分外（Services）の変更で、全 stop 経路に効く。回帰は `ConversationHarness(recognizerStopGate:)` で closing 中に gate を閉じたまま上限を超えさせ、取消経路に入ること・遅延結果が捨てられること・その後 sleeping と タップ起床が成立することを確認する（Fake recognizer に上限をどう模すかは実装時に決める）。
- 優先度: 引き金は Speech framework の停止で、起きれば本機能と無関係に会話が止まる既存問題。従って **本機能の merge を止める条件にはせず**、(a) 仕様・検証文書の「20 秒上限」を「provisional-only の区切りにのみ適用、finalization には及ばない」に正す、(b) recognizer 側の期限付き停止を別変更として起票、の 2 段を提案する。この優先度判断は利用者に委ねる。

## R4 寝ている間だけ隠した古い字幕が起床後に再表示 — 採用（Minor のまま）

裏取り
- `displayedCaption` は sleeping 中だけ "" を返す（ConversationViewState.swift:51）。`viewState.caption = ""` は `forgetConversation`（:404）と `startNewConversation`（:425）だけで、`startConversation`・`transition(to:)`（caption は渡された時だけ更新 :1570）・`resetTurnPresentation` は消さない。起床は `startConversation` なので古い返事が戻る。
- 結論: 指摘どおり、仕様「sleeping は古い字幕を消す」に反する。

対策の評価
- `enterSleeping` 時に VM の専用メソッドで `caption` だけを消す（`sceneBecameInactive` に入れない: 背景遷移で字幕を保つ既存挙動を変えないため）。`typedText / showsTypedInput` は保持。
- これを入れると `displayedCaption` の sleeping 分岐は二重の仕組みになるので、同時に外して一本化してよい（任意）。
- 回帰: 返事完了 → 600 秒 → sleeping → タップ → `caption == ""`、`typedText` 保持。

## まとめ

| ID | 判定 | 重要度 | 要点 |
|---|---|---|---|
| R1 | 採用 | Important | 監視の武装を `permitsFaceTracking` から切り離す別旗。文字専用 + 299/300/600 の回帰 |
| R2 | 採用 | Important | `evaluate` で `.failed` を `.paused` 同等に。pause 経路が error 表示を消すので追加の表示関心は不要。cleanup 中の再入とタイマー 1 回入りを回帰で確認 |
| R3 | 修正採用 | Important（本機能の merge 条件からは外す提案） | 上限は recognizer の `stop()` に置く（inactivity 側の見張りでは pause が `oldClosing` 待ちで止まる）。仕様の「20 秒」記述を訂正し、期限付き停止は別変更 |
| R4 | 採用 | Minor | `enterSleeping` で caption のみ消す専用メソッド。`displayedCaption` の分岐は一本化可 |

未確認: 実機・Simulator での再現は行っていない（read-only）。R2 の再入順序は読解のみで、回帰テストで確定させること。

## 追記（2026-10-26）R3 の Codex 側訂正について

- Codex の reviewer 訂正「現行の 20 秒は utterance/segmentation の境界であり、graceful finalization 全体の 20 秒保証という表現は強すぎる。無上限の closing は既存コード」は、上記 R3 の裏取りと一致する。判定は 修正採用 のまま。
- 最小変更箇所を `AppleSpeechRecognizer.stopCapture` の `driver.stop()` 待ち（期限超過で `driver.cancel()` に切り替え、元の finalization と cancel の両方の完了まで join して所有権を保つ）とする案に同意。これは上記で述べた「recognizer actor に閉じる」置き場所の具体化であり、VM/coordinator 側は `stop()` 完了待ちのままでよい。
- 本差分で必要な修正は「仕様・検証文書の 20 秒記述の訂正」まで。期限付き停止は既存の停止保証の範囲の改善として別変更に切り出す、という区別で合意できる。
