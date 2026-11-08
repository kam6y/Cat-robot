# 挙動を保つリファクタリングの検証（2026-11-07）

基点: `3699ef13ab527fb17b154a4f33b109482c54299f`（main、#29 統合後）。作業ブランチ: `codex/refactor-20261107`。設計: [確定設計](../superpowers/specs/2026-11-07-behavior-preserving-refactor-design.md)（`94978c51`）。計画: [実装計画](../superpowers/plans/2026-11-07-behavior-preserving-refactor.md)（`9341836f`）。

この記録は作業中に追記する。完了していない task の結果は書かない。

## ユーザーの指示と判断

- 依頼: 「かなり実装を進めたのでここでリファクタリングを行ってください。もう寝るので自律的に進めておいてください。実機検証は後でしてください。」
- 追加判断: 「待機中の動きの古い仕組みは本番で使ってないなら消していいよ」。条件の「本番で使ってない」は、Task 1 の特性試験で現行コードについて確かめる。
- ユーザーは途中の質問を不要とした。対象・順序・除外・検証方法は Codex と Claude の判断で、個別の承認は得ていない。
- 2026-11-07 の当初の完了範囲はブランチへの commit・自動検証・独立レビュー・記録まで。main への統合と push、有料のモデル試行、端末操作はこの段階では行わない。2026-11-08 の追加依頼と承認は末尾に追記した。

## Task 1: 旧待機スケジューラ

### 撤去前の配線の特性試験

`RobotLifecycleIntegrationTests` に 2 件を追加した（本番コードは未変更）。

- `testAppWiringDisablesLegacyIdleBeforeFreshWaiting`:
  - 準備
    - 接続済み・準備完了・静止の `MotionHarness` を使う。
    - `idleEnabled = true`、`trackingEnabled = false` とする。
    - 実際の VM（`PlaybackIntegrationHarness(motion:)`）と実際の `ConversationAppCoordinator` を作る。idle 設定は専用の UserDefaults を使う。
  - 経路
    - VM の init が `.idle` を通知するので、この順序では旧スケジューラの期限が一度 arm される。
    - その後、Coordinator の init が flag を有効にして期限を消す。本番の初期化（link が未接続のため arm されない）より強い分岐を通る。
  - 観測
    - SwiftUI の view を作らないので、顔の首 cue は来ない。
    - STATUS を新しく保ちながら 12 秒進め、idle 優先度の書込みと MOVE が無いことを確かめる。
    - その後、明示的な顔 cue を 1 回送り、idle 優先度の MOVE が出ることも確かめる。首の動作が設定や背景などで止められていたのではないことを示すためである。
- `testLegacyIdleControlRunsWithoutAppCoordinator`:
  - 検出力の対照。上と同じ準備と `.idle` で、Coordinator だけを作らない。
  - 12 秒以内に、旧スケジューラによる idle 優先度の MOVE が出ることを確かめる。
  - 旧経路に固有なので、撤去時に削除する。

結果（t1-wiring-1、本番コード未変更）:
- `MotionCoordinatorTests`、`FaceTrackingMotionTests`、`RobotLifecycleIntegrationTests` を実行し、98 件中 98 件成功、失敗 0、skip 0。
- 追加した 2 件が実行されたことを log で確認した。
- 入力は前後で一致した（HEAD `9341836f`、inputs `4867c89c…`）。
- receipt `a3402587…`、summary `b35a3475…`。

### 依存する試験の実測（一時 probe）

- 方法: `MotionCoordinator` の `idleFaceDriven` の既定値だけを一時的に `true` にして、同じ 3 class を実行した。commit はしていない。
- 目的と位置づけ: 依存を探すためのもので、機能の RED ではない。
- 結果: 98 件中、成功 91 件、失敗 7 件、skip 0。
  - `testIdleIntervalBoundsSmoothSamplesAndRate` は、MOVE が空のときの強制 unwrap で crash した。
  - 再起動後に残りの case も実行されたことを、98 件すべての開始記録で確かめた。
- 記録: receipt `5283d327…`、summary `5fa32b83…`。失敗した assertion の全行は Codex の private な記録 `t1-probe-findings.json` にある。
- 復元: 実行後に元の 1 行へ戻した。`MotionCoordinator.swift` の SHA-256 は `1337302a…` で元と一致した。

失敗 7 件と分類:

| 試験 | 分類 | 理由 |
|---|---|---|
| `MotionCoordinatorTests.testIdleIntervalBoundsSmoothSamplesAndRate` | 移植（名前を `testIdleColumnBoundsSmoothSamplesAndRate` に変更） | 列の上下限 ±3°/±2°・速度 10・50ms 以上の間隔・始点と終点・3 秒の長さは、現役の顔 cue でも同じ契約。4 秒の待ち間隔の主張だけを除く。 |
| `MotionCoordinatorTests.testToolSpeechInvalidatesBlockedIdleMove` | 移植 | 送信待ちの待機 MOVE が、道具の発話で無効になる契約。 |
| `MotionCoordinatorTests.testIdleEnabledKeepsPWMAcrossSettingsAndWaitingMovements` | 移植 | 待機動作の合間に PWM を切らない契約。2 秒以上の静止をはさむ顔 cue を 3 回送って確かめる。 |
| `FaceTrackingMotionTests.testFaceAcquisitionPreemptsIdleIncludingItsQueuedNextSample` | 移植 | 顔の取得が、queue 済みの次の sample を含めて待機動作に優先する契約。 |
| `FaceTrackingMotionTests.testHoldingSuppressesIdleAndSearchingAllowsIt` | 移植 | holding 中は cue を拒否し、searching では受け付ける契約。拒否中にも cue を送って拒否を観測する。 |
| `FaceTrackingMotionTests.testThermalSuspensionPreventsTrackingAndIdleUntilReleased` | 移植 | 熱による停止中は追尾も cue も拒否し、解除後は受け付ける契約。 |
| `RobotLifecycleIntegrationTests.testLegacyIdleControlRunsWithoutAppCoordinator` | 撤去時に削除 | 旧経路が残っていることを示す検出力の対照で、旧経路に固有。 |

- setter の副作用（`cancelDecorativeMotion`、`nextIdleAt = nil`、`service()`）だけに依存する失敗は無かった。
- 「face-driven で cue なしのまま新しい STATUS で 12 秒進めても送信しない」ことは、単体試験の既存 `MotionCoordinatorTests.testFaceDrivenIdleWaitsForCueAndKeepsExistingCapsAndSpeed` が固定している。これを再利用し、同じ期待値の case は追加しない。

### 移植

移植した 6 件は、既存の試験関数をその場で書き換えた。

- `setIdleFaceDriven(true)` を明示し、時間の経過で旧スケジューラが動くのを待つ代わりに `requestIdleFaceMotion` を送る。
- cue の値には、旧 random が与えていた値を使う。scripted の値があればその値、空なら範囲の下限（yaw −3°・pitch −2°、または yaw 3°・pitch 2°）である。
- 安全と所有権の主張は変えていない。
- 撤去時に変えるのは、`setIdleFaceDriven(true)` の行を消すことだけである。

