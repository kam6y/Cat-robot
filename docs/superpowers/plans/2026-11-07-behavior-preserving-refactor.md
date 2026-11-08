# Behavior-Preserving Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 現役の会話・要約・音声・表示・追尾の契約を保って責務と重複を整理し、本番で使わない旧待機スケジューラを撤去する。

**Architecture:** 現在のactorと状態機械を保ち、純粋な判定・表示値・エラー変換を小さな境界で共有する。旧待機動作は現役の顔からの要求へ試験を移してから削除する。モデル入力の組立てと保存形式は変えない。

**Tech Stack:** Swift 6 strict concurrency、iOS 27、Xcode 27.2、ClaudeForFoundationModels 0.2.3、ONNX Runtime 1.24.2、既存のRuby/Python生成・検証スクリプト。

**Spec:** [確定設計](../specs/2026-11-07-behavior-preserving-refactor-design.md)（commit 94978c5188ffdaef067265a4da32a69507eae179、SHA-256 3176fe930aaea19515a30c03393b6644aa6341b2f7a52ca4f851dca31ee84c5c）。

## Global Constraints

- 利用者は「自律的に進めて」「実機検証は後で」と指定した。各設計・計画の個別承認は受けておらず、両者の技術確認で進める。追加判断「本番で使ってないなら古い待機動作を消してよい」の条件はTask 1で確認する。
- 実装は実際のCodex/Claudeのペア。executing-plansを使うが、実装者subagentへ置き換えない。各taskのDriverだけが合意ファイルを編集し、CodexがGit/build/test/commitを実行する。
- 基点3699ef13ab527fb17b154a4f33b109482c54299f、branch codex/refactor-20261107、既存managed worktreeを保持。今回の完了範囲はbranch commit・自動検証・独立レビュー・記録。main統合/pushは行わない。
- 有料モデル試行0、端末操作0。devicectl、実機destinationへの実行、install、launch、音声/首の実機試験は使わない。generic iOSのcompileと署名buildだけを行う。
- UIの文言・表示・VoiceOver、保存形式・保存先・互換ID、依存パッケージ版を保つ。
- 固定指示・生成した返答指示・要約promptのUTF-8 bytes、分類JSONのキー整列した論理payload、Generable型名・Guide字面・schema field/case名を保つ。SDK包装/HTTP wire bytesは未観測。
- 首・追尾・電源の安全条件と判定順、actor/await/cancel/join順を保つ。T1で明示した旧経路以外の状態機械を組み替えない。
- 既存の期待値とオラクルを弱めない。compile-onlyの引数適応と、T1の理由を付けた旧経路試験の分類/移植/削除だけを明示例外にする。
- project.pbxprojとshared schemesは生成器経由のみ。旧spec/plan、device runner、vendor、資産、Package.resolvedは凍結。
- 実装はT1～T7すべてを対象とする。新しい根拠のあるリスクで延期するときは理由と残りを記録し、単なる余力で打ち切らない。

## Review Focus

1. 接続済み・静止・STATUSがfreshな初期化でも、顔cueなしで旧MOVEを送らないこと。Task 1の実VM→Coordinatorと旧経路の対照で固定する。
2. 聞き返しの発話中にpendingが期限切れになっても、正常に聞こえた元発言と質問を一度だけ保存すること。Task 2で固定する。
3. 参照の見出しと正規化形の異なるUnicodeを含む要約promptのUTF-8が変わらないこと。Task 3の独立した期待byte列とoffline inventoryで固定する。
4. native辞書/推論の失敗とCancellationErrorを共有wrapperが取り違えないこと。Task 4で既存mapと新wrapperの違いを固定する。
5. 設定から戻る際のinactivity評価・mode更新・wake lock・認識再開の順と、追尾の0.4秒/10秒境界を保つこと。Task 7の既存統合試験と境界試験で固定する。

## 共通の実行・入力記録

