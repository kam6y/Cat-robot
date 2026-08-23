# Cat Robot Gemma 4 Foundation Models PoC 実装計画

> **実装を担当するエージェントへ:** 必須サブスキルとして `superpowers:subagent-driven-development`（推奨）または `superpowers:executing-plans` を使用し、この計画をタスク単位で実装すること。進捗管理にはチェックボックス（`- [ ]`）を使用する。ただし、ステップごとのreviewやfix/revalidate、spec reviewとcode-quality reviewの二段階実行など、スキル既定の細かなcheckpointは使用しない。以下の「タスク単位の実装・検証ルール」と最大2 loopの上限がスキル既定値より優先される。

**目標:** Appleのcontent-tagging住所判定classifierを維持したまま、iOS 27 Foundation Models API経由でGemma 4 E2BをCat Robotの応答・画像理解backendとして動かす。上限付きcontext compaction、Gemma主導のローカルmemory tool、read-onlyの端末日時toolを追加し、接続済みiPhone 16 Pro上でPoCを実証する。

**アーキテクチャ:** 既存の逐次的な住所判定フローを維持し、応答生成だけをGoogle公式の`LiteRTLMFoundationModels` adapterへ置き換える。model storeが固定済みartifactを一度だけ検証し、状態を持つreply actorがFoundation Modelsのtranscriptとcompactionを所有する。Gemmaのreply sessionには、transactionalなlocal storeをbackendとする検証付き`rememberMemory`、`forgetMemory`、`searchMemory` toolと、端末時計を読むだけの`getCurrentDateTime` toolを渡す。toolが必要かはGemmaが判断し、アプリはmemory変更をstageして応答成功後だけcommitし、小さな非blocking通知を表示する。実機probeはアプリと同じ`LanguageModelSession`経路を使用し、実行回数に厳格な上限を設ける。

**技術スタック:** Swift 6.0 strict concurrency、SwiftUI、iOS 27、Xcode 27、Apple Foundation Models、Google LiteRT-LM `0.16.0`、XCTest、Ruby `xcodeproj 1.27.0`。

**仕様:** `PLAN.md`自体を承認済みPoC仕様兼実行計画とする。以下の完了条件と検証予算を規範とする。

## ベースラインとworkspace

- Worktree: `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-foundationmodels-poc`
- Branch: `feature/gemma4-foundationmodels-poc`
- Base: local `main`の`d3db63e5e4770d17fb4180e0d4a5baac56d4d051`
- 既存の比較branchはread-only参照とする: `feature/gemma4-e2b-comparison`
- `ruby scripts/test_generate_project.rb`: 2026-08-24時点でPASS。
- Xcode 27で既存アプリとtestがiOS 27 Simulator向けにcompileできることを確認済み。ただしautomationを2回試した際の`.xcresult` bundleはいずれも不完全だったため、test完了は主張していない。実装開始時に新しいresult bundleでbaseline testを1回だけ実行し、`.xcresult`が不完全でもprocess exitとbuild/test logから結果を判定できる場合はその結果とevidence制約を記録して先へ進む。結果自体を判定できない場合、または利用可能なiOS 27 Simulatorがない場合だけenvironment blockerとする。

## 全体制約

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`を使用し、globalな`xcode-select`は変更しない。
- deployment targetをiOS 27.0とし、Xcode 27で生成・build可能なproject設定へ更新する。`LastUpgradeCheck`の特定文字列はcontractにしない。
- local `main`だけをbaseにする。fetch、pull、push、PR作成、mergeは禁止する。
- `feature/gemma4-e2b-comparison`をcheckout、merge、rebase、cherry-pick、編集しない。調査には`git show`と`git diff`だけを使用する。
- `https://github.com/google-ai-edge/LiteRT-LM`を厳密に`0.16.0`へ固定し、product `LiteRTLMFoundationModels`をlinkする。
- `LiteRTLanguageModel`はApple `LanguageModelSession`経由で使用する。LiteRT直接生成はdiagnostic専用であり、応答・画像理解の完了条件を満たさない。
- `FoundationModelAddressClassifier`は`SystemLanguageModel(useCase: .contentTagging)`をbackendとして維持し、classifier実行後にreplyを逐次実行する。
- アプリlevelのthinking/reasoning設定、UI、transcript保存、output strippingを追加しない。
- 通常応答の上限は256 output tokens、明示的な詳細要求と画像応答は512とする。
- 通常の文体は結論先行の1〜3文とし、詳細は要求された場合だけ展開する。
- `rememberMemory`、`forgetMemory`、`searchMemory`、`getCurrentDateTime` toolはGemma reply sessionだけに渡す。Apple住所判定classifierとcompaction専用sessionには渡さない。
- Foundation Modelsのtool-calling modeは`.allowed`を使い、`.required`は使わない。通常応答に不要なtool round tripを強制しない。
- reply sessionへ渡す4 toolは、個別tool上限やmutation件数上限を設けず、4 tool合計でuser turnごとに最大12 callとする。13 call目はtool本体を実行せず専用errorでそのreply生成を終了し、memoryとcontextのturn transactionをrollbackする。
- `getCurrentDateTime`は端末の現在日時・曜日・timezoneだけを返すread-only toolとする。network access、永続化、memory通知、system clock変更を行わない。
- Gemmaは通常のユーザー発話から有用な事実を自律的に保存してよい。変更の`supportingQuote`がUnicode正規化後の現在のユーザーtext内に存在する場合だけ有効とする。assistant応答、summary、tool output、画像だけからの推論はmemory sourceにしない。
- 生成中のmemory変更はstageする。streaming textはmemory commitが完了するまで一時draftとして扱い、commit成功後だけuser/assistant pairをcontextへ確定してspeechと小さな一時通知を開始する。commit failureではstageとdraftを破棄し、contextを進めず、通知とspeechを開始しない。確認dialogやblockingなmemory UIは追加しない。
- context reserveは20%とする: `operationalContextBudget = floor(validatedContextCapacity * 0.8)`。
- model context calibrationと実compaction確認は、flake retry、修正後の再確認、fix/revalidate loopを含む累積full-model 14回を上限とし、途中でledgerをresetしない。
- vision検証はretry、prompt修正、fix/revalidate loopを含む累積8 inference、統合tool検証はmemoryと日時を合わせて累積6 user-turn reply requestを上限とし、途中でledgerをresetしない。各vision inferenceとtool user turnには5分timeoutを設ける。
- review、修正、再検証は以下のタスク境界でだけ行い、各タスク最大2 fix/revalidate loopとする。
- inputとbinaryが不変なら、full SHA、full build、full test suite、device sweep、context sweepを繰り返さない。
- production download orchestration、cloud memory、embedding、無関係なrefactor、別model、別LiteRT version、fallback adapterは実装しない。

## タスク単位の実装・検証ルール

