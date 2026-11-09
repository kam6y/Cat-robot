import XCTest
@testable import CatRobot

/// 通常・確認待ちの宛先判定を、共有factoryのClaude wrapperを通して会話VMで扱う。モデル呼び出しだけをfakeにする。
@MainActor
final class ClarificationRoutingTests: XCTestCase {
    private static let original = "今日の天気はどう？"
    private static let context = ClarificationContext(originalUtterance: original)
    private static let originalRequest = AddressClassificationRequest(utterance: original)

    @MainActor
    private struct Routed {
        let harness: ConversationHarness
        let haiku: ClarificationAddressClient
        let sleeper: ConversationTestSleeper

        var clarificationsSpoken: Int {
            get async { await harness.speaker.texts.filter { $0 == ClarificationContext.question }.count }
        }
    }

    /// 最初のHaiku判定が ambiguous となり、聞き返して確認待ちになる。
    /// 振り分けは発話の1.2秒後に始まるので、確認待ちの作成時刻は T=1.2、期限は T+15=16.2。
    private func makeRouted(
        haiku result: GeneratedAddressTarget = .addressed,
        haikuError: ConversationServiceError? = nil,
        haikuGate: ConversationTestGate? = nil,
        memory: any ConversationMemoryManaging = UnsupportedConversationMemoryManager(),
        history: any ConversationHistoryReading = FakeConversationHistory()
    ) async -> Routed {
        let haiku = ClarificationAddressClient(result: result, error: haikuError, gate: haikuGate)
        let sleeper = ConversationTestSleeper()
        let classifier = ConversationComposition.makeAddressClassifier(claudeClient: haiku, history: history)
        let harness = ConversationHarness(memory: memory, classifierOverride: classifier,
                                          clarificationDelay: { await sleeper.sleep(for: $0) })
        await harness.completeUnengagedTurn(Self.original, at: 0)
        return Routed(harness: harness, haiku: haiku, sleeper: sleeper)
    }

    private func finish(_ routed: Routed) async {
        await routed.harness.sut.shutdown()
        await routed.sleeper.releaseAll()
    }

    func testExcludedRepliesKeepOriginalPendingUntilExpiry() async {
        let routed = await makeRouted(haiku: .notAddressed)
        await routed.harness.completeUnengagedTurn("お姉ちゃん、傘どこ？", at: 2)
        await routed.haiku.setResult(.ambiguous)
        await routed.harness.completeUnengagedTurn("明日の予定は？", at: 4)
        await routed.haiku.setResult(.addressed)
        await routed.harness.completeUnengagedTurn("言ったよ", at: 6)

        let haikuRequests = await routed.haiku.requests
        let generatedPrompts = await routed.harness.reply.prompts
        let expiries = await routed.sleeper.durations
        let clarifications = await routed.clarificationsSpoken
        XCTAssertEqual(haikuRequests.map(\.utterance), [Self.original, "お姉ちゃん、傘どこ？", "明日の予定は？", "言ったよ"])
        XCTAssertEqual(haikuRequests.map(\.clarification), [nil, Self.context, Self.context, Self.context])
        XCTAssertEqual(clarifications, 1)
        XCTAssertEqual(expiries, [.seconds(15)], "Excluded replies neither recreate nor extend the original 15 seconds")
        XCTAssertEqual(generatedPrompts, ["言ったよ"])
        await finish(routed)
    }

    func testPendingContextIsFixedWhenRoutingStartsAtTheExpiryBoundary() async {
        // T+14.9 に振り分けを始めた返事は文脈つき、T+15.0 からもHaikuで文脈なしに判定する。
        for (spokenAt, isPending) in [(14.9, true), (15.0, false)] {
            let routed = await makeRouted(haiku: .ambiguous)
            await routed.harness.completeUnengagedTurn("言ったよ", at: spokenAt)

            let haikuRequests = await routed.haiku.requests
            let generatedPrompts = await routed.harness.reply.prompts
            let followup = AddressClassificationRequest(utterance: "言ったよ", clarification: isPending ? Self.context : nil)
            XCTAssertEqual(haikuRequests, [Self.originalRequest, followup], "\(spokenAt)")
            XCTAssertEqual(generatedPrompts, [], "\(spokenAt)")
            await finish(routed)
        }
    }

