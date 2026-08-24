# 通常起動アプリへのReply Tool統合設計

**日付:** 2026-08-24

**Branch:** `feature/gemma4-independent-tools`

**開始commit:** `c85da4cc640340f60187b289cd5184ae2eacb48f`

**前提となる基盤仕様:** `docs/superpowers/specs/2026-08-24-gemma4-independent-tools-design.md`

## 目的

実装済みの`rememberMemory`、`forgetMemory`、`searchMemory`、`getCurrentDateTime`を、接続済みiPhone上で通常起動したCat Robotアプリから利用できるようにする。最初のlive backendにはAppleのon-device `SystemLanguageModel(useCase: .general)`を使う。一方で、会話、tool transaction、永続化、UIの各layerはこの具体的なmodelから独立させ、将来Foundation Models互換のGemma sessionへ置き換える際に書き直さなくてよい設計にする。

この変更にはtyped/voiceの両reply、簡潔でnonblockingなmemory変更通知、signed device install、通常のapp launchを含む。LiteRT、Gemma artifact、vision、context compaction、cloud memory、memory管理screenは追加しない。

## 設計原則

1. **model非依存のreply lifecycleを1つだけ持つ。** Turn ownership、tool budget、transactional memory、draft streaming、commit、rollback、通知はbackend非依存のreply serviceが所有する。
2. **backendの差し替え点を1か所に限定する。** Apple固有のmodel生成とreadinessは`ReplySessionFactory`の内側へ置く。将来のGemma実装ではこのfactoryだけを差し替え、ViewModel、UI、memory store、toolは変更しない。
3. **Foundation Modelsを共通runtime surfaceにする。** 現在のApple modelと将来のGemma adapterはどちらも`LanguageModelSession`、`Tool`、`GenerationOptions`、`Transcript`を使用する。`SystemLanguageModel`や将来のLiteRT型をApple/Gemma factory実装の外へ漏らさない。
4. **観測可能な成功より先にcommitする。** 生成中のdraft textは表示してよい。speech、durableなtranscript進行、memory通知はmemory transactionのcommit後だけ開始する。
5. **failureをatomicかつvisibleにする。** cancellation、generation failure、tool上限、無効なtool decode、persistence failureではstaged memoryとsession turnをrollbackする。memory初期化・永続化failureを黙って無効化しない。
6. **既存のownershipを維持する。** 現在のMainActor ViewModelが持つlifecycle generation、voice/typed turn ID、voice reply前のclassifier順序、audio teardown、reply reset behaviorを引き続き正とする。

## アーキテクチャ

### Domain reply contract

文字列だけのreply request/stream contractを、turnとcommitの意味が明示されたcontractへ置き換える。

```swift
struct ReplyTurnRequest: Equatable, Sendable {
    let turnID: UInt64
    let userText: String
}

enum ReplyMemoryChange: Equatable, Sendable {
    case remembered
    case forgotten
    case updated
}

struct ReplyTurnCommit: Equatable, Sendable {
    let finalText: String
    let memoryChange: ReplyMemoryChange?
}

enum ReplyStreamEvent: Equatable, Sendable {
    case draft(String)
    case committed(ReplyTurnCommit)
}

protocol ReplyGenerating: Sendable {
    func prepare() async throws
    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error>
    func reset() async
}
```

`ReplyMemoryChange`はpresentation-safeな情報だけを持ち、fact、quote、UUID、tool argumentを含めない。同一turnの複数のcommit済みmutationは1つの値へ集約する。rememberとforgetが混在するturnは`.updated`とする。searchだけ、または日時取得だけのturnは`nil`とする。

typedとvoiceの両requestで、既存ViewModelのturn IDを変更せず渡す。同じ論理turnのretryではshared tool-call budgetをresetせず、ViewModelが新しいturn IDを発行した場合だけresetする。

### Backend非依存のorchestration

`ToolEnabledReplyService`をliveの具体的な`ReplyGenerating`実装にする。このactorは次を所有する。

- lazyに初期化する`LocalMemoryStore`を1つ。
- `MemoryToolContext`を1つ。
- shared `ReplyToolCallBudget`を1つ。
- 安定した4 toolのsetを1つ。
- `ReplySessionFactory`を1つ。
- 現在の`ReplySessionClient`を1つ。
- 既存のsingle-generation exclusion。

このserviceは、sessionがApple、Gemma、または別のFoundation Models互換language modelのどれを使用するかを知らない。下記のsession/factory protocolだけを参照する。

