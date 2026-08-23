# Cat Robot Gemma 4 Foundation Models PoC 実装計画

> **実装を担当するエージェントへ:** 必須サブスキルとして `superpowers:subagent-driven-development`（推奨）または `superpowers:executing-plans` を使用し、この計画をタスク単位で実装すること。進捗管理にはチェックボックス（`- [ ]`）を使用する。この計画でユーザーが承認したレビュー上限は、問題がなくなるまでreview/fix loopを続けるスキル既定値より優先される。

**目標:** Appleのcontent-tagging住所判定classifierを維持したまま、iOS 27 Foundation Models API経由でGemma 4 E2BをCat Robotの応答・画像理解backendとして動かす。上限付きcontext compactionとGemma主導のローカルmemory toolを追加し、接続済みiPhone 16 Pro上でPoCを実証する。

**アーキテクチャ:** 既存の逐次的な住所判定フローを維持し、応答生成だけをGoogle公式の`LiteRTLMFoundationModels` adapterへ置き換える。model storeが固定済みartifactを一度だけ検証し、状態を持つreply actorがFoundation Modelsのtranscriptとcompactionを所有する。Gemmaのreply sessionには、transactionalなlocal storeをbackendとする検証付き`rememberMemory`、`forgetMemory`、`searchMemory` toolを渡す。toolが必要かはGemmaが判断し、アプリは変更をstageして応答成功後だけcommitし、小さな非blocking通知を表示する。実機probeはアプリと同じ`LanguageModelSession`経路を使用し、実行回数に厳格な上限を設ける。

**技術スタック:** Swift 6.0 strict concurrency、SwiftUI、iOS 27、Xcode 27、Apple Foundation Models、Google LiteRT-LM `0.16.0`、XCTest、Ruby `xcodeproj 1.27.0`。

**仕様:** `PLAN.md`自体を承認済みPoC仕様兼実行計画とする。以下の完了条件と検証予算を規範とする。

## ベースラインとworkspace

- Worktree: `/Users/goodapple/workspace/Cat_robot/.worktrees/feature-gemma4-foundationmodels-poc`
- Branch: `feature/gemma4-foundationmodels-poc`
- Base: local `main`の`d3db63e5e4770d17fb4180e0d4a5baac56d4d051`
- 既存の比較branchはread-only参照とする: `feature/gemma4-e2b-comparison`
- `ruby scripts/test_generate_project.rb`: 2026-08-24時点でPASS。
- Xcode 27で既存アプリとtestがiOS 27 Simulator向けにcompileできることを確認済み。ただしautomationを2回試した際の`.xcresult` bundleはいずれも不完全だったため、test完了は主張しておらず、それ以上のretryもしていない。実装開始時に新しいresult bundleでbaseline testを1回だけ実行する。再び不完全なら、同一条件で再実行せずblockerとして記録する。