結果（t1-ported-1）:
- 本番コードは HEAD `9341836f` のままで、移植後の同じ 3 class を実行した。98 件中 98 件成功、失敗 0、skip 0。
- 入力は前後で一致した（inputs `23dc6ba6…`）。
- receipt `259ce375…`、summary `826e570e…`。

### 撤去

- 撤去前の本番で移植後 98 件が成功した状態を、`a93c6aaea20dee0e69a216121ed5252db11eb42e` に先に commit した。commit された全 source/test は試験候補 `23dc6ba6…` と一致する。
- Claude から Codex へ Driver を交代した。旧 scheduler 末尾、`nextIdleAt` の専用 reset、`idleFaceDriven` と setter、MotionCoordinator の random 依存を除いた。追尾の分岐と return、安全上の判定順、顔 cue とあくびの列は保った。
- 本番の Composition と Coordinator、および試験の constructor 引数・setter 呼出し行だけを適応した。実機試験の変更は compile 用の引数だけで、実機では実行しない。
- 分類どおり、旧経路の検出力を確認する対照 1 件だけを削除した。6 件の移植後の assert は変えていない。RobotRandomSource / ScriptedRobotRandom は顔の動作に必要なので残した。

結果（t1-after-1）:
- 5 class、140 件中 140 件成功、失敗・skip・expected failure は 0。内訳は Motion 43、FaceTrackingMotion 33、RobotLifecycle 21、FaceTrackingCoordinator 27、ConversationIdle 16。
- candidate と before/after は完全一致（inputs `c7199e91…`）。receipt `e78c306a…`、summary `36664799…`。
- Claude の Navigator 確認でも追尾の分岐・安全条件・所有権・移植した assert の保持を確認した。Low の既存 device comment は compile caller 以外を変えない範囲に従い維持し、配線試験名も撤去前の記録との対応のため維持した。
- Task 1 の試験数の変化は、配線 1 件と対照 1 件の追加、対照 1 件の削除で差引 +1。6 件は移植なので減っていない。

## Task 2: 聞き返しの発話と所有者判定

### 整理前の特性試験

`ConversationMemoryIntegrationTests.testClarificationFinishingAfterExpiryStillRecordsOriginal` を追加した。本番コードは変更していない。

- 状況:
  - 末尾に空白を付けた発言で聞き返しに入り、speaker を止めておく。
  - speaker を保持したまま、注入した `clarificationDelay` を解放する（この時点では、pending の clear が終わったことを同期して確かめていない）。
  - その後、`.started` と `.finished` を返して正常に終える。
- 確かめること:
  - 元の発言を trim したものと固定の質問が、1 回だけ保存される。
  - 生成の prompt（`ScriptedSessionClient.prompts`）と usage は 0 件。音声の準備で `prewarm` が session を 1 件作るのは別の処理なので、session の数は数えない。
  - 認識が再開する（start 2 回目）。
  - 計測は `.ambiguous` で終わり、見える milestone が無い。
  - reply trace の終了は `.ambiguous` の 1 件だけで、聞き返しの発話に caption や発話の trace は付かない。
- 期限 task の待ち時間が 15 秒であること（`sleeper.durations == [.seconds(15)]`）も、独立に固定する。
- 発話の開始と期限 task の登録は、1 秒の時間制限付きで待つ。待てなかった場合は後片付けをして終える。
- pending が消えていた最終的な証拠:
  - 続く発言は、時計の上では 15 秒の期限前（3 秒）に送る。それでも分類の依頼に元の発言が付かない。
  - routing 側の `>=` による期限判定では消えないので、期限 task が pending を消したことが分かる。
  - 解放後に 20 回 `Task.yield()` するのは、MainActor の処理を進める既存の書き方であり、それ自体は証拠ではない。
  - 証拠の範囲（Task 8 の独立レビューを受けて限定）: この case が示すのは、続く request より前に期限 task が pending を消したことである。発話の完了と保存より前に消えたことは確立していない。`sleeper.release(0)` は期限 task を join せず、20 回の yield も順序を保証しないため。
  - 現行の本番は、発話の前に trim した候補を取り込み、発話の後に pending を読み直さない（`askForClarification`）。そのため、記憶の保存はこの順序に依存しない。
- 計画との差と限界:
  - 計画では「時計で 15 秒を越えて失効」させる予定だった。
  - 時計を進めると、続く発言の時点で routing 側の判定でも消えるため、期限 task の働きを区別できない。そのため期限は注入 delay の解放で再現し、時計は期限前に置いた。
  - この case は、実時間や時計の 15 秒経過そのものは計らない。

実行の経過:
- t2-before-1: build に失敗し、0 件実行。新しい case が、`ConversationLatencyTests` の private extension にある helper を別 file から参照していた。新しい case の中だけを直した。機能の RED には数えない。
- t2-before-2: 111 件中、成功 110 件、失敗 1 件。
  - 失敗は新しい case の `sessions == 0` だけで、oracle の誤りだった。VM の音声準備（`prepareVoice`）が `reply.prewarm()` を呼び、`ClaudeConversationService` が session を 1 件作る。生成は `snapshots(for:)` の呼出しであって、session の数とは別である。
  - 既存の `testClarificationHistoryReachesTheNaturalConfirmationSession` と同じく、`client.prompts.isEmpty` で生成 0 を確かめる形に直した。usage 0 などの他の assert はそのまま。

結果（t2-before-3、本番コード未変更）:
- 7 class を実行し、111 件中 111 件成功、失敗・skip・expected failure は 0。
- candidate と before/after は一致した（source `aa999dd1…`）。

### 整理

- **聞き返し専用の発話:** 唯一の呼出し元だった `speakAndResume` を、`askForClarification(candidate:generation:turnID:)` に置き換えた。
  - 字幕と発話は固定の質問。保存する元の発言は、渡された candidate を trim した値を関数の中で保持する。発話中に期限 task が消し得る `pendingClarification` からは読み戻さない。
  - 処理の順序は変えていない: 正常な発話の終了 → 記憶への保存 → 所有の再確認 → 聞き取りの再開。失敗時の後片付けと、口の形を変える event の順序も同じ。
  - 取り除いたのは、もともと効果の無かった処理だけである。
    - trace と latency の記録。直前でこのターンの計測を `.ambiguous` で終えているので、`voiceLatency.trace` は nil で、`matching` も nil を返していた。
    - engagement の `.none` 分岐。
  - 生成側の `.arm` / `.refresh` は残した。
- **分類分岐の抽出:** `performTurn` の分類分岐を、`classifyAndRespond(_:wasCorrectingPending:generation:turnID:)` に抜き出した。
  - throw するのは分類器の呼出しだけなので、`switch target` を `do` の外へ出した。
  - 分類の trace、routing 開始時の context、current の確認、await の順序はそのまま。
  - `generateReply` と `setPendingClarification` へ渡す文字列は、`request.utterance` に変えた。`AddressClassificationRequest.init` が candidate をそのまま保持するので、値は同じである。
