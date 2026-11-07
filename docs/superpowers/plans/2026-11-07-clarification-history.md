# Clarification History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execution is the agreed Codex/Claude Driver–Navigator pair; the final independent review is separate.

**Goal:** 聞き返し前後の実発言を重複なく保存し、確認回答の文意をHaiku・返答・要約のモデルへ伝える。

**Architecture:** 分類要求で実発言と任意の聞き返し文脈を分け、確認待ち中の非対面入力だけHaikuへ送る。VMは既存pendingの期限と所有権を保ち、生成には実発言だけを渡す。要約には保持側の往復を解釈用に添え、構造化された「残す内容なし」を通常の生成失敗と区別する。

**Tech Stack:** 既存のSwift 6 / iOS 27 / FoundationModels / ClaudeForFoundationModels 0.2.3 / XCTest。依存・音声資産・モデル定数は追加・更新しない。

**Spec:** [承認済み設計](../specs/2026-11-07-clarification-history-design.md)。commit `095d1d3ec8a6225e15ce0d4088122066dd7b5b3a`、SHA-256 `a2ef08ce88f31d359fc72c0153eb0dd07ad3bcbd3dea1ec10175be6af9128a84`。

## Global Constraints

- 「パターンマッチ（肯定語・否定語の一覧）では判定しない。」フィラーの一覧は今回変えない。
- 「promptは常に今回の実際の発言。元の発言を再送しない。」分類用文脈をprompt・保存履歴に連結しない。
- 「保存形式（`ConversationMemoryTurn`の`prompt`と`response`、schema 1）。移行は不要。」互換IDも既存の`claude-memory-v1`を維持する。
- 「15秒の確認待ちと期限、30秒・最大5分の会話継続窓、顔向きと人数の条件。」否定への返答後も既存どおりarm/refreshする。
- 「残すのは同じ元の発言・同じ期限・同じ期限監視で、作り直したり15秒を延ばしたりしない。」期限は振り分け開始時に判定する。
- 「聞き返しを記録する時点（読み上げの正常完了後）。読み上げの途中・失敗・取消・未完了では記録しない。」通常生成は生成確定時に記録する。
- 「履歴の渡し方（system指示文の中の『利用者:／猫:』の文字列）。役割付きのtranscriptで復元する変更はしない（#27の範囲）。」
- 保存失敗・再試行、`sessionEpoch`/`operationEpoch`、停止・新しい会話・forgetの防御を維持する。代替モデルへClaudeの文脈を渡す変更はしない。
- 現ブランチ`codex/issue-29-clarification-history`と管理されたworktreeを保持する。承認済みspecは凍結し、仕様変更が必要なら利用者承認を経る。
- **現在の編集権はこの計画ファイルのみ。** 計画のレビュー・承認と実装HANDOFF ACKが済むまで、ソース・テスト・生成プロジェクトを変更しない。`.codex/`と秘密情報をcommitしない。
- ソースのwriterは常に1名。検証中は双方とも入力を凍結する。xcodebuild・実機操作の実行者はCodex。mainへのsquashまでが統合対象で、pushは利用者承認後。

## Review Focus

1. 確認待ち開始から14.9秒後に始めた分類が期限後に完了しても、確認待ちの復活・再聞き返し・停止後の生成を起こさない（Task 2の期限競合試験）。
2. 家族宛てや宛先不明の発言を複数回はさんでも、同じ元発言への本人の返事を元の期限内に扱う（Task 2のpending維持試験）。
3. 肯定/否定が圧縮の保持側にあり、さらに4,000字を超える往復が残っても、要約が確認結果を見失わず参考の新事実を混入させない（Task 3/4）。
4. 全ての要約対象が未確認・否定済みでも正常に圧縮でき、前回の要約を空配列だけで消さず、壊れた空生成や通信失敗は成功にしない（Task 3/4）。
5. 文字のフィラー、生成確定後の読み上げ失敗・取消、保存失敗を、それぞれ正しい履歴/usageとして扱う（Task 2の統合試験）。

## ファイルと役割

