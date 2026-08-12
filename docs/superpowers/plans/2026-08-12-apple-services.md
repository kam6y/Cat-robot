# Apple Voice and AI Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the iOS 26 Apple-framework adapters for on-device Japanese model availability, addressee classification, streaming replies, progressive transcription, speech synthesis, and interruption-safe audio lifecycle.

**Architecture:** Implement the domain protocols delivered by the preceding `feature/conversation-domain` branch with focused actors and adapters under `CatRobot/Conversation/Services`. Keep one stateful, prewarmed reply `LanguageModelSession`, create a fresh guided-generation session for each addressee decision, translate framework failures at the boundary, and isolate microphone/synthesizer callbacks behind `AsyncStream` so app integration never imports Foundation Models, Speech, or AVFAudio details.

**Tech Stack:** Swift 6 strict concurrency, iOS 26.0+, Foundation Models, Speech (`SpeechAnalyzer` / `SpeechTranscriber` / `AnalyzerInput` / `AssetInventory`), AVFAudio (`AVAudioEngine` / `AVAudioConverter` / `AVSpeechSynthesizer` / `AVAudioSession`), XCTest, Xcode 26.6 with installed iPhoneOS 26.5 SDK.

## Global Constraints

- Branch from the integrated `conversation-domain` commit into bounded branch `feature/apple-services`; do not begin from this planning worktree.
- Use `CatRobot.xcodeproj`, shared scheme/module/app target `CatRobot`, and hosted unit target `CatRobotTests`; regenerate it with `ruby scripts/generate_project.rb` after adding files.
- Keep deployment target iOS 26.0, Swift language mode 6, strict concurrency complete, iPhone only, and both landscape orientations; add no packages.
- Keep model and speech processing on device. Never write audio, rejected transcripts, prompts, model transcripts, or conversations to disk or send them over a network.
- Japanese locale is `Locale(identifier: "ja-JP")`; user-facing failures remain domain values for the integration layer to render in Japanese.
- Classifier and reply requests are serialized by the app/domain coordinator. Never add a reply validator, confidence score, second model pass, cloud fallback, or output post-validation.
- Use Foundation Models' default guardrails. Do not use `.permissiveContentTransformations`.
- The reply session is stateful and long-lived until reset after context exhaustion. The addressee session is fresh and stateless for every call.
- `SpeechTranscriber.Result.isFinal` is forwarded as event metadata only; this service does not decide end of turn.
- Stop real microphone capture while speaking, paused, inactive, or interrupted. An interruption never causes automatic listening resume, even if AVFAudio reports `shouldResume`.
- Hardware-backed model, microphone, Speech assets, and audible synthesis are smoke-tested on the iPhone; unit tests use fakes/adapters and never invoke them.
- Keep the project-local iOS 26 `SpeechAudioConverter` architecture. Do not compile references to iOS 27-only `AnalyzerInputConverter` or `CaptureInputSequenceProvider` in production, tests, availability branches, or dead code.
- Integrate with `git merge --squash`; push and retain `feature/apple-services` after its squash commit lands on `main`.

## SDK audit and compatibility decision

The signatures in this plan were checked against:

- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface`
- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
- the installed AVFAudio headers under the same SDK.

Installed Foundation Models exposes `SystemLanguageModel.availability`, `supportsLocale(_:)`, `LanguageModelSession.prewarm(promptPrefix:)`, guided `respond(to:generating:)`, string `streamResponse(to:)`, and the documented `GenerationError` cases. Installed Speech exposes `SpeechTranscriber(locale:preset:)`, `.progressiveTranscription`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)`, `prepareToAnalyze(in:)`, `analyzeSequence(_:)`, `cancelAndFinishNow()`, `AnalyzerInput(buffer:bufferStartTime:)`, and `AssetInventory` installation APIs.

Apple's current DocC metadata identifies `AnalyzerInputConverter` and `CaptureInputSequenceProvider` as **beta, introduced in iOS 27.0**. They do not appear in the installed iOS 26.5 `Speech.swiftinterface` or `Speech.tbd`. Xcode 26.6 (17F113) is the latest stable Xcode and already installed; Xcode 27 is beta. Updating is neither necessary nor useful for this iOS 26 MVP because the helper classes would remain iOS 27-only. Compile no references to them. Use the small project-local `SpeechAudioConverter` below; reassess replacing it only if the deployment floor later becomes iOS 27.

## Expected domain contract

Consume the exact public declarations from the preceding conversation-domain plan/branch rather than redeclaring them here. This plan assumes that branch supplies the following semantically equivalent surface; update adapter spellings mechanically if the merged declaration names differ, without changing behavior:

```swift
public protocol ModelAvailabilityChecking: Sendable {
    func availability() async -> ModelAvailability
}

public protocol AddressClassifying: Sendable {
    func classify(_ utterance: String) async throws -> AddressTarget
}

public protocol ReplyGenerating: Sendable {
    func prewarm() async
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}

public protocol SpeechRecognizing: Sendable {
    func prepare() async throws
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
    func stop() async
}

public protocol SpeechSpeaking: Sendable {
    func prepare() async throws
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error>
    func stop() async
}
```

`ModelAvailability` must distinguish `.available`, `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`, and `.unsupportedLocale`; `SpeechRecognitionEvent` carries text plus `isFinal`; `SpeechEvent` distinguishes started, word-range/mouth activity, finished, and cancelled; `ConversationServiceError` distinguishes guardrail/refusal, context exceeded, unavailable assets/locale, concurrent/busy, capture/audio-session/synthesis failures, and cancellation. In particular, synthesis-driver failures and rejected overlapping `speak` calls both map to the merged domain case `.speechSynthesisFailed`; a missing installed voice remains `.speechVoiceUnavailable`. Tasks below use those domain names, not duplicate adapter-only error enums.

## File map

- `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`: maps `SystemLanguageModel` and Japanese locale support to domain availability.
- `CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift`: guided, one-shot addressee classification.
- `CatRobot/Conversation/Services/FoundationModelReplyService.swift`: owns the prewarmed stateful reply session and cumulative reply stream.
- `CatRobot/Conversation/Services/FoundationModelErrorMapper.swift`: single exhaustive mapping from `GenerationError` to domain service errors.
- `CatRobot/Conversation/Services/SpeechAssetPreparer.swift`: resolves Japanese support and installs/reserves required Speech assets.
- `CatRobot/Conversation/Services/SpeechAudioConverter.swift`: injected iOS 26 `AVAudioConverter` bridge to `[AnalyzerInput]`.
- `CatRobot/Conversation/Services/AppleSpeechRecognizer.swift`: owns `AVAudioEngine`, `SpeechAnalyzer`, transcriber, input stream, and result tasks.
- `CatRobot/Conversation/Services/AppleSpeechSynthesizer.swift`: retains synthesizer/delegate and bridges lifecycle/word callbacks.
- `CatRobot/Conversation/Services/AppleAudioSessionController.swift`: configures play-and-record/voice-chat and emits interruption/route events.
- Mirror each responsibility under `CatRobotTests/Conversation/Services/` with framework seams or pure mapper tests.

---

### Task 1: Foundation Models availability and failure mapping