- **所有者判定の共有:** 計画どおり `ConversationTurnOwner.isOwned(generation:turnID:captureID:)` を追加し、recorder と VM の同じ switch をまとめた。
  - 同期の純粋関数で、VM の shutdown / shuttingDown の guard は外に残した。
  - 期限の `>=` と `<` は変えていない。
  - `VoiceTurnLatencyRecorderTests.testOwnerMatchesOnlyItsGenerationAndActiveTurnOrCapture` で、13 行の固定期待値（nil の ID を含む）を固定した。

結果（t2-after-1）:
- 7 class を実行し、112 件中 112 件成功、失敗・skip・expected failure は 0。
- 所有者表の新 case と期限の特性試験を含む。
- candidate と before/after は一致した（source `6317fed3…`）。
- receipt `f7abc2d4…`、summary `47229918…`。
- Codex の Navigator 確認で実装差分は承認された。
- 試験数は整理前の 111 件から、所有者表 1 件だけ増えた。

## Task 3: 要約の入力と結果

### 整理前のバイト契約

- `ConversationInstructionsTests.testSummaryReferencePromptPreservesExactUTF8` を追加した。本番コードは未変更。
- 前回要約、追加の往復、参考の往復、1200 文字の指示を含む期待値を独立した固定文字列で与え、`Array(prompt.utf8)` を比較する。参考には分解形の「か＋結合濁点」を使い、Swift String の正規化等価で差を見逃さない。
- 指示文と prompt builder、Guide、生成 schema は編集しない。

結果（t3-before-1）:
- 本番未変更の 4 class、61 件中 61 件成功。失敗・skip・expected failure は 0。
- candidate と before/after が完全一致（source `fee079e4…`）。receipt `36285954…`、summary `74e47d6f…`。
- Navigator も固定期待値を builder と照合し、末尾改行なし・1200 の表記・分解形 Unicode を確認した。

### 整理

- `validatedText` の `previousSummary` を必須にした。試験側の空の前回値は明示し、本番ではダミーの前回値を渡さない。
- `validatedSummary` が trim・非空・文字数を同じエラーで検証する。Generated の結果もこれを直接使い、factory と service の各検証境界は維持した。
- `.noContent` は前回文字列を trim せずそのまま返し、文字数の guard も残した。
- compact で残す配列は一度だけ作り、参考の往復と戻り値で同じ値を使う。分割位置と prompt builder は変えていない。

結果:
- `t3-after-1`: 同じ 4 class、61/61 成功。失敗・skip・expected failure は 0。receipt `02b579d1…`、summary `1a074fe9…`。
- `t3-inventory-1`: オフラインの 1 method が成功。receipt `b16413a6…`、summary `369a0501…`。
- 両実行とも candidate と before/after が完全一致し、source は `a8ec8596…`。
- 24 fixture の指示・prompt・history の UTF-8、分類用の正規化された論理 JSON、期待値、model、effort、上限 token、SDK revision は baseline と一致。7 file の source literal / Guide / Generable 宣言も一致した。比較結果の canonical inventory SHA-256 は `8ad343aa6cc71a0a5aac6478b5a96d46ae020c813e3f06918cb904f1bd4c3508`。
- モデルの呼出しは 0。SDK 内部と HTTP wire のバイト列は観測していない。
- Claude の Navigator 確認でも、noContent の保持、両検証境界、固定値と分解形 UTF-8 の保持を確認した。任意の fileprivate 化は採らず、計画の型メンバーのままにした。
- Task 3 の試験数の変化は、独立 byte 試験 1 件の追加だけ。

## Task 4: Supertonic のエラー変換

### 既存の map の固定

`SupertonicErrorMapperTests.testDictionaryAndCancellationErrorsMapDirectlyToSynthesisFailure` を追加した。本番コードは変更していない。

- `JapanesePronunciationError.dictionaryUnavailable` と `CancellationError` を `map` に直接渡すと、どちらも `.speechSynthesisFailed` になる。
- 既存の `testUnavailableAssetsAreDistinguishedFromInferenceFailure`（assets 3 種 → `.speechVoiceUnavailable`、`inferenceFailed` → `.speechSynthesisFailed`）は変えていない。
- `CancellationError` を `.cancelled` にするのは `map` ではなく、呼出し元の do/catch である。この違いを先に固定しておき、次の helper の抽出で取り違えないようにする。

結果:
- `t4-map-before-1`: `SupertonicErrorMapperTests` の 2/2 が成功。失敗・skip・expected failure は 0。receipt `b7db037d…`、summary `ee48df14…`。
- candidate と before/after は完全一致し、source は `21bd285f…`。本番コードは HEAD `b8820f94` のまま。

### helper の抽出と境界の固定

`SupertonicErrorMapper.mapping(_:)` を追加した。渡された `@Sendable` の operation を一度だけ await する。`CancellationError` は `.cancelled` に、それ以外は既存の `map` に通す。この catch の順は、Speaker の 3 closure が持つ do/catch と同じ。新しい Task・actor・キャンセル確認は加えていない。`map` の本体と、既存 2 case の期待値は変えていない。

- `testMappingRunsTheOperationOnceAndReturnsItsValue`: 文字列と `SpeechPCM`（samples と sampleRate を個別に比較）を、そのまま返す。2 回の呼出しで operation の実行回数は 2。回数は試験ファイル内の private actor で数える。
- `testMappingKeepsCancellationAndOtherwiseMatchesMap`: 投げたエラーと期待値を独立した固定表で確かめる。`CancellationError` → `.cancelled`、assets 3 種 → `.speechVoiceUnavailable`、`inferenceFailed` と `dictionaryUnavailable` → `.speechSynthesisFailed`。どの行も rethrow され、値を返さない。
- 新 API がないことによる compile 失敗は RED ではない。この段階では Speaker の caller はまだ変えていない。

結果:
- `t4-mapping-1`: `SupertonicErrorMapperTests` の 4/4 が成功。失敗・skip・expected failure は 0。receipt `bf278eb3…`、summary `671459a4…`。
- candidate と before/after は完全一致し、source は `c6a8ce71…`。

### caller の接続

`SupertonicSentenceSpeaker` の convenience init にある 3 つの closure を、各自の do/catch から `SupertonicErrorMapper.mapping` へ置き換えた。各 operation の中身は前と同じ。

- prepare: `engine.prepare()` の後に `JapanesePronunciationService.shared.prepare()` を await する。2 つは同じ operation の中にあり、順序も同じ。
- normalize: `JapanesePronunciationService.shared.normalize(text)`。
- synthesize: `engine.synthesize(text:voiceID: preset.rawValue, steps: 8)`。

designated init、`prepare()` の共有 Task とキャンセル handler、先読み、再生本体、音声 preset は変えていない。