各reply requestについて、actorは次のsequenceを直列化して実行する。

1. generationが重複した場合は既存の`.modelBusy` errorでrejectする。
2. persistent tool runtimeとreply sessionがpreparedであることを保証する。
3. sessionのturn開始前`Transcript` checkpointを取得する。
4. `MemoryToolContext.beginTurn(id:userText:)`を呼ぶ。
5. `ReplyToolCallBudget.beginTurn(id:)`を呼ぶ。
6. 累積model snapshotを`.draft` eventとしてstreamする。
7. 空白ではないfinal snapshotを必須とし、cancellationを確認する。
8. memoryをcommitして`MemoryNotice`を取得する。
9. そのnoticeをprivacy-safeな`ReplyMemoryChange`最大1件へmapする。
10. terminalな`.committed` eventを厳密に1件emitし、正常終了する。

ステップ10より前のfailureでは、serviceは次を必ず行う。

1. active model streamをcancel/finishする。
2. `MemoryToolContext.rollbackTurn()`を呼ぶ。
3. `ReplySessionClient`経由でturn開始前のsession transcriptをrestoreする。
4. cleanup完了後にだけgenerating flagをclearする。
5. `.committed`をemitせず、map済みのrecoverable errorを伝播する。

memory commit前に届いたcancellationはrollbackする。memory commitとterminal committed eventが完了した後にTTSやaudioがfailureになっても、意味的に成功したreplyやmemory変更は取り消さない。

### 差し替え可能なsession境界

backend seamは意図的に小さく保つ。

```swift
protocol ReplySessionFactory: Sendable {
    func prepare() async throws
    func makeSession(
        tools: [any Tool]
    ) async throws -> any ReplySessionClient
}

protocol ReplySessionClient: Sendable {
    func prewarm() async
    func transcript() async -> Transcript
    func restoreTranscript(_ transcript: Transcript) async
    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error>
}
```

これらのprotocolは`FoundationModels`のimportが妥当なservice layerへ置く。Domain、integration、memory、UI codeは`SystemLanguageModel`、LiteRT、Gemmaを参照しない。

`AppleSystemReplySessionFactory`をApple reply backendの唯一の実装にする。このfactoryは次を担当する。

- `SystemLanguageModel(useCase: .general, guardrails: .default)`の所有。
- `prepare()`におけるgeneral model readinessの確認。
- 渡された4 toolを厳密に登録した`LanguageModelSession`の生成。
- Cat Robotの人格とtool使用規則を含むinstructionsの付与。
- persistent tool runtimeを変更せず、取得済み`Transcript`へsessionを置換またはresetすることによるfailed turnのrestore。

将来の`GemmaReplySessionFactory`は、modelをdownload/verifyしてFoundation Models互換のGemma sessionを生成できる。この実装も同じ2 protocolへ適合する。追加時の変更はlive compositionまたはfactory選択だけに限定し、`ToolEnabledReplyService`、`ConversationViewModel`、`ConversationView`、`LocalMemoryStore`、`MemoryToolContext`、4 toolは変更しない。

### Generation policyとinstructions

live sessionへ4 toolすべてを渡し、次のpolicyを使用する。

- tool calling modeは`.allowed`とし、`.required`は使用しない。
- temperatureは`0.5`。
- maximum response tokensは`256`。
- reasoning/thinking UIやreasoning outputの露出は追加しない。

明示的なiOS 27 tool-calling optionにavailability handlingが必要なdeployment targetでcompileする場合、iOS 27 runtime pathでは`.allowed`を明示する。この統合だけを理由にproject deployment targetは変更しない。

backend instructionsは既存のCat Robotの人格を維持し、次の簡潔な規則を追加する。

- 将来役立つ可能性が高い、user提供の安定したfactだけをrememberする。
- `supportingQuote`は現在のuser textから完全に同じ文字列をcopyする。
- 一時的な観察、推測、assistantの主張、summary、画像だけからの結論をrememberしない。
- 競合する可能性のあるfactを置換または削除する前にsearchする。
- 質問に現在の日付・時刻または相対的な日時基準が必要な場合だけ日時toolを使う。
- 現在の日付、曜日、timezoneをmodel knowledgeから推測しない。
- 回答に不要なtoolは呼ばない。

toolを渡すのはreply sessionだけとする。Apple content-tagging classifierと将来のcompaction専用sessionはtool-freeのまま維持する。

### Preparationとcomposition

reply backendのreadinessとmemory store初期化failureを黙って無視せず報告できるよう、`ReplyGenerating.prewarm()`をthrowingな`prepare()`へ置き換える。