**Files:**
- Create: `CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift`
- Create: `CatRobot/Conversation/Services/FoundationModelErrorMapper.swift`
- Test: `CatRobotTests/Conversation/Services/FoundationModelAvailabilityServiceTests.swift`
- Test: `CatRobotTests/Conversation/Services/FoundationModelErrorMapperTests.swift`

**Interfaces:**
- Consumes: domain `ModelAvailabilityChecking`, `ModelAvailability`, and `ConversationServiceError`.
- Produces: `FoundationModelAvailabilityService`, `FoundationModelErrorMapper.map(_:)` used by Tasks 2–3.

- [ ] **Step 1: Write failing availability tests through an injectable snapshot seam**

```swift
final class FoundationModelAvailabilityServiceTests: XCTestCase {
    func testMapsEveryFrameworkAvailabilityReason() async {
        let locale = Locale(identifier: "ja-JP")
        let cases: [(FoundationModelAvailabilitySnapshot, ModelAvailability)] = [
            (.init(availability: .available, supportsLocale: true), .available),
            (.init(availability: .available, supportsLocale: false), .unsupportedLocale),
            (.init(availability: .deviceNotEligible, supportsLocale: true), .deviceNotEligible),
            (.init(availability: .appleIntelligenceNotEnabled, supportsLocale: true), .appleIntelligenceNotEnabled),
            (.init(availability: .modelNotReady, supportsLocale: true), .modelNotReady),
        ]

        for (snapshot, expected) in cases {
            let service = FoundationModelAvailabilityService(locale: locale) { snapshot }
            let actual = await service.availability()
            XCTAssertEqual(actual, expected)
        }
    }
}
```

- [ ] **Step 2: Write failing mapper tests for every model failure the coordinator handles**

```swift
func testMapsGenerationFailuresWithoutLeakingDebugDescriptions() {
    XCTAssertEqual(FoundationModelErrorMapper.map(.guardrailViolation), .guardrailViolation)
    XCTAssertEqual(FoundationModelErrorMapper.map(.refusal), .refusal)
    XCTAssertEqual(FoundationModelErrorMapper.map(.exceededContextWindowSize), .contextExceeded)
    XCTAssertEqual(FoundationModelErrorMapper.map(.unsupportedLanguageOrLocale), .modelLocaleUnsupported)
    XCTAssertEqual(FoundationModelErrorMapper.map(.assetsUnavailable), .modelAssetsUnavailable)
    XCTAssertEqual(FoundationModelErrorMapper.map(.concurrentRequests), .modelBusy)
    XCTAssertEqual(FoundationModelErrorMapper.map(.other), .modelGenerationFailed)
}
```

Use a small internal `FoundationModelFailureKind` in the mapper test seam so tests never need to manufacture `GenerationError.Context` or `Refusal`. The production overload pattern-matches the real error and delegates to the pure kind mapper.

- [ ] **Step 3: Run the focused tests and confirm they fail**

Run:

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests -only-testing:CatRobotTests/FoundationModelErrorMapperTests test
```

Expected: FAIL because the service, snapshot, and mapper do not exist.

- [ ] **Step 4: Implement availability with the installed SDK's exact model API**

```swift
import Foundation
import FoundationModels

struct FoundationModelAvailabilitySnapshot: Sendable {
    enum Availability: Sendable { case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady }
    let availability: Availability
    let supportsLocale: Bool
}

struct FoundationModelAvailabilityService: ModelAvailabilityChecking {
    private let locale: Locale
    private let snapshot: @Sendable () -> FoundationModelAvailabilitySnapshot

    init(locale: Locale = Locale(identifier: "ja-JP")) {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        self.init(locale: locale) {
            let availability: FoundationModelAvailabilitySnapshot.Availability
            switch model.availability {
            case .available: availability = .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: availability = .deviceNotEligible
                case .appleIntelligenceNotEnabled: availability = .appleIntelligenceNotEnabled
                case .modelNotReady: availability = .modelNotReady
                @unknown default: availability = .modelNotReady
                }
            }
            return .init(availability: availability, supportsLocale: model.supportsLocale(locale))
        }
    }

    init(locale: Locale, snapshot: @escaping @Sendable () -> FoundationModelAvailabilitySnapshot) {
        self.locale = locale
        self.snapshot = snapshot
    }

    func availability() async -> ModelAvailability {
        let value = snapshot()
        guard value.supportsLocale else { return .unsupportedLocale }
        switch value.availability {
        case .available: return .available
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        }
    }
}
```

The nested `SystemLanguageModel.Availability.UnavailableReason` is nonfrozen even though the outer availability enum is frozen. The `@unknown default` above is therefore required and conservatively reports `.modelNotReady`, allowing the UI's existing retry path rather than treating a future reason as eligibility or locale failure.

In the error mapper, switch every currently installed `LanguageModelSession.GenerationError` case: `.exceededContextWindowSize`, `.assetsUnavailable`, `.guardrailViolation`, `.unsupportedGuide`, `.unsupportedLanguageOrLocale`, `.decodingFailure`, `.rateLimited`, `.concurrentRequests`, and `.refusal`. The error enum is nonfrozen, so the production switch must also include `@unknown default: return .modelGenerationFailed`. Map cancellation first with `error is CancellationError`. Keep `Context.debugDescription` out of returned domain values.

- [ ] **Step 5: Run focused tests and commit**

Run the command from Step 3. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/FoundationModelAvailabilityService.swift CatRobot/Conversation/Services/FoundationModelErrorMapper.swift CatRobotTests/Conversation/Services/FoundationModelAvailabilityServiceTests.swift CatRobotTests/Conversation/Services/FoundationModelErrorMapperTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: map Foundation Models availability and errors"
```

### Task 2: Fresh guided-generation addressee classifier

**Files:**
- Create: `CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift`
- Test: `CatRobotTests/Conversation/Services/FoundationModelAddressClassifierTests.swift`

**Interfaces:**
- Consumes: `AddressClassifying`, domain `AddressTarget`, and Task 1 error mapper.
- Produces: `FoundationModelAddressClassifier.classify(_:) async throws -> AddressTarget`.

- [ ] **Step 1: Write failing tests for prompt, mapping, fresh-session behavior, and error mapping**

```swift
func testClassificationUsesFreshRequestAndMapsAllTargets() async throws {
    let client = FakeAddressModelClient(outputs: [.addressed, .ambiguous, .notAddressed])
    let classifier = FoundationModelAddressClassifier(client: client)

    let addressed = try await classifier.classify("ねえ、今日どう？")
    let ambiguous = try await classifier.classify("それ置いといて")
    let notAddressed = try await classifier.classify("テレビ消した？")
    let requestCount = await client.requestCount
    let prompts = await client.prompts

    XCTAssertEqual(addressed, .addressed)
    XCTAssertEqual(ambiguous, .ambiguous)
    XCTAssertEqual(notAddressed, .notAddressed)
    XCTAssertEqual(requestCount, 3)
    XCTAssertEqual(prompts, ["ねえ、今日どう？", "それ置いといて", "テレビ消した？"])
}

func testClassificationMapsModelError() async {
    let classifier = FoundationModelAddressClassifier(client: FakeAddressModelClient(error: .guardrailViolation))
    do {
        _ = try await classifier.classify("発話")
        XCTFail("Expected classification to throw")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .guardrailViolation)
    }
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelAddressClassifierTests test
```