結果:
- `t4-after-1`: 4 class で 45/45 が成功。内訳は `SupertonicErrorMapperTests` 4、`SupertonicSentenceSpeakerTests` 12、`JapanesePronunciationServiceTests` 13、`SentenceReplyPlaybackTests` 16。失敗・skip・expected failure は 0。receipt `2f51f419…`、summary `0e5f18b0…`。
- candidate と before/after は完全一致し、source は `3dbd596d43fc7a76b6173a1c5bbd21127205163ae96cdff87ea3828094f0b8ac`。
- Codex の Navigator 確認で、変えたのは 3 closure の接続だけであり、mapper と試験も試験済みの入力と一致することを確かめた。
- Task 4 の試験数の変化は、mapper の試験 3 件の追加（直接 map の固定 1 件、helper の境界 2 件）だけ。Speaker の既存試験には手を加えていない。

## Task 5: 分類器の adapter と試験 support

- 本番の分類はすべて `AddressClassificationRequest` を渡す。呼ばれていない model-client の String overload を削除し、classifier の試験用 String convenience だけを本文のまま `ConversationFakes` へ移した。実機モデル試験も typed request であり、変更していない。
- FakeAddressClassifier の calls と private FakeAddressModelClient の prompts/requestCount は、従来どおり記録する requests から導く。失敗時も要求を先に記録する順序は同じ。
- `pollUntil` は既存の ContinuousClock 期限・Task.yield・最後の condition 確認を移したもの。harness と summary 待機はこれへ委譲し、1 秒の default、false 時の assert/guard/message を維持した。無期限の gate 待機には変えていない。
- `makeClaudeService` の従来の factory/store/usage/budget と新しい optional longTerm/tools/configuration の default を保持した。local builder は RememberToolProvider と settings.current を明示して委譲する。configuration gate の counter と await 位置は変えていない。
- 変更した試験 support の既存 assertion 行と test method 名が不変であることも `t5-oracle-proof.json` で照合した。新規・削除 case はない。

結果:
- `t5-after-1`: 9 class、172/172 成功。失敗・skip・expected failure は 0。receipt `49735bec…`、summary `0a73540a…`。
- `t5-inventory-1`: オフラインの 1 method が成功。receipt `88294233…`、summary `d768fa5d…`。24 fixture と 7 source guard は baseline と一致し、canonical inventory は前回と同じ `8ad343aa…`、networkCalls は 0。
- 両実行とも candidate と before/after が一致し、source は `4aef0e3b81670433f496d468fa897d6845246cdf1dcfdf215279fbf7fcf1be36`。
- Claude の Navigator 確認で、移動した adapter 本文、fake の記録順、ポーリング本文と MainActor、builder の default と設定 gate を照合した。blocking 指摘なし。
- 共有 support の残りの利用先 11 class は、Task 8 の予定された full suite で実行数まで照合する。Task 5 単独では実行したと扱わない。対象は `t5-support-full-required.json` に保存した。後で失敗した場合の原因切分けは少し広くなるが、別 commit と今回の主要 9 class の証拠を保つ。

## Task 6: 記憶の表示値と設定識別子

- `ConversationViewState.memoryPresentation` を計算 property として追加した。保存も cache もせず、読むたびに `ConversationMemoryPresentation(state: memoryState)` を作る。
- `ConversationViewState` の 4 か所（`allowsIdleFaceLife`・`showsTapToResume`・`statusChips`・`allowsTypedSubmission`）と `ConversationView` の 4 か所（`prioritizesContent`・聞き取りボタンの `disabled`・記憶カードの `message` と `canRetry`）を、この property に置き換えた。計 8 か所。評価の回数と順序、表示条件は同じ。
- 計画の対象外にある同じ形の呼出し（`ConversationAccessibility` の `newState`、`ConversationViewModel` の 2 か所）は変えていない。
- `ConversationSettingsIdentifier` に `faceTrackingEnabled`・`faceTrackingStatus`・`faceTrackingYawCorrectionStepper` を `cameraPermissionButton` の次の行へ追加した。raw 値は旧 literal と同じ。カメラ pane の 3 か所の literal は、この識別子の `rawValue` を参照する。control の構成・順序・label・文言は変えていない。
- `testSettingsSheetDeclaresItsControls` の固定一覧へ、この 3 値を宣言順で加えた。既存の 9 値とその順序は変えていない。`allCases` を使うのはこの試験だけ。
- 新しい case がない状態での compile 失敗は RED ではない。

結果:
- `t6-after-1`: 5 class で 60/60 が成功。内訳は `ConversationAccessibilityTests` 16、`ConversationMemoryPresentationTests` 2、`ConversationViewStateTests` 18、`FaceConversationPresentationTests` 16、`OnboardingSettingsTests` 8。失敗・skip・expected failure は 0。receipt `23c4ff64…`、summary `f39c3bf9…`。
- candidate と before/after は完全一致し、source は `f5f46436ef9f66b7fe2368a63b44a1a8d477550a81436c5de5956465e6dda065`。
- Codex の Navigator 確認で、cache なしの計算 property、置換が 8 か所だけであること、UI の条件・文言・構成の不変、3 つの raw 値と旧 9 値の相対順を保つ固定一覧を確かめた。
- Task 6 で試験の件数は変わらない。既存試験の固定一覧に 3 値を加えただけで、case の追加・削除はない。

## Task 7: scene・設定復帰・追尾の整理

### 整理前の追尾境界

- `FaceTrackingCoordinatorTests.testFreshnessHelperPreservesFutureEpsilonAndExpiry` を追加した。本番コードは未変更。
- 各 harness で t=0 の STATUS/pose を取り込み、時計を一度だけ進める。capturedAt=0 の画像は `(0.4 - 0.000001).nextDown` では following 1 件、厳密な境界値では 0 件という独立した期待値を固定する。
- 別の harness に capturedAt=completedAt=0.0000005 の画像を now=0 で直接送る。投影はまだ 0 件で、now=0.000002 の STATUS を加えると 1 件になる。未来側の許容 epsilon と pending の保持を確かめる。
- 画像を送る前の pose と、時計を刻まず一度だけ進める条件を保ち、境界の丸めを変えない。

結果（t7-before-1）:
- 本番未変更の 7 class、102/102 成功。失敗・skip・expected failure は 0。
- candidate と before/after は一致（source `34a4b388…`）。receipt `175e9c81…`、summary `9529ae4e…`。
- Navigator も時計の一度 advance、厳密な境界と future pending の構成を照合した。

### 整理

- `sceneControlMode` を共有し、settingsModel.setApplicationMode の後に読み、制御更新の前へ持ち上げていない。`updateRobotScene` は現在の scene を読む。設定復帰は settingsDidClose → 制御更新 → wake lock → 認識再開の順で、close 側の updateInactivity はその前に残した。
- `permitsAction` は scene・settings・sleep の短絡順を保つ。Task 内でも cancellation が先、scene generation が最後という guard 順を保った。
- composition init は既存 init へ同じ全 field を forward し、live composition を作り直さない。既存 root lazy 試験はそのまま残し、新しい init にも別の lazy case を追加した。onboarding 完了済みの状態で root を保持して処理を進め、マイク・モデル確認・音声準備・認識・音声セッション・返答準備・記憶読込・カメラ許可と撮影・リンク開始が 0 であることを確かめる。
- `isFresh` は既存の厳密な比較式を 3 か所から共有する。loss の 10 秒だけを定数へ移し、thermal の 10 秒は別のまま残した。