- Codexのprivate runner: /private/tmp/cat-refactor-20261107/run-tests.py。phaseごとに新しい結果directoryを作り、source/test/project/scripts/native・全docs・HEAD・patch・runner hashの前後一致、xcresult実数、0件誤選択を確認する。
- full実行はSupertonicIntegrationDeviceTests、RobotMotionIntegrationDeviceTests、ClarificationHistoryModelTestsの3 classを除外する。選択したclass/methodが実際に実行されたこともlogから照合する。
- 入力が同一の直前1039 PASSはbaseline.json（6ebbd466…）に照合済み。同じbaseline全suiteを再実行しない。変更した範囲の試験と最後の全suiteは実行する。
- モデル比較基準: model-inputs-before.json（24 fixture、d62645ec…）、model-contracts-before.json（2e11fbd567bf5fab72f116184e052ff991f66763b7bd3beda67d497fea1ad272）。
- Model inventoryはSimulatorでtestFixtureInventoryAndPromptSizesの1methodだけ。全24件のinstructions/prompt/hash/expectation/model/effort/maxTokens/SDKとsource-text guardを比較する。旧72試行は新sourceでの実行と記載しない。
- 各taskの検証完了または15～30分後の最初の安全な区切りで実作業を交代する。実行中は入力を固定し、RELEASE/OFFERに対象・HEAD・digest・結果を添え、復唱ACK後に書く。
- taskごとに採否・結果・交代をignored ledgerへ、試験移植と未確認事項をvalidationへ記録する。commit前に全blobが検証した候補と一致することを照合する。

| 作業 | Driver | 次の境界 |
| --- | --- | --- |
| T1の特性試験・probe・移植 | Claude | probeまたは移植GREEN後の安全な境界でCodexへ |
| T1の撤去 | Codex | T2へ |
| T2 / T3 / T4 | Claude / Codex / Claude | 各taskのGREEN後 |
| T5 / T6 / T7 | Codex / Claude / Codex | 各taskのGREEN後 |
| T8の文書 | Claude | Codexが検証・commit、両者が独立初回を受領 |

---

### Task 1: 旧待機スケジューラを現役契約の試験へ移して撤去する

**Files:** MotionのrootはCatRobot/Motion/。変更する本番はMotionCoordinator.swift、RobotMotionControlling.swift、CatRobot/App/ConversationComposition.swift、ConversationAppCoordinator.swift。試験はCatRobotTests/Motion/MotionTestDoubles.swift、MotionCoordinatorTests.swift、FaceTrackingMotionTests.swift、RobotLifecycleIntegrationTests.swift、およびCatRobotTests/Device/RobotMotionIntegrationDeviceTests.swiftのcompile-only引数。記録はdocs/validation/2026-11-07-behavior-preserving-refactor.md。architecture更新はTask 8。

**Interfaces:** Consumes: requestIdleFaceMotion(yaw: Double, pitch: Double)、requestYawnMotion(pitch: Double)、cancelIdleFaceMotion()、MotionHarness.advanceFresh(by:step:)、PlaybackIntegrationHarness(motion:)。Produces: MotionCoordinator.init(link:clock:preferences:trace:)（random引数なし）。face-driven APIとRobotPreferences.idleEnabled、RobotRandomSourceは残る。setIdleFaceDriven(_:)だけをprotocolと実装から除く。