Expected: FAIL because classifier/client types do not exist.

- [ ] **Step 3: Implement the guided output and production client**

```swift
import FoundationModels

@Generable
struct AddressDecision {
    @Guide(description: "Whether the utterance is addressed to the AI cat")
    var target: GeneratedAddressTarget
}

@Generable
enum GeneratedAddressTarget { case addressed, ambiguous, notAddressed }

private struct LiveAddressModelClient: AddressModelClient {
    func classify(_ utterance: String) async throws -> GeneratedAddressTarget {
        let model = SystemLanguageModel(useCase: .contentTagging, guardrails: .default)
        let session = LanguageModelSession(model: model) {
            """
            あなたは発話の宛先だけを分類します。AIの猫に向けた発話は addressed、
            明確に別の人・テレビ・独り言なら notAddressed、判別不能なら ambiguous。
            内容への返答、説明、信頼度は生成しません。
            """
        }
        return try await session.respond(
            to: utterance,
            generating: AddressDecision.self,
            options: GenerationOptions(sampling: .greedy, temperature: 0)
        ).content.target
    }
}
```

`FoundationModelAddressClassifier` injects `any AddressModelClient`, maps the generated enum to the domain enum, and catches through `FoundationModelErrorMapper`. The live client constructs `LanguageModelSession` inside every `classify` call; it never receives or retains the reply session or previously rejected text.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift CatRobotTests/Conversation/Services/FoundationModelAddressClassifierTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: classify addressee with guided generation"
```

### Task 3: Stateful prewarmed streaming reply service

**Files:**
- Create: `CatRobot/Conversation/Services/FoundationModelReplyService.swift`
- Test: `CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift`

**Interfaces:**
- Consumes: `ReplyGenerating`, domain errors, Task 1 mapper.
- Produces: one session's cumulative Japanese snapshots plus explicit `prewarm()` and `reset()`.

- [ ] **Step 1: Write failing state/stream tests with an injected session client**

```swift
func testPrewarmThenStreamUsesOneStatefulSessionAndCumulativeSnapshots() async throws {
    let client = FakeReplyModelClient(streams: [["うん", "うん、いいよ。"], ["次", "次も聞かせて。"]])
    let service = FoundationModelReplyService(clientFactory: { client })

    await service.prewarm()

    let firstStream = try await service.streamReply(to: "いい？")
    var firstSnapshots: [String] = []
    for try await snapshot in firstStream {
        firstSnapshots.append(snapshot)
    }

    let secondStream = try await service.streamReply(to: "続けるね")
    var secondSnapshots: [String] = []
    for try await snapshot in secondStream {
        secondSnapshots.append(snapshot)
    }

    let prewarmCount = await client.prewarmCount
    let prompts = await client.prompts
    XCTAssertEqual(firstSnapshots, ["うん", "うん、いいよ。"])
    XCTAssertEqual(secondSnapshots, ["次", "次も聞かせて。"])
    XCTAssertEqual(prewarmCount, 1)
    XCTAssertEqual(prompts, ["いい？", "続けるね"])
}

func testResetReplacesSessionAndPrewarmsReplacement() async {
    let factory = FakeReplyClientFactory()
    let service = FoundationModelReplyService(clientFactory: factory.make)
    await service.prewarm()
    await service.reset()
    let creationCount = await factory.creationCount
    let clients = await factory.clients
    let replacementPrewarmCount = await clients[1].prewarmCount
    XCTAssertEqual(creationCount, 2)
    XCTAssertEqual(replacementPrewarmCount, 1)
}

func testContextErrorIsNotSilentlyRetried() async {
    let service = FoundationModelReplyService(clientFactory: { FakeReplyModelClient(error: .contextExceeded) })
    do {
        let stream = try await service.streamReply(to: "続き")
        for try await _ in stream {}
        XCTFail("Expected context exhaustion to throw")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .contextExceeded)
    }
}
```

The last assertion makes reset visible to app integration: this service reports context exhaustion; the coordinator shows the memory-reset explanation and calls `reset()`. Do not silently retry a user prompt.

- [ ] **Step 2: Run the focused test and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/FoundationModelReplyServiceTests test
```

Expected: FAIL because the reply actor/client seam does not exist.

- [ ] **Step 3: Implement an actor around one live session**

```swift
private final class LiveReplyModelClient: ReplyModelClient, @unchecked Sendable {
    private let session: LanguageModelSession

    init() {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        session = LanguageModelSession(model: model) {
            """
            あなたは親しみやすいAIの猫「Cat Robot」です。日本語で自然に話します。
            通常は音声で聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
            訂正されたら短く認めて会話を続けます。自分を人間だと偽りません。
            """
        }
    }

    func prewarm() { session.prewarm() }

    func snapshots(for prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = session.streamResponse(
                        to: prompt,
                        options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 160)
                    )
                    for try await snapshot in response {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: FoundationModelErrorMapper.map(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

Make `FoundationModelReplyService` an actor. Lazily create exactly one client, prewarm it during `prewarm`, reuse it across calls, reject concurrent `streamReply` calls as `.modelBusy`, and create/prewarm a new client on `reset`. `snapshot.content` is already the cumulative `String.PartiallyGenerated == String`; emit it directly without a validator, trimming, rewriting, or a second request. Ensure the `isGenerating` flag clears in `defer` when stream collection ends or is cancelled.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/FoundationModelReplyService.swift CatRobotTests/Conversation/Services/FoundationModelReplyServiceTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: stream replies from a stateful model session"
```

### Task 4: Japanese Speech asset preparation and iOS 26 audio conversion

**Files:**
- Create: `CatRobot/Conversation/Services/SpeechAssetPreparer.swift`
- Create: `CatRobot/Conversation/Services/SpeechAudioConverter.swift`
- Test: `CatRobotTests/Conversation/Services/SpeechAssetPreparerTests.swift`
- Test: `CatRobotTests/Conversation/Services/SpeechAudioConverterTests.swift`

**Interfaces:**
- Consumes: domain speech availability errors.
- Produces: `SpeechAssetPreparer.makePreparedTranscriber()`, internal `SpeechAudioConverting`, and `SpeechAudioConverter` for Task 5.

- [ ] **Step 1: Write failing asset-state tests against a narrow inventory seam**