    func testPendingClassifierFinishesAfterExpiry() async {
        // T+14.9 に文脈つきで判定を始め、T+15.0 に期限が切れ、T+15.1 に判定が返る。
        for target in [GeneratedAddressTarget.addressed, .ambiguous, .notAddressed] {
            let gate = ConversationTestGate()
            let routed = await makeRouted(haiku: target, haikuGate: gate)
            let harness = routed.harness
            let followup = Task { await harness.completeUnengagedTurn("言ったよ", at: 14.9) }
            let entered = await harness.waitUntil { await routed.haiku.requests.count == 2 }
            XCTAssertTrue(entered, "\(target): the pending reply must reach the contextual Haiku")
            harness.now.set(16.2)
            await routed.sleeper.release(0)
            for _ in 0..<20 { await Task.yield() }
            harness.now.set(16.3)
            await gate.open()
            await followup.value

            let postExpiryReclarifications = await routed.clarificationsSpoken - 1
            let generatedPrompts = await harness.reply.prompts
            XCTAssertEqual(postExpiryReclarifications, 0, "\(target)")
            XCTAssertEqual(generatedPrompts, target == .addressed ? ["言ったよ"] : [], "\(target)")
            if target != .addressed {
                await harness.completeUnengagedTurn("次の話", at: 20)
                let nextRequest = await routed.haiku.requests.last
                XCTAssertEqual(nextRequest, .init(utterance: "次の話"), "\(target): an expired pending must not add context")
            }
            await finish(routed)
        }
    }

    func testPendingHaikuFailureEndsTheTurnAndReleasesPending() async {
        let routed = await makeRouted(haikuError: .modelUnreachable)
        let harness = routed.harness
        await harness.completeUnengagedTurn("言ったよ", at: 3)
        await harness.sut.retryRecovery()
        await harness.emitCompletedUtterance("うん", at: 5)

        let haikuRequests = await routed.haiku.requests
        let generatedPrompts = await harness.reply.prompts
        XCTAssertEqual(haikuRequests, [Self.originalRequest, .init(utterance: "言ったよ", clarification: Self.context), .init(utterance: "うん")],
                       "The failed request is not retried, and the next request carries no clarification")
        XCTAssertEqual(generatedPrompts, [])
        await finish(routed)
    }

    /// Review Focus 2: 聞き返しの記録が .unsaved で終わっても、メモリ上の末尾（元の発言 → 聞き返し）は文脈から除かれ、
    /// 復元済みの往復だけが Haiku に届く。
    func testUnsavedClarificationPairIsStillDroppedFromContext() async {
        let prior = ConversationMemoryTurn(prompt: "ねこ、おはよう", response: "おはよう！")
        let store = MemoryStoreFake(snapshot: .init(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
                                                    revision: 1, savedAt: Date(), summary: "", turns: [prior]))
        let service = makeClaudeService(StubSessionFactory(), store: store)
        await store.setSaveFailure(true)
        let routed = await makeRouted(memory: service, history: service)
        let unsaved = await routed.harness.waitUntil { routed.harness.sut.viewState.memoryState == .unsaved }
        XCTAssertTrue(unsaved, "the clarification record fails to save but the reply still waits for confirmation")

        await routed.harness.completeUnengagedTurn("うん", at: 3)

        let requests = await routed.haiku.requests
        XCTAssertEqual(requests.map(\.utterance), [Self.original, "うん"])
        XCTAssertEqual(requests.first?.recentTurns, [prior], "the original judgement already sees the restored turn")
        XCTAssertEqual(requests.last?.clarification, Self.context)
        XCTAssertEqual(requests.last?.recentTurns, [prior],
                       "the unsaved (original → question) pair is dropped from the context like a saved one")
        await finish(routed)
    }

    func testFacingReplyDuringPendingSkipsClassifier() async {
        let routed = await makeRouted()
        routed.harness.attention.isFacingScreen = true
        await routed.harness.completeUnengagedTurn("いいえ", at: 3)

        let haikuRequests = await routed.haiku.requests
        let generatedPrompts = await routed.harness.reply.prompts
        XCTAssertEqual(haikuRequests, [Self.originalRequest])
        XCTAssertEqual(generatedPrompts, ["いいえ"])
        await finish(routed)
    }