## 全体制約

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`を使用し、globalな`xcode-select`は変更しない。
- deployment targetをiOS 27.0、project upgrade markerをXcode 27へ上げる。
- local `main`だけをbaseにする。fetch、pull、push、PR作成、mergeは禁止する。
- `feature/gemma4-e2b-comparison`をcheckout、merge、rebase、cherry-pick、編集しない。調査には`git show`と`git diff`だけを使用する。
- `https://github.com/google-ai-edge/LiteRT-LM`を厳密に`0.16.0`へ固定し、product `LiteRTLMFoundationModels`をlinkする。
- `LiteRTLanguageModel`はApple `LanguageModelSession`経由で使用する。LiteRT直接生成はdiagnostic専用であり、応答・画像理解の完了条件を満たさない。
- `FoundationModelAddressClassifier`は`SystemLanguageModel(useCase: .contentTagging)`をbackendとして維持し、classifier実行後にreplyを逐次実行する。
- アプリlevelのthinking/reasoning設定、UI、transcript保存、output strippingを追加しない。
- 通常応答の上限は256 output tokens、明示的な詳細要求と画像応答は512とする。
- 通常の文体は結論先行の1〜3文とし、詳細は要求された場合だけ展開する。
- `rememberMemory`、`forgetMemory`、`searchMemory` toolはGemma reply sessionだけに渡す。Apple住所判定classifierにはmemory toolを一切渡さない。
- Foundation Modelsのtool-calling modeは`.allowed`を使い、`.required`は使わない。通常応答に不要なtool round tripを強制しない。
- Gemmaは通常のユーザー発話から有用な事実を自律的に保存してよい。変更の`supportingQuote`がUnicode正規化後の現在のユーザーtext内に存在する場合だけ有効とする。assistant応答、summary、tool output、画像だけからの推論はmemory sourceにしない。
- 生成中のmemory変更はstageし、応答成功後だけcommitして小さな一時通知を表示する。確認dialogやblockingなmemory UIは追加しない。
- context reserveは20%とする: `operationalContextBudget = floor(validatedContextCapacity * 0.8)`。
- model context calibrationはfull-model 14回、vision検証はinference 8回を上限とする。
- 統合memory-tool検証はuser-turn reply request 6回を上限とする。
- whole-diffを対象とした正式なreview/fix/revalidateは最大2 roundとする。第1 roundがcleanならreviewを終了する。
- inputとbinaryが不変なら、full SHA、full build、full test suite、device sweep、context sweepを繰り返さない。
- production download orchestration、cloud memory、embedding、無関係なrefactor、別model、別LiteRT version、fallback adapterは実装しない。

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
- `scripts/generate_project.rb`を変更: iOS 27、Xcode 27 marker、厳密なLiteRT package、`LiteRTLMFoundationModels` productを設定する。
- `scripts/test_generate_project.rb`を変更: 厳密なdependency、product、deployment target、marker、model ignore ruleをassertする。
- `CatRobot.xcodeproj/project.pbxproj`と`CatRobot.xcodeproj/xcshareddata/xcschemes/CatRobot.xcscheme`を再生成する。
- package resolutionにより`CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`を作成する。
- `README.md`を変更: Xcode 27/iOS 27要件、model size/download、PoCの制限を記載する。

### Domainとintegration

- `CatRobot/Conversation/Domain/ReplyRequest.swift`を作成: multimodal requestとoutput policyを定義する。
- `CatRobot/Conversation/Domain/ConversationServices.swift`を変更: `ReplyRequest`を受け取り、明示的なGemma preparationを公開する。
- `CatRobot/Conversation/Domain/ConversationTypes.swift`を変更: UI recoveryで個別処理が必要なmodel-download errorとmemory errorだけを追加する。
- `CatRobot/Conversation/Integration/ConversationDependencies.swift`を変更: Apple classifier availabilityとGemma reply preparationをcomposeする。
- `CatRobot/Conversation/Integration/ConversationViewModel.swift`を変更: memory-tool transaction完了、一時通知、既存のcancellation ownershipを扱う。
- `CatRobot/Conversation/UI/ConversationViewState.swift`と`ConversationView.swift`を変更: 上限付きmodel-preparation進捗と小さな非blocking memory通知を扱う。

### Gemma backend

- `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaModelStore.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaFoundationModelFactory.swift`を作成する。
- `CatRobot/Conversation/Services/GemmaFoundationModelReplyService.swift`を作成する。
- `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`を変更: 置換対象のApple general reply modelではなく、Apple content-tagging classifierを確認する。
- compile probeで実際に観測した具体的なiOS 27 errorに限り、`CatRobot/Conversation/Services/FoundationModelErrorMapper.swift`を変更する。

### Contextとmemory

- `CatRobot/Conversation/Context/ConversationTurn.swift`を作成する。
- `CatRobot/Conversation/Context/TokenBudgeting.swift`を作成する。
- `CatRobot/Conversation/Context/ConversationContextController.swift`を作成する。
- `CatRobot/Conversation/Memory/MemoryFact.swift`を作成する。
- `CatRobot/Conversation/Memory/LocalMemoryStore.swift`を作成する。
- `CatRobot/Conversation/Memory/MemoryToolContext.swift`を作成する。
- `CatRobot/Conversation/Memory/RememberMemoryTool.swift`を作成する。
- `CatRobot/Conversation/Memory/ForgetMemoryTool.swift`を作成する。
- `CatRobot/Conversation/Memory/SearchMemoryTool.swift`を作成する。
- `CatRobot/Conversation/UI/MemoryNoticeView.swift`を作成する。