```swift
func testPrepareRejectsUnsupportedJapaneseLocale() async {
    let preparer = SpeechAssetPreparer(locale: Locale(identifier: "ja-JP"), inventory: .unsupported)
    do {
        _ = try await preparer.makePreparedTranscriber()
        XCTFail("Expected an unsupported locale error")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .speechLocaleUnsupported)
    }
}

func testPrepareDownloadsWhenRequestExistsThenReservesLocale() async throws {
    let inventory = FakeSpeechAssetInventory(equivalentLocale: Locale(identifier: "ja-JP"), needsDownload: true)
    let preparer = SpeechAssetPreparer(locale: Locale(identifier: "ja-JP"), inventory: inventory)
    _ = try await preparer.makePreparedTranscriber()
    let downloadCount = await inventory.downloadCount
    let reservedLocales = await inventory.reservedLocales
    XCTAssertEqual(downloadCount, 1)
    XCTAssertEqual(reservedLocales, [Locale(identifier: "ja-JP")])
    await preparer.releaseReservation()
}

func testReservationFailureDoesNotHideInstalledAssets() async throws {
    let inventory = FakeSpeechAssetInventory(
        equivalentLocale: Locale(identifier: "ja-JP"),
        reserveError: ConversationServiceError.speechAssetsUnavailable
    )
    let preparer = SpeechAssetPreparer(locale: Locale(identifier: "ja-JP"), inventory: inventory)
    _ = try await preparer.makePreparedTranscriber()

    await preparer.releaseReservation()
    let releasedLocales = await inventory.releasedLocales
    XCTAssertTrue(releasedLocales.isEmpty)
}

func testExplicitReleaseOnlyReleasesASuccessfulReservationOnce() async throws {
    let locale = Locale(identifier: "ja-JP")
    let inventory = FakeSpeechAssetInventory(equivalentLocale: locale, reserveResult: true)
    let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
    _ = try await preparer.makePreparedTranscriber()

    await preparer.releaseReservation()
    await preparer.releaseReservation()
    let releasedLocales = await inventory.releasedLocales
    XCTAssertEqual(releasedLocales, [locale])
}

func testInstallationFailureMapsToSpeechAssetsUnavailable() async {
    let inventory = FakeSpeechAssetInventory(
        equivalentLocale: Locale(identifier: "ja-JP"),
        installError: NSError(domain: "SpeechAssetPreparerTests", code: 1)
    )
    let preparer = SpeechAssetPreparer(locale: Locale(identifier: "ja-JP"), inventory: inventory)

    do {
        _ = try await preparer.makePreparedTranscriber()
        XCTFail("Expected installation failure")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .speechAssetsUnavailable)
    }
}
```

- [ ] **Step 2: Write failing converter tests for passthrough, resampling, flush, and construction failure**

```swift
func testMatchingFormatProducesAnalyzerInputWithoutConverter() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    buffer.frameLength = 480
    let converter = try SpeechAudioConverter(sourceFormat: format, analyzerFormat: format)
    let output = try converter.convert(buffer, at: AVAudioTime(sampleTime: 960, atRate: 48_000))
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0].bufferStartTime, CMTime(value: 960, timescale: 48_000))
}

func testUnsupportedConversionThrowsCaptureFailure() {
    let invalid = AVAudioFormat(commonFormat: .otherFormat, sampleRate: 0, channels: 0, interleaved: false)!
    do {
        _ = try SpeechAudioConverter(sourceFormat: invalid, analyzerFormat: validAnalyzerFormat)
        XCTFail("Expected unsupported conversion to throw")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
    }
}

func testFlushReturnsAnyPrimedFramesOnlyOnce() throws {
    let converter = try makeResamplingConverter()
    _ = try converter.convert(makeInputBuffer(), at: nil)
    let first = try converter.flush()
    let second = try converter.flush()
    XCTAssertGreaterThan(first.reduce(0) { $0 + Int($1.buffer.frameLength) }, 0)
    XCTAssertTrue(second.isEmpty)
}
```

- [ ] **Step 3: Run both test classes and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/SpeechAssetPreparerTests -only-testing:CatRobotTests/SpeechAudioConverterTests test
```

Expected: FAIL because the preparer and converter do not exist.

- [ ] **Step 4: Implement exact iOS 26 asset setup**

```swift
protocol SpeechAssetInventory: Sendable {
    func equivalentSupportedLocale(to locale: Locale) async -> Locale?
    func installIfNeeded(supporting transcriber: SpeechTranscriber) async throws
    func isInstalled(_ transcriber: SpeechTranscriber) async -> Bool
    func reserve(locale: Locale) async throws -> Bool
    func release(reservedLocale: Locale) async -> Bool
}

private var reservedLocale: Locale?

func makePreparedTranscriber() async throws -> SpeechTranscriber {
    guard let supported = await inventory.equivalentSupportedLocale(to: locale) else {
        throw ConversationServiceError.speechLocaleUnsupported
    }
    let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
    do {
        try await inventory.installIfNeeded(supporting: transcriber)
    } catch is CancellationError {
        throw ConversationServiceError.cancelled
    } catch {
        throw ConversationServiceError.speechAssetsUnavailable
    }
    guard await inventory.isInstalled(transcriber) else {
        throw ConversationServiceError.speechAssetsUnavailable
    }
    if reservedLocale == nil,
       (try? await inventory.reserve(locale: supported)) == true {
        reservedLocale = supported
    }
    return transcriber
}

func releaseReservation() async {
    guard let locale = reservedLocale else { return }
    reservedLocale = nil
    _ = await inventory.release(reservedLocale: locale)
}
```

Implement `SpeechAssetPreparer` as an actor and wrap every environment-dependent static query behind the internal inventory seam used by tests, including `SpeechTranscriber.isAvailable`, equivalent-locale lookup, installation, installed status, reserve, and release. The live `installIfNeeded` implementation—not the seam—calls `AssetInventory.assetInstallationRequest(supporting:)` and then `downloadAndInstall()` when a request exists; `AssetInstallationRequest` is final and has no public initializer, so never expose it through the fakeable seam. Map installation cancellation to `.cancelled` and every other installation/request failure to `.speechAssetsUnavailable`; do not leak framework errors. Reservation is best-effort after status reaches `.installed`: a thrown error or `false` return leaves `reservedLocale` nil and does not fail transcription, because only eviction protection was unavailable. Record the locale only when `reserve(locale:)` returns `true`. `releaseReservation()` is the explicit, idempotent async teardown; clear the stored locale before awaiting release so reentrancy cannot release it twice. The owning composition must call it during async service teardown. Never attempt to `await` from `deinit`, and never release a locale that this instance did not successfully reserve.

- [ ] **Step 5: Implement the converter protocol and AVAudioConverter bridge**

```swift
protocol SpeechAudioConverting: AnyObject {
    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}