| 対象 | 役割・変更 |
| --- | --- |
| 新規 `CatRobot/Conversation/Domain/AddressClassificationRequest.swift` | 実発言と一時的な聞き返し文脈の値型。保存状態は追加しない |
| `Domain/ConversationServices.swift`、`Services/FoundationModelAddressClassifier.swift` | 分類要求を渡すprotocolと既存の結果・エラー変換。端末内の指示文は不変 |
| `Services/Claude/ClaudeAddressClassifier.swift`、`App/ConversationComposition.swift` | 文脈の有無によるルーティング、Haikuの通常入力と確認回答入力、実際の組立て |
| `Domain/AddresseePolicy.swift`、`Integration/ConversationViewModel.swift` | 肯定/否定語経路の撤去、開始時文脈の採取、元期限のpending維持 |
| `Services/Claude/ConversationInstructions.swift` | 返答とrememberに対する確認回答の扱い |
| 新規 `Services/Claude/ConversationSummaryResult.swift` | 構造化要約の出力、正常0件、本文の検証 |
| `Services/Claude/ConversationSessionFactory.swift`、`ClaudeSessionFactory.swift`、`ClaudeConversationService.swift` | 参考往復つき要約要求、構造化生成、検証済みの空要約を保存 |
| `CatRobotTests/Conversation/Services/{FoundationModelAddressClassifierTests.swift,ClaudeTestDoubles.swift}`、`Integration/ConversationFakes.swift` | 要求記録・ゲート・型変更を既存のfakeへ集約 |
| `CatRobotTests/Conversation/Services/Claude/{RoutedAddressClassifierTests.swift,ConversationInstructionsTests.swift,ClaudeSessionFactoryTests.swift,ClaudeConversationServiceTests.swift,ClaudeMemoryPersistenceTests.swift}` | 分類境界・要約・保存の検証 |
| `CatRobotTests/Conversation/{Domain/AddresseePolicyTests.swift,Integration/FacingAddressingTests.swift,Integration/ConversationMemoryIntegrationTests.swift,Integration/ClaudePlaybackMemoryTests.swift,Integration/AppCompositionTests.swift}` | VM、実組立て、寿命、保存・再生との統合 |
| 新規 `CatRobotTests/Conversation/Integration/ClarificationRoutingTests.swift` | 制御可能な分類ゲートを使う期限・取消の統合試験 |
| 新規 `CatRobotTests/Device/ClarificationHistoryModelTests.swift`、`scripts/run_clarification_history_model_tests.sh` | 明示実行する有料API試験と結果回収。通常suiteから除外 |
| `CatRobot.xcodeproj/` | `scripts/generate_project.rb`で再生成。手編集せず`Package.resolved`を保持 |
| `README.md`、`docs/README.md`、旧#23設計、`docs/application-flow.html`、新規`docs/validation/2026-11-07-clarification-history.md` | 現行説明、旧仕様の注記、図と検証結果。承認済み#29設計は変更しない |

上表で省略したアプリ内のパスは`CatRobot/Conversation/`基準（`App/`だけ`CatRobot/`基準）。責務外のファイル整理は行わない。

## 実行・交代・検証の共通手順

| 区切り | REDのDriver | GREENのDriver | GREEN後 |
| --- | --- | --- | --- |
| Task 1 分類要求とHaikuルート | Codex | Claude | ClaudeがTask 2のREDを担当 |
| Task 2 VM・実発言・履歴 | Claude | Codex | CodexがTask 3のREDを担当 |
| Task 3 構造化要約・圧縮 | Codex | Claude | Codexへモデル試験用ファイルの編集権を移す |
| Task 4 実モデル確認 | Codex | 修正が必要なら対象を明記して交代 | 成功候補を凍結し、ClaudeへTask 5文書を移す |
| Task 5 文書・全体確認 | Claudeが文書、Codexが検証実行 | 指摘修正はHANDOFFで1名を指定 | 独立レビュー、実機受入、承認範囲の統合 |

- 各REDは意図した挙動のassertion失敗を保存する。新しい型の宣言だけによるコンパイル失敗では終えず、旧挙動を保つ署名アダプタまで用意して原因を確認する。
- 各HANDOFFは旧Driverの書込み停止、対象/HEAD/入力digest/試験結果/次手の通知、新Driverの復唱ACKの順。15〜30分が経過したら、実行中の検証を終えた最初の安全な区切りでも交代する。
- Swift変更後は`ruby scripts/generate_project.rb`、`ruby scripts/test_generate_project.rb`を実行し、再生成を繰り返して差分が増えないことを確認する。
- 各build/testの前後に`git diff --binary HEAD`のSHAと対象ソース・テスト・project・scriptsの実ファイルSHAを比較し、HEADとともに保存する。新規ファイルもdigestへ入れる。入力が変わればその結果を変更後の成功とは扱わない。
- GREEN後のDriverがそのTaskのFilesと生成プロジェクトだけをstageし、指定のcommitを作る。独立レビューの候補は全Taskの差分であり、REDの作業途中を製品の合格候補としない。

最初に`xcrun simctl list devices available`でiOS 27のSimulatorを選び、`ISSUE29_SIMULATOR_UDID`へ設定する。固定UDIDを計画へ埋め込まない。検証記録は`/private/tmp/cat-issue29-clarification-20261107/`へ置く。

```sh
ISSUE29_DERIVED=/private/tmp/cat-issue29-clarification-20261107/SimulatorDerived
issue29_test() {
  xcodebuild -project CatRobot.xcodeproj -scheme CatRobot \
    -destination "platform=iOS Simulator,id=${ISSUE29_SIMULATOR_UDID}" \
    -derivedDataPath "$ISSUE29_DERIVED" -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO "$@" test
}
```

以後の`issue29_test`はCodexが実行し、フェーズ別のログ・xcresult・入力digestを保存する。最初のベースラインはTask 1〜3が挙げる既存クラスを実行し、既存の失敗があれば先に切り分ける。この計画を書く段階で試験を実行済みとはしない。

### Task 1: 分類要求と、確認待ち専用のHaiku経路

**Files:** 新規`Domain/AddressClassificationRequest.swift`。変更は`ConversationServices.swift`、`FoundationModelAddressClassifier.swift`、`ClaudeAddressClassifier.swift`、`ConversationComposition.swift`、分類器の2テスト、`RoutedAddressClassifierTests.swift`、`AppCompositionTests.swift`、`ConversationFakes.swift`、生成project。