### PoC probeとevidence

- `CatRobot/Diagnostics/VisionFixtureFactory.swift`を作成する。
- `CatRobot/Diagnostics/GemmaVisionDeviceProbe.swift`を作成する。
- `CatRobot/Diagnostics/GemmaContextCalibrationProbe.swift`を作成する。
- `CatRobot/Diagnostics/PoCProcessMetrics.swift`を作成する。
- `CatRobotTests/Diagnostics/GemmaVisionDeviceProbeTests.swift`を作成する。
- `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`を作成する。
- 実装中に`docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`を作成する。

### Unit testとintegration test

- `CatRobotTests/Conversation/Services`、`Context`、`Memory`配下に、各新規serviceと対応するtestを作成する。
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
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -resultBundlePath /tmp/CatRobotGemmaBaseline.xcresult \
  test
```

期待結果: 既存suiteがPASSした完全なresult bundle。再びbundleが不完全ならenvironment blockerを記録し、同一条件では再実行しない。

- [ ] **ステップ2: 失敗するgenerator assertionを書く**

generator contractへ次の要件を追加する:

```ruby
LITERT_LM_URL = "https://github.com/google-ai-edge/LiteRT-LM"
LITERT_LM_VERSION = "0.16.0"
LITERT_PRODUCT = "LiteRTLMFoundationModels"
DEPLOYMENT_TARGET = "27.0"
```

package referenceが1つだけであること、厳密なversion、app target上のFoundation Models product、test targetに直接package productがないこと、`LastUpgradeCheck == "2700"`をassertする。

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

厳密なtagにこのAPIがない場合、dependencyを切り替えず停止する。

- [ ] **ステップ7: project contractをcommitする**

```bash
git add .gitignore README.md scripts CatRobot.xcodeproj
git commit -m "build: add iOS 27 LiteRT Foundation Models dependency"
```

---

### タスク2: 上限付きartifact downloadと一度限りのintegrity検証を実装する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Services/GemmaModelDescriptor.swift`
- 新規作成: `CatRobot/Conversation/Services/GemmaModelIntegrity.swift`
- 新規作成: `CatRobot/Conversation/Services/GemmaModelStore.swift`
- テスト: `CatRobotTests/Conversation/Services`配下の対応ファイル

**インターフェース:**
- 提供: `GemmaModelPreparing.prepare(progress:) async throws -> URL`。
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

struct GemmaModelDownloadProgress: Equatable, Sendable {
    let receivedBytes: Int64
    let expectedBytes: Int64?
}

protocol GemmaModelPreparing: Sendable {
    var installedModelURL: URL { get }
    func prepare(progress: (@Sendable (GemmaModelDownloadProgress) -> Void)?) async throws -> URL
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

- [ ] **ステップ3: streaming SHAとatomic installationを実装する**

2.6 GB全体をmemoryへloadせず、chunk readするCryptoKit `SHA256`を使用する。UUID付きpartial pathへdownloadし、byte数とdigestを検証してverification recordを書き、最後に所定位置へrenameする。

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
    func prepare(progress: (@Sendable (GemmaModelDownloadProgress) -> Void)?) async throws
    func streamReply(to request: ReplyRequest) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}