- [ ] **Step 1 — 現行の配線を固定:** RobotLifecycleIntegrationTestsへtestAppWiringDisablesLegacyIdleBeforeFreshWaitingを追加する。readyなMotionHarnessでidleEnabled=true/trackingEnabled=false、実VMをPlaybackIntegrationHarness(motion:)で作り、それを実ConversationAppCoordinatorへ渡す。idleSettingsにはRobotAppHarness同様に専用UserDefaults suiteを渡す。SwiftUIのConversationViewを作らず、onNeck由来の顔cueが無いことを前提にする。このready条件ではVM.initの.idleが旧期限をarmし、続くCoordinatorが消すという、本番初期化より強い分岐を通る。設定/背景で抑止して成功した扱いにせず、.idleのままfresh STATUSを保って12秒進める。

    await motionHarness.advanceFresh(by: 12)
    XCTAssertFalse(motionHarness.link.sent.contains { $0.priority == .idleMotion })
    XCTAssertFalse(motionHarness.sentCommands.contains { if case .move = $0 { true } else { false } })

  対照testLegacyIdleControlRunsWithoutAppCoordinatorは同じready条件と.idleでCoordinatorを通さず12秒進め、idle priorityのMOVEが1件以上出ることを確認する。前者は保持、後者は旧経路の検出力確認として撤去時に削除する。teardownを最後に行い、観測中にphaseを変えない。
- [ ] **Step 2 — 現行GREENを記録:** 次を実行し、両試験を含む選択3classが全件成功することを確認する。

    python3 /private/tmp/cat-refactor-20261107/run-tests.py t1-wiring-1 MotionCoordinatorTests FaceTrackingMotionTests RobotLifecycleIntegrationTests

- [ ] **Step 3 — 一時probe:** 新しいOFFER/ACKでMotionCoordinator.swiftのidleFaceDriven既定値1か所だけをtrueへ変更する。commitしない。Codexが同じ3classをprobe-1で実行し、全失敗case/assertionを一覧化する。これは依存探索であり、機能のREDや不明な失敗0とは報告しない。終了・after記録後にその1行を正確に復元し、sourceの復元を照合する。意図したprobeではprivate runnerの複製だけでcollect-test-diagnostics=neverを選べる。
- [ ] **Step 4 — 失敗を分類し移植:** 各caseを「旧scheduler固有なので削除」「現在も必要なので顔APIへ移植」「別原因を調査」に分類する。static cross-checkの6候補（interval/bounds、blocked idle、PWMを切らない、顔取得preemption、holding/searching、thermal）以外の失敗も漏らさない。上下限yaw±3°/pitch±2°、速度10、50ms間隔、無効化、PWM維持の主張は残し、現行コードでsetIdleFaceDriven(true)と明示cueを使って通す。4～10秒と乱数3～4秒の周期だけの主張は理由を付けて除く。単体にもface-driven有効・cueなし・fresh12秒でMOVEなしを追加する。
- [ ] **Step 5 — 移植GREEN後に交代:** 同じ3classをt1-ported-1で実行する。現行productionのまま移植後が全件成功したら、試験と分類記録だけをtest: pin face-driven motion contracts before cleanupとして先にcommitし、旧本番でのGREENを履歴に残す。分類表・入力を凍結してCodexへ撤去の編集権を渡す。
- [ ] **Step 6 — 撤去:** scheduler末尾、flag/setter/guard、nextIdleAtとその専用reset、MotionCoordinatorのrandom依存だけを除く。追尾のserviceAutonomous分岐・優先順・Column本体は維持。Composition/Coordinatorとtest callerの引数・setterだけを適応する。独立したRobotRandomSourceやidleEnabled設定は消さない。対照と純粋な周期試験の削除は分類表と一致させる。
- [ ] **Step 7 — GREEN/commit:** 同じ3classにFaceTrackingCoordinatorTests、ConversationIdleIntegrationTestsを加えてt1-after-1を実行する。新規Swift fileが無ければprojectを変えない。削除caseと保持/移植case、source前後不変、diff --checkを確認し、明示対象だけをcommitする。

    git commit -m "refactor: remove unused random idle scheduler"

### Task 2: 聞き返し専用の発話と所有者判定へ整理する

**Files:** CatRobot/Conversation/Integration/ConversationViewModel.swift、VoiceTurnLatencyRecorder.swift。試験は同じIntegration配下のConversationMemoryIntegrationTests.swift、VoiceTurnLatencyRecorderTests.swift（新規期待値のみ）。既存のRecovery/Latency/Routing/Policy/Playbackはオラクルを変えない。