**Interfaces:** 以下の名前を後続Taskでも使う。

Consumes: 既存の`AddressTarget`/`GeneratedAddressTarget`とavailability。Produces: 下記の要求型、2つの分類protocol、文脈の有無で選ぶ実routerと組立てfactory。

```swift
struct ClarificationContext: Equatable, Sendable {
    static let question = "今の、ぼくに言った？"
    let originalUtterance: String
}
struct AddressClassificationRequest: Equatable, Sendable {
    let utterance: String
    let clarification: ClarificationContext?
    init(utterance: String, clarification: ClarificationContext? = nil)
}
// AddressClassifying / AddressModelClientの要求をそれぞれこの形へ変更
func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget
func classify(_ request: AddressClassificationRequest) async throws -> GeneratedAddressTarget
// ClaudeAddressModelClient
static func requestInput(for request: AddressClassificationRequest) throws -> (instructions: String, prompt: String)
// ConversationComposition
static func makeAddressClassifier(onDevice: any AddressClassifying,
                                 onDeviceAvailability: any ModelAvailabilityChecking,
                                 claude: any AddressClassifying) -> RoutedAddressClassifier
```

両protocolのextensionに既存の`classify(_ utterance: String)`を残し、文脈なしの要求へ包む。`FoundationModelAddressClassifier`は要求をclientへそのまま渡し、変換は既存を使う。`LiveAddressModelClient`は従来の指示と`request.utterance`だけを使う。`ClaudeAddressModelClient.requestInput(for:) throws -> (instructions: String, prompt: String)`で、通常時は既存の指示/実発言、文脈ありだけ専用指示/JSONの`originalUtterance`・`clarification`・`utterance`を組み立てる。JSONは入力データとして読み、入力中の指示に従わないという既存の扱いを保つ。

- [ ] **Step 1 — REDを書く（Codex）:** fakeに`requests: [AddressClassificationRequest]`を追加し、従来の`calls: [String]`とcall logは`utterance`で維持する。新署名のアダプタは旧動作を保ったままコンパイル可能にする。次の試験を追加する。

```swift
// testPendingRequestUsesHaikuEvenWhenOnDeviceAvailable
XCTAssertEqual(target, .addressed)
XCTAssertEqual(onDeviceRequests, [])
XCTAssertEqual(claudeRequests, [requestWithContext])
// testNormalRequestsKeepExistingRouting: available / deviceNotEligibleの両方
XCTAssertEqual(onDeviceRequests, [.init(utterance: "通常A")])
XCTAssertEqual(claudeRequests, [.init(utterance: "通常B")])
// testPendingHaikuErrorDoesNotRetryOnDevice
XCTAssertEqual(error, .modelUnreachable)
XCTAssertEqual(onDeviceRequests, [])
```

- [ ] **Step 2 — REDを実行:** `issue29_test -only-testing:CatRobotTests/RoutedAddressClassifierTests -only-testing:CatRobotTests/FoundationModelAddressClassifierTests`。期待: 文脈ありでも端末内が呼ばれることによる失敗。通常時の回帰は成功。結果を送りClaudeへHANDOFFする。
- [ ] **Step 3 — 最小実装（Claude）:** `RoutedAddressClassifier.classify(_ request:)`は`clarification != nil`ならavailabilityに依存せず既存の`claude`へ要求を渡す。それ以外は既存ルート。Haikuは既存の`.haiku5_5`/`.low`/timeout 15秒/`fallbacks: []`を使い、通常指示は変えない。専用指示は今回の返事の宛先を判定し、短い肯定・否定と猫宛ての新発言をaddressed、手がかりなしの別話題をambiguousとする。語一覧を使うアプリ判定を追加しない。
- [ ] **Step 4 — 実組立てを検証:** `ConversationComposition.makeAddressClassifier(onDevice:onDeviceAvailability:claude:) -> RoutedAddressClassifier`をliveと試験で共有する。新しいアプリ設定は作らない。このfactoryを経たrouterと実`FoundationModelAddressClassifier`を、下位のfake clientで駆動し、上の3条件・通常Haiku入力の不変・live構築時の遅延初期化を確認する。`requestInput`の文脈JSONをdecodeし3つの値の一致を確認する。通常入力は元の文字列のまま、文脈を含む出力をVM/履歴へ返すAPIはない。
- [ ] **Step 5 — GREEN/commit:** Step 2の2クラスと`AppCompositionTests`を再実行して失敗0。`git diff --check`後、当TaskのFilesだけをstageし`git commit -m "feat: route clarification replies to contextual Haiku classification"`。ClaudeがTask 2のREDへ進むことを通知する。

### Task 2: 実発言で生成し、元の期限の確認待ちを維持する

**Files:** `AddresseePolicy.swift`、`ConversationViewModel.swift`、`ConversationInstructions.swift`、`ConversationInstructionsTests.swift`、`ConversationFakes.swift`、`AddresseePolicyTests.swift`、`FacingAddressingTests.swift`、`ConversationMemoryIntegrationTests.swift`、`ClaudePlaybackMemoryTests.swift`、新規`ClarificationRoutingTests.swift`、生成project。