`ConversationDependencies.live()`は次をcomposeする。

```text
AppleSystemReplySessionFactory
        ↓
ToolEnabledReplyService
        ↓
ReplyGenerating dependency
```

memory storeは`LocalMemoryStore.applicationSupport()`を通してlazyに解決し、process lifetime中保持する。Session resetでは同じfactoryから新しいsessionを作り、同じ4 tool、budget actor、context actor、persistent storeを再attachする。

`FoundationModelAvailabilityService`は引き続きApple `.contentTagging` classifier availabilityを表す。Reply backend readinessは`ReplySessionFactory.prepare()`の責務とする。この分離により、将来のGemma factoryはclassifier behaviorを変更せずにdownload、verification、warmupを所有できる。

## ViewModelとUI flow

typedとvoiceの両pathで、既存の`turnID`と受理したuser textを`ReplyGenerating`へ渡す。

eventのconsume中は次のように扱う。

- `.draft(text)`は既存captionだけを更新する。
- `.committed(commit)`はfinal textを記録し、optionalなtransient memory noticeをpublishして、既存speech pathの開始を許可する。
- `.committed`なしで正常stream終了した場合はgeneration failureとする。
- errorがthrowされた場合はuncommitted draftをclearしてからrecovery UIをpublishする。

voiceの順序は次を維持する。

```text
speech recognition → Apple content-tagging classifier → tool-enabled reply → memory commit → speech
```

typed inputはこれまでどおりaddress classificationを通さず、同じtool-enabled reply serviceを直接使用する。

### Memory notice

`ConversationViewState`へoptionalなtransient noticeを1件追加する。ViewModelはcommit済み`ReplyMemoryChange`を次の短い日本語へmapする。

- remembered: `記憶しました`
- forgotten: `記憶を削除しました`
- mixed/updated: `記憶を更新しました`

noticeは次の要件を満たす。

- compactなtop overlay/bannerとして表示する。
- fact text、supporting quote、ID、tool argumentを表示しない。
- model transcriptやcaptionへ入れない。
- inputを受け付けず、focusを奪わず、speechを停止せず、typed/voice actionをblockしない。
- accessibility labelを持ち、Dynamic Typeとreduced transparencyへ対応する。
- より新しいcommit済みmutationが届いた場合は既存noticeを置き換える。
- ViewModelが所有するcancellable taskによって自動的に消える。
- search、日時取得、rollback、commit failureでは表示しない。

具体的な表示時間はpresentation detailであり、domain contractにしない。

## Errorとcancellation semantics

tool-free replyへ黙ってfallbackせず、recoverableなmemory/tool-runtime error presentationを追加する。UIは必要に応じて既存のretryやtyped-input recoveryを提供してよい。

次のすべてのcaseではterminal commit event、speech、noticeを発生させない。

- persistent store初期化failure。
- model/session preparation failure。
- model generationまたはtool decoding failure。
- 13 call目の`ReplyToolCallLimitExceeded`。
- 空のfinal response。
- commit前のViewModel cancellation、scene inactivity、pause、shutdown。
- memory persistence failure。

serviceはasync rollbackとtranscript restoreを完了してからstreamを終了する。`onTermination` cancellationではforwarding taskをcancelする必要があるが、同期的なtermination callbackだけではcleanup完了とみなさない。

production logへuser fact、supporting quote、search result、tool argument、raw promptを出力しない。

## Test方針

すべてのbehaviorをred/green TDDと決定論的fakeで実装する。Live inferenceを主要なcorrectness testにしない。

### Reply service test

次をcoverする。

- 厳密な4 tool登録と、1つのshared budget/context runtime。
- iOS 27 pathにおける`.allowed` tool modeと256-token policy。
- draft eventの後にterminal committed eventが厳密に1件続くこと。
- terminal eventより先にmemory commitが完了すること。
- remember、forget、mixedのnoticeを集約して`ReplyMemoryChange`へmapすること。
- search/date-only successではnoticeがないこと。
- staged mutation後のgeneration failureでstoreとtranscriptがrollbackされること。
- draft後のcancellationがstream終了前にrollbackされること。
- 13 call目がtool本体を実行せずrollbackすること。
- persistence failureでcheckpointをrestoreし、commit eventをemitしないこと。
- resetで新しいsessionを生成しつつpersistent memory/tool actorを保持すること。
- 同じturn IDではbudgetをresetせず、新しいIDでresetすること。