    func testNegativeReplyGetsAReplyAndStartsTheFollowUpWindow() async {
        let routed = await makeRouted(haiku: .addressed)
        await routed.harness.completeUnengagedTurn("いいえ、あなたには言ってない", at: 3)
        await routed.harness.completeUnengagedTurn("じゃあ明日は？", at: 20)

        let haikuRequests = await routed.haiku.requests
        let generatedPrompts = await routed.harness.reply.prompts
        XCTAssertEqual(haikuRequests, [Self.originalRequest, .init(utterance: "いいえ、あなたには言ってない", clarification: Self.context)])
        XCTAssertEqual(generatedPrompts, ["いいえ、あなたには言ってない", "じゃあ明日は？"])
        await finish(routed)
    }

    func testPendingClassifierCannotOutliveLifecycle() async {
        enum Lifecycle: CaseIterable { case pause, newConversation, forget }
        for lifecycle in Lifecycle.allCases {
            let gate = ConversationTestGate()
            let routed = await makeRouted(haiku: .addressed, haikuGate: gate, memory: FakeConversationMemoryManager())
            let harness = routed.harness
            let ready = await harness.waitUntil { harness.sut.viewState.memoryState == .ready }
            XCTAssertTrue(ready, "\(lifecycle)")
            let followup = Task { await harness.completeUnengagedTurn("言ったよ", at: 3) }
            let entered = await harness.waitUntil { await routed.haiku.requests.count == 2 }
            XCTAssertTrue(entered, "\(lifecycle): the pending reply must reach the contextual Haiku")
            // 停止側は分類の完了を待つので、無効化が見えてからゲートを開ける。
            let operation = Task {
                switch lifecycle {
                case .pause: await harness.sut.toggleListening()
                case .newConversation: await harness.sut.startNewConversation()
                case .forget: await harness.sut.forgetConversation()
                }
            }
            let invalidated = await harness.waitUntil { harness.sut.viewState.phase == .paused }
            XCTAssertTrue(invalidated, "\(lifecycle)")
            let startsBeforeLateCompletion = await harness.recognizer.startCount
            await gate.open()
            await followup.value
            await operation.value
            for _ in 0..<20 { await Task.yield() }

            let lateGeneratedPrompts = await harness.reply.prompts
            let lateRecognizerRestarts = await harness.recognizer.startCount - startsBeforeLateCompletion
            XCTAssertEqual(lateGeneratedPrompts, [], "\(lifecycle)")
            XCTAssertEqual(lateRecognizerRestarts, 0, "\(lifecycle)")
            await finish(routed)
        }
    }

    func testTypedFillerIsSubmittedAndEmptyTypedInputIsNot() async {
        let routed = await makeRouted()
        let harness = routed.harness
        harness.sut.showTypedInput()
        await harness.sut.submitTypedText("   ")
        await harness.sut.submitTypedText("えっと")
        await harness.completeUnengagedTurn("うん", at: 10)

        let typedPrompts = await harness.reply.prompts
        let haikuRequests = await routed.haiku.requests
        XCTAssertEqual(typedPrompts.first, "えっと", "Typed text is sent as typed, without filler filtering or context")
        XCTAssertEqual(haikuRequests, [Self.originalRequest], "Typed input releases the pending clarification")
        await finish(routed)
    }
}

/// Models the first ambiguous classification and later replies without a second classifier/backend.
private actor ClarificationAddressClient: AddressModelClient {
    private var result: GeneratedAddressTarget
    private let error: ConversationServiceError?
    private let gate: ConversationTestGate?
    private(set) var requests: [AddressClassificationRequest] = []
    init(result: GeneratedAddressTarget, error: ConversationServiceError?, gate: ConversationTestGate?) {
        self.result = result; self.error = error; self.gate = gate
    }
    func classify(_ request: AddressClassificationRequest) async throws -> GeneratedAddressTarget {
        requests.append(request)
        if requests.count == 1 { return .ambiguous }
        await gate?.wait()
        if let error { throw error }
        return result
    }
    func setResult(_ result: GeneratedAddressTarget) { self.result = result }
}