final class SpeechAudioConverter: SpeechAudioConverting {
    init(sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) throws
    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput]
    func flush() throws -> [AnalyzerInput]
}
```

For equal formats, return one `AnalyzerInput` and convert a valid `AVAudioTime` explicitly with `CMTime(value: CMTimeValue(time.sampleTime), timescale: CMTimeScale(time.sampleRate.rounded()))`; use `nil` when sample time or sample rate is invalid. Otherwise create `AVAudioConverter(from: sourceFormat, to: analyzerFormat)` and throw `.speechCaptureFailed` if it returns nil. Allocate output capacity as `ceil(inputFrames * analyzerRate / sourceRate) + 32`, call `convert(to:error:withInputFrom:)`, supply the input once with `.haveData`, then `.noDataNow`, and return an `AnalyzerInput` for every nonempty `.haveData` or `.inputRanDry` output buffer. Track output sample time so resampled buffers have a continuous `CMTime`; on the first buffer, derive it from `AVAudioTime.sampleTime/sampleRate` when valid. `flush()` supplies `.endOfStream` until `.endOfStream`/zero frames, returns pending nonempty frames, calls `reset()`, and is idempotent. Treat `.error` or an `NSError` as `.speechCaptureFailed`.

`AVAudioConverterInputBlock` is `@Sendable` in Swift 6. Do not directly capture the non-Sendable `AVAudioPCMBuffer` or a mutable local "supplied" flag. Put only that per-conversion state in this narrowly scoped box:

```swift
private final class ConverterInputState: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer?
    private let exhaustedStatus: AVAudioConverterInputStatus
    private var didSupplyBuffer = false

    init(buffer: AVAudioPCMBuffer?, exhaustedStatus: AVAudioConverterInputStatus) {
        self.buffer = buffer
        self.exhaustedStatus = exhaustedStatus
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !didSupplyBuffer, let buffer else {
            status.pointee = exhaustedStatus
            return nil
        }
        didSupplyBuffer = true
        status.pointee = .haveData
        return buffer
    }
}

let inputState = ConverterInputState(buffer: inputBuffer, exhaustedStatus: .noDataNow)
let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) {
    _, inputStatus in
    inputState.next(status: inputStatus)
}
```

The `@unchecked Sendable` claim is limited to this box: `AVAudioConverter.convert(to:error:withInputFrom:)` invokes its input block synchronously on the calling converter operation, each box is created for one call, and it neither escapes nor participates in concurrent conversion. Keep converter ownership serialized. Do not generalize the box into shared mutable state; use the same pattern with `buffer: nil` and `exhaustedStatus: .endOfStream` for flush.

Do not implement channel maps, codecs, file formats, or a general audio library; the source is `AVAudioEngine` PCM and the destination is Speech PCM.

- [ ] **Step 6: Run focused tests and commit**

Run the command from Step 3. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/SpeechAssetPreparer.swift CatRobot/Conversation/Services/SpeechAudioConverter.swift CatRobotTests/Conversation/Services/SpeechAssetPreparerTests.swift CatRobotTests/Conversation/Services/SpeechAudioConverterTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: prepare Japanese speech assets and audio input"
```

### Task 5: Progressive Japanese capture with AVAudioEngine and SpeechAnalyzer

**Files:**
- Create: `CatRobot/Conversation/Services/AppleSpeechRecognizer.swift`
- Test: `CatRobotTests/Conversation/Services/AppleSpeechRecognizerTests.swift`

**Interfaces:**
- Consumes: `SpeechRecognizing`, `SpeechRecognitionEvent`, Task 4 preparer/converter.
- Produces: an idempotently startable/stoppable progressive recognition stream plus concrete `shutdown() async`; it does not own permission UI or turn segmentation.

- [ ] **Step 1: Write failing lifecycle/result tests against engine/analyzer driver seams**

```swift
func testStartForwardsProgressiveAndFinalResults() async throws {
    let driver = FakeSpeechCaptureDriver(results: [
        .init(text: "こん", isFinal: false),
        .init(text: "こんにちは", isFinal: true),
    ])
    let recognizer = AppleSpeechRecognizer(driverFactory: { driver })
    let stream = try await recognizer.start()
    var events: [SpeechRecognitionEvent] = []
    for try await event in stream {
        events.append(event)
        if events.count == 2 { break }
    }
    XCTAssertEqual(events, [
        SpeechRecognitionEvent(text: "こん", isFinal: false),
        SpeechRecognitionEvent(text: "こんにちは", isFinal: true),
    ])
    await recognizer.stop()
}

func testNormalStopFlushesThenFinalizesAndDrainsResultsWithoutCancellation() async throws {
    let driver = FakeSpeechCaptureDriver()
    let recognizer = AppleSpeechRecognizer(driverFactory: { driver })
    _ = try await recognizer.start()
    await recognizer.stop()
    let calls = await driver.calls
    XCTAssertEqual(calls, [
        .prepare, .installTap, .beginAnalysis, .startEngine,
        .removeTap, .stopEngine, .resetEngine,
        .flushConverter, .finishInput, .finalizeAnalyzer, .drainResults,
    ])
}

func testSecondStartDoesNotCreateParallelCapture() async throws {
    let factory = FakeSpeechCaptureDriverFactory()
    let recognizer = AppleSpeechRecognizer(driverFactory: factory.make)
    _ = try await recognizer.start()
    do {
        _ = try await recognizer.start()
        XCTFail("Expected a second capture to be rejected")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .speechCaptureAlreadyRunning)
    }
}

func testShutdownStopsAndReleasesSuccessfulReservationOnlyOnce() async throws {
    let locale = Locale(identifier: "ja-JP")
    let inventory = FakeSpeechAssetInventory(equivalentLocale: locale, reserveResult: true)
    let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
    let recognizer = AppleSpeechRecognizer(
        assetPreparer: preparer,
        driverFactory: { FakeSpeechCaptureDriver() }
    )
    try await recognizer.prepare()

    await recognizer.shutdown()
    await recognizer.shutdown()

    let releasedLocales = await inventory.releasedLocales
    XCTAssertEqual(releasedLocales, [locale])
}

func testAnalysisFailureThrowsCaptureFailureAndTearsDownExactlyOnce() async throws {
    let driver = FakeSpeechCaptureDriver(analysisFailure: TestError.failed)
    let recognizer = AppleSpeechRecognizer(driverFactory: { driver })
    let stream = try await recognizer.start()

    do {
        for try await _ in stream {}
        XCTFail("Expected analysis failure")
    } catch {
        XCTAssertEqual(error as? ConversationServiceError, .speechCaptureFailed)
    }

    let teardownCount = await driver.immediateTeardownCount
    XCTAssertEqual(teardownCount, 1)
}

func testConsumerCancellationStopsCaptureImmediately() async throws {
    let driver = FakeSpeechCaptureDriver()
    let recognizer = AppleSpeechRecognizer(driverFactory: { driver })
    let stream = try await recognizer.start()
    let consumer = Task { for try await _ in stream {} }
    consumer.cancel()
    _ = await consumer.result

    await driver.waitUntilImmediateTeardown()
    let immediateTeardownCount = await driver.immediateTeardownCount
    XCTAssertEqual(immediateTeardownCount, 1)
}
```

Add the same throwing-stream assertion for a result-stream failure, and add an engine-start-failure test that verifies the installed tap/input/analyzer are cleaned up exactly once. `testPrepareDoesNotInstallTapOrStartEngine` must prove preparation performs asset/analyzer preflight only. A `prepare(); start()` sequence must reuse the prepared driver without preparing twice; after `stop()`, a later `start()` creates a fresh per-run driver while the recognizer retains the same asset preparer. The strict ordering assertion begins only at synchronous lifecycle boundaries; do not assert scheduler ordering between child tasks.