- 1タスクを「全ステップを完了する1つの実装batch」と「末尾の1つの検証境界」として扱う。同じ担当agentが原則としてタスクの先頭から末尾まで所有し、ステップ間でreviewerへhandoffしない。
- タスク内の各ステップが終わるたびに、subagent review、spec review、code-quality review、広いtest、修正、再検証を行ってはならない。ステップごとにfresh reviewerを起動したり、別agentによる確認を挟んだりもしない。
- baseline、意図的に失敗させるred test、API compile probe、上限付き実機測定など、そのステップの実装または観測そのものに不可欠なcommandは記載どおり1回実行してよい。これはreview checkpointではなく、その場でreview/fix loopへ入らない。後続作業が安全に続けられる失敗は記録してタスク末尾まで進め、前提条件を失う失敗だけはblockerとして停止する。
- 全実装ステップが終わってから、そのタスクに列挙されたtargeted test、build、静的確認を1つのvalidation bundleとして1回実行する。複数commandがあっても1回のタスク検証としてまとめ、command間で修正に戻らない。実行可能な項目を完了してからfailureをまとめる。
- タスク1〜3と5はmechanical taskとしてreviewerを起動しない。タスク4、6、7、9だけは設計・concurrency・context解釈に不確実性が残る場合に限り、validation bundle後に同じtask diffを確認するheavy reviewerを最大1人使用してよい。タスク8と10はfresh reviewerを起動せず、acceptance修正がタスク4、6、7、9のhigh-risk機構を変更した場合だけ該当タスク相当のreviewを最大1回行う。spec reviewとcode-quality reviewを別agent・別roundへ分割せず、Critical/Important findingだけを修正対象とし、Minorはscopeを広げずhandoffへ記録する。
- initial validation/reviewがcleanなら即座にcommitして次のタスクへ進む。failureまたはCritical/Important findingがあれば全件を1つの修正batchにまとめ、影響範囲のvalidation bundleを1回だけ再実行する。これを1 loopと数え、1タスクにつき最大2 loopまでとする。3 loop目は行わず、未解決ならそのタスクをblockedとして報告する。
- タスク末尾の検証を通過したあとに、同じdiffへ追加のwhole-diff review、重複test、念のためのbuildを行わない。タスク10は最終acceptance全体を1つのvalidation bundleとして扱い、各acceptance項目の間では修正せず、bundle完了後にだけ同じ最大2 loopルールを適用する。

## 固定するmodel artifact

```swift
static let gemma4E2B = GemmaModelDescriptor(
    identifier: "litert-community/gemma-4-E2B-it-litert-lm",
    revision: "6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94",
    fileName: "gemma-4-E2B-it.litertlm",
    remoteURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94/gemma-4-E2B-it.litertlm")!,
    expectedBytes: 2_588_147_712,
    expectedSHA256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
    minimumFreeBytes: 3_200_000_000
)
```

modelはApplication Support配下へ保存し、backup対象から除外する。full SHA-256を実行するのは、新規download、pin変更、信頼済みverification recordの欠落、size/metadata不一致、具体的なload failureのいずれかがある場合だけとする。通常のwarm launchではverification recordとfile metadataを使用し、2.6 GBを再hashしない。

## 正式な参照資料

- Apple custom model protocol: `https://developer.apple.com/documentation/foundationmodels/languagemodel`
- Apple tool protocol: `https://developer.apple.com/documentation/foundationmodels/tool`
- Apple tool-calling guide: `https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling`
- Apple context管理: `https://developer.apple.com/documentation/foundationmodels/managing-the-context-window`
- Google Swift概要: `https://developers.google.com/edge/litert-lm/swift`
- 厳密なpackage manifest: `https://github.com/google-ai-edge/LiteRT-LM/blob/v0.16.0/Package.swift`
- 厳密なFoundation Models adapter: `https://github.com/google-ai-edge/LiteRT-LM/blob/v0.16.0/swift/apple_fm/LiteRTLanguageModel.swift`
- 固定済みmodel card: `https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm`
- 既存のlocal context evidence: `git show feature/gemma4-e2b-comparison:docs/validation/2026-08-23-classifier-context-follow-up.html`

実装中は上記の厳密な参照先だけを読む。current `main`、新しいrelease、一般的なweb surveyへ置き換えない。

## 対象ファイル構成

### Project設定

- `.gitignore`を変更: `*.litertlm`、partial download、Application Support外へcopyされたmodel verification record、raw promptを含むdevice evidence exportをignoreする。
- `scripts/generate_project.rb`を変更: iOS 27、Xcode 27互換のproject設定、厳密なLiteRT package、`LiteRTLMFoundationModels` productを設定する。
- `scripts/test_generate_project.rb`を変更: 厳密なdependency、product、deployment target、Xcode 27での生成・build contract、model ignore ruleをassertする。
- `CatRobot.xcodeproj/project.pbxproj`と`CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`を再生成する。
- package resolutionにより`CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`を作成する。
- `README.md`を変更: Xcode 27/iOS 27要件、model size/download、PoCの制限を記載する。

### Domainとintegration

- `CatRobot/Conversation/Domain/ReplyRequest.swift`を作成: multimodal requestとoutput policyを定義する。
- `CatRobot/Conversation/Domain/ConversationServices.swift`を変更: `ReplyRequest`を受け取り、明示的なGemma preparationを公開する。
- `CatRobot/Conversation/Domain/ConversationTypes.swift`を変更: UI recoveryで個別処理が必要なmodel-download errorとmemory errorだけを追加する。
- `CatRobot/Conversation/Integration/ConversationDependencies.swift`を変更: Apple classifier availabilityとGemma reply preparationをcomposeする。
- `CatRobot/Conversation/Integration/ConversationViewModel.swift`を変更: memory-tool transaction完了、一時通知、既存のcancellation ownershipを扱う。
- `CatRobot/Conversation/UI/ConversationViewState.swift`と`ConversationView.swift`を変更: model準備中の単純な状態と小さな非blocking memory通知を扱う。

### Gemma backend

- `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaModelStore.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaFoundationModelFactory.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift`を作成する。
- `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`を変更: 置換対象のApple general reply modelではなく、Apple content-tagging classifierを確認する。
- compile probeで実際に観測した具体的なiOS 27 errorに限り、`CatRobot/Conversation/Services/FoundationModelErrorMapper.swift`を変更する。

### Context、memory、tool

- `CatRobot/Conversation/Context/ConversationTurn.swift`を作成する。
- `CatRobot/Conversation/Context/TokenBudgeting.swift`を作成する。
- `CatRobot/Conversation/Context/ConversationContextController.swift`を作成する。
- `CatRobot/Conversation/Memory/MemoryFact.swift`を作成する。
- `CatRobot/Conversation/Memory/LocalMemoryStore.swift`を作成する。
- `CatRobot/Conversation/Memory/MemoryToolContext.swift`を作成する。
- `CatRobot/Conversation/Memory/RememberMemoryTool.swift`を作成する。
- `CatRobot/Conversation/Memory/ForgetMemoryTool.swift`を作成する。
- `CatRobot/Conversation/Memory/SearchMemoryTool.swift`を作成する。
- `CatRobot/Conversation/Tools/ReplyToolCallBudget.swift`を作成する。
- `CatRobot/Conversation/Tools/CurrentDateTimeTool.swift`を作成する。
- `CatRobot/Conversation/UI/MemoryNoticeView.swift`を作成する。

### PoC probeとevidence

- `CatRobot/Diagnostics/VisionFixtureFactory.swift`を作成する。
- `CatRobot/Diagnostics/GemmaVisionDeviceProbe.swift`を作成する。
- `CatRobot/Diagnostics/GemmaContextCalibrationProbe.swift`を作成する。
- `CatRobotTests/Diagnostics/GemmaVisionDeviceProbeTests.swift`を作成する。
- `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`を作成する。
- 実装中に`docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`を作成する。

### Unit testとintegration test

- `CatRobotTests/Conversation/Services`、`Context`、`Memory`、`Tools`配下に、各新規service/toolと対応するtestを作成する。
- `CatRobotTests/Conversation/Integration/ConversationFakes.swift`を変更する。
- `CatRobotTests/Conversation/Integration/ConversationViewModelTests.swift`を変更する。
- `CatRobotTests/Conversation/Integration/AppCompositionTests.swift`を変更する。
- 既存Foundation Models classifier testはApple backendが維持されることのassertだけを変更し、classifier自体は書き直さない。

---

### タスク1: iOS 27とLiteRT package contractを確立する