結果（t7-after-1）:
- 同じ 7 class、103/103 成功。失敗・skip・expected failure は 0。receipt `0b6e2235…`、summary `ae5677b8…`。
- candidate と before/after は完全一致し、source は `380cfddcfd4a778ca63095096ca5d25e8eb72f3ece49c6ab42c9b2f50199282e`。
- Navigator が scene setter 後の mode 評価、設定復帰と Task guard の順、全 field の転送、厳密な鮮度式と loss/thermal の分離を確認した。blocking 指摘なし。
- wake lock の非書込みの直接の証拠は、既存 root case の `idleTimer.writes == []` による。新 init の case は wakeLock 引数を持たないため、その assert を適用したとは扱わない。
- Task 7 の追加は追尾境界 1 件と新 init の lazy 1 件の計 2 件。既存 case と assert は保持した。

## Task 8: 文書・最終検証・引継ぎ

### 文書

- `docs/architecture.md` を現行のコードに合わせた。
  - 旧い定型句「なあに？」を削り、聞き返しの「今の、ぼくに言った？」だけにした。現役の発話の実装（`ClarificationContext.question`）と architecture の説明には「なあに？」は無い。過去の日付つき文書とこの記録には、歴史の記述として残る。設計では T2 で直す予定だったが、計画で文書の更新を Task 8 にまとめたため、ここで直した。
  - 待機時の微動は顔の計画からの要求だけで動き、内蔵の乱数スケジューラは撤去した、と書いた。
  - 今回まとめた責務を追記した: `askForClarification`、`ConversationTurnOwner.isOwned`、`memoryPresentation`、`SupertonicErrorMapper.mapping`、`AppRootView(composition:)`、`sceneControlMode`・`resumeAfterSettings`・`permitsAction`、`isFresh`・`faceLossTimeout`。
- `docs/README.md` の索引に、今回の設計・計画・検証記録を加えた。
- 2026-10-11 要件の FR-MOV-6 と 2026-10-23 robot-link 設計の待機微動の節（4〜10 秒の乱数動作）は、歴史の記録として書き換えていない。#29 の静的な分岐図も変えていない。

### task ごとの commit と試験

| Task | commit | 個別の検証 | 通常 suite の件数の増減 |
|---|---|---|---|
| 設計・計画 | `94978c51`、`9341836f` | — | 0 |
| T1 旧待機スケジューラ | `a93c6aae`（試験の移植）、`f1492b1f`（撤去） | `t1-after-1` 140/140 | +1（特性 2 件を追加し、旧経路に固有の対照 1 件を撤去時に削除） |
| T2 聞き返しと所有者判定 | `d59fa338` | `t2-after-1` 112/112 | +2 |
| T3 要約 | `b8820f94` | `t3-after-1` 61/61、`t3-inventory-1` 1/1 | +1 |
| T4 Supertonic のエラー変換 | `b0ee1d08` | `t4-after-1` 45/45 | +3 |
| T5 分類器と試験 support | `f783bebb` | `t5-after-1` 172/172、`t5-inventory-1` 1/1 | 0 |
| T6 記憶の表示値と設定識別子 | `82d7419f` | `t6-after-1` 60/60 | 0 |
| T7 scene・設定復帰・追尾 | `2de4ec71` | `t7-after-1` 103/103 | +2 |

- 通常 suite の期待件数は、基点の 1,039 件に上の増減 +9 を足した 1,048 件。全 suite の実数で照合する。
- T5 で変えた共有の試験 support の利用先 11 class は、T5 では単独で実行していない。全 suite でそれぞれの実行数を照合する（`/private/tmp/cat-refactor-20261107/t5-support-full-required.json`）。
- モデルへの入力（24 fixture と 7 source guard）は T3 と T5 の後に baseline と一致した。モデルの呼出しは 0。SDK の内部や HTTP の wire のバイト列、実 token 数、請求額は計測していない。
- 端末の操作（install・launch・devicectl）は 0。

### 全 suite・生成・build

結果:
- 生成: `ruby scripts/generate_project.rb` を 2 回、`ruby scripts/test_generate_project.rb` を 1 回実行し、すべて成功。2 回の生成と契約検査の後の snapshot は完全に一致した。project・Package.resolved・`scripts`・`native`・`CatRobot/Resources` は基点 main と同じ（`t8-protected-inputs.json`）。
- Python: `python3 -m unittest discover -s scripts -p 'test_*.py'` で 34 件が成功。
- `full-1`（実機専用の 2 class と有料モデルの 1 class を除いた通常 suite）: 1,048 件を実行し、1,047 件が成功、1 件が失敗。失敗は `CatFaceLifePresentationTests.testVisibleSleepyTransitionShowsYawnAndSpeechClearsIt` の 34 行目（発話へ切り替えた 400 ms 後の口の画素が 9,280、期待は 0）。下の「顔の表示試験の失敗」を参照。
- `full-2`（同じ入力で再実行）: 1,048/1,048 が成功。失敗・skip・expected failure は 0。receipt `c54cc4c3…`、summary `ad3746b0…`。source は `380cfddc…`、HEAD は `2de4ec71` で、前後で変わっていない。
  - 基点の 1,039 件との差は +9 で、class ごとの増分は task 表と一致した（AppComposition +1、ConversationInstructions +1、ConversationMemoryIntegration +1、FaceTrackingCoordinator +1、RobotLifecycleIntegration +1、SupertonicErrorMapper +3、VoiceTurnLatencyRecorder +1）。
  - T5 の共有 support の利用先 11 class はすべて実行された（ClaudePlaybackMemory 2、ConversationIdleIntegration 16、ConversationMemoryIntegration 20、ConversationSmartTurn 7、FaceExpressionIntegration 6、LookIntegration 5、LookSessionLifetime 4、MotionPlaybackIntegration 5、OnDeviceFallbackReplyGenerator 23、ReplyTrace 8、SentenceReplyPlayback 16。`t8-full-coverage.json`）。
- `final-inventory-1`: オフラインの 1 method が成功。24 fixture の UTF-8、正規化した論理 JSON、7 source guard が baseline と一致し、canonical inventory は `8ad343aa…`、networkCalls は 0。
- generic iOS の device-only compile（`t8-generic-tests-1`、receipt `cf837364…`）: `generic/platform=iOS` の build-for-testing が成功。実機専用の 2 class と有料モデルの 1 class の試験 source が iphoneos/Debug で compile され、試験の binary と `.xctestrun` ができたことを確かめた。実行はしていない。target の build への切り替えは不要だった。
- 通常の署名 Debug build（`t8-signed-debug-1`、receipt `74b81e17…`）: 別の DerivedData で Apple Development の署名つき Debug build が成功し、`codesign` の検証も成功した。app の実行ファイルは `3af9f386…`。install・launch・devicectl は使っていない。compile と build の成功は実機での合格を意味しない。
- 端末の操作と有料モデルの呼出しは、どちらも 0（`t8-automated-verification.json`）。
- 独立した初回レビューと受領は、文書の checkpoint commit `4a94972b` の後に行った（下の「独立した初回レビューと受領」）。