```

- [ ] **ステップ3: 決定論的な詳細要求判定を実装する**

明示的な日本語の詳細要求phraseまたは画像がある場合だけ512を選択する。通常の長いpromptだけでは応答上限を自動拡張しない。

- [ ] **ステップ4: fakeと既存testをcompile可能に更新する**

住所判定classifierのinterfaceは変更しない。

- [ ] **ステップ5: domain contractをcommitする**

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
- 提供: タスク6で使うinject可能な`[any Tool]` session境界。memoryをcomposeするまではdefaultを空にする。
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

live factoryは`[any Tool] = []`を受け取り、`LanguageModelSession(model:tools:instructions:)`を生成する。`model.capabilities`で`.vision`と`.toolCalling`が利用可能なことをassertし、reasoningは公開しない。タスク6でlive memory toolを渡し、reply requestでは明示的に`.allowed`を選択する。

- [ ] **ステップ3: 既存のbusy/cancellation semanticsを維持してreply streamingを実装する**

actorごとのactive generationを1つに制限し、Foundation Models errorを既存mapperで変換し、累積snapshotを`ConversationViewModel`と互換に保つ。

- [ ] **ステップ4: live dependencyをcomposeする**

次を使用する:

```swift
classifier: FoundationModelAddressClassifier()
reply: GemmaFoundationModelReplyService(...)
```

`FoundationModelAvailabilityService`は`SystemLanguageModel(useCase: .contentTagging)`のavailabilityを返す。Gemmaのdownload/readinessは`reply.prepare(progress:)`の責務とし、artifact欠落時でもpreparation flowを開始できるようにする。

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
- 提供: 同じreply serviceから得る上限付きdevice evidence。

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

3つのfixtureと1つのno-image controlを厳密に実行する。失敗caseは同一条件で1回だけretryできる。vision inferenceは合計8回を超えてはならない。明確なprompt修正は1回だけ許可し、それ以上のtuningはevidenceを残して停止する。

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

### タスク6: tool駆動の自動local memoryを実装する

**対象ファイル:**
- 新規作成: `CatRobot/Conversation/Memory/MemoryFact.swift`
- 新規作成: `CatRobot/Conversation/Memory/LocalMemoryStore.swift`
- 新規作成: `CatRobot/Conversation/Memory/MemoryToolContext.swift`
- 新規作成: `CatRobot/Conversation/Memory/RememberMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/Memory/ForgetMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/Memory/SearchMemoryTool.swift`
- 新規作成: `CatRobot/Conversation/UI/MemoryNoticeView.swift`
- テスト: 対応するmemory test
- 変更: `GemmaFoundationModelFactory.swift`、`GemmaFoundationModelReplyService.swift`、`ConversationDependencies.swift`、`ConversationViewModel.swift`、`ConversationViewState.swift`、`ConversationView.swift`、各fake

**インターフェース:**
- 提供: local-onlyのfact CRUDとFoundation Modelsの`rememberMemory`、`forgetMemory`、`searchMemory` tool。
- 提供: reply生成成功後だけcommitするturn単位のstaged mutation。
- 上限: 保存fact 50件。user turnごとに受理するmemory-tool call 5回、search 2回、search result合計8件、search-result token合計1,024、staged mutation 3件。

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
    func stageForget(memoryIDs: [UUID], forgetAll: Bool, supportingQuote: String) async -> String
    func commitTurn() async throws -> [MemoryNotice]
    func rollbackTurn() async
}
```

- [ ] **ステップ2: persistenceとtransactionのtestを先に書く**

restart後のreload、正規化後に完全一致するduplicateのupdate、安定したsearch順序、50 fact上限、8 result/1,024 token上限、個別削除、全削除、3 mutation上限、commit、rollback、新しいstore instanceでもcommit済みfactが残ることを検証する。cancellationまたはgeneration failure後にstaged mutationが見えないことも確認する。

- [ ] **ステップ3: actor-backedのatomic JSON storeを実装する**

Application Supportへ保存する。commit対象turnの変更を1 batchで適用し、同階層のtemporary fileへ書いてatomicに置換することで、複数toolを呼んだturnが部分commitされないようにする。complete file protectionを設定し、fileをbackup対象外にし、factやsupporting quoteをproduction logへ書かない。textは`precomposedStringWithCanonicalMapping`で正規化する。正規化後に完全一致するduplicateではfact、quote、source turn、timestampを更新する。50 fact上限到達時は既存factを黙ってevictせず、新規factをrejectする。Searchはcommit済みfactと現在のturnでstageされた変更を参照し、正規化substring/token overlapで決定論的に順位付けし、最後のtie-breakerにrecencyを使う。空queryでは更新日時が新しいfactを返す。cloud sync、embedding、encryption UIは追加しない。

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
    var forgetAll: Bool
    var supportingQuote: String
}