**対象ファイル:**
- 変更: `.gitignore`
- 変更: `scripts/generate_project.rb`
- 変更: `scripts/test_generate_project.rb`
- 変更: `README.md`
- 再生成: `CatRobot.xcodeproj/project.pbxproj`
- SwiftPMで作成: `CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**インターフェース:**
- 提供: 厳密な`LiteRTLMFoundationModels` 0.16.0をlinkするiOS 27 app target。
- 提供: compile時に利用可能な`LiteRTLanguageModel`、`EngineConfig`、`Backend`。

- [ ] **ステップ1: source変更前の新しいbaselineを1回取得する**

次を1回だけ実行する:

```bash
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -quiet \
  -project CatRobot.xcodeproj \
  -scheme CatRobot \
  -destination '<xcodebuild -showdestinationsで解決した利用可能なiOS 27 iPhone Simulator>' \
  -resultBundlePath /tmp/CatRobotGemmaBaseline.xcresult \
  test
```

実行前に`xcodebuild -showdestinations`で利用可能なiOS 27のiPhone Simulatorを解決する。既知のdevice IDが利用可能なら再利用してよいが、固定UUIDを前提にしない。baseline command自体は1回だけ実行する。`.xcresult`が不完全でもexit statusとlogからPASS/FAILを判定できる場合は結果とevidence制約を記録し、判定不能またはiOS 27 destination不在の場合だけblockerとする。既存test failureを判定できた場合はpre-existing failureとして記録し、機能実装の検証と区別する。

- [ ] **ステップ2: 失敗するgenerator assertionを書く**

generator contractへ次の要件を追加する:

```ruby
LITERT_LM_URL = "https://github.com/google-ai-edge/LiteRT-LM"
LITERT_LM_VERSION = "0.16.0"
LITERT_PRODUCT = "LiteRTLMFoundationModels"
DEPLOYMENT_TARGET = "27.0"
```

package referenceが1つだけであること、厳密なversion、app target上のFoundation Models product、test targetに直接package productがないこと、deployment targetが27.0であることをassertする。`LastUpgradeCheck`の特定値はassertしない。

- [ ] **ステップ3: 実装前にcontractが失敗することを確認する**

実行:

```bash
ruby scripts/test_generate_project.rb
```

期待結果: 最初に追加したiOS 27またはLiteRT assertionでFAILする。

- [ ] **ステップ4: generator変更とmodel ignore ruleを実装する**

`LiteRTLM`だけではなく`LiteRTLMFoundationModels`をlinkする。repositoryへ次のignoreを追加する:

```gitignore
*.litertlm
*.litertlm.*.download
*.model-verification.json
device-evidence-private/
```

- [ ] **ステップ5: 再生成し、決定性を確認する**

実行:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
```

期待結果: PASS。generatorをもう1回実行し、追加のproject diffが発生しないことを確認する。

- [ ] **ステップ6: packageをresolveし、公式adapter APIをcompileする**

package resolutionとbuildをそれぞれ1回実行する。app code内の最初のadapter callは、固定済みの次のAPI形状でcompileできなければならない:

```swift
import LiteRTLM
import LiteRTLMFoundationModels

let config = try EngineConfig(
    modelPath: modelPath,
    backend: .gpu,
    visionBackend: .cpu(),
    audioBackend: nil,
    maxNumTokens: contextCapacity,
    cacheDir: cacheDirectory.path
)
let model = LiteRTLanguageModel(engineConfig: config)
let session = LanguageModelSession(model: model)
```

compile前に固定tagの公開sourceを読み、同じ機能を提供する実際のv0.16.0 public API shapeへsampleを合わせてよい。厳密なtagに必要なcustom-model adapter機能自体がない場合は、dependencyを切り替えず停止する。

- [ ] **ステップ7: project contractをcommitする**

```bash
git add .gitignore README.md scripts CatRobot.xcodeproj
git commit -m "build: add iOS 27 LiteRT Foundation Models dependency"
```

---

### タスク2: PoC用artifact準備と一度限りのintegrity検証を実装する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`
- 新規作成: `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`
- 新規作成: `CatRobot/Conversation/Services/GemmaModelStore.swift`
- テスト: `CatRobotTests/Conversation/Services`配下の対応ファイル

**インターフェース:**
- 提供: `GemmaModelPreparing.prepare() async throws -> URL`。
- 提供: warm launchの高速検証に使う`GemmaModelVerificationRecord`。

- [ ] **ステップ1: immutableなdescriptorとverification interfaceを定義する**

```swift
struct GemmaModelDescriptor: Equatable, Sendable, Codable {
    let identifier: String
    let revision: String
    let fileName: String
    let remoteURL: URL
    let expectedBytes: Int64
    let expectedSHA256: String
    let minimumFreeBytes: Int64
}

struct GemmaModelVerificationRecord: Equatable, Sendable, Codable {
    let identifier: String
    let revision: String
    let fileName: String
    let byteCount: Int64
    let sha256: String
    let modificationDate: Date
    let verifiedAt: Date
}

protocol GemmaModelPreparing: Sendable {
    var installedModelURL: URL { get }
    func prepare() async throws -> URL
}
```

- [ ] **ステップ2: integrity policyの失敗するtestを書く**

小さなfixtureで次のcaseを厳密に検証する:

- 新規downloadではhashを1回だけ計算し、atomicにinstallする。
- size、modification date、pin tuple、recordが一致する場合はhashせず返す。
- record欠落時は1回だけhashする。
- sizeまたはmetadata不一致時は1回だけhashする。
- load failureによる無効化後はreverify/redownload経路を1回だけ許可する。
- cancellation時は自身が所有するpartial fileだけを削除する。
- concurrent callerは1つのpreparation taskを共有する。
- install済みmodel directoryをbackup対象外にする。
- DEBUG/test-onlyのSHA invocation counterまたはsignpostが、新規検証で1増え、信頼済みwarm pathでは増えない。

- [ ] **ステップ3: streaming SHAとatomic installationを実装する**

2.6 GB全体をmemoryへloadせず、chunk readするCryptoKit `SHA256`を使用する。前景での初回準備だけを対象に、UUID付きpartial pathへ1回downloadし、byte数とdigestを検証してverification recordを書き、最後に所定位置へrenameする。DEBUG/test-onlyのSHA invocation counterまたはsignpostを`GemmaModelStore`内に設ける。background download、resume、複数mirror、byte単位progress UI、一般化したredownload orchestrationは実装しない。

- [ ] **ステップ4: 対象testを確認する**

model storeとintegrityのtest classだけを実行する。期待結果: networkと実modelなしでPASSする。

- [ ] **ステップ5: model storeをcommitする**

```bash
git add CatRobot/Conversation/Services/GemmaModel* CatRobotTests/Conversation/Services/GemmaModel*
git commit -m "feat: add bounded Gemma model store"
```

---

### タスク3: multimodal reply contractとoutput policyを導入する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Domain/ReplyRequest.swift`
- 変更: `CatRobot/Conversation/Domain/ConversationServices.swift`
- 変更: `CatRobotTests/Conversation/Integration/ConversationFakes.swift`
- テスト: `CatRobotTests/Conversation/Domain/ReplyRequestTests.swift`

**インターフェース:**
- 提供: text、optional image、output上限をまとめる単一request型。
- 維持: 累積text snapshotのstreaming。

- [ ] **ステップ1: response policyのtestを書く**

必須case:

```swift
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: .init(text: "こんにちは")), 256)
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: .init(text: "詳しく教えて")), 512)
XCTAssertEqual(ReplyDetailPolicy.maximumTokens(for: requestWithImage), 512)
```

- [ ] **ステップ2: protocol layerへUIKitをimportせずdomain型を定義する**

```swift
struct ReplyImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

struct ReplyRequest: Equatable, Sendable {
    let text: String
    let image: ReplyImage?

    init(text: String, image: ReplyImage? = nil) {
        self.text = text
        self.image = image
    }
}

enum ReplyDetailPolicy {
    static func maximumTokens(for request: ReplyRequest) -> Int {
        if request.image != nil { return 512 }
        let detailedPhrases = ["詳しく", "詳細に", "理由も", "もう少し説明"]
        return detailedPhrases.contains(where: request.text.contains) ? 512 : 256
    }
}

protocol ReplyGenerating: Sendable {
    func prepare() async throws
    func streamReply(to request: ReplyRequest) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}
```