**Interfaces:** Consumes: Task 1後も同じmotion/会話port。Produces: private askForClarification(candidate: String, generation: UInt64, turnID: UInt64) async、private classifyAndRespond(_ request: AddressClassificationRequest, wasCorrectingPending: Bool, generation: UInt64, turnID: UInt64) async。ConversationTurnOwner.isOwned(generation: UInt64, turnID: UInt64?, captureID: UInt64?) -> Boolは同期・純粋。VMのshutdown guardはその外に残す。

- [ ] **Step 1 — 特性を固定:** testClarificationFinishingAfterExpiryStillRecordsOriginalを追加する。speakerを止めたまま聞き返しに入り、注入clarificationDelayと時計で15秒を越えてpendingを失効させ、正常finishedを返す。trimした元候補→固定質問が1回保存され、generation呼出し/usage増加は0、認識再開と既存traceのambiguous終了を確認する。
- [ ] **Step 2 — 現行GREEN:** 下記class群をt2-before-1で実行する。

    python3 /private/tmp/cat-refactor-20261107/run-tests.py t2-before-1 ConversationLatencyTests ConversationRecoveryTests ConversationMemoryIntegrationTests ClarificationRoutingTests AddresseePolicyTests FacingAddressingTests VoiceTurnLatencyRecorderTests

- [ ] **Step 3 — 発話/分類の責務を抽出:** 単一callerのspeakAndResumeをaskForClarificationへ狭める。caption/発話はClarificationContext.question、memoryPromptは渡されたcandidateのtrimを保持する。発話中に消えるpendingから読み戻さない。正常speech→external record→所有権再確認→resume、失敗cleanup、mouth event順を維持。元からno-opだったtrace/latencyと.noneのengagement分岐を除き、生成の.arm/.refreshは残す。分類のtrace、初期snapshot、current guard、await順はそのまま抽出する。
- [ ] **Step 4 — 純粋owner判定を共有:** 既存switchと同じisOwnedを追加し、generation一致/不一致、turn/capture一致/不一致、nilのIDを表で固定する。recorderとVMを接続し、VMの!isShutdown/!isShuttingDownは残す。期限の>=と<は既存のまま変えない。
- [ ] **Step 5 — GREEN/commit:** Step 2のclass群をt2-after-1で実行し、全期待値/trace/cancel/記憶境界が同じことをNavigatorと確認してcommitする。

    git commit -m "refactor: specialize clarification speech and ownership checks"

### Task 3: 要約のbyte契約と明示的な前回要約を保つ

**Files:** CatRobot/Conversation/Services/Claude/ConversationSummaryResult.swift、ClaudeConversationService.swift。Test: CatRobotTests/Conversation/Services/Claude/ConversationInstructionsTests.swift、ClaudeSessionFactoryTests.swift。Instructions/SessionFactoryのモデル文字列は編集しない。

**Interfaces:** Produces: validatedText(previousSummary: String, characterLimit: Int) throws -> String（既定値なし）、ConversationSummaryResult.validatedSummary(_ text: String, characterLimit: Int) throws -> String。GeneratedConversationSummary.result(characterLimit:)とcompactは各境界の検証を維持。retained配列は一度だけ作り、referenceと戻り値で同じものを使う。

- [ ] **Step 1 — promptを独立したbytesで固定:** testSummaryReferencePromptPreservesExactUTF8を追加する。previousSummary="- 前"、evicted=(元,質問)、reference=(か\u{3099},返)、limit=1200。期待列はbuilderから導かず次の固定値とする。

    let expected = "これまでの記憶:\n- 前\n追加の会話:\n利用者: 元\nAI: 質問\n解釈のための参考（要約には含めない）:\n利用者: か\u{3099}\nAI: 返\n更新後の記憶だけを1200文字以内で出力してください。"
    XCTAssertEqual(Array(request.prompt.utf8), Array(expected.utf8))