- [ ] **Step 2: Run the test and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AppleSpeechRecognizerTests test
```

Expected: FAIL because recognizer/driver types do not exist.

- [ ] **Step 3: Implement the actor and live driver using installed signatures**

Preparation/start sequence in the live driver is exact and ordered:

```swift
let transcriber = try await assetPreparer.makePreparedTranscriber()
let analyzer = SpeechAnalyzer(
    modules: [transcriber],
    options: .init(priority: .userInitiated, modelRetention: .lingering)
)
let inputNode = audioEngine.inputNode
let sourceFormat = inputNode.outputFormat(forBus: 0)
guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber],
    considering: sourceFormat
) else { throw ConversationServiceError.speechAssetsUnavailable }
let converter = try converterFactory(sourceFormat, analyzerFormat)
let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
try await analyzer.prepareToAnalyze(in: analyzerFormat)
inputNode.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { buffer, time in
    do {
        for input in try converter.convert(buffer, at: time) {
            _ = inputContinuation.yield(input)
        }
    }
    catch { inputContinuation.finish(); captureFailure(error) }
}
let analysisTask = Task { try await analyzer.analyzeSequence(inputs) }
audioEngine.prepare()
try audioEngine.start()
```

Run a separate result task: `for try await result in transcriber.results`, convert with `String(result.text.characters)`, and yield `SpeechRecognitionEvent(text:isFinal:)`. Preserve volatile results; do not trim away meaningful Japanese punctuation and do not close an utterance when `isFinal` arrives. Both analysis-task and result-task errors must enter one exactly-once failure teardown and finish the public stream with `.speechCaptureFailed`; an error must never remain trapped in a fire-and-forget task while the caller hangs. Map cancellation to `.cancelled` only when it originated outside the driver's own normal/immediate teardown. Give each run an identity and ignore late callbacks from an old run.

The concrete `AppleSpeechRecognizer` owns one injected-or-live `SpeechAssetPreparer` for its full lifetime and one prepared driver per run. Its explicit states are unprepared, prepared, running, and stopping. `prepare()` is idempotent: it performs asset preparation, constructs the per-run analyzer/driver, and calls `prepareToAnalyze`, but it never installs a tap or starts the engine. `start()` prepares lazily when needed and rejects a second running start. After a completed stop, the next start constructs and prepares a fresh driver; asset reservation remains owned by the recognizer.

Normal `stop()` is lossless and ordered: remove the tap, stop and reset the engine, serialize against any in-flight tap callback, append every converter `flush()` output with an explicit yield loop, finish the analyzer input, call `try await analyzer.finalizeAndFinishThroughEndOfInput()`, await the analysis task and drain the result task, then finish the public stream and nil all per-run objects. Do **not** cancel either task or call `cancelAndFinishNow()` on this normal path; doing so can discard the flushed tail and final result.

Tap/converter, analyzer, result-stream, engine-start, and returned-stream consumer-cancellation paths use the exactly-once immediate teardown: remove tap if installed, stop/reset engine, finish input without emitting a converter tail after a failure, cancel result/analysis tasks, `await analyzer.cancelAndFinishNow()`, and finish the public stream with the mapped error (consumer cancellation may finish without a second error). Mark the run as stopping before cancellation so self-generated `CancellationError` does not recursively trigger failure teardown. The public stream's `onTermination` starts immediate teardown for its matching run identity, so abandoning a stream cannot leave the microphone active.

`AVAudioNodeTapBlock` may execute away from the actor executor and carries non-Sendable `AVAudioPCMBuffer`. Do not move its buffer into a `Task` and do not rely on actor isolation alone. Put the converter plus input continuation in one narrowly scoped `@unchecked Sendable` tap bridge protected by an `NSLock` or a dedicated serial queue. Convert and explicitly yield synchronously inside that boundary; serialize normal-stop flush/finish and failure close through the same bridge. Convert failures to the Sendable `ConversationServiceError.speechCaptureFailed` before notifying the actor with a `@Sendable` callback. The bridge must stop accepting buffers before flush/finish and guarantee one finish. Keep `AVAudioEngine`, `SpeechAnalyzer`, and their other non-Sendable run state inside the live driver.

Add a concrete-only `shutdown() async` to `AppleSpeechRecognizer`; do not expand `SpeechRecognizing`. `shutdown()` idempotently completes or immediately tears down an active run before `await assetPreparer.releaseReservation()`, and the test must verify that ordering as well as one release across repeated shutdown calls. Per-turn `stop()`, pause, background, and interruption do **not** release the reservation, avoiding a new asset setup on the next explicit resume. App composition invokes `shutdown()` only when leaving the conversation screen/app-root ownership lifetime. No `deinit` performs async work.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/AppleSpeechRecognizer.swift CatRobotTests/Conversation/Services/AppleSpeechRecognizerTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: stream progressive Japanese speech recognition"
```

### Task 6: Retained AVSpeechSynthesizer and mouth events

**Files:**
- Create: `CatRobot/Conversation/Services/AppleSpeechSynthesizer.swift`
- Test: `CatRobotTests/Conversation/Services/AppleSpeechSynthesizerTests.swift`

**Interfaces:**
- Consumes: `SpeechSpeaking`, domain `SpeechEvent`, `ConversationServiceError`.
- Produces: `prepare()` preflight plus retained Japanese synthesis whose delegate drives start/range/finish/cancel events.

- [ ] **Step 1: Write failing lifecycle tests using a main-actor synthesizer driver**

```swift
@MainActor
final class AppleSpeechSynthesizerTests: XCTestCase {
    func testSpeakUsesInstalledJapaneseVoiceAndForwardsMouthLifecycle() async throws {
        let driver = FakeSpeechSynthesizerDriver(voiceAvailable: true)
        let service = AppleSpeechSynthesizer(driver: driver, language: "ja-JP")
        let stream = try await service.speak("おはよう")
        let runID = try XCTUnwrap(driver.lastRunID)
        driver.emit(.didStart(runID: runID))
        driver.emit(.willSpeak(runID: runID, range: NSRange(location: 0, length: 2)))
        driver.emit(.didFinish(runID: runID))
        var events: [SpeechEvent] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events, [.started, .willSpeak(range: 0..<2), .finished])
        XCTAssertEqual(driver.spokenText, "おはよう")
    }

    func testMissingVoiceFailsBeforeSpeaking() async {
        let service = AppleSpeechSynthesizer(driver: FakeSpeechSynthesizerDriver(voiceAvailable: false), language: "ja-JP")
        do {
            try await service.prepare()
            XCTFail("Expected a missing voice error")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechVoiceUnavailable)
        }
    }

    func testDriverFailureMapsToSpeechSynthesisFailed() async {
        let driver = FakeSpeechSynthesizerDriver(
            voiceAvailable: true,
            speakError: NSError(domain: "AppleSpeechSynthesizerTests", code: 1)
        )
        let service = AppleSpeechSynthesizer(driver: driver)
        do {
            _ = try await service.speak("テスト")
            XCTFail("Expected the driver failure to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }
    }

    func testOverlappingSpeakMapsToSpeechSynthesisFailed() async throws {
        let service = AppleSpeechSynthesizer(driver: FakeSpeechSynthesizerDriver(voiceAvailable: true))
        _ = try await service.speak("最初の発話")
        do {
            _ = try await service.speak("重なる発話")
            XCTFail("Expected overlapping speech to be rejected")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed)
        }
        await service.stop()
    }

    func testStopCancelsCurrentUtteranceAndFinishesStream() async throws {
        let driver = FakeSpeechSynthesizerDriver(voiceAvailable: true, stopResult: true)
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("長い文")
        let runID = try XCTUnwrap(driver.lastRunID)
        let stopTask = Task { await service.stop() }
        await Task.yield()
        driver.emit(.didCancel(runID: runID))
        await stopTask.value
        var events: [SpeechEvent] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events, [.cancelled])
        XCTAssertEqual(driver.stopBoundary, .immediate)
    }

    func testStopFinishesImmediatelyWhenDriverReportsNothingWasStopped() async throws {
        let driver = FakeSpeechSynthesizerDriver(voiceAvailable: true, stopResult: false)
        let service = AppleSpeechSynthesizer(driver: driver)
        let stream = try await service.speak("長い文")
        await service.stop()
        var events: [SpeechEvent] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events, [.cancelled])
    }

    func testAbandoningStreamStopsOnlyItsMatchingRun() async throws {
        let driver = FakeSpeechSynthesizerDriver(voiceAvailable: true, stopResult: false)
        let service = AppleSpeechSynthesizer(driver: driver)
        var first: AsyncThrowingStream<SpeechEvent, Error>? = try await service.speak("最初")
        let firstRunID = try XCTUnwrap(driver.lastRunID)
        first = nil
        await eventually { driver.stopCallCount == 1 }

        let second = try await service.speak("次")
        let secondRunID = try XCTUnwrap(driver.lastRunID)
        XCTAssertNotEqual(firstRunID, secondRunID)
        driver.emit(.didCancel(runID: firstRunID))
        driver.emit(.didFinish(runID: secondRunID))
        var events: [SpeechEvent] = []
        for try await event in second {
            events.append(event)
        }
        XCTAssertEqual(events, [.finished])
    }
}
```