- [ ] **ステップ3: 決定論的な詳細要求判定を実装する**

明示的な日本語の詳細要求phraseまたは画像がある場合だけ512を選択する。通常の長いpromptだけでは応答上限を自動拡張しない。

- [ ] **ステップ4: fakeと既存testをcompile可能に更新する**

住所判定classifierのinterfaceは変更しない。

- [ ] **ステップ5: task-level validation bundleを実行する**

`ReplyRequestTests`と、変更した`ReplyGenerating`を使うintegration fake/対象testのcompileをまとめて1回確認する。command間で修正せず、failureはbundle完了後にまとめる。

- [ ] **ステップ6: domain contractをcommitする**

```bash
git add CatRobot/Conversation/Domain CatRobotTests/Conversation
git commit -m "refactor: add multimodal reply request"
```

---

### タスク4: 公式Foundation Models経由のGemma reply pathを構築する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Services/GemmaFoundationModelFactory.swift`
- 新規作成: `CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift`
- 変更: `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`
- 変更: `CatRobot/Conversation/Integration/ConversationDependencies.swift`
- テスト: 対応するservice testとapp-composition test

**インターフェース:**
- 入力: 検証済みmodel URLと`ReplyRequest`。
- 提供: `LanguageModelSession`からの累積text snapshot。
- 提供: タスク6で使うinject可能な`[any Tool]` session境界。reply toolをcomposeするまではdefaultを空にする。
- 維持: Apple content-tagging classifierは変更しない。

- [ ] **ステップ1: inject可能なsession clientを境界にfactoryの失敗するtestを書く**

live factoryはtext GPU、vision CPU、audioなし、reasoning設定なし、書込み可能なcache path、暫定`24_576` context capacityで`EngineConfig`を生成する。暫定literalはタスク9で測定した最終値へ置き換える。

- [ ] **ステップ2: factoryと明示的なcapability checkを実装する**

```swift
protocol GemmaSessionClient: Sendable {
    func prewarm() async
    func stream(request: ReplyRequest, maximumTokens: Int) async throws -> AsyncThrowingStream<String, Error>
}
```

live factoryは`[any Tool] = []`を受け取り、`LanguageModelSession(model:tools:instructions:)`を生成する。`model.capabilities`で`.vision`と`.toolCalling`が利用可能なことをassertし、reasoningは公開しない。タスク6でlive reply toolを渡し、reply requestでは明示的に`.allowed`を選択する。

- [ ] **ステップ3: 既存のbusy/cancellation semanticsを維持してreply streamingを実装する**

actorごとのactive generationを1つに制限し、Foundation Models errorを既存mapperで変換し、累積snapshotを`ConversationViewModel`と互換に保つ。

- [ ] **ステップ4: live dependencyをcomposeする**

次を使用する:

```swift
classifier: FoundationModelAddressClassifier()
reply: GemmaFoundationModelReplyService(...)
```

`FoundationModelAvailabilityService`は`SystemLanguageModel(useCase: .contentTagging)`のavailabilityを返す。Gemmaのdownload/readinessは`reply.prepare()`の責務とし、artifact欠落時でもpreparation flowを開始できるようにする。

- [ ] **ステップ5: classifierが不変であることを証明する**

production classifierがApple backendのままであることをapp-composition assertionへ追加する。`GemmaAddressClassifier`は導入しない。

- [ ] **ステップ6: reply、classifier、error mapper、compositionの対象testを実行する**

期待結果: fakeを使いSimulator上でPASSし、実modelはdownloadしない。

- [ ] **ステップ7: text backendをcommitする**

```bash
git add CatRobot/Conversation CatRobotTests/Conversation
git commit -m "feat: route replies through LiteRT Foundation Models"
```

---

### タスク5: 決定論的なvision fixtureとFoundation Models vision probeを追加する

**対象ファイル:**
- 新規作成: `CatRobot/Diagnostics/VisionFixtureFactory.swift`
- 新規作成: `CatRobot/Diagnostics/GemmaVisionDeviceProbe.swift`
- テスト: `CatRobotTests/Diagnostics/GemmaVisionDeviceProbeTests.swift`

**インターフェース:**
- 提供: semantic predicateを持つ3つの生成画像。
- 提供: 同じreply serviceを使い、タスク10だけが実行する上限付きdevice probe。

- [ ] **ステップ1: 厳密なCoreGraphics fixtureを生成する**

```swift
enum VisionFixtureID: String, CaseIterable, Sendable {
    case redTriangleAboveBlueSquare
    case blueSquareAboveRedTriangle
    case greenCircleLeftOfYellowStar
}

struct VisionExpectation: Equatable, Sendable {
    let shapes: Set<String>
    let colors: Set<String>
    let relation: String
}
```

白い512 x 512 canvas、彩度の高い色、互いに離れたshapeを使用し、textは埋め込まない。

- [ ] **ステップ2: semantic rubricのtestを書く**

生成文の完全一致はassertしない。`shapes`、`colors`、`count`、`relation`を含むguided responseをparseし、field単位で比較する。

- [ ] **ステップ3: `LanguageModelSession`経由のdevice probeを実装する**

3つのfixtureと1つのno-image controlを入力でき、semantic rubric、5分timeout、累積run ledgerを記録できるprobeを実装する。このタスクではlive model inferenceを実行しない。実機実行はタスク10へ一元化し、retry、prompt修正、fix/revalidate loopを含むPoC全体のvision inference累積8回を共有する。

- [ ] **ステップ4: vision entryをdiagnostic専用に保つ**

probeは実機XCTestまたはDEBUG launch argument経由で公開する。このPoCではproduct向け`PhotosPicker`、media library、image history、編集、圧縮設定、複数画像選択を追加しない。

- [ ] **ステップ5: fixture unit testを実行する**

期待結果: model inferenceなしでPASSする。

- [ ] **ステップ6: vision supportをcommitする**

```bash
git add CatRobot/Diagnostics CatRobotTests/Diagnostics
git commit -m "feat: add bounded Gemma vision probe"
```

---

### タスク6: Gemma reply toolと自動local memoryを実装する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Memory/MemoryFact.swift`
- 新規作成: `CatRobot/Conversation/Memory/LocalMemoryStore.swift`
- 新規作成: `CatRobot/Conversation/Memory/MemoryToolContext.swift`
- 新規作成: `CatRobot/Conversation/Memory/RememberMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/Memory/ForgetMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/Memory/SearchMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/Tools/ReplyToolCallBudget.swift`
- 新規作成: `CatRobot/Conversation/Tools/CurrentDateTimeTool.swift`
- 新規作成: `CatRobot/Conversation/UI/MemoryNoticeView.swift`
- テスト: 対応するmemory test、`CatRobotTests/Conversation/Tools/ReplyToolCallBudgetTests.swift`、`CatRobotTests/Conversation/Tools/CurrentDateTimeToolTests.swift`
- 変更: `GemmaFoundationModelFactory.swift`、`GemmaFoundationModelReplyService.swift`、`ConversationDependencies.swift`、`ConversationViewModel.swift`、`ConversationViewState.swift`、`ConversationView.swift`、各fake

**インターフェース:**
- 提供: local-onlyのfact CRUDとFoundation Modelsの`rememberMemory`、`forgetMemory`、`searchMemory`、`getCurrentDateTime` tool。
- 提供: reply生成成功後だけcommitするturn単位のstaged mutation。
- 上限: user turnごとに4 tool合計12 call、search result合計8件、search-result token合計1,024。保存fact件数、個別tool回数、staged mutation件数の上限は設けない。