- [ ] **Step 2 — 現行GREEN:** ConversationInstructionsTests、ClaudeSessionFactoryTests、ClaudeConversationServiceTests、ClaudeMemoryPersistenceTestsをt3-before-1で実行する。
- [ ] **Step 3 — 整理:** previousSummaryを必須化し、該当testで必要な空の前回値を明示する。Generated.resultは新しいvalidatedSummaryを直接呼び、本番でダミーのpreviousSummaryを渡さない。共通validatorはtrim/非空/文字数と同じmodelGenerationFailedを保つ。noContentは前回文字列をtrimせず返し、その文字数guardも残す。factory/serviceのどちらの検証も省かない。retain/splitやprompt文字列は変えない。
- [ ] **Step 4 — GREEN/モデル比較/commit:** 同じ4classをt3-after-1で実行する。続けて次の1methodを実行し、24fixtureと全source-text guardがbaselineと一致することを保存してcommitする。

    python3 /private/tmp/cat-refactor-20261107/run-tests.py t3-inventory-1 ClarificationHistoryModelTests/testFixtureInventoryAndPromptSizes
    git commit -m "refactor: make summary preservation explicit"

### Task 4: Supertonicのエラー変換を一か所へ集める

**Files:** CatRobot/Conversation/Services/Supertonic/SupertonicErrorMapper.swift、SupertonicSentenceSpeaker.swift。Test: CatRobotTests/Conversation/Services/SupertonicErrorMapperTests.swift。推論/再生/先読み本体は変えない。

**Interfaces:** Produces: static SupertonicErrorMapper.mapping<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T。Task/actorを新設せず、そのclosureを一度awaitして旧catch順のまま変換する。

- [ ] **Step 1 — 現行mapを固定:** missingAssets/invalidAssets/unsupportedVoice→speechVoiceUnavailable、inferenceFailedとdictionaryUnavailableとCancellationErrorの直接map→speechSynthesisFailedをassertし、SupertonicErrorMapperTestsをt4-map-before-1で成功させる。
- [ ] **Step 2 — 境界を抽出して固定:** 現在の3closureのdo/catchをmappingへ機械的に写し、success文字列/PCM値が同じ、operationは一度だけ、CancellationError→cancelled、辞書→synthesisFailedを試験する。この新API不存在のcompile失敗をREDとは呼ばない。t4-mapping-1でmapper全件をGREENにする。
- [ ] **Step 3 — callerを接続:** prepareのengine→辞書準備、normalize、synthesize(steps:8)をそれぞれ同じclosureでwrapperへ渡す。既存のキャンセルhandler・await順・生成option・音声presetは変えない。
- [ ] **Step 4 — GREEN/commit:** t4-after-1でSupertonicErrorMapperTests、SupertonicSentenceSpeakerTests、JapanesePronunciationServiceTests、SentenceReplyPlaybackTestsを実行しcommitする。

    git commit -m "refactor: centralize Supertonic error mapping"

### Task 5: 未使用adapterと試験supportを整理する

**Files:** CatRobot/Conversation/Domain/ConversationServices.swift、CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift。Test: CatRobotTests/Conversation/Integration/ConversationFakes.swift、CatRobotTests/Conversation/Services/FoundationModelAddressClassifierTests.swift、ClaudeTestDoubles.swift、Claude/ClaudeConversationServiceTests.swift。

**Interfaces:** Produces (test target only): AddressClassifying.classify(_ utterance: String) async throws -> AddressTarget（typed requestへ委譲）、@MainActor @discardableResult func pollUntil(timeout: Duration = .seconds(1), _ condition: @escaping @MainActor () async -> Bool) async -> Bool。harnessの@discardableResultも維持する。makeClaudeServiceの既存factory/store/usage/budgetにlongTerm: LongTermMemoryManager? = nil、tools: any ConversationToolProvider = StaticToolProvider([])、configuration: @escaping @Sendable () async -> ConversationModelConfiguration = { .init() }を追加する。