**Interfaces:** Task 1の要求を使用。`ConversationHarness.init`へ`classifierOverride: (any AddressClassifying)? = nil`を加え、既存fakeは保持しつつ、指定時は共有factoryの実routerをVMへ注入する。fake分類器へ任意の`ConversationTestGate`と失敗を設定できるようにし、既存の時計/`clarificationDelay`を利用する。新しい製品のpendingフラグは作らない。

Consumes: Task 1の`AddressClassificationRequest`/`ClarificationContext`。Produces: 既存`performTurn(_:generation:turnID:) async`から、実発言だけを`generateReply(to:engagementUpdate:generation:turnID:) async`へ渡す経路と、期限を維持するpendingの振る舞い。

- [ ] **Step 1 — REDを書く（Claude）:** 旧「肯定で元発言再送・否定でdismiss」の試験を新規則へ置き換える。固定語4種だけでなく「言ったよ」「違うよ、ママに言ったの」「猫ちゃん、別の質問」を同じルートで扱う。

```swift
// testPendingSpeechUsesActualWordsWithoutYesNoRewrite
XCTAssertEqual(policy.route("はい", at: 2, engagement: .inactive,
                          pending: pending, isFacingScreen: true), .accept("はい"))
XCTAssertEqual(policy.route("いいえ", at: 2, engagement: .inactive,
                          pending: pending, isFacingScreen: false), .classify("いいえ"))
// testNegativeReplyCommitsActualFollowupOnce（実VM+実Claude記憶、モデルだけfake）
XCTAssertEqual(client.prompts, ["いいえ、あなたには言ってない"])
XCTAssertEqual(savedTurns, [clarificationTurn, negativeTurn])
XCTAssertEqual(chargedTurns, 1)
// testExcludedRepliesKeepOriginalPendingUntilExpiry
XCTAssertEqual(contextsForFollowups, [originalContext, originalContext, originalContext])
XCTAssertEqual(fixedClarificationsSpoken, 1)
XCTAssertEqual(generatedPrompts, ["言ったよ"])
```

- [ ] **Step 2 — REDを実行:** `issue29_test -only-testing:CatRobotTests/AddresseePolicyTests -only-testing:CatRobotTests/FacingAddressingTests -only-testing:CatRobotTests/ConversationMemoryIntegrationTests -only-testing:CatRobotTests/ClarificationRoutingTests -only-testing:CatRobotTests/ConversationInstructionsTests`。期待: 再送/dismiss、文脈なし、途中の除外によるpending消失のassertion失敗。確認後CodexへHANDOFFする。
- [ ] **Step 3 — 最小実装（Codex）:** 肯定/否定語と`.dismissPending`を削除する。VMは期限確認後・最初のawait前に`ClarificationContext`と開始時の確認待ち有無を固定し、分類要求へ入れる。分類開始時のclearを外し、addressedまたは対面の生成開始でclearする。notAddressed/ambiguousは元のpendingと期限監視を変更しない。開始時が確認待ちなら、await後に期限切れでも追加の聞き返しをしない。既存の`isCurrent(generation, turnID:)`/取消guard、失敗cleanupと寿命処理を維持する。聞き返しは`ClarificationContext.question`を共有する。
- [ ] **Step 4 — 返答と記憶の境界を検証:** `ConversationInstructions`の固定前方へ、肯定→元発言へ回答、否定→短い受け止め、生成へ届いた別話題→新しい話題、未確認/否定の元発言→利用者の事実・未解決の質問・remember対象にしない、を追加する。systemの履歴形式は維持する。`ConversationInstructionsTests`の`testFixedPrefixDoesNotChangeWithMemory`と`testSectionsAppearInOrderAndEmptyOnesAreOmitted`をこのTaskで確認し、指示と記憶の配置・固定前方の安定を維持する。新しい文言を単に検索するだけの試験は増やさない。fake返答による統合試験は配線/記録の検証であり、意味理解はTask 4で検証する。

```swift
// testPendingClassifierFinishesAfterExpiry: targetを3結果で表駆動
XCTAssertEqual(postExpiryReclarifications, 0) // 14.9秒開始→15秒満了→15.1秒完了
if target != .addressed { XCTAssertNil(nextRequest.clarification) }
XCTAssertEqual(generatedPrompts, target == .addressed ? [actualFollowup] : [])
// testPendingClassifierCannotOutliveLifecycle（pause/typed/new/forget）
XCTAssertEqual(lateGeneratedPrompts, [])
XCTAssertEqual(lateRecognizerRestarts, 0)
// testTypedFillerIsSubmittedAndEmptyTypedInputIsNot
XCTAssertEqual(typedPrompts, ["えっと"])
// testSpeechFailureOrCancellationAfterCommitKeepsHistoryAndUsage
XCTAssertEqual(savedTurns.count, 2) // 聞き返し+生成済みの返事
XCTAssertEqual(chargedTurns, 1)
```