- [ ] **ステップ1: 保存record、通知、turn単位transaction境界を定義する**

```swift
struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fact: String
    var supportingQuote: String
    let createdAt: Date
    var updatedAt: Date
    var sourceTurnID: UInt64
}

enum MemoryNotice: Equatable, Sendable {
    case remembered(String)
    case forgotten(String)
}

actor MemoryToolContext {
    func beginTurn(id: UInt64, userText: String) async
    func search(query: String, limit: Int) async -> [MemoryFact]
    func stageRemember(fact: String, supportingQuote: String) async -> String
    func stageForget(memoryIDs: [UUID], supportingQuote: String) async -> String
    func commitTurn() async throws -> [MemoryNotice]
    func rollbackTurn() async
}

actor ReplyToolCallBudget {
    static let maximumCallsPerTurn = 12

    func beginTurn(id: UInt64)
    func consumeCall() throws
}
```

4 toolは同じactor-backed `ReplyToolCallBudget` instanceを共有する。各toolはdecode後、意味検証や本体処理より先に`consumeCall()`を呼ぶ。最初の12 callだけが本体へ進み、13 call目は専用の`ReplyToolCallLimitExceeded`をthrowしてgenerationを終了する。semantic reject、並行dispatch、同じtool/argumentの繰り返しも、decodeされbudgetへ到達した時点で1 callとして数え、cacheによる短絡は行わない。`beginTurn`は実際の新しいuser turn開始時に1回だけcounterをresetし、同じuser turnのcontext retryではresetしない。

- [ ] **ステップ2: persistenceとtransactionのtestを先に書く**

restart後のreload、正規化後に完全一致するduplicateのupdate、安定したsearch順序、8 result/1,024 token上限、現在turnのsearchで返したIDだけの個別削除、4件以上のmutationも個別上限ではrejectされないこと、commit、rollback、新しいstore instanceでもcommit済みfactが残ることを検証する。cancellationまたはgeneration failure後にstaged mutationが見えないことも確認する。shared call budgetは4 toolを任意の順で合計12回まで受理し、13回目のtool本体を実行せずgenerationを専用errorで終了してturn全体をrollbackすること、個別tool回数やmutation件数ではrejectしないこと、semantic reject、並行dispatch、同一tool/argumentの繰り返しもcall数へ含むこと、繰り返したtool本体が12回以内では毎回実行されること、新しいuser turnだけでcounterがresetされることを検証する。

- [ ] **ステップ3: actor-backedのatomic JSON storeを実装する**

Application Supportへ保存する。commit対象turnの変更を1 batchで適用し、同階層のtemporary fileへ書いてatomicに置換することで、複数toolを呼んだturnが部分commitされないようにする。complete file protectionを設定し、fileをbackup対象外にし、factやsupporting quoteをproduction logへ書かない。textは`precomposedStringWithCanonicalMapping`で正規化する。正規化後に完全一致するduplicateではfact、quote、source turn、timestampを更新する。Searchはcommit済みfactと現在のturnでstageされた変更を参照し、正規化した完全一致とsubstring一致だけで絞り、同順位では更新日時降順、最後にUUID文字列表現で安定化する。token overlapやfuzzy rankingは追加しない。空queryでは更新日時が新しい順、同時刻はUUID順で返す。cloud sync、embedding、encryption UIは追加しない。

- [ ] **ステップ4: 3つのFoundation Models toolを実装する**

`@Generable` argumentを次のように定義する:

```swift
@Generable
struct RememberMemoryArguments {
    var fact: String
    var supportingQuote: String
}

@Generable
struct ForgetMemoryArguments {
    var memoryIDs: [String]
    var supportingQuote: String
}

@Generable
struct SearchMemoryArguments {
    var query: String
    var limit: Int
}
```

`rememberMemory`は将来有用な簡潔なfactを1件stageする。`searchMemory`はfact IDとtextを返し、残りのturn単位result/token allowance以内にoutputを制限し、private metadataは返さない。`forgetMemory`は現在のuser turnで`searchMemory`が返したUUIDだけを受け付け、全削除special caseは持たない。2つのmutation toolでは、Unicode正規化後の現在のuser textから抜き出した空でないexact substringを`supportingQuote`として必須とする。型としてdecodeできても意味的に無効な値は、短いreject文字列をGemmaへ返しstorageを変更しない。schema/argumentのdecode failure、13 call目、実際のstore I/O errorは`ToolCallError`としてreply serviceがturn全体をrollbackする。

- [ ] **ステップ5: read-onlyの`getCurrentDateTime` toolを実装する**

```swift
struct CurrentDateTimeSnapshot: Codable, Equatable, Sendable {
    let iso8601: String
    let localDate: String
    let localTime: String
    let isoWeekday: Int
    let timeZoneIdentifier: String
    let utcOffsetSeconds: Int
}

protocol CurrentDateTimeProviding: Sendable {
    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot
}

@Generable
struct CurrentDateTimeArguments {
    var includeSeconds: Bool
}

```

live providerは`Date.now`、Gregorian `Calendar`、`TimeZone.autoupdatingCurrent`をcallごとに読み、`en_US_POSIX`の安定したISO 8601/local表現を生成する。`includeSeconds == true`では`2026-08-24T12:34:56+09:00`/`12:34:56`、falseでは`2026-08-24T12:34+09:00`/`12:34`の粒度にする。`isoWeekday`は月曜を1、日曜を7とする。`CurrentDateTimeTool`はsnapshotをJSON textとして返すだけで、network、file、memory store、UI、system clockを変更しない。日時tool固有のcall gateやcacheは設けず、他の3 toolと同じ`ReplyToolCallBudget`だけを使用する。同一turnで同じargumentが再度呼ばれた場合も、総call budget内なら現在の時計を再取得する。

testでは`FixedCurrentDateTimeProvider`と時刻を順に返すtest providerをinjectし、`2026-08-24T12:34:56+09:00`、`Asia/Tokyo`、ISO weekday 1、`includeSeconds`のtrue/false、同一turnの同一argumentでもproviderが毎回呼ばれて新しいsnapshotを返すこと、総call budget内で繰り返し実行できること、notificationとmemory mutationが発生しないことを検証する。testはsystem clockへ依存させない。

- [ ] **ステップ6: toolをGemma reply sessionへcomposeする**

4つのtoolを渡してreply用`LanguageModelSession`を生成し、`GenerationOptions.ToolCallingMode.allowed`を設定する。memory tool descriptionでは、後で有用になりそうな安定した好み、人間関係、routine、ユーザー提供factを保存し、一時的な観察、推測、assistantが生成した主張、summary、画像だけからの結論は保存しないようGemmaへ指示する。既存factと競合し得るfactを置換または削除する前にはsearchするよう指示する。日時tool descriptionでは、現在日時、曜日、timezone、相対日付の基準が必要な場合だけ呼び、modelの学習知識から現在日時を推測しないよう指示する。4つすべてのtoolへ同じ`ReplyToolCallBudget`をinjectし、13 call目は専用errorをthrowしてtool本体と後続生成を終了する。これらのtoolを`FoundationModelAddressClassifier`やcompaction専用sessionへ渡さず、別のextraction model callも実行しない。

各response前にmemory transactionとshared tool-call budgetの`beginTurn`を呼ぶ。生成中のsnapshotはUI上の一時draftに留め、生成完了後にmemory `commitTurn()`を先に成功させてから、user/assistant pairを`ConversationContextController`へ確定し、speechとnoticeを開始する。cancellation、context/generation failure、13 call目、memory commit failureではmemoryをrollbackし、candidate context turnと一時draftを破棄してmap済みのrecoverable errorを返す。commit failure時も通知とspeechを開始しない。reply actorはこのlifecycleを既存context transactionと同じ順序でserializeし、tool mutationとtranscript stateが食い違わないようにする。