- [ ] **Step 1 — callerを再確認:** 本番の分類呼出しが全てAddressClassificationRequestであることと、AddressModelClientのString overloadが無参照であることをrgと実コードで確認する。T2/T3のGREENが前提。
- [ ] **Step 2 — adapter/fakeを整理:** model-clientのString overloadは削除、classifierのString overloadは既存ConversationFakesへ移す。FakeAddressClassifier.calls、private FakeAddressModelClientのprompts/requestCountはrequestsからの計算値にし、従来のassertionとerror fakeは維持する。
- [ ] **Step 3 — bounded待機とbuilder:** 既存と同じContinuousClock期限・最後のcondition確認・Task.yield間隔をpollUntilへ移し、harnessとsummary待機から委譲する。false時の既存XCTAssert/guard/messageを残し、gateの無制限待機へ置換しない。共通builderは従来のデフォルトを保ち、local makeServiceはRememberToolProvider/settings.currentを明示して委譲する。configuration gate付きbuilderも呼出し数/await位置を保って委譲する。
- [ ] **Step 4 — GREEN:** t5-after-1でFoundationModelAddressClassifierTests、RoutedAddressClassifierTests、AppCompositionTests、ClaudeConversationServiceTests、ClaudeMemoryPersistenceTests、ConversationViewModelTests、FacingAddressingTests、ConversationRecoveryTests、ClarificationRoutingTestsを実行する。t5-inventory-1で24fixtureの不変を再確認する。
- [ ] **Step 5 — commit:** 既存の期待値・件数・bounded待機を弱めていないことをNavigatorが確認しcommitする。

    git commit -m "refactor: simplify classifier and conversation test support"

### Task 6: 記憶の表示値と設定識別子を共有する

**Files:** CatRobot/Conversation/UI/ConversationViewState.swift、ConversationView.swift、CatRobot/App/ConversationSettingsView.swift、CameraTrackingSettingsPane.swift。Test: CatRobotTests/Conversation/UI/ConversationAccessibilityTests.swift。

**Interfaces:** Produces: ConversationViewState.memoryPresentation: ConversationMemoryPresentation（計算property、cacheなし）。ConversationSettingsIdentifierにfaceTrackingEnabled、faceTrackingStatus、faceTrackingYawCorrectionStepperを追加しraw stringは旧literalのまま。

- [ ] **Step 1 — raw値を固定:** accessibility testで3rawValueを旧literalと比較し、既存の宣言済みcontrol一覧に加える。新enum caseがまだ無いcompile errorをREDとはしない。画面のcontrol構成/順序/labelは変えない。
- [ ] **Step 2 — 共有:** 8か所のConversationMemoryPresentation(state:)だけをstate.memoryPresentationへ置換し、カメラpaneは新しい識別子を参照する。stored stateや表示条件は変えない。
- [ ] **Step 3 — GREEN/commit:** t6-after-1でConversationViewStateTests、ConversationMemoryPresentationTests、ConversationAccessibilityTests、FaceConversationPresentationTests、OnboardingSettingsTestsを実行する。

    git commit -m "refactor: share memory presentation and settings identifiers"

### Task 7: sceneと設定復帰・追尾鮮度の重複を整理する

**Files:** CatRobot/App/ConversationAppCoordinator.swift、AppRootView.swift、CatRobotApp.swift、CatRobot/FaceTracking/FaceTrackingCoordinator.swift。Test: CatRobotTests/Conversation/Integration/AppCompositionTests.swift、CatRobotTests/FaceTracking/FaceTrackingCoordinatorTests.swift（必要な特性の追加だけ）。