試験時計は`emitCompletedUtterance`が1.2秒進める点を考慮し、**VMが振り分けを始める時刻**を確認待ち作成時刻`T`に対する`T+14.9`/`T+15.0`へ合わせる。上の試験例の秒数もこの相対時刻を指す。期限監視はゲートで制御し実時間15秒を待たない。除外2回→本人、フィラー→本人、期限ちょうどの通常分類、Haiku失敗→pending解除、対面→分類器0回、否定の成功後の30秒/最大5分の継続、開始時の4,000字超入力・従来の入力上限も維持する。失敗/取消の確定前は履歴/usage追加0、保存失敗時はメモリ内追加とunsaved/retryを確認する。再生失敗/取消は先に生成の保存/usage確定を待ち、未完了speakerを終了させて巻戻しがないことを確認する。ゲートは後始末で必ず開き、取消を待つ処理を閉じたゲートで待ち続けない。

```swift
// testPendingReplyFallbackRecordsActualFollowupWithZeroClaudeUsage
XCTAssertEqual(secondaryPrompts, [actualFollowup])
XCTAssertEqual(savedTurns, [clarificationTurn, .init(prompt: actualFollowup, response: notice + body)])
XCTAssertEqual(chargedTurns, 0)
```

- [ ] **Step 5 — GREEN/commit:** Step 2の5クラスに`ClaudePlaybackMemoryTests`、`ConversationRecoveryTests`、`ConversationNewSessionTests`を加え、失敗0。聞き返し未完了・復元・停止/forget競合の既存試験を削らない。当TaskのFilesだけをstageし`git commit -m "feat: preserve actual clarification replies and pending lifetime"`。CodexがTask 3のREDを担当する。

### Task 3: 保持側を参照する要約と、正常な0件

**Files:** 新規`Services/Claude/ConversationSummaryResult.swift`、`ConversationSessionFactory.swift`、`ClaudeSessionFactory.swift`、`ClaudeConversationService.swift`、`ClaudeTestDoubles.swift`、`ConversationInstructionsTests.swift`、`ClaudeSessionFactoryTests.swift`、`ClaudeConversationServiceTests.swift`、`ClaudeMemoryPersistenceTests.swift`、生成project。

**Interfaces / 決定する方式:** 保存schemaを変えず、API境界を型で区別する。

Consumes: 既存の`ShortTermMemory`/`ConversationMemoryTurn`と要約要求。Produces: 下記の型付き要約結果、`referenceTurns`を含む要求、正常0件も保存/復元できる圧縮経路。

```swift
enum ConversationSummaryResult: Equatable, Sendable {
    case noContent
    case text(String)
    func validatedText(previousSummary: String = "", characterLimit: Int) throws -> String
}
@Generable struct GeneratedConversationSummary: Sendable {
    @Guide(description: "残す事実や会話の要点。残すものが無ければ空配列")
    var items: [String]
    func result(characterLimit: Int) throws -> ConversationSummaryResult
}
// ConversationSessionFactoryと2つのconformerを変更
func summarize(_ request: ConversationSummaryRequest) async throws -> ConversationSummaryResult
```

`items == []`だけを`.noContent`とし、非空配列は各項目をtrimして空項目を拒否、`- `を付け改行で結合して`.text`にする。`validatedText`は`.noContent`なら渡された`previousSummary`をそのまま返す（既定の空文字列なら正常な空要約）。`.text`はtrim後の非空と全体が引数`characterLimit`（既定1,200文字）以下であることを検査し、不正なら既存の`modelGenerationFailed`。保持する`previousSummary`も文字数上限を超える場合は拒否する。SDKのparse/通信/取消の失敗はthrowのまま。`ConversationSummaryRequest.referenceTurns: [ConversationMemoryTurn] = []`を追加し、空なら従来のprompt形式を維持、非空なら「解釈のための参考。ここから新しい項目を要約へ追加しない」として別節に全文を渡す。

**前回要約の保護（Navigator I1、案aを採用）:** `compact`は常に`validatedText(previousSummary: original.summary, characterLimit: budget.summaryCharacterLimit)`を呼ぶ。前回要約があるときの空配列は「今回は追加・置換する本文がない」と解釈し、前回要約を消さず圧縮と返答を続ける。非空の`.text`は従来どおり更新後の要約全体として置き換える。この保護には、モデルの空配列だけでは前回要約の全項目を消せない制約がある。古い事実を全て撤回した場合まで正しく表現できるとは主張せず、明示的な新しい会話/全削除の既存経路は維持する。意味に基づくアプリ側の選別は追加しない。

- [ ] **Step 1 — REDを書く（Codex）:** 型とconformerの署名アダプタは旧検証を維持してcompileを通す。stubの`summaries`を`[ConversationSummaryResult]`へ更新し、既存1箇所の文字列指定も`.text("memory-1")`にする。