Also cover exact-locale preference with Japanese language fallback, overlapping `speak`, a fake `speak` throw, consumer-task cancellation, and a late callback from a stopped first utterance arriving after a second utterance starts. Keep `FakeSpeechSynthesizerDriver` and its callback-emitting `emit(_:)` seam `@MainActor`; every fake event includes its monotonic run identity. `SpeechEvent.willSpeak` carries the `NSRange` UTF-16 offsets supplied by `AVSpeechSynthesizer`, not Swift `String.Index` offsets.

- [ ] **Step 2: Run the focused test and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AppleSpeechSynthesizerTests test
```

Expected: FAIL because the synthesizer adapter/driver do not exist.

- [ ] **Step 3: Implement one retained synthesizer behind an explicit main-actor driver**

```swift
@MainActor
protocol SpeechSynthesizerDriving: AnyObject {
    var onEvent: (@MainActor @Sendable (SpeechSynthesizerDriverEvent) -> Void)? { get set }
    func availableVoices() -> [SpeechVoiceDescriptor]
    func speak(_ text: String, voiceIdentifier: String, runID: UInt64) throws
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

struct SpeechVoiceDescriptor: Equatable, Sendable {
    let identifier: String
    let language: String
}

enum SpeechSynthesizerDriverEvent: Sendable {
    case didStart(runID: UInt64)
    case willSpeak(runID: UInt64, range: NSRange)
    case didFinish(runID: UInt64)
    case didCancel(runID: UInt64)
}
```

Keep `AppleSpeechSynthesizer`, the driver protocol, the live driver, and all mutable AVFoundation state `@MainActor`; this is the documented isolation guarantee for both production and fake drivers. The live driver retains one `AVSpeechSynthesizer`, sets `usesApplicationAudioSession = true`, and owns the current `AVSpeechUtterance`. Its concrete `speak` implementation calls the `Void` AVFoundation API but keeps the protocol's throwing signature so enqueue failures can be exercised deterministically by the fake.

Do not pass non-Sendable `AVSpeechUtterance` objects across isolation boundaries. Use a small `@unchecked Sendable` `NSObject` delegate proxy whose nonisolated Objective-C callbacks synchronously reduce each utterance to a Sendable integer identity token (`UInt(bitPattern: ObjectIdentifier(utterance))`) plus Sendable event data, then forward to the main actor. The live driver accepts a callback only when that token matches its retained active utterance and emits the associated run ID; stale callbacks are ignored. Clear the retained utterance only after forwarding its terminal callback. This confines the narrowly justified unchecked boundary to identity/event bridging rather than the service.

`prepare()` selects and retains a descriptor from `availableVoices()`. Prefer canonical exact locale equality (`Locale.Language(identifier: voice.language) == Locale.Language(identifier: language)`), then fall back to a descriptor whose canonical language code is Japanese. Fail `.speechVoiceUnavailable` if none is installed. `speak` calls the same idempotent preflight, creates a new monotonic run ID, installs its continuation before invoking the driver, and rejects overlap with `.speechSynthesisFailed`. Map a driver `speak` throw to `.speechSynthesisFailed` and atomically clear the failed run.

Forward only matching-run `didStart`, `willSpeakRangeOfSpeechString`, `didFinish`, and `didCancel` events. On finish/cancel, yield the terminal domain event, clear active run state, finish its stream exactly once, and resume any matching `stop()` waiter. Preserve the synthesizer's `NSRange` integer values as UTF-16 offsets in `SpeechEvent.willSpeak`.

Install `onTermination` on every returned stream. Consumer cancellation or abandonment starts main-actor cancellation only for the captured run ID. The monotonic run guard ensures a delayed termination or delegate callback from a previous stream cannot stop or finish a newer utterance.

`stop()` is idempotent. With an active run it calls `stopSpeaking(at: .immediate)`. When the driver returns `true`, keep the run in stopping state and await the matching `didCancel`; when it returns `false`, AVFoundation does not promise a cancel callback, so synchronously yield `.cancelled`, clear and finish the stream, and resume the waiter. A repeated stop joins or returns from the same teardown rather than issuing another stop request.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/AppleSpeechSynthesizer.swift CatRobotTests/Conversation/Services/AppleSpeechSynthesizerTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: publish speech synthesis mouth events"
```

### Task 7: AVAudioSession activation and explicit interruption lifecycle

**Files:**
- Create: `CatRobot/Conversation/Services/AppleAudioSessionController.swift`
- Test: `CatRobotTests/Conversation/Services/AppleAudioSessionControllerTests.swift`

**Interfaces:**
- Consumes: the conversation-domain audio lifecycle protocol if provided; otherwise add this minimal service-local public contract for the integration branch:

```swift
protocol AudioSessionControlling: Sendable {
    var events: AsyncStream<AudioSessionEvent> { get }
    func activate() async throws
    func deactivate() async
}

enum AudioSessionEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
}
```

- Produces: `AppleAudioSessionController`, retained for the whole conversation screen lifetime.

- [ ] **Step 1: Write failing configuration and notification-mapping tests**

```swift
func testActivateUsesPlayAndRecordVoiceChatAndSpeakerBluetoothOptions() async throws {
    let session = FakeAudioSession()
    let controller = AppleAudioSessionController(session: session, notifications: center)
    try await controller.activate()
    XCTAssertEqual(session.category, .playAndRecord)
    XCTAssertEqual(session.mode, .voiceChat)
    XCTAssertEqual(session.options, [.defaultToSpeaker, .allowBluetoothHFP])
    XCTAssertTrue(session.isActive)
}

func testInterruptionEventsNeverReactivateAutomatically() async throws {
    let session = FakeAudioSession()
    let controller = AppleAudioSessionController(session: session, notifications: center)
    let events = controller.events
    let firstTwoEvents = Task { () -> [AudioSessionEvent] in
        var received: [AudioSessionEvent] = []
        for await event in events {
            received.append(event)
            if received.count == 2 { return received }
        }
        return received
    }
    center.post(name: AVAudioSession.interruptionNotification, object: session.object,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    center.post(name: AVAudioSession.interruptionNotification, object: session.object,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                           AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
    let received = await firstTwoEvents.value
    XCTAssertEqual(received, [.interruptionBegan, .interruptionEnded(shouldResume: true)])
    XCTAssertEqual(session.activateCallCount, 0)
}
```

- [ ] **Step 2: Run the focused test and confirm failure**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AppleAudioSessionControllerTests test
```

Expected: FAIL because the controller/session seam does not exist.

- [ ] **Step 3: Implement configuration, observation, and deactivation**

```swift
func activate() async throws {
    try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.defaultToSpeaker, .allowBluetoothHFP]
    )
    try session.setActive(true)
}

