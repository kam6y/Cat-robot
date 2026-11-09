# 端末内モデルを外し、宛先判定と返答をClaudeに一本化する（issue #30）

対象: [issue #30](https://github.com/kam6y/Cat-robot/issues/30)。main `7913e157a0a310b5064b3779620e006f11e87159`（挙動を変えない整理の後）から `codex/issue-30-haiku-only` を作成。

端末内モデル（Apple Foundation Models の `SystemLanguageModel`）による宛先判定・代替返答・可否確認をすべて取り除く。宛先判定は常に Claude Haiku で行い、直前までの会話を文脈として添える。Claude が使えないときは端末内へ切り替えず、会話が失敗したら猫が決まった文を声で伝えてから失敗の表示に移る。別のモデル実装を後から足せるよう、Claude 固有の型は adapter 層に閉じ込める。

## 利用者と決めたこと（2026-11-09）

- 端末内モデルを完全に削除して Claude に切り替える。今後 Claude API 以外の実装も予想されるので、疎結合で実装する（issue 本文）。
- 宛先判定の AI は Haiku にする。Haiku ならコンテキストウィンドウに余裕が出るので、文脈を含んで判定する形に変える。
- この変更で、端末内 AI へフォールバックする処理はすべて削除してよい。
- エラーは、基本的にすべて音声で案内する。文章は事前に用意した定型文を使う（最初の指示は「ネットにアクセスできない場合と Claude が落ちている場合のみ」だったが、草案の提案 B・C・D・F への回答で「基本的に全てのエラーは音声案内してほしい」に広がった）。
- 草案の提案のうち承認されたもの:
  - A. 判定に添える文脈は、短期記憶にある猫との直近の往復を新しい方から合計 4,000 文字まで（往復単位）。要約は添えない。
  - E. 音声案内の後は聞き取りを止めて失敗を表示する。自動では再開しない。
  - G. 設定「送るもの・保存するもの」に、猫宛てかの判定のために聞き取った発話と直近の会話も Claude へ送ることを書く。
  - H. 定型文の文面（下の一覧に含める。ネット断の文は、同じ分類になるタイムアウト・429・529 も指せるよう少し広げた）。
  - I. 音声で案内しない例外（下の一覧）。
  - K. 開始前の確認（Claude の設定・ネット断・記憶の読み込み・聞き取りの準備）で失敗したときも声で案内する。
  - L. 返答の本文が一部出た後に生成が失敗した場合も、声で案内してから失敗を表示する。
  - M. 定型文の一覧（下の表）。
  - J. Haiku 化の対象は宛先判定だけ。返答の既定は Claude Opus 5.5 のまま（選択肢と effort も変えない）。要約と事実の統合はすでに Haiku 5.5（effort low）で、変更はない。
  - N. 例外 I への追加: 返答や聞き返しが正常に終わった後の自動保存の失敗（記憶の状態 `.unsaved`。未保存の表示と再試行）は、声を出さず従来のまま。
  - O. K の実現方法: 通常の開始手順の順序（可否確認 → 記憶 → 話者 → audio session → 聞き取り）は変えない。話者と audio session の準備より前に失敗したときだけ、案内の処理が自分で話者を準備し audio session を有効にして読み上げ、終わったら止めて解除する。
  - P. 文脈超過の定型文は「ごめんね、話が長くなりすぎて、うまく続けられなかった。もう一回話しかけてね。」（返答の失敗だけが短期記憶をリセットし、宛先判定の文脈超過ではリセットしないので、副作用を約束しない文にした）。

利用者の回答の原文（agmsg で Codex に共有済み）: 「A,E,G,H→問題ない」「B,C,D,F,→基本的に全てエラーは音声案内してほしい。」「他はOKです」（I・K・L・M）「Jは既定はOpusのまま、N,OもOKです」「pもOK」。

承認済みの A は「合計 4,000 文字まで」なので、最新の 1 往復だけで 4,000 文字を超えるときは文脈を添えない（空）。超える往復を特別に含める案は採らない。

確認待ちの提案は残っていない。

### 定型文の一覧（承認済み）

| 分類 | 対象の失敗（`ConversationServiceError` など） | 定型文 | 失敗の表示 |
| --- | --- | --- | --- |
| つながらない | `.modelUnreachable`（接続失敗・タイムアウト・429/529）、開始前の確認での `.modelUnavailable(.claudeUnreachable)` | 「ごめんね、いまは Claude とうまくつながらないみたい。少し待ってから、また話しかけてね。」 | 既存（通信が不安定／Claude に接続できません） |
| 答えられなかった | `.modelGenerationFailed`（HTTP 5xx や非公開型の API エラー、解析失敗、空の返答）、`.modelBusy` | 「ごめんね、いまはうまく答えられなかった。もう一回話しかけてね。」 | 既存 |
| 設定 | `.modelUnavailable(.claudeCredentialMissing / .claudeAttestationUnsupported / .claudeAttestationFailed / .available)`、`.modelLocaleUnsupported` | 「ごめんね、Claude につなぐ準備ができていないみたい。設定を確認してね。」 | 既存 |
| 上限 | `.dailyLimitReached` | 「今日はたくさん話したから、もうおしまいにするね。また明日、話しかけてね。」 | 既存（設定を開く） |
| 答えられない内容 | `.refusal`、`.guardrailViolation` | 「ごめんね、それには答えられないんだ。別の話をしよう。」 | 既存 |
| 話が長い | `.contextExceeded` | 「ごめんね、話が長くなりすぎて、うまく続けられなかった。もう一回話しかけてね。」 | 既存（返答の失敗では短期の会話内容をリセットした旨） |
| 入力が長い | `.inputTooLong` | 「ちょっと長すぎて、一度に聞ききれなかった。短く分けて話してね。」 | 既存 |
| 聞き取り | `.speechCaptureFailed`、`.speechEndpointingFailed`、`.speechCaptureAlreadyRunning`、`.speechAssetsUnavailable`、`.speechLocaleUnsupported` | 「ごめんね、いまは聞き取りがうまくできないみたい。もう一度試してみてね。」 | 既存 |
| 記憶 | 開始時・文字入力時の `ConversationMemoryError`（読み込み失敗など） | 「ごめんね、会話の記憶をうまく読めなかったみたい。」 | 既存（記憶の状態と再試行） |
| 例外（声なし。承認済みの I と N） | (1) 音声出力そのものの失敗 `.speechVoiceUnavailable` `.speechSynthesisFailed` `.audioSessionFailed`、(2) `.microphoneDenied`、(3) `.cancelled`（取消・一時停止）、(4) 聞き取り中の `.speechUnrecognized`（聞き取りを続けながら出す表示）、(5) 設定画面からの記憶の操作の失敗（削除・再試行）、(6) 正常に終わった返答・聞き返しの後の自動保存の失敗 `.unsaved` | なし | 既存 |

音声になる失敗と文面は `ConversationServiceError` の計算 property（例: `spokenGuidance`）と 1 か所の定数で決め、ViewModel は種類だけを見る。HTTP 5xx・400・403・404 は SDK 0.2.3 が非公開型で返すため `.modelGenerationFailed` にまとまり、区別しない（既存どおり。文字列・`debugDescription`・reflection による判定はしない）。

## 変える振る舞い

### 1. 宛先判定（文脈つきの Claude Haiku）

- 宛先判定は常に Claude Haiku（`.haiku5_5`、effort low、15 秒）で行う。端末内の分類器（`FoundationModelAddressClassifier`）、端末内モデルの可否確認（`FoundationModelAvailabilityService`）、両者の振り分け（`RoutedAddressClassifier`）を削除する。確認待ち中もそうでないときも同じ経路を通る。
- 文脈は短期記憶の直近の往復とする（承認済みの A）。読み取り口として SDK に依存しない port `ConversationHistoryReading`（`recentTurns() async -> [ConversationMemoryTurn]`）を Domain に置き、`ClaudeConversationService` が実装する。返すのは actor 内の短期記憶のその時点の複製で、未復元・削除中・削除失敗中は空にする。要約は返さない。新しい往復から順に、合計が 4,000 文字（`ConversationBudget.retainedCharacters` と同じ値）を超えない範囲で往復単位に含める。往復の途中では切らない。最新の 1 往復だけで超えるときは空。
- 取り付けは、SDK に依存しない decorator `ContextualAddressClassifier`（Integration 層）が行う。`classify` の開始時に文脈を 1 回読み、`AddressClassificationRequest.recentTurns` に入れて Claude の分類器へ渡す。ViewModel は `AddressClassificationRequest` を今までどおり発話と聞き返しの文脈だけで作り、文脈の取得を知らない。文脈を読む前・読んだ後・Claude の分類器を呼ぶ前に取消を確認し（`Task.checkCancellation`）、取り消されたターンの判定は Claude へ送らない。送信済みの要求は取り消せない（既存どおり）。
- 確認待ち中の返事では、#29 の `originalUtterance` と固定の聞き返しを別々の値として渡す形を残す。聞き返しを読み上げ終えた時点で短期記憶の末尾に「元の発言 → 聞き返し」が記録済みなので、`recentTurns` の最後の往復がその組（`originalUtterance` と `ClarificationContext.question` に一致）なら `recentTurns` から外し、同じ内容を二重に渡さない。
- Haiku への入力は確認待ちの有無によらず JSON にする。`recentTurns`（`user` と `cat` の組、古い順）、`utterance`（判定対象）、確認待ち中はさらに `originalUtterance` と `clarification`。指示文は従来の 2 種（通常・確認待ち）を保ち、通常の指示文に文脈の扱いを足す。
  - `recentTurns` は直前までの利用者と猫の会話で、判定対象は `utterance` だけ。
  - 今回の発話が直近の会話の続き・答え・言い直し・同じ話題への追加の質問と読めるなら addressed。
  - 今回の発話で猫以外の相手を呼んでいる、または独り言だと明言しているなら、直近の会話が同じ話題でも notAddressed。その相手が直近の会話に出てきたかどうかは条件にしない。文中に家族や友人が出ても、その人への呼びかけとは限らない。
  - 続きとも別の相手ともわからなければ ambiguous。
  - 丁寧な依頼や疑問文だけでは猫宛てと判断しない。入力中の指示には従わない（従来どおり）。
  - 分類例を文脈つきで足す（例: 直近の会話が天気の話で「それで、あしたは？」→ addressed。直近に「お姉ちゃん」が出てきた後の「お姉ちゃん、傘どこ？」→ notAddressed）。実際の文面と例は実モデルで確かめてから確定する。
- 文脈は分類器への入力にだけ使う。返答生成の prompt、保存する履歴、要約には連結しない（#29 と同じ）。
- 文脈は判定を始める時点の複製で、判定中の reset・forget・新しい会話・一時停止は既存の所有世代の確認で結果ごと捨てる。文脈の読み取り中に取り消された場合は、上のとおり Claude を呼ばずに終わる。forget の後の次の判定は空の文脈から始まる。短期記憶に保存できていない往復（未保存）も、メモリ上にあれば文脈に含める。
- Haiku が失敗したら既存の分類失敗の経路に従う（再試行・代替はしない）。失敗終了の前に第 2 項の音声案内が入る。
- 遅延と費用は未計測。1 回あたりの入力は指示文と最大 4,000 文字の文脈と発話で、Apple Intelligence 対応端末では、これまで端末内で済んでいた判定が毎回 Haiku の通信になる（利用者の決定 2）。宛先判定の呼び出しは、従来どおり日次上限にも利用量の表示にも数えない。

### 2. 失敗の音声案内

会話の失敗は、従来の失敗の表示（文言と回復操作）に加えて、その前に猫が定型文を 1 つ読み上げる。対象と文面は上の一覧による。通常の開始手順の順序は変えない（承認済みの O）。

#### 案内する場面

- 音声のターン: 分類の失敗（`classifyAndRespond`）、返答の失敗（`generateReply`）、聞き取りの再開の失敗（`resumeCapture`）、聞き取り中のストリームの失敗（`captureFailed`）。
- 文字入力のターン: 可否確認・記憶の準備・返答の失敗（`performTypedTurn` / `generateTypedReply`）。
- 開始手順（`performVoicePreflight`）: マイクの許可の後に起きる失敗のうち、可否確認・記憶の準備・聞き取りの準備・聞き取りの開始。話者の準備と audio session の有効化そのものの失敗、マイクの許可なしは声を出せないので文字だけ（承認済みの I）。
- 記憶の失敗（`ConversationMemoryError`）は、定型文の後に従来どおり記憶の状態（`ConversationMemoryState`）をそのまま表示して一時停止へ移る。`modelGenerationFailed` などの一般の失敗に読み替えない。回復操作（再試行）も従来のまま。

#### 失敗終了の手順（音声・文字入力・開始手順で共通）

1. 所有の確定と入力の停止（await の前に同期で行う）。失敗の所有者（`ConversationTurnOwner`）を確定し、`wantsListening = false`、確認待ちと会話継続窓の解除、区切りの timer（`segmentationTask`）の取消を行う。現行 `finishVoiceFailure` の冒頭と同じで、これを定型文の前に済ませる。以後、案内の所有判定は失敗の所有者で行い、`wantsListening` を要求する `isCurrent` は使わない。
2. 聞き取りと再生の停止。聞き取り中なら認識を止め（現行の `stopRecognizer`）、失敗した返答の再生があれば join する（`SentenceReplyPlayback` が話者を止めて合流する既存の動き）。音声の出力だけを残す。
3. 音声の準備（開始前の失敗だけ）。話者の準備と audio session の有効化が済んでいなければ、案内の処理がここで行う（承認済みの O）。準備に失敗したら読み上げを省き、手順 5 へ進む。
4. 読み上げ。phase を `.speaking`、字幕を定型文にして、`speaker.speak(定型文)` を最後まで待つ。口の形は聞き返しの読み上げ（`askForClarification`）と同じく話者のイベントで動かす。`ReplyPlaybackCoordinator` は通さないので、首・表情・視線の新しいターン（`beginTurn`）は始まらず、ジェスチャの予約も起きない（失敗した返答のターンは既に begin と cancel が済んでいる）。
5. 後始末。定型文を話した・話そうとした後は、失敗した返答の `speakerAlreadyStopped: true` を引き継がず、話者を止めて合流し（`speaker.stop()`）、その後で audio session を解除する（手順 3 で有効にした場合も含む）。`contextExceeded` の返答の失敗では従来どおり返答 session をリセットする。読み上げが途中で終わっても、次の読み上げを始められる状態に戻す。
6. 表示。失敗の表示と回復操作を出す（承認済みの E）。記憶の失敗では記憶の状態を表示して一時停止へ。

- 開始前の失敗の所有と取消: 可否確認・記憶の復元・聞き取りの準備を待つ間に一時停止・scene の inactive・audio の割り込みや route の変更・shutdown が来たら、その後に案内・聞き取りの開始・audio session の再有効化をしない。audio session を有効にした後の失敗は必ず解除まで行う。開始手順や聞き取りの Task を自分自身から await しない。
- 本文が一部出た後の生成の失敗でも案内する（承認済みの L）。記憶と回数の確定は従来どおり生成が正常に終わった時点（#29）で、生成が確定する前に失敗したら記憶・回数とも 0、生成が確定した後の読み上げの失敗・取消は 1・1 のまま戻さない（既存の `testSpeechFailureOrCancellationAfterCommitKeepsHistoryAndUsage` の契約）。読み上げの失敗は例外（声なし）なので、確定後に声が重なることはない。
- 定型文の途中で一時停止・新しい会話・全削除・文字入力・shutdown が来たら、既存のターンの取消と同じく話者を止め、所有者の確認で抜ける。失敗の表示は出さない（一時停止が勝つ）。聞き返しの読み上げ中と同じ扱い。
- 定型文の読み上げ自体が失敗・途中で終了・取消になっても、手順 5 の停止と合流を行い、元の失敗で手順 6 へ進む。読み上げの失敗で案内を重ねず、再試行もしない。
- 定型文は記憶に残さない（`recordExternalTurn` を呼ばない）、利用量に数えない、返答の計測（`ReplyTrace`）の返答としても記録しない。ログには失敗の種類だけを残し、文面と元エラーは残さない（旧 fallback のログ方針と同じ）。
- 連続失敗の回数で文言を変える仕組み（3 回で「何度もうまく話せないみたい」）は廃止する。
- 表情は phase に従う（読み上げ中は `.speaking`、失敗の表示後は `.failed`）。失敗したターンの表情・首・視線の予約は、従来どおり失敗時に無効化され、定型文の読み上げで解放されない。
- Claude 経由の失敗を `ConversationServiceError` に写す `ClaudeErrorMapper` の分け方は変えない（`URLError`・タイムアウト・`rateLimited` → `.modelUnreachable`、非公開型の API エラー → `.modelGenerationFailed`、認証 → `.modelUnavailable`）。`allowsOnDeviceFallback` を削除し、`spokenGuidance` を足す。

### 3. 日次上限

- 上限の判定は旧 fallback の中にしかなかったので、SDK に依存しない decorator `DailyLimitedReplyGenerator`（`ReplyGenerating`）として残す。`streamReply` の最初と `prewarm` で `usage.isDailyLimitReached(limit:)` を見る。達していれば `streamReply` は `.dailyLimitReached` を投げ、`prewarm` は base を呼ばずに戻る。どちらも Claude のセッション生成（`makeReplySession`）・通信・記憶の書き込み・利用量の加算を行わない。`reset` は素通し。会話の開始（音声・文字入力）は可否確認 → 記憶の準備 → `reply.prewarm` の順で進むので、上限の日は prewarm でもセッションを作らない（現行の fallback は上限でも `primary.prewarm()` を呼んでいた）。可否確認の認証（`authenticateIfNeeded`）と宛先判定の通信は上限で止めない。
- 組み立ては `MotionReplyGenerator(base: DailyLimitedReplyGenerator(base: claude))`。可否確認（`ModelAvailabilityChecking`）と記憶（`ConversationMemoryManaging`）は `ClaudeConversationService` を直接使う。
- 上限に達したターンは、上限の定型文を読み上げてから既存の表示「今日のClaudeとの会話が上限に達しました。設定で上限を変えるか、明日また話しかけてください。」に移る。設定「利用量」の脚注「上限に達した日は、端末内のモデルで短く答えます。」を「上限に達した日は返事をせず、声でお知らせします。上限はここで変えられます。」に変える。
- 宛先判定は上限で止めない（従来どおり）。

### 4. 端末内モデルの削除と、実装の境界（疎結合）

削除するもの:

- `FoundationModelAvailabilityService.swift`、`FoundationModelAddressClassifier.swift`、`FoundationModelReplyService.swift`、`FoundationModelErrorMapper.swift`、`OnDeviceFallbackReplyGenerator.swift`、`RoutedAddressClassifier`。`SystemLanguageModel` の参照を 0 にする。
- `ModelAvailability` の Apple Intelligence の理由（`.deviceNotEligible` `.appleIntelligenceNotEnabled` `.modelNotReady` `.unsupportedLocale`）とその表示文言。`ConversationServiceError.modelAssetsUnavailable` と `allowsOnDeviceFallback`。
- 旧 fallback の通知文 3 種と連続失敗の閾値。

移すもの（削除するファイルに同居している、Claude でも使う定義）:

- `ReplyModelClient`（SDK 非依存の protocol）→ `ConversationSessionFactory.swift`。
- `LanguageModelSession.contentSnapshots`（FoundationModels の拡張）→ `ClaudeSessionFactory.swift`。
- `AddressDecision` `GeneratedAddressTarget` `AddressModelClient`（構造化出力の型）→ `ClaudeAddressClassifier.swift`。`GeneratedAddressTarget` から `AddressTarget` への変換も Claude の分類器の中で行う。
- `LanguageModelSession.GenerationError` の写し（解析失敗・同時要求・guardrail・言語非対応・拒否・文脈超過）→ `ClaudeErrorMapper`。Claude のセッションも構造化出力でこの型を投げうる。`.assetsUnavailable` は端末内モデルにしか起きないので `.modelGenerationFailed` に落とす。

境界の決め方:

- バックエンドの契約は Domain の既存 port（`AddressClassifying` `ReplyGenerating` `ModelAvailabilityChecking` `ConversationMemoryManaging`）と、今回足す `ConversationHistoryReading`、それに `ConversationServiceError` と `ModelAvailability` の語彙とする。いずれも SDK の型を含まない。
- `ClaudeForFoundationModels` と `FoundationModels` を import するファイルは `Conversation/Services/Claude/` と `Conversation/Tools/`（`Tool` に準拠する道具）に限る。`Domain` `Integration` `UI` `App`（組み立てを除く）は import しない。受入は grep で確かめる。
- `FoundationModels` の `LanguageModelSession` `Tool` `Generable` `GenerationError` は Claude SDK が通信と構造化出力の API として使う型で、端末内推論ではない。これらは残る。
- 組み立て（`ConversationComposition.live`）だけが Claude の具体型を知り、`ClaudeConversationService` を返答・記憶・可否・文脈の 4 つの port として配る。別のバックエンドを足すときは、同じ port に準拠する adapter を `Services/<名前>/` に置き、組み立てを差し替える。
- 今回やらないこと（記録）: `ModelAvailability` の `claude...` という名前の中立化、`ClaudeConversationService` から短期記憶の管理を分離すること、`ConversationSessionFactory.makeReplySession` が受ける `[any Tool]` を中立な型にすること。いずれも挙動を変えずに済む後続の整理で、今回の範囲では名前と置き場所の変更だけに留める。

### 5. 表示・設定・説明

- `ConversationErrorPresentation`: Apple Intelligence の 4 文言を外す。表示の文言はそのほか変えない（定型文は読み上げと読み上げ中の字幕に使い、失敗の表示の文言には使わない）。
- 設定「利用量」の脚注（第 3 項）。設定「このアプリについて」の「送るもの・保存するもの」に、猫宛てかの判定のために聞き取った発話と直近の会話も送ることを足す（承認済みの G）。
- 文書: `docs/architecture.md` の図（「失敗時は端末内モデル」）と「返答のモデルと記憶」の項（`OnDeviceFallbackReplyGenerator` `RoutedAddressClassifier` → `DailyLimitedReplyGenerator` `ContextualAddressClassifier`、失敗の音声案内の手順）、`docs/README.md` の索引、`docs/application-flow.html` の「03 返答と記憶」（「条件が合えば、端末内で簡単に答える」）と宛先判定の行。#29 の spec にある「確認待ちでないときの振り分け（端末内モデルが使えれば端末内、使えなければ Haiku）は変えない」は古くなる旨を索引に示す。

## 変えないもの

- 保存形式（`ConversationMemoryTurn`、schema 1、互換 ID）。移行は不要。
- 15 秒の確認待ちと期限、30 秒・最大 5 分の会話継続窓、顔の向きと人数の条件、フィラーの一覧。確認待ち中の振り分けと addressed / notAddressed / ambiguous の意味（#29）。
- 返答のモデルの既定（Claude Opus 5.5）と選択肢（Opus / Sonnet / Haiku）、effort（承認済みの J）。要約と事実の統合のモデル（Haiku 5.5、effort low）。
- 宛先判定の Haiku の設定（effort low、15 秒）と、確認待ち中の判定規則・分類例。
- 利用量の集計（返答のターンだけを数え、宛先判定は数えない）と日次上限の既定値 300。
- 会話の開始手順の順序。音声はマイクの許可 → 可否確認 → 記憶の準備 → 話者の準備 → audio session → 聞き取りの準備 → prewarm → 聞き取りの開始。文字入力は聞き取りの停止 → 可否確認 → 記憶の準備 → prewarm → 話者の準備 → audio session → 返答の生成で、マイクの許可を求めず、認識の準備・開始もしない（マイクを拒否していても文字で話せる既存の契約を維持）。
- 失敗の表示の文言と回復操作、`ClaudeErrorMapper` の分け方、`contextExceeded` の返答の失敗で返答 session をリセットする方針（分類の失敗ではリセットしない）。
- 自動保存の失敗（`.unsaved`）の扱い: 返答は成功のまま、未保存の表示と再試行（承認済みの N）。
- 返答の生成と再生（`ReplyPlaybackCoordinator` `SentenceReplyPlayback`）、記憶の保存失敗の扱い、所有世代と取消の防御、聞き返しを記録する時点。
- `MotionCancellationReason.fallback`（`MotionCoordinator` が失敗 phase で使う）は名前を含めて残す。
- 返答用の固定指示（`ConversationInstructions.fixedPrefix`）とプロンプトキャッシュの構造。

## 場面ごとの結果

「記憶」は短期記憶へ加わる往復の数、「回数」は会話回数の加算。

| 場面 | 音声 | 表示 | 聞き取り | 記憶 | 回数 |
| --- | --- | --- | --- | --- | --- |
| 宛先判定の Haiku が失敗 | 種類に応じた定型文 | 失敗（既存の文言） | 止める | 0 | 0 |
| 返答が本文の前に失敗 | 種類に応じた定型文 | 同上 | 止める | 0 | 0 |
| 返答が本文の一部を出した後、生成の確定前に失敗 | 種類に応じた定型文 | 同上 | 止める | 0 | 0 |
| 生成が確定した後に読み上げが失敗・取消（既存） | なし（例外） | 失敗（読み上げ）または一時停止 | 操作に従う | 1（戻さない） | 1（戻さない） |
| 生成が確定した後の自動保存の失敗（既存） | なし（例外） | 未保存の表示と再試行 | 続ける | 1 | 1 |
| 文字入力の返答が失敗 | 種類に応じた定型文 | 同上 | （文字入力は元から止まっている） | 0 | 0 |
| 日次上限 | 上限の定型文 | 上限に達しました（設定） | 止める | 0 | 0 |
| 開始前の可否確認・記憶の読み込み・聞き取りの準備・開始に失敗 | 案内の処理が話者と audio session を準備して定型文 | 既存の文言（記憶は記憶の状態） | 始めない | 0 | 0 |
| 開始前の話者の準備・audio session・マイクの許可に失敗 | なし（例外） | 既存の文言 | 始めない | 0 | 0 |
| 聞き取り中にストリームが失敗 | 聞き取りの定型文 | 既存の文言 | 止める | 0 | 0 |
| 定型文の途中で一時停止・新しい会話・全削除・文字入力 | 止める | 失敗の表示は出さない | 操作に従う | 0 | 0 |
| 定型文の読み上げ自体が失敗 | 途中で止まる | 元の失敗の表示 | 止める | 0 | 0 |

宛先判定の入力:

| 場面 | 指示文 | 入力 |
| --- | --- | --- |
| 確認待ちでない・判定が必要 | 通常（文脈の扱いを追記） | `recentTurns` と `utterance` |
| 確認待ち中・こちらを向いていない | 確認待ち用（#29） | `recentTurns`（末尾の「元の発言 → 聞き返し」を除く）、`originalUtterance`、`clarification`、`utterance` |
| 短期記憶が空・未復元・削除中、最新の 1 往復だけで 4,000 文字を超える | 同上 | `recentTurns` は空配列 |

## 確認すること

### 自動テスト

- 削除する試験（端末内モデルだけの契約）: `FoundationModelAvailabilityServiceTests`、`FoundationModelAddressClassifierTests`、`FoundationModelReplyServiceTests`、`OnDeviceFallbackReplyGeneratorTests`、`RoutedAddressClassifierTests`、`AppleServiceCompositionTests` の端末内サービスの準拠確認。基準 1,048 件からの増減は、削除・移植・新設に分けて検証記録に残す。
- 移植する試験（旧 fallback を使って確かめていた、残る契約）:
  - 表情（`FaceExpressionIntegrationTests`）: 失敗した返答が予約した表情が、定型文の読み上げで解放されず、失敗時に無効化されること。
  - 首（`MotionPlaybackIntegrationTests`）: 失敗した返答の予約が無効化され、定型文の読み上げでジェスチャが起きないこと。
  - 視線（`LookIntegrationTests`）: 画像取得の後に失敗しても表示が消え、次のターンが通常どおり動くこと。
  - 記憶（`ConversationMemoryIntegrationTests`）: 確認待ちの後の返事が `URLError` で失敗したとき、定型文が話者へ渡り、失敗したターンは保存されず、回数も加算されないこと。旧 `testPendingReplyFallbackRecordsActualFollowupWithZeroClaudeUsage` の置き換え。
  - `FoundationModelErrorMapperTests` の `GenerationError` の写しは `ClaudeErrorMapperTests` へ移す。
- 新しい試験:
  - `ContextualAddressClassifier`: 文脈が判定の開始時に 1 回読まれて `recentTurns` に入ること。4,000 文字の上限（往復単位、新しい方から。最新の 1 往復だけで超えるときは空）。確認待ち中に末尾の「元の発言 → 聞き返し」だけが除かれ、一致しない末尾は残ること。未復元・削除中・削除失敗中は空。文脈が prompt と保存に入らないこと。文脈の読み取りを fake で止めている間に一時停止・新しい会話・全削除・shutdown を起こしてから解除すると、Claude の分類器が呼ばれず、表示・記憶・利用量に後から影響しないこと。
  - `ClaudeConversationService.recentTurns()`: メモリ上の往復（未保存を含む）を返し、forget 後は空。生成中の往復（未確定）は含まない。
  - `ClaudeAddressModelClient.requestInput`: 通常・確認待ちの JSON の形と、指示文の選択。
  - `ClaudeErrorMapper`: `GenerationError` の各ケースの写し。既存の loopback（`LoopbackHTTPResponder`、実クライアント経由）の 401 / 413 / 400 / 403 / 404 / 429 / 529 / 500 / 502 / 503 の写しが変わらないこと（`allowsOnDeviceFallback` の検査は `spokenGuidance` の検査に置き換える）。
  - `ConversationServiceError.spokenGuidance`: 全ケースの表（声になる種類と文面、例外は nil）。
  - `DailyLimitedReplyGenerator`: 上限で `.dailyLimitReached` を投げ、`prewarm` でも base を呼ばず、記憶・利用量が変わらないこと。上限未満は素通し。VM 経由（会話の開始から）で、上限の日にセッションが 1 つも作られず（`StubSessionFactory` の呼び出し 0）、可否確認と宛先判定は従来どおり動くこと。
  - 会話 VM の失敗終了（音声・文字入力・開始手順）:
    - 声になる種類の失敗では定型文が話者へ渡ってから失敗が表示され、例外の種類では話者を呼ばないこと。本文が一部出た後の生成の失敗でも案内すること。
    - 手順 1 の同期の停止: 区切り待ちの timer がある状態で聞き取りのストリームが失敗し、定型文の読み上げを fake で止めている間に timer を発火・解放しても、新しいターン・分類・ジェスチャ・二重の案内・聞き取りの再開が起きないこと。
    - 開始前の失敗（音声・文字入力それぞれで可否確認の失敗と記憶の失敗、定型文の成功と失敗の組み合わせ）: 案内の処理が話者と audio session を準備し、終了後に audio session が非 active に戻ること。認識の開始・prewarm・返答が起きないこと。記憶の失敗では元の記憶の状態と回復操作が保たれ、一般の失敗に読み替えられないこと。通常の開始手順の呼び出し順序が変わらないこと。
    - 開始前の可否確認や記憶の復元を fake で止めている間に一時停止・scene の inactive・route の変更・shutdown を起こしてから解除しても、案内・聞き取りの開始・audio session の再有効化が起きないこと。
    - 定型文の読み上げ失敗・途中終了でも、話者の停止と合流の後に audio session が解除され、元の失敗が表示され、次の読み上げを始められること。定型文の途中の一時停止・新しい会話・全削除・文字入力で話者が止まり、失敗が表示されないこと。
    - 定型文が記憶・利用量・返答の計測に残らないこと。定型文が首・表情・視線の新しいターンを増やさないこと。
    - 自動保存の失敗（`.unsaved`）で声が出ず、返答・聞き返しが成功のまま、未保存の表示と再試行が従来どおりであること（既存の `testSaveWarningDoesNotFailTheSpokenReply` と `testClarificationSaveFailurePreservesContextAndCanBeRetried` を維持）。
  - 組み立て（`AppCompositionTests`）: 本番の分類器が `ContextualAddressClassifier` → Claude の分類器の順で、文脈の読み取り元が返答サービスと同じ実体であること。返答が `MotionReplyGenerator` → `DailyLimitedReplyGenerator` → `ClaudeConversationService` であること。組み立て時に通信・モデル生成をしないこと（既存）。
  - `ClarificationRoutingTests`: 端末内の経路が無くなった前提で、確認待ち中・そうでないときの判定が同じ Haiku の分類器に文脈つきで届くこと。既存の期限・所有世代の試験は維持。
- 既存の回帰対象を維持する: 聞き返しの流れ（#29）、否定の短い返答、保存失敗と再試行、停止・削除の競合、音量 0 の警告、待機、開始手順の順序。
- 受入の静的確認: `SystemLanguageModel` の参照が 0、`import FoundationModels` と `import ClaudeForFoundationModels` が `Services/Claude/` と `Tools/` の外に無いこと。

### 実モデル（有料）

- [ ] 文脈つきの通常判定で、直近の会話の続き（「それで、あしたは？」「もう一回言って」）が addressed、文脈と無関係で手がかりのない発話が ambiguous になること。直近の会話が同じ話題でも、今回の発話が家族への呼びかけ（「ママ、あしたの天気どうだった？」）や独り言の明言なら notAddressed で、その相手が直近の会話に出てきたかどうかで結果が変わらないこと。文脈が無いときの既存の例（「ねこ、元気？」→ addressed、「パパ、鍵はどこ？」→ notAddressed、「明日は雨かな。」→ ambiguous）が変わらないこと。#29 の確認待ちの例が、文脈を足しても同じ結果になること。実行回数と合否の基準は実装計画で実行前に決め、不合格なら指示文を直して測り直す。
- [ ] 実機で機内モードにして話しかけ、「つながらない」の定型文が読まれてから失敗が表示されること。文字入力でも同じこと。機内モードのまま猫をタップしたとき、開始前の確認の失敗が声で案内されること（App Attest の資格情報が無い場合）。

### 実機・文書

- 通常版を実機に入れ、利用者がオンラインでの通常の会話、機内モードでの案内、上限（設定で下げて）での案内を確認する。
- `docs/README.md` の索引、`docs/architecture.md`、`docs/application-flow.html` を更新し、検証記録を `docs/validation/` に残す。

## 進め方

Codex・Claude のペアで進める。spec（この文書）は Claude が Driver、Codex が Navigator。spec 承認後に実装計画を作り、テストの区切りまたは 15〜30 分ごとに Driver／Navigator を交代する。ソースを編集するのはその時の Driver だけで、ビルド・試験中は双方が入力を固定する。xcodebuild と実機は Codex が担当する。

最後に Claude の実際の `/simplify`（修正を適用しない 4 観点）と Codex 側の独立レビュー 1 名、相互の receiving を行う。main への統合（squash・push）、有料の実モデル試験、実機への導入は、この issue ではまだ承認されていないので、それぞれ着手する前に利用者の承認を得る。