```swift
// testStructuredSummaryAcceptsOnlyExplicitNoContent
XCTAssertEqual(try GeneratedConversationSummary(items: []).result(characterLimit: 1200), .noContent)
XCTAssertThrowsError(try GeneratedConversationSummary(items: [" "]).result(characterLimit: 1200))
XCTAssertThrowsError(try ConversationSummaryResult.text("").validatedText(characterLimit: 1200))
XCTAssertThrowsError(try ConversationSummaryResult.text(String(repeating: "x", count: 1201)).validatedText(characterLimit: 1200))
// testCompactionReferencesConfirmationAcrossBoundary（retainedCharacters=45）
XCTAssertEqual(request.evictedTurns, [originalAndClarification])
XCTAssertEqual(request.referenceTurns, [confirmationAndReply, laterTurn])
// testNoContentCompactionCommitsReplyAndRestoresEmptySummary
XCTAssertEqual(savedSummary, "")
XCTAssertEqual(savedTurns, retainedTurns + [newTurn])
XCTAssertEqual(chargedTurns, 1)
// testNoContentPreservesExistingSummaryAndCommitsReply
let previousSummary = "- 好きな飲み物は紅茶"
XCTAssertEqual(try ConversationSummaryResult.noContent.validatedText(previousSummary: previousSummary, characterLimit: 1200), previousSummary)
XCTAssertEqual(savedSummary, previousSummary)
XCTAssertEqual(savedTurns, retainedTurns + [newTurn])
XCTAssertEqual(chargedTurns, 1)
// testNonemptySummaryCanReplacePreviousSummary
XCTAssertEqual(try ConversationSummaryResult.text("- 好きな飲み物はコーヒー").validatedText(previousSummary: previousSummary, characterLimit: 1200), "- 好きな飲み物はコーヒー")
```

- [ ] **Step 2 — REDを実行:** `issue29_test -only-testing:CatRobotTests/ConversationInstructionsTests -only-testing:CatRobotTests/ClaudeSessionFactoryTests -only-testing:CatRobotTests/ClaudeConversationServiceTests -only-testing:CatRobotTests/ClaudeMemoryPersistenceTests`。期待: 参考往復の欠落/正常0件の拒否/空配列での前回要約の消失。確認してClaudeへHANDOFFする。
- [ ] **Step 3 — 最小実装（Claude）:** `compact`は既存のkeepFromでevictedとreferenceを分ける。切り詰めず同じcandidateから採る。factoryは既存Haiku/lowで`respond(to:generating: GeneratedConversationSummary.self,options:)`を使い、resultへ変換する。構造化出力にはJSONの構造も必要なため、`ClaudeSessionFactory.summaryMaximumResponseTokens = 4_096`を定義して要約だけの上限に使う（旧既定は`1_200 * 2 = 2_400`）。これはparse成功を保証する値ではなく、上限付近の実token使用量・打切り率は未計測として記録する。`compact`は前項の引数つき`validatedText`を通す。candidateの確定・session無効化・保存の順序は既存を維持する。指示はpreviousSummaryを引き継ぎ更新後の全体を返すこと、evictedだけが追加対象であること、referenceは確認/訂正の解釈用であることを明示する。
- [ ] **Step 4 — 境界と失敗を検証:** `budget = .init(compactionTriggerCharacters: 60, retainedCharacters: 45)`、元発言「私はピーナッツアレルギーです」→固定聞き返し、保持側「うん、私のこと」→「わかったよ。」、後続30字+返答6字のfixtureをsnapshotにseedし、次の生成前にkeepFrom=1を作る。同じ位置の否定でも確認し、別fixtureで保持側5,002文字が切れずに渡ることを確認する。正常0件後の保存/retry/復元、前回要約あり+`.noContent`で前回要約/retained/newTurn/usageが保存・復元されること、非空`.text`での旧summary更新、`.text`がちょうど1,200字の場合の受理、空白/1,201字の拒否、SDKのparse/出力打切り/通信のthrowとforget競合で候補が確定しないことを確認する。fake要約の意味理解や実token予算の十分性は主張せず、入力分割・検証・確定を検証する。
- [ ] **Step 5 — GREEN/commit:** Step 2の4クラスと`ConversationMemoryIntegrationTests`、`OnDeviceFallbackReplyGeneratorTests`が失敗0。schema 1と互換ID不変を保存snapshotでも確認。当TaskのFilesだけをstageし`git commit -m "feat: summarize clarification context with explicit empty results"`。CodexへTask 4の編集権をHANDOFFする。

### Task 4: 固定した実モデル確認を実行する

**Files:** 新規`CatRobotTests/Device/ClarificationHistoryModelTests.swift`、`scripts/run_clarification_history_model_tests.sh`、生成project、`docs/validation/2026-11-07-clarification-history.md`。製品の修正が必要なら別HANDOFFで対象を指定する。

**Interfaces:** `ClarificationHistoryModelTests.testAcceptanceMatrix() async throws`。runnerは`<Xcode-device-ID> <CoreDevice-ID>`を受け、`CLARIFICATION_HISTORY_MODEL_TESTS=1`とUUIDの`CLARIFICATION_HISTORY_RUN_ID`を複製したxctestrunにだけ渡す。testは未設定/Simulator/非Debugではskip。既存`ClaudeAuthConfiguration.live()`を使い、test側のin-memory記憶/remember writerへ限定する。秘密情報をログや引数へ出さない。

Consumes: Task 1の本番Haiku client、Task 2の返答指示、Task 3の本番summary factory。Produces: runID別の全試行・tool呼出し・合否のJSONとxcresult。実行時だけ使う環境変数を製品UIや通常起動へ持ち込まない。