@Generable
struct SearchMemoryArguments {
    var query: String
    var limit: Int
}
```

`rememberMemory`は将来有用な簡潔なfactを1件stageする。`searchMemory`はfact IDとtextを返し、残りのturn単位result/token allowance以内にoutputを制限し、private metadataは返さない。`forgetMemory`は現在のturnでsearchから返されたUUIDだけを受け付ける。ただし`forgetAll == true`の場合を除く。2つのmutation toolでは、Unicode正規化後の現在のuser textに完全なsubstringとして存在する、空でない`supportingQuote`を必須とする。型としてdecodeできても意味的に無効な値は、短いreject文字列をGemmaへ返しstorageを変更しない。schema/argumentのdecode failureは`ToolCallError`となり、reply serviceがturn全体をrollbackする。正常にdecodeされたtool callからthrowしてよいのは、実際のstore I/O errorだけとする。

- [ ] **ステップ5: toolをGemma reply sessionへcomposeする**

3つのtoolを渡してreply用`LanguageModelSession`を生成し、`GenerationOptions.ToolCallingMode.allowed`を設定する。tool descriptionでは、後で有用になりそうな安定した好み、人間関係、routine、ユーザー提供factを保存し、一時的な観察、推測、assistantが生成した主張、summary、画像だけからの結論は保存しないようGemmaへ指示する。既存factと競合し得るfactを置換または削除する前にはsearchするよう指示する。`MemoryToolContext`はturn単位上限を超えるcallに、短い`tool budget exhausted; answer without another memory tool` resultを返してrejectする。これらのtoolを`FoundationModelAddressClassifier`へ渡さず、別のextraction model callも実行しない。

各response前に`beginTurn`を呼ぶ。responseが完全に成功した場合は`commitTurn`、cancellation、context failure、generation failureでは`rollbackTurn`を呼ぶ。reply actorはこのlifecycleを既存context transactionと同じ順序でserializeし、tool mutationとtranscript stateが食い違わないようにする。

- [ ] **ステップ6: commit後だけ小さな通知を表示する**

commit済み`MemoryNotice`を`ConversationViewModel`へpublishし、同一turnの複数mutationを1つのcompactなoverlay/bannerへまとめる。表示するfact textは80文字でtruncateし、view modelが所有するcancel可能taskで2.5秒後にdismissする。通知はtapを要求せず、speechを停止せず、focusを奪わず、conversation transcriptへ含めない。accessibility labelを付与する。確認、設定、memory管理screenは追加しない。

- [ ] **ステップ7: toolとUIのintegration testを確認する**

fake tool/session outputを使用し、自動remember/search/forget routing、成功turnのatomic commitと1つにまとめた通知、failure/cancellation/schema-decode時のrollback、searchでは通知しないこと、住所判定classifierからaccessできないこと、`覚えて`や`忘れて`という語を決定論的な必須条件にしないことを証明する。quote欠落・不一致、call/mutation/result超過、stale/unknown UUID、storage failureを検証し、いずれもstoreを部分変更してはならない。dependency側のunknown-tool JSON parser testは重複させない。ここでは実model inferenceを使わない。

- [ ] **ステップ8: memory toolをcommitする**

```bash
git add CatRobot/Conversation/Memory CatRobot/Conversation/Integration CatRobotTests/Conversation
git add CatRobot/Conversation/Services CatRobot/Conversation/UI
git commit -m "feat: add Gemma-driven local memory tools"
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
- 使用: session-scoped summary、直近4 turn pair、memory-tool definition/result、現在input、image token、output reserve。

- [ ] **ステップ1: 厳密なbudgeting型を定義する**