- [ ] **ステップ7: memory commit後だけ小さな通知を表示する**

commit済み`MemoryNotice`を`ConversationViewModel`へpublishし、同一turnの複数mutationを1つのcompactな一時overlay/bannerへまとめる。通知はtapを要求せず、speechを停止せず、focusを奪わず、conversation transcriptへ含めない。表示時間や文字数をdomain contractにせず、内容を短く保ってaccessibility labelを付与する。確認、設定、memory管理screenは追加しない。

- [ ] **ステップ8: toolとUIのintegration testを確認する**

fake tool/session outputを使用し、自動remember/search/forget routing、成功turnのatomic commitと1つにまとめた通知、failure/cancellation/schema-decode時のrollback、searchと日時取得では通知しないこと、日時取得がmemory transactionへ影響しないこと、住所判定classifierとcompaction専用sessionから全reply toolへaccessできないこと、`覚えて`や`忘れて`という語を決定論的な必須条件にしないことを証明する。quote欠落・不一致、4 tool共通の13 call目によるterminal failure、result allowance超過、現在turnでsearchされていないstale/unknown UUID、storage failureを検証し、いずれもstoreを部分変更してはならない。commit failpointではpersistent memoryなし、committed context advanceなし、noticeなし、speechなし、一時draft破棄をまとめてassertする。mutation件数だけを理由にrejectするtestや全削除testは置かない。dependency側のunknown-tool JSON parser testは重複させない。ここでは実model inferenceを使わない。

- [ ] **ステップ9: Gemma reply toolをcommitする**

```bash
git add CatRobot/Conversation/Memory CatRobot/Conversation/Tools CatRobot/Conversation/Integration CatRobotTests/Conversation
git add CatRobot/Conversation/Services CatRobot/Conversation/UI
git commit -m "feat: add Gemma reply tools and local memory"
```

---

### タスク7: token budgetとatomicなauto-compactionを実装する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Context/ConversationTurn.swift`
- 新規作成: `CatRobot/Conversation/Context/TokenBudgeting.swift`
- 新規作成: `CatRobot/Conversation/Context/ConversationContextController.swift`
- テスト: 対応するcontext test
- 変更: `GemmaFoundationModelReplyService.swift`

**インターフェース:**
- 提供: 予測token accountingと再構築可能なcontext state。
- 使用: session-scoped summary、直近4 turn pair、reply-tool definition/result、現在input、image token、output reserve。

- [ ] **ステップ1: 厳密なbudgeting型を定義する**

```swift
struct ConversationContextPolicy: Equatable, Sendable {
    let validatedContextCapacity: Int
    let recentTurnPairCount: Int
    static let operationalFraction = 0.8
    static let compactTargetFraction = 0.6

    var operationalContextBudget: Int {
        Int((Double(validatedContextCapacity) * Self.operationalFraction).rounded(.down))
    }
}

struct TokenProjection: Equatable, Sendable {
    let instructions: Int
    let summary: Int
    let recentTurns: Int
    let toolDefinitions: Int
    let toolResults: Int
    let currentInput: Int
    let images: Int
    let outputReserve: Int
    var total: Int { instructions + summary + recentTurns + toolDefinitions + toolResults + currentInput + images + outputReserve }
}

struct ConversationTurn: Equatable, Sendable {
    enum Role: Equatable, Sendable { case user, assistant }
    let role: Role
    let text: String
}

struct ConversationContextState: Equatable, Sendable {
    let summary: String?
    let recentTurns: [ConversationTurn]
}

struct PreparedReplyContext: Equatable, Sendable {
    let state: ConversationContextState
    let projection: TokenProjection
    let requiresSessionRebuild: Bool
}
```

- [ ] **ステップ2: thresholdとpreservationの失敗するtestを書く**

256/512 output reserve、image、4つのtool definition、memory/date-time tool resultの計上、追加marginのない厳密な80% operational境界、60% compact target、summaryから独立したpersistent store、直近4 pairのverbatim保持、promptが厳密に1回だけ現れること、cancellation/failure時のrollback、繰り返しcompaction、context exceeded時の1回だけのretryを検証する。

- [ ] **ステップ3: context actorを実装する**

```swift
actor ConversationContextController {
    func prepare(_ request: ReplyRequest) async throws -> PreparedReplyContext
    func record(user: ReplyRequest, assistant: String) async
    func recoverFromContextExceeded(_ request: ReplyRequest) async throws -> PreparedReplyContext
    func reset() async
}
```

Compactionはtoolを持たない専用Gemma sessionで古いconversation turnをsummary化する。完了済みtool callとtool outputをsummary sourceから除外し、直近4 pairをverbatimで保持し、reply sessionへ4つのtool definitionを再度attachする。`ConversationContextPolicy.compactTargetFraction == 0.6`を唯一のsource of truthとして、validated capacityの60%以下をtargetにreplacement transcript/sessionを構築し、preparation成功後だけswapする。20% reserve以外の隠れmarginは設けない。persistent memoryは`LocalMemoryStore`に残し、必要時に`searchMemory`で再取得する。

- [ ] **ステップ4: context exceeded時のretryを1回だけ追加する**

現在のpromptを2回appendしてはならない。compact-and-retryが1回失敗したら、map済みerrorを返す。

- [ ] **ステップ5: token estimationを3回だけcalibrateする**

small、medium、near-thresholdの各値をprovider/runtime accountingと1回ずつ比較する。そのevidenceを再利用し、反復的なestimator tuningは行わない。

- [ ] **ステップ6: context unit testとintegration testを実行する**

期待結果: fake session clientを使い、modelなしでPASSする。

- [ ] **ステップ7: compactionをcommitする**

```bash
git add CatRobot/Conversation/Context CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift CatRobotTests/Conversation
git commit -m "feat: add bounded conversation compaction"
```

---

### タスク8: model preparation、memory、cancellationをapp lifecycleへ統合する

**対象ファイル:**
- 変更: `ConversationDependencies.swift`
- 変更: `ConversationViewModel.swift`
- 変更: `ConversationViewState.swift`
- 変更: `ConversationView.swift`
- 変更: integration fakeとtest

**インターフェース:**
- 維持: 既存lifecycle generation ID、turn ownership、classifier sequence、audio teardown、reply reset behavior。
- 追加: 単純なmodel準備中state、memory-tool transaction完了、一時memory通知。Visionはタスク5のdiagnostic pathに限定する。

- [ ] **ステップ1: 新しいflowのintegration testを書く**

必須sequence:

```text
voice: recognize -> Apple classify -> Gemma reply -> speak
typed: submit -> Gemma reply -> speak
memory mutation: begin turn -> Gemma tool call -> stage -> transient draft -> memory commit -> context record -> speak + notice
memory rollback: begin turn -> Gemma tool call -> stage -> cancel/generation fail/commit fail/tool limit -> discard draft + memory + candidate context; no speech/notice
current date/time: begin turn -> shared 12-call budget -> Gemma tool call -> read current device clock -> reply without notice
contextExceeded: compact -> retry once -> speak or fail
cancel: stop streaming -> preserve last committed context
```

- [ ] **ステップ2: `prewarm()`を明示的なmodel preparationへ置き換える**

signingやglobal configurationを変更せず、準備中かどうかだけをUIへ公開する。voice preflightではApple classifier availabilityを確認し、audio sessionをactivateする前に`reply.prepare()`を完了させる。typed inputでも生成前にreply backendをprepareする。model-preparation failureはrecover可能なCat Robot errorへmapする。byte単位progress UIは追加しない。

- [ ] **ステップ3: Apple classifierの順序を維持する**

voice turnではGemma replyより前に必ず`dependencies.classifier.classify`を呼ぶ。typed turnは既存のdirect-reply behaviorを維持してよい。