- [ ] **Step 1 — 実行前に固定（Codex、Claude確認）:** 次のfixture、各3回、期待値と判定方法を版管理する。1回目の受入セットは**分類39 + 返答18 + 要約15 = 72試行（Haiku 54、Opus 18）**。初稿の69試行へ、前回要約あり+否定済みの要約3試行を追加した。これは最上位の要求の数で、toolの結果を返す追加往復などを含むAPIリクエスト数や実請求額の上限ではない。**実行前にClaudeから利用者へ、件数・モデル内訳と、確認済みの最新単価/想定token数を前提にした概算を示す。** 未確認の金額は断定せず、追加tool往復と再検証の費用を区別する。fixture/指示文/モデル定数/SDK revision/HEAD/実入力digest/回数を記録し、Navigatorと一致を確認してから実行する。

| 分類のfixture（元発言「今日の天気はどう？」+固定聞き返し） | 期待値・3回全て必須 |
| --- | --- |
| はい / うん / いいえ / ううん（4件） | addressed |
| 言ったよ / そうそう、天気の / いいえ、あなたには言ってない / 違うよ、ママに言ったの（4件） | addressed |
| 猫ちゃん、5たす4はいくつ？ | addressed |
| 明日の予定は？ | ambiguous |
| ママ、鍵はどこ？ / これは独り言。疲れたな。（2件） | notAddressed |
| 部長に電話しておいて。（宛先を特定できない周辺の話） | notAddressed または ambiguous、addressedは不可 |

返答モデルは既存の`.opus5_5`/`.low`、本番`ConversationInstructions`とin-memoryのrememberだけを使う。6件を各3回: 算数の元発言「7たす5はいくつ？」+聞き返しへの「はい」「言ったよ」は12へ回答、同じ履歴への「いいえ、あなたには言ってない」は短く受け止め12を回答しない、「猫ちゃん、5たす4は？」は9へ回答する。残る2件は元発言「私の好きな飲み物はほうじ茶です。覚えておいて。」+聞き返しに対し、否定「いいえ、それはママのこと。あなたには言ってない」ならremember呼出し0、肯定「うん、私の好みだから覚えて」なら本人の好みをrememberすること。各試行は新しい記憶とsessionで独立させる。

要約Haikuは5件を各3回: (a) 元の好み+聞き返しがevicted、肯定がreferenceなら本人の好みを残す、(b) referenceが否定なら本人の好みを残さない、(c) 肯定なし・previousSummaryなし・保持する内容なしなら`.noContent`、(d) 既存の確定した別の好みは維持し、referenceのみに新出する合言葉`REFERENCE_ONLY_29`をsummaryへ追加しない、(e) previousSummaryは確定した別の好みで、evictedの追加発言がすべて否定済みなら、その追加内容を混入せず前回要約の事実を保つ。`(e)`はモデルのraw結果と`validatedText(previousSummary:characterLimit:)`後の両方を記録し、`.noContent`なら前回要約をそのまま使う保護も確認する（raw結果を`.noContent`へ誘導する試験ではない。この分岐自体はTask 3のstubで確定検証する）。(a)/(b)にもreferenceだけの新事実を置き、混入がないことを確認する。

合格は**全試行が期待範囲内**。分類はenumで自動照合、要約は型/長さと期待事実/否定/参考混入を照合、返答の意味とrememberの内容はNavigatorが実出力とtool記録を全件確認する。「短い受け止め」は通常の1〜2文を基準とし、意味を伴わない文字列一致だけで合格にしない。timeout/認証/parse/通信失敗は成功に数えず、未検証/失敗として残す。

- [ ] **Step 2 — runnerを検証:** 既存device runnerのbuild→xctestrun複製→明示の環境変数→test-without-building→Documents回収の手順を再利用する。`OnlyTestIdentifiers`は新規1メソッドだけ、並列実行NO、自動retryなし。fixtureごとにtrial/model/prompt hash/result/error/elapsed/tool記録を`Documents/ClarificationHistory/<runID>/results.json`へ逐次保存する。`bash -n scripts/run_clarification_history_model_tests.sh`が成功し、通常suiteでは有料呼出し0であることを確認する。
- [ ] **Step 3 — 凍結して実行（Codex）:** `scripts/run_clarification_history_model_tests.sh "$ISSUE29_XCODE_DEVICE_ID" "$ISSUE29_CORE_DEVICE_ID"`。結果jsonとxcresultを回収し、72試行と全件の合否を集計する。skipや記録不足は受入成功にせずrunnerを非0で終了する。モデルの機能確認に不足する設定/認証があれば未検証として残し、単体試験の成功で代替しない。
- [ ] **Step 4 — 不合格時:** 初回結果を保存して失敗のfixture/指示文/出力をNavigatorへ送る。指示文修正のDriverと対象をHANDOFFで確定し、意味判定の語一覧や無返答tool、端末内での再判定を追加しない。変更した指示に依存する受入セットを全件再実行し、閾値は緩めず、失敗を消すための選別再試行をしない。仕様変更が必要なら承認済みspecの扱いに従う。
- [ ] **Step 5 — GREEN/commit:** 全期待を満たした実入力/結果をvalidationへ記録し、当TaskのFilesだけをstageして`git commit -m "test: validate clarification semantics against live models"`。Claudeへ文書の編集権をHANDOFFする。

### Task 5: 文書・全体検証・独立レビュー・実機受入

**Files:** `README.md`、`docs/README.md`、`docs/superpowers/specs/2026-11-06-neutral-history-design.md`への後継設計注記、`docs/application-flow.html`、`docs/validation/2026-11-07-clarification-history.md`。承認済み#29 specは凍結したまま。