**Interfaces:** Produces: private sceneControlMode: RobotControlMode、updateRobotScene()、resumeAfterSettings()、permitsAction(allowWhileSleeping: Bool) -> Bool、AppRootView.init(composition: ConversationComposition, onboardingSettings: OnboardingSettings? = nil)、private FaceTrackingCoordinator.isFresh(_ observation: FaceObservation) -> BoolとfaceLossTimeout: TimeInterval = 10。

- [ ] **Step 1 — 境界を固定:** 現行のroot構築lazy試験は既にあるので、そのオラクルを保ち、新composition initの追加後にも同じmodel/認証/memory/capture非起動のassertionを適用する。追尾にはtestFreshnessHelperPreservesFutureEpsilonAndExpiryを追加する。新しいFaceTrackingHarnessごとにenvironmentとt=0のSTATUSを設定し、robotDrainで下側pose sampleを取り込む。clockは0から一度だけadvanceして、capturedAt=0の最初のframeを、now=(0.4-0.000001).nextDownで届ける場合はfollowing.count=1、now=0.4-0.000001の場合は0と固定する。statusFreshness=1なのでこの区間はfreshであり、0.1刻みのadvanceFreshを使って境界の丸めを変えない。別のharnessでもt=0のSTATUS/poseを先に取り込み、capturedAt=completedAt=0.0000005のframeをsource.emitで直接now=0に届ける（frame()はcompletedAt=nowにするので使わない）。clockを0.000002へ進めSTATUSを追加した後following.count=1を確認する。後者は微小future frameをpendingとして保持する既存契約であり、CameraSnapshot.isFreshへの置換を検出する。期待値を比較関数から導かず、現行でGREENを確認する。
- [ ] **Step 2 — 現行GREEN:** t7-before-1でAppCompositionTests、RobotLifecycleIntegrationTests、VoiceSettingsIntegrationTests、ConversationIdleIntegrationTests、FaceTrackingAppIntegrationTests、FaceTrackingCoordinatorTests、LookIntegrationTestsを実行する。
- [ ] **Step 3 — Coordinatorを整理:** sceneControlModeは各使用箇所でsettingsModel.setApplicationModeの後に評価し、事前letへ持ち上げない。updateRobotScene引数をなくす。resumeAfterSettingsはsettingsDidClose→updateRobotScene→wake lock→resumeの順。close側のupdateInactivityはその前に残す。permitsActionは既存short-circuit順で呼び、後半のcancel/actionSceneGeneration guardもそのまま。新しいawait/task/表示stateの統合はしない。
- [ ] **Step 4 — root/鮮度を整理:** composition initは既存initへ同じ全fieldをforwardし、live compositionを作り直さない。isFreshは既存のclock.now−capturedAt < imageFreshness−0.000001をそのまま使う。CameraSnapshot.isFreshへ置換しない。10秒はlossだけの定数とし、thermalの別の10秒へ結合しない。
- [ ] **Step 5 — GREEN/commit:** Step 2の全classをt7-after-1で実行する。設定・inactive/background・pending frame・lossの既存assertionと順序を確認してcommitする。

    git commit -m "refactor: consolidate scene and tracking policies"

### Task 8: 文書・最終自動検証・独立レビュー・後日の引継ぎ

**Files:** docs/architecture.md、docs/README.md、新規docs/validation/2026-11-07-behavior-preserving-refactor.md。必要な生成project出力のみ。過去の日時付きspec/plan・#29の静的application-flow snapshotは変更しない。

**Interfaces:** Consumes: T1～T7の候補・個別GREEN・分類表・model比較。Produces: branch最終commitと入力digest、初回レビュー/採否、未実施の実機確認一覧。個別task実施で必要な新規Swift fileを選ぶときは、先にfile単位の責務を合意してから生成器へ渡す。