func deactivate() async {
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
}
```

Create one multicast-safe stream at controller initialization and retain notification observer tokens. Parse `AVAudioSession.interruptionNotification` using `AVAudioSessionInterruptionTypeKey` and `AVAudioSessionInterruptionOptionKey`; publish began/ended but never call `setActive(true)` from the handler. Publish `.routeChanged` for `AVAudioSession.routeChangeNotification` so integration can stop capture and re-preflight rather than continuing against a stale input format. Remove observers and finish the stream when the controller is released. Activation errors map to `.audioSessionFailed`; deactivation is best-effort.

- [ ] **Step 4: Run focused tests and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add CatRobot/Conversation/Services/AppleAudioSessionController.swift CatRobotTests/Conversation/Services/AppleAudioSessionControllerTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "feat: manage conversation audio session lifecycle"
```

### Task 8: Compile integration surface and verify the bounded branch

**Files:**
- Modify: `scripts/generate_project.rb` only if recursive source discovery from the foundation branch is demonstrably broken; otherwise no source modification.
- Test: all files under `CatRobotTests/Conversation/Services/`.

**Interfaces:**
- Consumes: every adapter above and the exact conversation-domain protocols.
- Produces: a buildable service layer for the later `feature/app-integration` branch; it does not create a view model, request permission, or start capture at launch.

- [ ] **Step 1: Add one compile-only composition test**

```swift
@MainActor
func testAppleServiceCompositionConformsToDomainProtocols() {
    let availability: any ModelAvailabilityChecking = FoundationModelAvailabilityService()
    let classifier: any AddressClassifying = FoundationModelAddressClassifier()
    let replies: any ReplyGenerating = FoundationModelReplyService()
    let concreteRecognizer = AppleSpeechRecognizer()
    let recognizer: any SpeechRecognizing = concreteRecognizer
    let shutdown: @Sendable () async -> Void = {
        await concreteRecognizer.shutdown()
    }
    let speaker: any SpeechSpeaking = AppleSpeechSynthesizer()
    let audio: any AudioSessionControlling = AppleAudioSessionController()
    _ = (availability, classifier, replies, recognizer, shutdown, speaker, audio)
}

func testServiceTeardownClosureReleasesSpeechReservationOnce() async throws {
    let locale = Locale(identifier: "ja-JP")
    let inventory = FakeSpeechAssetInventory(equivalentLocale: locale, reserveResult: true)
    let preparer = SpeechAssetPreparer(locale: locale, inventory: inventory)
    let concreteRecognizer = AppleSpeechRecognizer(
        assetPreparer: preparer,
        driverFactory: { FakeSpeechCaptureDriver() }
    )
    let recognizer: any SpeechRecognizing = concreteRecognizer
    let shutdown: @Sendable () async -> Void = {
        await concreteRecognizer.shutdown()
    }
    try await recognizer.prepare()

    await shutdown()
    await shutdown()

    let releasedLocales = await inventory.releasedLocales
    XCTAssertEqual(releasedLocales, [locale])
}
```

Place both tests in `CatRobotTests/Conversation/Services/AppleServiceCompositionTests.swift`. Live composition must retain `concreteRecognizer` while exposing it as `any SpeechRecognizing`, and must expose an `@Sendable () async -> Void` teardown closure that captures the same concrete instance and calls `shutdown()`. The first test proves protocol alignment without calling hardware/model methods; the second uses the fake inventory seam to prove repeated composition teardown releases one successfully reserved locale exactly once.

- [ ] **Step 2: Regenerate and run all service tests**

```bash
ruby scripts/generate_project.rb
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' -only-testing:CatRobotTests/AppleServiceCompositionTests -only-testing:CatRobotTests/FoundationModelAvailabilityServiceTests -only-testing:CatRobotTests/FoundationModelErrorMapperTests -only-testing:CatRobotTests/FoundationModelAddressClassifierTests -only-testing:CatRobotTests/FoundationModelReplyServiceTests -only-testing:CatRobotTests/SpeechAssetPreparerTests -only-testing:CatRobotTests/SpeechAudioConverterTests -only-testing:CatRobotTests/AppleSpeechRecognizerTests -only-testing:CatRobotTests/AppleSpeechSynthesizerTests -only-testing:CatRobotTests/AppleAudioSessionControllerTests test
```

Expected: all selected tests PASS with no Swift 6 concurrency warnings promoted to errors.

- [ ] **Step 3: Run the full simulator suite and a device build**

```bash
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=0D540017-B9D7-4E42-B99F-6D0840FD41DA' test
xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS,id=00008140-000610311A90801C' build
```

Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`. If the stable device identifier differs, obtain the connected `Not so bad` identifier from `xcrun devicectl list devices` and substitute that exact identifier; do not weaken code signing or change bundle IDs.

- [ ] **Step 4: Commit verification glue, review, squash-integrate, and retain the branch**

Runtime speech/model checks are deferred to the complete app-integration branch, where the real UI and lifecycle are present; this services branch performs only its focused simulator tests and signed device build.

```bash
git add CatRobotTests/Conversation/Services/AppleServiceCompositionTests.swift CatRobot.xcodeproj/project.pbxproj
git commit -m "test: verify Apple service composition"
git status --short
git log --oneline --decorate main..feature/apple-services
```

Expected before integration: clean status and only bounded service/test commits. From the main worktree after review:

```bash
git switch main
git merge --squash feature/apple-services
git commit -m "feat: add Apple voice and AI services"
git push origin main
git push -u origin feature/apple-services
```

Expected: one integrated commit on `main`; `feature/apple-services` remains pushed and is not deleted. The local `.worktrees/apple-services` directory may be removed only after verifying both pushes.