```swift
struct ConversationContextPolicy: Equatable, Sendable {
    let validatedContextCapacity: Int
    let recentTurnPairCount: Int
    let compactTargetFraction: Double

    var operationalContextBudget: Int {
        Int((Double(validatedContextCapacity) * 0.8).rounded(.down))
    }
}

struct TokenProjection: Equatable, Sendable {
    let instructions: Int
    let summary: Int
    let recentTurns: Int
    let memoryToolDefinitions: Int
    let memoryToolResults: Int
    let currentInput: Int
    let images: Int
    let outputReserve: Int
    let margin: Int
    var total: Int { instructions + summary + recentTurns + memoryToolDefinitions + memoryToolResults + currentInput + images + outputReserve + margin }
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

256/512 reserve、image/tool-definition/tool-resultの計上、厳密な80%境界、summaryから独立したpersistent store、直近4 pairのverbatim保持、promptが厳密に1回だけ現れること、cancellation/failure時のrollback、繰り返しcompaction、context exceeded時の1回だけのretryを検証する。

- [ ] **ステップ3: context actorを実装する**

```swift
actor ConversationContextController {
    func prepare(_ request: ReplyRequest) async throws -> PreparedReplyContext
    func record(user: ReplyRequest, assistant: String) async
    func recoverFromContextExceeded(_ request: ReplyRequest) async throws -> PreparedReplyContext
    func reset() async
}
```

Compactionは専用Gemma sessionで古いconversation turnをsummary化する。完了済みtool callとtool outputをsummary sourceから除外し、直近4 pairをverbatimで保持し、3つのtool definitionを再度attachする。validated capacityの40%以下をtargetにreplacement transcript/sessionを構築し、preparation成功後だけswapする。persistent memoryは`LocalMemoryStore`に残し、必要時に`searchMemory`で再取得する。

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
- 追加: 上限付きpreparation進捗、memory-tool transaction完了、一時memory通知。Visionはタスク5のdiagnostic pathに限定する。

- [ ] **ステップ1: 新しいflowのintegration testを書く**

必須sequence:

```text
voice: recognize -> Apple classify -> Gemma reply -> speak
typed: submit -> Gemma reply -> speak
memory mutation: begin turn -> Gemma tool call -> stage -> successful reply -> commit -> notice
memory rollback: begin turn -> Gemma tool call -> stage -> cancel/fail -> discard
contextExceeded: compact -> retry once -> speak or fail
cancel: stop streaming -> preserve last committed context
```

- [ ] **ステップ2: `prewarm()`を明示的なmodel preparationへ置き換える**

signingやglobal configurationを変更せずdownload進捗を公開する。voice preflightではApple classifier availabilityを確認し、audio sessionをactivateする前に`reply.prepare(progress:)`を完了させる。typed inputでも生成前にreply backendをprepareする。model-preparation failureはrecover可能なCat Robot errorへmapする。

- [ ] **ステップ3: Apple classifierの順序を維持する**

voice turnではGemma replyより前に必ず`dependencies.classifier.classify`を呼ぶ。typed turnは既存のdirect-reply behaviorを維持してよい。

- [ ] **ステップ4: 既存のconcurrency ownershipを維持する**

session mutation周辺にdetached taskを導入しない。すべてのcontext/memory mutationは対応actorを経由し、UI変更は`@MainActor`に留める。一時通知はpresentation stateだけであり、reply streamingやspeechを遅延させない。

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
- 新規作成: `CatRobot/Diagnostics/PoCProcessMetrics.swift`
- テスト: `CatRobotTests/Diagnostics/GemmaContextCalibrationProbeTests.swift`
- 測定後に変更: `GemmaFoundationModelFactory.swift`、`ConversationContextController.swift`
- evidence追記: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`

**インターフェース:**
- 提供: runtimeで受理されたboundary、validated capacity、80% operational budget。
- 制約: flake retryを含め、full-model context runは14回以内。

- [ ] **ステップ1: 決定論的なrequestとresult recordを実装する**

```swift
struct ContextProbeResult: Codable, Equatable, Sendable {
    let configuredCapacity: Int
    let actualInputTokens: Int
    let outputReserve: Int
    let coldStart: Bool
    let timeToFirstTokenSeconds: Double
    let totalResponseSeconds: Double
    let residentBytesBefore: UInt64?
    let residentBytesAfter: UInt64?
    let thermalBefore: String
    let thermalAfter: String
    let outcome: String
}
```

- [ ] **ステップ2: 有限search controllerをunit testする**

coarse candidateは厳密に`2_048`、`8_192`、`16_384`、`24_576`、`32_000`とする。boundary searchは最大4回の二分探索を行い、最も広い区間でも約512-tokenのresolutionまで絞り、受理可能なalignmentへ丸める。stability確認では最終candidateを3回成功させ、そのうち1回以上をcold startにする。coarse、boundary、stability、fallback確認、flake retryは、full-model 14回という1つのhard budgetを共有する。