### 顔の表示試験の失敗

- `full-1` の 1 件は、あくびの最中に発話へ切り替えた 400 ms 後の画像で、口と目が補間の途中に見える画像だった。状態の変化（聞き取りの chip が消えたこと）は画面に反映されていた。
- この経路で今回の変更に触れるのは `ConversationView`／`ConversationViewState` の `memoryPresentation` への置換だけで、発話中は `allowsIdleFaceLife` の最初の phase の判定で false になり、置換した値まで評価されない。顔の動き・描画・この試験のファイルは基点から変えていない。
- 追加の実行（すべて source と試験の判定は無変更）:
  - 候補、同じ class: 3/3 成功。
  - 候補、失敗した method を `test` で 10 回: 9 成功・1 失敗（同じ 34 行目、42,386 画素）。
  - 基点と候補を `test-without-building` で 10 回ずつ交互に 3 組: 基点 30/30、候補 30/30。
- 判定の規則は結果を見る前に決めた。基点で 1 回でも失敗すれば既存の時間依存の試験、基点 0/30 で候補が 2 回以上失敗すれば回帰の可能性として調べ直す、それ以外は判別不能とする。結果は 3 つ目で、判別不能である。
- 描画の時間に依存する失敗が疑われるが、原因は証明していない。基点の試験が不安定だとは示せておらず、回帰も否定できていない。失敗はすべて build してから実行する `test` の mode で起き、基点はこの mode で反復していない。
- `full-2` の成功は、この失敗の原因が解決したことを意味しない（`t8-face-diagnosis.json`）。

### 途中の判断と、誤っていた場合の代償

| 判断 | 誤っていた場合の代償 |
|---|---|
| 全体: 既存の試験と、先に追加して現行コードで通した特性試験で固定し、GREEN → 整理 → GREEN として進める。compile の失敗や T1 の probe は、機能の RED とは扱わない | 既存の試験と特性試験が捉えない回帰を見逃す。独立した oracle、task ごとの試験、入力の照合、最後の全 suite で補う |
| 全体: task の完了の証拠は、同じ入力の再実行ではなく、task ごとの runner の receipt と、commit した blob が試験済みの入力と同じことの照合とする | 古い証拠を別の入力に対応づける危険がある。file・diff・HEAD・runner の前後の manifest で補う |
| 全体: 後日の実機確認のため、計画の作業領域と証拠を残す。managed worktree や過去の証拠は消さない | 手元の保存容量を使う |
| T1: 顔の要求がないまま新しい STATUS で 12 秒待っても待機動作を送らないことは、既存の単体試験 `testFaceDrivenIdleWaitsForCueAndKeepsExistingCapsAndSpeed` を再利用して確かめる | その単体試験の oracle が弱ければ見逃す。新しい配線の特性試験で補う |
| T1: 旧スケジューラの撤去は、本番で使っていないことを配線の特性試験と probe で確かめてから行う | 本番で旧経路が動いていた場合、待機中の首の動きが減る。後日の実機確認で見る |
| T2: 失効の再現は、時計を期限の前に保ったまま、注入した clarificationDelay を解放して行う | 15 秒の実時間の経過そのものは測っていない（duration の値は固定試験で確認）。また、発話の完了より前に失効したことは確立していない。本番が発話後に pending を読み直すように変わった場合、不利な実行順ではこの case が見逃す |
| T5: 共有 support の利用先 11 class は T5 単独では実行せず、全 suite で実行数を照合する | 失敗した場合の原因の切り分けが広くなる。`full-2` で全 class の実行を確認した |
| T7: 新しい root init の lazy 試験は wake lock を注入できないので、wake lock の非書込みは既存の root 試験だけを証拠とする | 新しい init 経由の wake lock の書込みは直接は確かめていない |
| T8: 顔の表示試験の失敗は、事前に決めた規則で判別不能と記録し、判定も source も変えずに全 suite を再実行する | 回帰であった場合に見逃す。表示経路の変更が等価な置換だけであることで補う |
| T8: 文書を一度 checkpoint commit し、その commit 範囲を両者の独立した初回レビューへ渡す。レビュー後の採否は最後の文書 commit に記録する | 文書の commit が 1 つ増える。文書もレビューの対象に確実に含めるため |

### 独立した初回レビューと受領

対象は BASE `3699ef13` から checkpoint `4a94972b` までの 11 commit（source は試験済みの `380cfddc…` と同じ）。双方とも、初回を保存して SHA を通知するまで内容を交換しなかった。どちらも読取りだけで、build・test・モデル・端末の操作はしていない。

- Claude: 実際の `/simplify` を report-only で実行した。再利用・簡素化・効率・Altitude を、それぞれ新しい読取専用の context で調べた（再委任なし）。
- Codex: 新しい独立レビュアー 1 名に読取りを依頼した。
- 初回の SHA-256（`/private/tmp/cat-refactor-20261107/`）:
  - `codex-review-initial.md`: `5f0551b88a0bc7f92ae1ab725a5d0225e992f8f2a31614f7d822d65196d5ae22`
  - `claude-review/simplify-reuse-first.md`: `36084a0efac6ced57d3fe1874bf2008c9f2e71d13ebbb2bb7471125788041735`
  - `claude-review/simplify-simplification-first.md`: `1a05249dd75e80f91d5f8249bb83ebf9ef26aa0a24a8c7a841c09f1249cb6f07`
  - `claude-review/simplify-efficiency-first.md`: `ca3a4f3b2910ff8188d66b08892b1890e5fd095cb636710fb16d37cdfd07dd27`
  - `claude-review/simplify-altitude-first.md`: `876b212f4fcb32493c0d693a5ff95c115605633d21df4d5ccda3c1eba87f3e09`
  - `claude-review/simplify-consolidated-first.md`（4 件の重複整理）: `57d544d08ab9063def1242765e4ce03dd73bca8c70e1683b4ff6bf435cdfc4a3`
- 受領は双方とも `superpowers:receiving-code-review` に従い、実コードと照合した。受領の記録は `review-reception-codex-v1.json`（`b1cd9357…`）と `claude-review/claude-reception-of-codex-initial.md`（`70bbad15…`）。

結果: Critical 0、Important 0。指摘はすべて Minor か任意の整理で、今回の候補には source も試験も追加の変更をしない。