**Interfaces:** 製品APIの追加なし。validationから候補HEAD・入力digest・RED/GREEN・交代・実モデル試行・初回レビュー・通常署名版・利用者の確認結果を辿れるようにする。

Consumes: Task 1〜4の候補・受入結果。Produces: 現行説明と検証記録、独立レビューの採否、人による実機受入結果、承認範囲の統合記録。

- [ ] **Step 1 — 文書を更新（Claude）:** READMEの肯定/否定、確認待ち中だけのHaiku送信、保持側参考、正常0件を現行に合わせる。索引へspec/計画/validationを加え、旧#23の「肯定で元発言を再送」は後継specで変更されたと注記する。図は確認待ち→顔向き/文脈Haiku→除外時pending維持の分岐、実発言のprompt、例の強調を合わせる。
- [ ] **Step 2 — 図を検証:** HTMLのembedded定義と事前描画SVGを両方更新し、日付/対象issueと入力revision/digestを候補に合わせる。既存のMermaid 12.3.0のtask-private rendererをコピーして再利用できるが、そのパスを利用者の恒久依存にしない。オフラインで6図の切替、該当分岐の表示/強調、詳細リンク、キーボード、拡大縮小、印刷、スマホ幅を確認し、JSエラー/外部要求0を保存する。図以外の5図を意図せず変更していないことも確認する。
- [ ] **Step 3 — 最終入力を固定し全体検証（Codex）:** 次を実行し、失敗0と除外/skipの実数を記録する。新規有料testは明示的に除外し、Task 4の結果へ参照する。プロジェクト再生成の決定性、`git diff --check`、Package.resolved/資産の不変も確認する。

```sh
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
issue29_test \
  -skip-testing:CatRobotTests/SupertonicIntegrationDeviceTests \
  -skip-testing:CatRobotTests/RobotMotionIntegrationDeviceTests \
  -skip-testing:CatRobotTests/ClarificationHistoryModelTests
git diff --check
```

- [ ] **Step 4 — 独立レビュー:** 全差分を固定し、Claudeが実際の`/simplify`をreport-onlyの4観点で実施、Codexが`superpowers:requesting-code-review`で新しい独立レビュアー1名へ読取専用レビューを依頼する。Navigatorを独立レビュアーに数えない。初回をhash付きで保存してから交換し、双方`superpowers:receiving-code-review`で採否と根拠を記録する。Critical/Importantを解消し、修正に対応するRED/GREENと必要範囲の再検証を行う。文書のみの修正で全suiteを無理由に繰り返さない。
- [ ] **Step 5 — 通常版の実機受入（Codex）:** 実行時に`xcodebuild -showdestinations`/`xcrun devicectl list devices`で選んだ端末へ、検証済み入力の通常Debug署名版をbuild/install/launchする（READMEの手順、bundle `com.kamby.CatRobot`）。XCTest・モデル試験用引数/環境なしで起動し、利用者に対面/非対面の肯定・否定・別話題、周囲の発言後の返事を確認してもらう。インストール/PID/自動試験を利用者の受入回答に置き換えない。結果待ちは未完了として残す。
- [ ] **Step 6 — commitと統合:** 当Taskの文書だけをstageし`git commit -m "docs: document clarification routing and validation"`。承認済みの統合範囲に従い最新mainとの差分と検証済みtreeを照合し、1 commitへsquashする。競合/入力変更なら対応する再検証、最終版の通常実機build/install/launchを行う。**pushは利用者承認後にnon-forceで実施**し、remote hash/issue状態/worktreeを実際に照合する。host worktree・他者のbranchを削除しない。

## 初稿のセルフレビューと引継ぎ

- specの振り分け/実発言/返答/寿命はTask 1〜2、要約はTask 3、実モデルはTask 4、文書・実機・統合はTask 5に対応する。
- 正常0件は`GeneratedConversationSummary.items == []`→`.noContent`→前回要約の保持（元々空なら空のまま）という明示契約にした。非空`.text`は更新後全体で置き換え、不正な空生成/parse失敗とは区別する。空配列では前回要約全体を撤回できない制約もTask 3に記載した。
- 実モデルの初回72試行、3/3、全件合格という基準はこの計画の提案であり、承認後に実行前の入力とともに固定し、Claudeから利用者へ件数と概算を示す。本文改稿時点では未実行。構造化要約の4,096token上限の十分性と上限付近の実測は未検証。
- 実装方法は既にDriver/Navigatorのペアと決まっている。初稿のSHAをClaude Navigatorへ送り、レビュー/計画承認と実装HANDOFFを経てTask 1を開始する。
- 現在のspec SHAとHEADを再確認し、計画以外を変更していないことを示して初稿を凍結する。計画レビュー中にソースへ進まない。

SDKの構造化生成は、固定revision `0262e1a766c461a4268dcec656eca95dd74cebf8`のREADMEと既存`ConsolidatedFacts`/`AddressDecision`の利用を確認した。[公式のstructured outputの例](https://github.com/anthropics/ClaudeForFoundationModels/blob/0262e1a766c461a4268dcec656eca95dd74cebf8/README.md#structured-output)を使用し、ライブラリの更新は不要。