### ViewModel/integration test

2つ目のconversation stackを作らず、既存fakeとharnessを拡張する。typedとvoiceの両pathで次をcoverする。

- draftはcaptionを更新するがspeechを開始しない。
- committed final textがspeechを開始する。
- commit済みmutationがspeechをblockせずnoticeを1件publishする。
- search/date-only commitではnoticeをpublishしない。
- reply error/cancellationでuncommitted draftをclearし、speech/noticeを発生させない。
- Apple classifierが引き続きvoice replyより先に実行される。
- pause/background/shutdownがtransaction cleanup完了を待つ。
- 既存lifecycle、recovery、latency、clarification、typed-input behaviorがgreenのままである。

### UIとcomposition test

次をcoverする。

- banner visibility、private内容を含まないgeneric text、accessibility、Dynamic Type、noninteractive behavior。
- live compositionが`AppleSystemReplySessionFactory`を持つ`ToolEnabledReplyService`を使用すること。
- classifier availabilityが`.contentTagging`のままで、reply preparationから独立していること。
- LiteRT/Gemma dependencyやtypeを追加していないこと。

### Validationとdevice deployment

install前に次を満たす。

1. 決定論的project-generator contractがPASSする。
2. focused reply、memory、tool、ViewModel、composition、UI testが接続済みiPhoneでPASSする。
3. 変更していない`SpeechAudioConverterTests` class全体を除外したfull device regressionがPASSする。
4. `/Applications/Xcode-beta.app`を使ったsigned Debug device buildが成功する。
5. static scope/privacy checkがPASSする。
6. independent reviewで未解決のCritical/Important findingがない。
7. tracked worktreeがcleanである。

既存の`com.kamby.CatRobot` bundleをuninstallせず、signed appを上書きinstallしてApplication Support dataを保持する。現在のXcode/CoreDevice identifierを再列挙し、`devicectl`でinstallし、`--terminate-existing`でlaunchしてprocessが正常に開始することを確認する。自動validation中は確率的なlive tool promptを消費せず、hands-onのtyped/voice usability testはuserが実施する。

## Fileとownership

新規作成または実質的に変更する想定範囲は次のとおり。

- Domain: reply turn request、event、commit、memory-change contract。
- Services: backend非依存のtool-enabled reply service、session protocol、Apple session factory/client、error mapping。
- Integration: dependency compositionとtyped/voice event consumption。
- UI: transient memory notice stateとview。
- Tests: reply service、integration fake/harness、composition、view state/UI。
- 新規fileの追加で必要な場合に限り、既存generatorを通して生成するXcode project/scheme。

persistenceとtool実装をsource of truthとして維持する。validation、allowance、authorization、normalization、budget logicをreply serviceやViewModelへ複製しない。

## 明示的な対象外

- この変更でのLiteRT/Gemma dependencyまたはmodel install。
- Gemma model download、integrity verification、context calibration、compaction、vision。
- Cloud memory、embedding、fuzzy search、sync、memory管理screen。
- content-tagging classifierへのtool登録。
- tool使用判断のための2つ目のextraction/classification model call。
- Tool-call debug UI、raw tool argument/result、private prompt logging。
- push、PR作成、merge、blocked/comparison worktreeの変更。

## 完了条件

次のすべてを満たした場合だけ完了とする。

1. 通常起動したsigned device appが、`AppleSystemReplySessionFactory`を持つ`ToolEnabledReplyService`を使用する。
2. typed turnとclassifierがaddressedと判定したvoice turnの両方が、`.allowed` tool callingを設定した`LanguageModelSession`経由で4 toolすべてを利用できる。
3. Memory mutationはspeechより先にcommitされ、privacy-safeでnonblockingなnoticeを1件表示する。search/date-only turnでは表示しない。
4. commit前のすべてのfailure/cancellationでmemoryをrollbackし、turn開始前のtranscriptをrestoreする。
5. app restart後のinstanceがApplication Supportからcommit済みfactをloadできる。
6. reply lifecycle、memory/tool layer、ViewModel、UIはAppleの具体的modelや将来のGemma/LiteRT dependencyを含まない。
7. 将来のGemma backendは、新しい`ReplySessionFactory`/`ReplySessionClient`を実装・composeするだけで導入でき、shared lifecycleやUI layerを変更しない。
8. fresh focused/regression test、signed build、install、launch、review、clean-worktree checkがPASSする。
9. 既存のblocked worktreeとcomparison branchを変更せず、push/PR/mergeを行わない。