- [ ] **ステップ4: 既存のconcurrency ownershipを維持する**

session mutation周辺にdetached taskを導入しない。すべてのcontext/memory mutationは対応actorを経由し、UI変更は`@MainActor`に留める。一時通知はpresentation stateだけでありspeechを停止しない。streaming draftは表示してよいが、speechとcontext確定はmemory commit成功まで開始しない。

- [ ] **ステップ5: 既存および新規integration testを実行する**

期待結果: 既存のlifecycle、interruption、clarification、cancellation、latency、typed-input testが引き続きgreenになる。

- [ ] **ステップ6: app integrationをcommitする**

```bash
git add CatRobot/Conversation CatRobotTests/Conversation
git commit -m "feat: integrate Gemma context and memory lifecycle"
```

---

### タスク9: 上限付き実機context calibrationを実行し、測定capacityを固定する

**対象ファイル:**
- 新規作成: `CatRobot/Diagnostics/GemmaContextCalibrationProbe.swift`
- テスト: `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`
- 測定後に変更: `GemmaFoundationModelFactory.swift`、`ConversationContextController.swift`
- evidence追記: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`

**インターフェース:**
- 提供: runtimeで受理されたboundary、validated capacity、80% operational budget。
- 制約: search、stability、実compaction、flake retry、修正後の再確認を含むfull-model context runは累積14回以内。ledgerはタスク9のfix/revalidate loopでもresetしない。

- [ ] **ステップ1: 決定論的なrequestとresult recordを実装する**

```swift
struct ContextProbeResult: Codable, Equatable, Sendable {
    let configuredCapacity: Int
    let actualInputTokens: Int
    let outputReserve: Int
    let coldStart: Bool
    let outcome: String
    let timeToFirstTokenSeconds: Double?
    let totalResponseSeconds: Double?
    let residentBytesBefore: UInt64?
    let residentBytesAfter: UInt64?
    let thermalBefore: String?
    let thermalAfter: String?
}
```

capacity判定に必須なのはconfigured capacity、実input/output reserve、cold/warm条件、成功またはfailure outcomeだけとする。latency、RSS、thermalは取得できた場合のdiagnosticであり、欠落だけをacceptance failureにしない。

- [ ] **ステップ2: 有限search controllerをunit testする**

14枠のうち常に3回のstability確認と1回の実compactionを先に確保する。まず`2_048` smokeを1回実行し、失敗した場合は残budget内のflake確認1回を除いてsearchを進めずblockerとして記録する。成功したら`32_000`を1回probeする。`32_000`が成功した場合は同条件の成功を合計3回連続へ到達させ、そのうち1回以上をcold startにする。失敗した場合は次に`16_384`をprobeし、成功なら`24_576`、失敗なら`8_192`を選んで成功lower boundと失敗upper boundを作る。その後のmidpoint refinementは最大2回、受理可能なalignmentへ丸める。stability 3回とcompaction 1回の残枠を侵食する前にsearchを停止し、同じbinary/configurationで3回連続成功した最高candidateを`validatedContextCapacity`とする。sub-512 tokenの精度は求めない。すべてのprobe、fallback、flake retry、実compaction、fix後の再確認は1つの累積14-run ledgerを共有する。

- [ ] **ステップ3: Foundation Models経由で実機probeを逐次実行する**

device `00008140-000610311A90801C`、runごとの10分timeout、決定論的なsynthetic corpusを使用する。512 output reserveを含める。複数のmulti-GB engineが保持されないよう、configurationを変更するたびにcached LiteRT engineをreleaseする。

- [ ] **ステップ4: 無制限retryをせずoutcomeを分類する**

invalid configuration、context exceeded、OOM/app termination、timeout、cancellation、memory warning、thermal serious/critical、output failureを区別する。変更のないfailed commandへのflake retryは残枠がstability 3回とcompaction 1回を確保したうえで存在する場合だけ最大1回許可し、14回の上限に含める。hard budget到達後はretryしない。

- [ ] **ステップ5: 結果をproduction configurationへ固定する**

暫定`24_576` literalを、同じbinaryとconfigurationで3回連続成功し、そのうち1回以上がcold startだった最高candidateへ置き換える。最高candidateがstability確認に失敗した場合、残りのrun budgetは観測済みの低いcandidateを確認するためだけに使い、14回上限を延長しない。`ConversationContextPolicy`を唯一のsource of truthとし、別のformulaやmarginを重ねない:

```swift
let operationalContextBudget = contextPolicy.operationalContextBudget
```

推測値を`runtimeHardLimit`と呼ばない。boundaryを解決できない場合は、成功lower boundと失敗upper boundを報告する。

- [ ] **ステップ6: 実際のauto-compaction eventを1回実行する**

最終capacityを使い、現在promptが1回だけ現れること、summaryと直近4 pairが残ること、persistent factが分離されたままであること、compact後もconversationが継続することを証明する。この1回も累積14-run ledgerに含める。

- [ ] **ステップ7: task-level validation bundleを実行する**

測定値と実compaction evidenceを書き込んだ後に、context search controller/calibration probeのunit testと、最終`validatedContextCapacity`・80% operational budget・60% compact targetを含むapp targetのbuild/compileをまとめて1回実行する。追加のcontext sweepは行わない。

- [ ] **ステップ8: calibrated configurationとevidenceをcommitする**

```bash
git add CatRobot/Diagnostics CatRobotTests/Diagnostics CatRobot/Conversation docs/validation
git commit -m "test: calibrate Gemma context on iPhone 16 Pro"
```

---

### タスク10: 統合実機acceptanceを完了する

**対象ファイル:**
- 更新: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`
- source変更はscope内の具体的なacceptance failureへの対応に限る

**インターフェース:**
- 提供: すべての完了条件に対する有限なevidence。

以下のステップ1〜8を1つのtask-level validation bundleとして、修正を挟まず最後まで実行する。途中のfailureは記録し、依存関係上実行可能な残りの項目を完了してからまとめて修正する。再実行はfailureの影響範囲だけとし、「タスク単位の実装・検証ルール」の最大2 loopと、vision 8 inference・tool 6 user turnの累積ledgerへ含める。budget到達後に追加runは行わない。

- [ ] **ステップ1: 最終generator検証とSimulator検証を1回だけ実行する**

full Simulator suiteを1回だけ実行する。`ruby scripts/test_generate_project.rb`はタスク1後にgenerator、project、scheme、`Package.resolved`の入力が変更されている場合だけ再実行し、それ以外はタスク1のPASS evidenceを再利用する。直前のtargeted testは追加しない。具体的なstale-cache signatureがない限りDerivedDataをcleanしない。

- [ ] **ステップ2: 実機でbuild、install、launchする**

Xcode build、SDK、device OS/build、LiteRT version、Package.resolved pin、model revision、model size、初回SHAの1回分の結果を記録する。

- [ ] **ステップ3: textとroutingを確認する**

voice発話がApple content-tagging classificationの後にFoundation Models-backed Gemma replyへ進むことを証明する。typed発話がGemma replyを使うことも証明する。文章の完全一致をassertせず256/512上限を確認する。

- [ ] **ステップ4: 上限付きvision acceptanceを実行する**

タスク5で実装したprobeを使い、baseとして3つのfixtureとno-image controlを各1回実行する。失敗caseだけを再実行でき、prompt修正は全体で最大1回とする。各inferenceは5分timeout、retry、prompt修正、fix/revalidate loopを含む累積8 inference以内とし、修正後もledgerをresetしない。semantic rubricと、privateなuser contentを含まないraw responseを記録する。

- [ ] **ステップ5: reply tool acceptanceを実行する**

tool acceptanceは順番を固定した文章一致testではなく、次のscenario matrixを累積6 user turn以内で観測する。各turnは5分timeoutとし、fix/revalidate loopでもledgerをresetしない。