- [ ] **ステップ3: Foundation Models経由で実機probeを逐次実行する**

device `00008140-000610311A90801C`、runごとの10分timeout、決定論的なsynthetic corpusを使用する。512 output reserveを含める。複数のmulti-GB engineが保持されないよう、configurationを変更するたびにcached LiteRT engineをreleaseする。

- [ ] **ステップ4: 無制限retryをせずoutcomeを分類する**

invalid configuration、context exceeded、OOM/app termination、timeout、cancellation、memory warning、thermal serious/critical、output failureを区別する。変更のないfailed commandへのflake retryは最大1回とし、14回の上限に含める。

- [ ] **ステップ5: 結果をproduction configurationへ固定する**

暫定`24_576` literalを、同じbinaryとconfigurationでstability runが3回成功した最高candidateへ置き換える。最高candidateがstability確認に失敗した場合、残りのrun budgetは観測済みの低いcandidateを確認するためだけに使い、14回上限を延長しない。次を計算する:

```swift
let operationalContextBudget = Int(
    (Double(validatedContextCapacity) * 0.8).rounded(.down)
)
```

推測値を`runtimeHardLimit`と呼ばない。boundaryを解決できない場合は、成功lower boundと失敗upper boundを報告する。

- [ ] **ステップ6: 実際のauto-compaction eventを1回実行する**

最終capacityを使い、現在promptが1回だけ現れること、summaryと直近4 pairが残ること、persistent factが分離されたままであること、compact後もconversationが継続することを証明する。

- [ ] **ステップ7: calibrated configurationとevidenceをcommitする**

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

- [ ] **ステップ1: 最終generator検証とSimulator検証を1回だけ実行する**

`ruby scripts/test_generate_project.rb`、最後のcode変更の影響を受ける対象test、full Simulator suite 1回の順で実行する。具体的なstale-cache signatureがない限りDerivedDataをcleanしない。

- [ ] **ステップ2: 実機でbuild、install、launchする**

Xcode build、SDK、device OS/build、LiteRT version、Package.resolved pin、model revision、model size、初回SHAの1回分の結果を記録する。

- [ ] **ステップ3: textとroutingを確認する**

voice発話がApple content-tagging classificationの後にFoundation Models-backed Gemma replyへ進むことを証明する。typed発話がGemma replyを使うことも証明する。文章の完全一致をassertせず256/512上限を確認する。

- [ ] **ステップ4: 上限付きvision acceptanceを実行する**

タスク5の上限内で3つのfixtureとno-image controlを実行する。privateなuser contentを含まないraw responseを記録する。

- [ ] **ステップ5: memory acceptanceを実行する**

user-turn reply requestは6回以内とする。`覚えて`と言わずに安定した好みを1つ述べ、Gemmaが`rememberMemory`を呼ぶこと、成功turnでcommitされること、speechをblockせず小さな通知が表示されることを証明する。restart後、意味的に関連する質問を行い、`searchMemory`が保存factを取得することを証明する。次に削除を依頼し、`forgetMemory`が削除して通知を出すことを証明する。明らかに一時的な観察も1つ与え、mutation toolが呼ばれないことを証明する。各tool名、検証済みargument、tool result、commit/rollback outcome、user-visible通知を記録し、無関係なprivate conversationは記録しない。

- [ ] **ステップ6: warm-cache behaviorとoffline inferenceを確認する**

通常のwarm launchでfull SHAが再実行されないことを証明する。model install後は通常inferenceにnetwork accessが不要なことを証明する。

- [ ] **ステップ7: 制限事項を記録する**

LiteRT SwiftとFoundation Models adapterがearly-preview dependencyであること、v0.16.0 adapterのguided generationとtool selectionはhard constrained decodingではなくsoftなprompt-driven JSONであること、memoryに値するturnではtool round tripが追加されること、transcript replayによりlong-context TTFTが増える可能性があること、modelが約2.6 GBであること、production readinessは主張しないことを記載する。

---