- [ ] **Step 1 — 現行説明/記録:** architectureの旧「なあに？」と旧内蔵待機方式を現行に合わせ、抽出した責務を追記する。「なあに？」の修正はspec T2から文書をまとめるTask 8へ移した旨をvalidationに残す。索引へ今回のspec/plan/validationを追加する。validationには全task、probe/失敗分類/移植/削除の理由、実際のcommit/入力/件数、モデル0・端末0、後日の実機（待機・あくび・追尾・設定復帰）を記録し、利用者の個別設計承認を得たと書かない。
- [ ] **Step 2 — 生成と固定:** ruby scripts/generate_project.rbを2回、ruby scripts/test_generate_project.rbを実行し、2回の生成byte一致/契約成功を確認する。新規fileが無い場合は基点projectとの無変更も確認する。git diff --check、Package.resolved・資産・vendor・旧runnerの不変、モデルliteral/Guide/type名を照合し候補を凍結する。
- [ ] **Step 3 — 全通常suiteとinventory:** full-1をclass指定なしで実行し、3device/paid classを除外した実数/skip/failed/expectedFailuresを記録する。final-inventory-1で24fixtureを比較する。入力前後不変と全選択の実行を確かめる。T1で消したcase数と新規case数をbaseline1039と対応付ける。

    python3 /private/tmp/cat-refactor-20261107/run-tests.py full-1
    python3 /private/tmp/cat-refactor-20261107/run-tests.py final-inventory-1 ClarificationHistoryModelTests/testFixtureInventoryAndPromptSizes
    python3 -m unittest discover -s scripts -p 'test_*.py'

- [ ] **Step 4 — device-only compileと通常署名build:** pinned SourcePackagesを使い自動package更新を無効にする。generic platform=iOSのbuild-for-testingでdevice-only試験本体をcompileする（実行しない）。generic destinationがtest buildを拒否した場合は、同じiphoneos SDKでCatRobotTests targetのbuildに切り替え、実際のcommand/制約を記録する。別のDerivedDataで通常Debug署名buildを行いcodesignを検証する。実機ID・devicectl・install/launchは使わない。compile成功を実機合格と呼ばない。
- [ ] **Step 5 — 独立した初回:** 同じ凍結候補の全差分3699ef13..候補を渡し、Claudeは実際の/simplify report-onlyを再利用/簡素化/効率/Altitudeの新しい4contextで実施、Codexはrequesting-code-reviewにより新しい独立レビュアー1名へ読取依頼する。再委任・source変更・build/device/モデル呼出しは禁止。双方の初回とSHAを保存するまで交換しない。
- [ ] **Step 6 — 受領/修正:** receiving-code-reviewで指摘ごとの採否・重大度・重複・根拠を残す。Critical/Importantを解消する。挙動不具合はまず意味のある再現失敗を確認し、役割/対象を確定して直す。変更範囲に必要な再検証を行い、文書だけの修正で全suiteを繰り返さない。限定修正は同じreviewerへ戻し初回を上書きしない。
- [ ] **Step 7 — 最終記録commit/引継ぎ:** 最終の文書とverdictを確認して明示ファイルのみcommitし、commitの全blobと検証候補を照合する。main3699ef13を保持、branchをpushせず、managed/他worktreeを削除しない。実機確認は利用者指定により後日として残し、必要な通常版再build/install/voice/neck確認の対象を記録する。

    git commit -m "docs: record autonomous refactor validation and device follow-up"

## セルフレビューと最初の実行境界

- specのT1～T7を同じ番号で実装し、T1の例外・入力不変・後日の端末確認はTask 8に統合する。
- モデルのwire bytesや実token/請求額、物理の安全性を新たに計測したとは記載しない。非有限clockの>=と!(<)の差、未使用routeのための所有権再設計も持ち込まない。
- 初稿をClaude NavigatorへSHA付きで送り、型/対象/試験の確認を受ける。合意後に計画をcommitし、T1の最初のsource編集を新しいOFFER/ACKでClaudeへ渡す。ユーザーへの質問待ちは作らない。