1. `覚えて`と言わずに安定したfact Aを述べ、autonomous `rememberMemory`、成功commit、小さな非blocking通知を観測する。通知がspeechを停止せず、searchだけのturnでは表示されないことも確認する。toolが呼ばれなかった場合だけ、同じ文のretryではなく別の安定したfact Bを次turnで述べる。最初で成功した場合は空いたturnを通常のno-tool controlに使う。
2. restart後に保存factと意味的に関連する質問を行い、`searchMemory`を観測する。
3. そのfactの削除を依頼し、必要なsearch、`forgetMemory`、成功commit、小さな非blocking通知を観測する。
4. 明らかに一時的な観察を述べ、memory mutationも日時toolも呼ばれないことを観測する。
5. 現在日時・曜日・timezoneを尋ね、`getCurrentDateTime`を観測する。返却instantがtool call前後のdevice clock範囲内で、timezone identifier/offsetが端末値と一致し、通知とmemory mutationがないことを確認する。

PoC完了には少なくとも`rememberMemory`、`searchMemory`、`forgetMemory`、`getCurrentDateTime`を各1回liveで観測する。stochasticな未選択を同一promptで反復したり、無制限にtool descriptionをtuningしたりしない。6 turnで観測できなければその事実をFAILとして記録する。各turnの総call数、各tool名、検証済みargument、tool result、commit/rollback outcome、user-visible通知を記録し、無関係なprivate conversationは記録しない。transaction failure、13 call目、commit failpointの決定論的保証はタスク6/8のunit/integration test evidenceを再利用する。

- [ ] **ステップ6: warm-cache behaviorとoffline inferenceを確認する**

DEBUG/test-only SHA invocation counterまたはsignpostを用い、通常のwarm launch前後でfull SHA countのdeltaが0であることを証明する。model install後にnetworkを無効化またはblockした状態で実際のFoundation Models-backed Gemma inferenceを1回成功させ、通常inferenceにnetwork accessが不要なことを証明する。

- [ ] **ステップ7: 制限事項を記録する**

LiteRT SwiftとFoundation Models adapterがearly-preview dependencyであること、v0.16.0 adapterのguided generationとtool selectionはhard constrained decodingではなくsoftなprompt-driven JSONであること、memoryに値するturnや現在日時を尋ねるturnではtool round tripが追加されること、`getCurrentDateTime`は端末のsystem clock/timezoneの正確性に依存すること、transcript replayによりlong-context TTFTが増える可能性があること、modelが約2.6 GBであること、production readinessは主張しないことを記載する。

- [ ] **ステップ8: 最終handoffを行う**

branch、worktree、base SHA、変更file、厳密なpin、command/result、実機結果、vision/context/tool table、各累積run ledgerとtimeout outcome、validated capacity、operational budget、有効compact threshold、SHA実行回数と理由、各タスクで使用したfix/revalidate loop数、残存finding、制限事項、validation report pathを報告する。Critical/Important finding、未達の完了条件、または2 loop後も解消しないfailureがあれば完了を主張せず、該当タスクをblockedとして報告する。

## Subagent routing方針

- RootがGit/worktree、shared interface、package integration、Xcode、signing、Simulator、実機、model download、context run、結果統合、completion statusを所有する。
- `gpt-5.6-luna`の`max`は、file inventory、独立fixture生成、独立unit test、table整形など、上限が明確なmechanical taskだけを担当してよい。
- `gpt-5.6-sol`の`xhigh`は、Foundation Models/LiteRT設計、Swift concurrency、context log解釈、およびタスク4、6、7、9で条件を満たした場合の重いreviewを担当する。
- `gpt-5.6-terra`は使用しない。
- 同時にactiveにするsubagentは最大2つとし、taskとfile ownershipを重複させない。
- subagentを使うためだけに作業を分割せず、Xcode操作やdevice操作を委譲しない。1タスクを複数の実装agentへステップ分割せず、ステップ終了時のreviewerも起動しない。
- reviewer eligibilityは「タスク単位の実装・検証ルール」に従う。対象タスクでも1人だけとし、実装agent、spec reviewer、code-quality reviewerを順番に回す多段workflowは使用しない。findingへの修正と再検証はタスク担当へ戻してまとめて行う。
- subagentが利用できない場合、Terraで代替せずrootが進める。

## Retryとevidence再利用方針

- 変更のないfailed commandはflake確認のため1回だけrerunしてよい。
- それ以降のattemptには、新しい仮説と実質的な変更を必須とする。
- ステップ途中ではfailureごとのfix/revalidate loopへ入らず、タスク境界でfailureをまとめる。安全に後続ステップへ進めない前提failureだけは即時blockerとする。
- タスク境界でfailure signatureが変化し、測定可能な進捗があっても、fix/revalidateはそのタスクの最大2 loopを超えない。
- context 14 run、vision 8 inference、tool 6 user turnなどのtask固有hard budgetはgenericなflake retryより優先する。残budgetがなければretryせず、得られたevidenceと未達条件を報告する。
- documentation-onlyの変更では、full build、device run、model hash、context sweepを実行しない。
- source、binary、model、device、関連configurationが不変なら既存evidenceを再利用する。
- corruption pathのtestには小さなfixtureを使い、実modelを意図的に破損させない。

## 完了条件

単一のvalidation reportに以下すべてのevidenceがある場合だけ、PoCを完了とする:

1. 厳密な公式LiteRT packageと`LiteRTLMFoundationModels` productがXcode 27でresolveする。
2. Reply生成が`LanguageModelSession(model: LiteRTLanguageModel)`を経由する。
3. Apple `.contentTagging`が住所判定classifierとして維持され、voice reply生成より前に実行される。
4. app configurationとUIにthinking/reasoning modeが存在しない。
5. 通常replyは256、詳細・画像replyは512を上限とする。
6. 3つの決定論的vision fixtureとno-image controlが、retryと修正後再確認を含む累積8 inference以内でsemantic rubricを満たす。
7. Gemmaが`rememberMemory`、`searchMemory`、`forgetMemory`を自律的に呼べる。明示的なcommand wordingがなくてもfactを保存できる一方、検証済みの現在user quoteだけをmutation sourceにでき、削除は現在turnのsearchで返したIDだけを対象にする。failure/cancellation/commit failure時はmemory、一時draft、candidate contextをrollbackし、restart/search/deletionが動作し、commit済みmutationでは小さな非blocking通知だけを表示する。保存fact件数やmutation件数だけの上限は設けない。
8. Gemmaが必要時だけ`getCurrentDateTime`を呼び、callごとに端末由来の現在日時、ISO曜日、timezone identifier、UTC offsetを取得できる。4 toolは個別上限なしで1 turn合計12 call以内とし、同じtool/argumentでもcacheせず毎回実行する。13 call目はtool本体を実行せずgenerationを終了してturn全体をrollbackする。日時toolはread-onlyで、network、永続化、通知、memory mutationを行わない。
9. Contextのadaptive search、3回連続stability、実compactionがfix/revalidateを含む累積14 run以内に完了し、success/failure boundと、1回以上のcold startを含むvalidated capacityを記録する。
10. Operational budgetがvalidated capacityの厳密に80%、compact targetが60%で追加marginはなく、実際のcompaction後もsummary、直近4 pair、独立memory storeと再attachした4 tool、現在promptの厳密に1回の出現を維持する。
11. 初回model integrityが検証され、変更のないwarm launch前後のSHA invocation deltaが0であり、network無効状態でも実inferenceが成功する。
12. Generator contract、Simulator suite、signed device build、統合device acceptanceがPASSする。
13. validation reportにcontext、vision、toolの累積実行ledgerとtimeout outcomeがあり、各hard budgetを超えていない。
14. push、PR、merge、comparison-branch mutation、fallback model/library、scope外refactorを行わない。