### タスク11: 正式なreview/fixを最大2 round実行してhandoffする

**対象ファイル:**
- review対象: current goal diffだけ
- 更新: `docs/validation/2026-08-24-gemma4-foundationmodels-poc.md`

**インターフェース:**
- 提供: clean、または明確にblockedとされたPoC handoff。

- [ ] **ステップ1: Sol/xhighの正式reviewerを1つだけdispatchする**

`gpt-5.6-sol` subagentを`xhigh`で1つだけ使い、要件準拠、Swift concurrency、Foundation Models/LiteRT routing、model integrity policy、compaction時のprompt-once semantics、memory-toolのauthorization/transactionality/privacy、testが必要behaviorを証明しているかをreviewする。同じdiffを複数agentへreviewさせない。

- [ ] **ステップ2: 第1 roundを処理する**

scope内のCritical/Important findingだけを修正し、impact-based validationを実行する。Minor findingはscopeを拡張せず報告する。第1 roundにCritical/Important findingがなければ第2 roundをskipする。

- [ ] **ステップ3: 第1 roundの修正後だけ第2 roundを実行する**

同じreviewerへ、変更後diffのfresh reviewを依頼する。scope内のCritical/Important findingを修正し、impact-based validationを実行する。3回目のwhole-diff reviewは行わない。

- [ ] **ステップ4: terminal stateを強制する**

第2 round後もCritical/Important findingが残る場合、完了を主張せず停止する。後続のgoal turnで自動的に編集を続けない。残件がなく、すべての完了条件にevidenceがある場合だけcompleteとする。

- [ ] **ステップ5: 最終handoffを行う**

branch、worktree、base SHA、変更file、厳密なpin、command/result、実機結果、vision table、context table、validated capacity、operational budget、有効compact threshold、SHA実行回数と理由、使用したreview round、残存finding、制限事項、validation report pathを報告する。

## Subagent routing方針

- RootがGit/worktree、shared interface、package integration、Xcode、signing、Simulator、実機、model download、context run、結果統合、completion statusを所有する。
- `gpt-5.6-luna`の`max`は、file inventory、独立fixture生成、独立unit test、table整形など、上限が明確なmechanical taskだけを担当してよい。
- `gpt-5.6-sol`の`xhigh`は、Foundation Models/LiteRT設計、Swift concurrency、context log解釈、正式reviewを担当する。
- `gpt-5.6-terra`は使用しない。
- 同時にactiveにするsubagentは最大2つとし、taskとfile ownershipを重複させない。
- subagentを使うためだけに作業を分割せず、Xcode操作やdevice操作を委譲しない。
- subagentが利用できない場合、Terraで代替せずrootが進める。

## Retryとevidence再利用方針

- 変更のないfailed commandはflake確認のため1回だけrerunしてよい。
- それ以降のattemptには、新しい仮説と実質的な変更を必須とする。
- 同じfailure signature/root causeが3回連続したら、そのpathを停止してblockerとする。
- failure signatureが変化し、測定可能な進捗がある間は通常のTDDを続けてよい。
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
6. 3つの決定論的vision fixtureとno-image controlが8 run以内でsemantic rubricを満たす。
7. Gemmaが`rememberMemory`、`searchMemory`、`forgetMemory`を自律的に呼べる。明示的なcommand wordingがなくてもfactを保存できる一方、検証済みの現在user quoteだけをmutation sourceにできる。failure/cancellation時はrollbackし、restart/search/deletionが動作し、commit済みmutationでは小さな非blocking通知だけを表示する。
8. Context searchが14 run以内に完了し、success/failure boundと3 run安定したcapacityを記録する。
9. Operational budgetがvalidated capacityの厳密に80%であり、実際のcompaction後もsummary、直近4 pair、独立memory storeと再attachしたtool、現在promptの厳密に1回の出現を維持する。
10. 初回model integrityが検証され、変更のないwarm launchではartifactを再hashしない。
11. Generator contract、Simulator suite、signed device build、統合device acceptanceがPASSする。
12. 正式reviewは最大2 roundで、Critical/Important findingを残さない。
13. push、PR、merge、comparison-branch mutation、fallback model/library、scope外refactorを行わない。