| ID | 指摘 | 判断 | 理由と、見送った場合の代償 |
|---|---|---|---|
| Codex Minor 1 | T2 の失効の特性試験は、発話の完了より前に失効したことを確立していない | 試験の変更は延期し、記録の証拠の範囲を限定した（T2 の節と判断表） | 本番に同期用の hook を足すのは整理の範囲外。試験だけで、発話を保持したまま clear を観測してから発話を終える案（例: `Mirror` で private の `pendingClarification` を読む）もあるが、未実装・未検証で、private の名前に結びつくため今回は追加せず、後日の候補とした。代償: 本番が発話後に pending を読み直すように変わった場合、不利な実行順ではこの case が見逃す |
| C1 | 撤去した `setIdleFaceDriven` の doc 行が `requestIdleFaceMotion` の上に残る（`MotionCoordinator.swift:246`） | 見送り | 内容（顔の計画が待機の間を持ち、追尾は自律）は今の関数の説明としても正しい。検証済みの source を変えるほどの効果がない |
| C2 | `serviceAutonomous` の return が、削除した後続を飛ばすためだけのものになった | 見送り | 首の追尾経路の分岐と短絡の構造を、検証後に組み替えない。誤った指令も非効率も見つかっていない。代償: 読み手が無い待機経路を探す手間 |
| C3 | `ScriptedRobotRandom` の値の経路が死に、`RobotRandomSource` は `CatFaceLife` だけが使う | 見送り | 試験 support の配置の移動は、設計で延期した範囲 |
| C4 | 撤去した仕組みを指す試験名・device 試験のコメント・既定と同じ `trackingEnabled = false` | 見送り（コメントの前提は不採用） | 試験名は T1 で歴史的な名前として保持した。device 試験は凍結。thinking の phase は今の顔からの待機も追尾も抑えるので、コメントが誤りとは示せない。`false` の明示は否定側の準備を示す |
| C5 | `ConversationMemoryPresentation(state:)` を手で作る箇所が VM 2・accessibility 1・試験 1 に残る | 見送り | T6 は UI の 8 か所に限定した。残りも挙動の欠陥ではない |
| C6 | `updateRobotScene` の中で `sceneControlMode` が同じ scene を再び分岐する | 見送り | scene と設定の遷移時だけで、費用は無視できる。literal に戻す案や新しい表を足す案は、setter の後に読む順と link の順を崩す危険が上回る |
| C7 | `waitForSummaryCondition` は `pollUntil` を転送するだけ | 見送り | 計画で決めた委譲。同じ bounded polling で、重複した方針は残っていない |
| C8 | `wasCorrectingPending` は常に `request.clarification != nil` と同じ | 見送り | 計画で決めた private の interface。今は食い違いが起きない |
| C9 | `isFresh` の年齢比較が `CameraSnapshot.isFresh` と重複 | 見送り | `CameraSnapshot.isFresh` を直接使うと、固定した未来 epsilon の case を拒否する。年齢比較だけを `FaceCapturePolicy` に移す案は、検証した安全境界を広げる |
| C10 | `faceLossTimeout` を `static let` に | 見送り | 記憶域の差は無視できる。期限は変わらない。試験した instance の形を保つ |
| C11 | `docs/architecture.md` に private helper の名前が載る | 見送り | 今の名前は source と一致し、順序の約束事の近くで読む助けになる。既存の文書も内部名を載せる粒度である。将来の改名でずれる保守の危険は残る |
| C12 | `makeClaudeService` の optional の `longTerm` は非 optional の既定引数で足りる | 見送り | 計画で決めた形。代わりの形は build で確かめていない |
| C13 | 新しい試験の `.caption, .speech` の判定が `isVisibleMilestone` と重複 | 見送り | file-private の helper の公開範囲を広げるより、小さな重複のほうがよい |
| C14 | `wakeFromSleeping` の guard に `permitsAction` を使える | 見送り | 今の guard も cancel・scene と設定・sleep の順を保つ。helper は `launchAction` に限定した |
| C15 | `FaceTrackingHarness.frame` に `completedAt` 引数を足せる | 見送り | 微小な未来の入力を試験の中で見えるままにし、既存の helper の既定を変えない |
| C16 | `VoiceTurnLatencyRecorder` の `matching`／`noteASRActivity` も `isOwned` に委ねられる | 見送り | 入力が異なる。所有者の enum による共有は、取り消しと失敗処理に意図して限定した。残る直接の照合に古い token の不具合は見つかっていない |

ほかに、判断しなかった事項と範囲外として扱った事項:

| 事項 | 判断 | 誤っていた場合の代償 |
|---|---|---|
| 実機での首・声・あくび・追尾への引継ぎ・設定からの復帰 | 利用者の指定どおり後日に確かめる。simulator と build の証拠は branch の引継ぎだけを支える | 実機に固有の挙動は、付き添いの確認まで測れていない |
| SDK と HTTP の wire bytes、fixture 以外のモデルの挙動、token と請求額 | オフラインの契約の範囲と、変えていない依存関係にとどめる。有料の呼出しはしない | 観測していない SDK・wire・モデルの条件は保証の外 |
| 顔の表示試験の失敗の原因 | 判別不能のまま残し、元の oracle を保つ。推測による source の修正も、直ったという主張もしない | 断続的な回帰が残っていても見逃す。後日の調査のために開示する |
| 既存の `statusChips`・`prioritizesContent` の再計算と、root の `State` 初期値での物の構築 | 今回の差分で費用は増えていない。cache や寿命の変更は加えない | 既存の再構築と割当ての費用は残る。性能の実測はしていない |
| ほかの直接の所有者の照合、polling の helper、エラーの変換、画面の raw identifier | 共有の helper とは契約・isolation・戻り値・画面の持ち主が違うので、そのまま残す | 似た形の重複が残る |

### 後日の実機確認（2026-11-07 時点）

利用者の指定により、この段階では実機の確認を後日に残した。通常版を再 build して install し、次を確認する予定とした。実施した範囲と利用者の回答は、末尾の 2026-11-08 の追記を参照。

- 待機中の首の動き（顔の計画からの要求で視線に合わせて動くこと）と、あくび
- 待機から顔追尾への引継ぎ
- 設定画面を開いて閉じた後の首の制御モード・wake lock・聞き取りの再開
- 声の読み上げ（Supertonic のエラー変換を変えたため、通常の読み上げと準備失敗の表示）

### 承認の範囲（2026-11-07 時点）

- 対象・順序・除外・検証方法は Codex と Claude の判断で、利用者から個別の設計承認は得ていない。この段階で利用者の判断として記録したのは、冒頭の 2 件の発言だけである。
- この段階では main への統合と branch の push は行っておらず、承認もなかった。後日の追加承認は、以下の記録と区別する。


## 2026-11-08: 実機試験・利用者の受入・統合承認

### 追加依頼と担当

Claude が中継した利用者の原文は「実機に繋いだので実機のテストを行ってください。有料のものを含めて大丈夫です。」（中継受信 2026-11-08T14:05:49Z、原発言の正確な時刻は未確認）。この追加依頼により、この節の端末操作と有料試行を実施した。前日までの「端末 0・有料 0」は当時の結果である。

Claude が実機の実行を担当し、その間は両者とも source・docs・HEAD を変更していない。候補は clean な `6e7fe41d992b2bbcf205e304a9a92fe19e29be43`、source 入力は `380cfddcfd4a778ca63095096ca5d25e8eb72f3ece49c6ab42c9b2f50199282e`。iPhone 16 Pro、iOS 27.3 を用いた。Codex は実行済みの結果を読み取り、入力・ハッシュ・実数と返答／要約の意味を照合した。Codex が有料試行を追加実行したわけではない。

証拠は `/private/tmp/cat-refactor-20261107/device/`。実行担当の集約 `device-verification.json` は SHA-256 `d2b10c5a01708d994a86e1be851cbd201504fda7d1cbaf6dd25d5bd1b31574f3`。これは人の回答前に保存されているため `humanAcceptance: pending` のまま保持し、回答は下で別に記録する。

### 実機の自動試験

| 試験 | run ID | fixture の結果 | 結果 JSON の SHA-256 |
|---|---|---|---|
| Supertonic lifecycle | `355C961B-ABB3-4CC7-97AC-E1AA8EE1ACC4` | 5/5 成功 | `219e559538ce54805464e8301a7f16eb7d150019df312c109df5ae9766f5b791` |
| Supertonic fixed | `BB7D196C-7933-42EE-B6EC-920D8C272F35` | 18/18 成功 | `7e0143a01329c196f0d1156c1530db14c49432b7211f83624fac03c16cec0a09` |
| Supertonic voices | `380030A5-EACA-4366-BA02-66F8DC6D6952` | 10/10 成功 | `4d86dc4e2bbb294f7703f1a9b2e9845f9ad69b2fe9bd197d53b80f41cba31c21` |
| Supertonic latency-cloud（有料、Haiku） | `CC99F5A8-174F-4403-A9E9-A7EA4B892E2A` | 3/3 成功 | `1ac69d88950f8e7baf8d0ca2ea251b621b9fd862488aba9a4c6c59608b9b4c3f` |
| ClarificationHistory（有料） | `9267DC5D-B7AB-4B04-AB96-19227D66F0CB` | 72/72 成功 | `1b99dedcbd5e587d61fb41add6e8642af232baa3b61fcc3095a0e4f6efff91c4` |

各行の XCTest は 1 method が成功し、失敗・skip・expected failure は 0。表の fixture 数を XCTest の method 数とは混同しない。Supertonic 4 行の built revision と JSON の source revision は `6e7fe41d…`。ClarificationHistory の built tag は `6e7fe41d…-380cfddcfd4a778c`、実行前後の source 入力も一致した。

ClarificationHistory は分類 39 件、返答 18 件、要約 15 件（24 fixture × 3 回）。24 fixture の全文と各 72 record の入力は、前日のオフライン inventory および受入済みの同じ入力と一致し、自動条件も全件成功した。返答は Opus、分類と要約は Haiku。compaction 後の確認用返答はネットワークを使わない固定 client で、有料返答を追加していない。実 token 数・請求額は計測しておらず、試行数を SDK 内部の HTTP request 数や請求回数とはみなさない。SDK／HTTP wire bytes の同一性は主張しない。

XCTest の summary に、QoS の優先度逆転に関する runtime warning が各 5 run に 1 件ずつ（計 5 件）、main thread での同期 activate／deactivate が UI を応答不能にし得るという警告が Supertonic 4 run に計 7 件（lifecycle 1、fixed 2、voices 2、latency-cloud 2）記録された。後者の sourceURL は試験コード（SupertonicIntegrationDeviceTests／ResponseLatencyDeviceBenchmark）を指す。いずれも試験の失敗ではなく、原因や性能への影響は調査していない。全ジェスチャを動かす robot motion の自動試験は、利用者の選択により実行していない。

### 保存済み 33 件の独立した意味レビュー

- Codex は Claude の意味レビュー本文を読む前に、全 18 返答・15 要約の元発言、今回の発言、実際の返答、remember と保存事実、raw／解決後の要約を読み、33/33 pass とした。
- Codex 初回: `/private/tmp/cat-refactor-20261107/integration-codex-semantic-review-first.json`、SHA-256 `466cff843e9979e9cff428c9ffa1c39d088168075b67a338451761381d339b5d`。
- Claude 初回: `device/clarification-model/claude-semantic-review.json`、SHA-256 `d88a2815d362d1a40efd91ef192bb1c3487a3d5e22ca9658794849aff16e8664`、33/33 pass。
- 初回を保持してから trial ID ごとの判定を照合し、33 件すべて一致した。照合 `/private/tmp/cat-refactor-20261107/integration-semantic-comparison.json`、SHA-256 `fb36068ac8fecca674b0b2b9e8b6d2cde6c58748f57e37b3b17978ca96cbc3d3`。元の結果 JSON は変更していない。

元の算数への肯定は 12、新しい算数は 9、否定は短く受け止めて元の算数を回答しないことを確認した。否定された好みは保存せず、確認されたほうじ茶の好みは本人の preference として remember で保存した。要約は確認済みの好みを残し、否定／未確認のほうじ茶や参考だけの合言葉を混入せず、前回のジャズの好みを保持した。ここでの合格は、この fixture と 3 回の結果に限定する。

### 通常版と利用者の受入

通常の署名 Debug 版を別の `NormalDerived` で build し、実機へ install・通常起動した（試験 host ではない、PID 7013）。app の `CatRobotSourceRevision` は `6e7fe41d…`、実行ファイルの SHA-256 は `2a86c5989df63fb0b93558defe348960e602a8acec6c8d9140333f36384e0a7a`。Codex がファイルと install／launch log を照合し、macOS の証明書ストアにアクセスできる環境で `codesign --verify --deep --strict` の成功も確認した。

Claude が確認を依頼した次の 4 点に対し、利用者は「確認OKなのでmainにスカッシュマージしてpushしていいよ」と回答した（Claude からの中継受信 2026-11-08T14:42:24Z）。

1. 待機中の首の動きとあくび。
2. 待機から追尾への引継ぎ。
3. 設定から戻った後の首・画面スリープ防止・聞き取り。
4. あくび中の発話で話す顔へ戻ること。

この回答を通常版の人による受入 OK と記録する。各項目の個々の観察記録は受け取っていない。全ジェスチャの robot motion 自動試験や、全 voice の主観的な聴取評価を人が合格したとは扱わない。Simulator の初回 400 ms 描画試験失敗の原因は、実機での OK によって判明したわけではない。T2 の同期改善 Minor も未実施のまま残す。

### main への統合承認と実行範囲

利用者の上の原文により、今回の refactor branch を main へ 1 commit で squash し、main を push することが承認された。feature branch 自体の push、PR 作成、branch／managed worktree の削除は依頼されていないため行わない。個別の設計判断を利用者が承認したという記録には変更しない。

この節を書いた時点では、実機・人の受入・承認の記録を branch に commit し、続いて最新 main へ squash、通常 suite の確認、non-force push を実行する段階である。開始時のリモート main は `3699ef13`。branch と squash 後 main の tree 一致、および実機で受け入れた `6e7fe41d…` との全実装 blob の一致を確認する。文書と commit 履歴だけの変更であることを確認して、受入済みの通常版を対応づける。実装が変われば、この対応を流用しない。実行の最終 commit・remote の一致・作業ツリーの結果は、最終報告と `/private/tmp/cat-refactor-20261107/` の統合 receipt に残す。
