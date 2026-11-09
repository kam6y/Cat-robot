import Foundation
import XCTest
@testable import CatRobot

actor FakeConversationMemoryManager: ConversationMemoryManaging {
    private var state: ConversationMemoryState
    private var listeners: [AsyncStream<ConversationMemoryState>.Continuation] = []
    private(set) var forgets = 0
    private(set) var prepareCount = 0
    var failsForget = false
    /// 指定すると forgetConversation がこのゲートで待つ（削除中の操作を再現する）。
    private let forgetGate: ConversationTestGate?
    private let prepareGate: ConversationTestGate?
    init(state: ConversationMemoryState = .ready, forgetGate: ConversationTestGate? = nil,
         prepareGate: ConversationTestGate? = nil) {
        self.state = state
        self.forgetGate = forgetGate
        self.prepareGate = prepareGate
    }
    func setForgetFailure(_ value: Bool) { failsForget = value }
    func prepareMemory() async throws {
        prepareCount += 1
        await prepareGate?.wait()
        if case .restoreFailed(let error) = state { throw error }
        if case .forgetFailed = state { throw ConversationMemoryError.deleteFailed }
    }
    func memoryState() -> ConversationMemoryState { state }
    func recordExternalTurn(prompt: String, response: String) async {}
    func memoryUpdates() -> AsyncStream<ConversationMemoryState> {
        let (stream, continuation) = AsyncStream<ConversationMemoryState>.makeStream()
        listeners.append(continuation); continuation.yield(state)
        return stream
    }
    func publish(_ value: ConversationMemoryState) {
        state = value
        for listener in listeners { listener.yield(value) }
    }
    func retryMemoryOperation() async throws {
        if case .forgetFailed = state { try await forgetConversation() }
        else { publish(.ready) }
    }
    func forgetConversation() async throws {
        forgets += 1
        await forgetGate?.wait()
        if failsForget { publish(.forgetFailed(.deleteFailed)); throw ConversationMemoryError.deleteFailed }
        publish(.ready)
    }
}

@MainActor
final class ConversationMemoryIntegrationTests: XCTestCase {
    func testClarificationHistoryReachesTheNaturalConfirmationSession() async {
        let client = ScriptedSessionClient(chunks: ["天気のお話だね。"])
        let factory = StubSessionFactory(scripts: [client])
        let store = MemoryStoreFake()
        let service = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)

        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)

        let clarification = ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？")
        let afterClarification = await store.snapshot?.turns
        XCTAssertEqual(afterClarification, [clarification])
        XCTAssertTrue(client.prompts.isEmpty, "The clarification must not invoke generation")

        await harness.classifier.setResult(.addressed)
        await harness.completeUnengagedTurn("言ったよ", at: 3)

        let requests = await harness.classifier.requests
        XCTAssertEqual(requests.last, .init(utterance: "言ったよ", clarification: .init(originalUtterance: "今日の天気はどう？")),
                       "Only the classifier sees the original utterance as context")
        let instructions = await factory.sessions.last?.configuration.instructions ?? ""
        XCTAssertTrue(instructions.contains("利用者: 今日の天気はどう？\n猫: 今の、ぼくに言った？"))
        XCTAssertEqual(client.prompts, ["言ったよ"], "Preserve the actual follow-up rather than rewriting it as the original question")
        let saved = await store.snapshot?.turns
        XCTAssertEqual(saved, [clarification, .init(prompt: "言ったよ", response: "天気のお話だね。")])
        await harness.sut.shutdown()
    }

    func testClarificationHistorySurvivesRestoringTheMemoryService() async throws {
        let store = MemoryStoreFake()
        let service = makeClaudeService(store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
        await harness.sut.shutdown()

        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["天気のお話だね。宛先を確認できたよ。"])])
        let restored = makeClaudeService(factory, store: store)
        for try await _ in try await restored.streamReply(to: "言ったよ") {}

        let instructions = await factory.sessions.last?.configuration.instructions ?? ""
        XCTAssertTrue(instructions.contains("利用者: 今日の天気はどう？\n猫: 今の、ぼくに言った？"))
        let saved = await store.snapshot?.turns
        XCTAssertEqual(saved, [
            .init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？"),
            .init(prompt: "言ったよ", response: "天気のお話だね。宛先を確認できたよ。")
        ])
    }

    func testLongOriginalRemainsClassifierContextWhileShortReplyFitsGenerationLimit() async {
        let original = String(repeating: "あ", count: 4_001)
        let client = ScriptedSessionClient(chunks: ["元の話に答えるね。"])
        let factory = StubSessionFactory(scripts: [client])
        let store = MemoryStoreFake()
        let service = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        await harness.completeUnengagedTurn(original, at: 0)
        await harness.classifier.setResult(.addressed)
        await harness.completeUnengagedTurn("はい", at: 3)

        let requests = await harness.classifier.requests
        let saved = await store.snapshot?.turns
        XCTAssertEqual(requests.last, .init(utterance: "はい", clarification: .init(originalUtterance: original)),
                       "The full original is classification context, outside the generation prompt limit")
        XCTAssertEqual(client.prompts, ["はい"])
        XCTAssertEqual(saved, [.init(prompt: original, response: ClarificationContext.question),
                               .init(prompt: "はい", response: "元の話に答えるね。")])
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.shutdown()
    }

    func testOversizedCurrentReplyStillReportsInputTooLongWithoutRecordingAGeneratedTurn() async {
        let client = ScriptedSessionClient(chunks: ["使われない返事。"])
        let factory = StubSessionFactory(scripts: [client])
        let store = MemoryStoreFake()
        let service = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
        await harness.classifier.setResult(.addressed)
        await harness.completeUnengagedTurn(String(repeating: "あ", count: 4_001), at: 3)

        let saved = await store.snapshot?.turns
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.inputTooLong))
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: ClarificationContext.question)])
        await harness.sut.shutdown()
    }

    func testUnfinishedOrFailedClarificationDoesNotCreateHistory() async {
        enum Outcome: CaseIterable { case synthesisFailure, incompleteStream, cancelled }
        for outcome in Outcome.allCases {
            let store = MemoryStoreFake()
            let service = makeClaudeService(store: store)
            let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous,
                speakerAutomaticallyFinishes: false,
                speakerError: outcome == .synthesisFailure ? .speechSynthesisFailed : nil)
            if outcome == .synthesisFailure {
                await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
            } else {
                let turn = Task { await harness.completeUnengagedTurn("今日の天気はどう？", at: 0) }
                await harness.speaker.waitUntilTextCount(1)
                let beforeCompletion = await store.saveCount
                XCTAssertEqual(beforeCompletion, 0, "\(outcome)")
                await harness.speaker.yield(.started)
                if outcome == .cancelled {
                    await harness.sut.sceneBecameInactive()
                } else {
                    await harness.speaker.finish()
                }
                await turn.value
            }
            let saved = await store.snapshot
            let saves = await store.saveCount
            XCTAssertNil(saved, "\(outcome)")
            XCTAssertEqual(saves, 0, "\(outcome)")
            await harness.sut.shutdown()
        }
    }

    func testClarificationFinishingAfterExpiryStillRecordsOriginal() async {
        let client = ScriptedSessionClient(chunks: ["生成されない返答"])
        let factory = StubSessionFactory(scripts: [client])
        let store = MemoryStoreFake()
        let service = makeClaudeService(factory, store: store)
        let sink = RecordingReplyTraceSink()
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(replyOverride: service, replyTraceSink: sink, memory: service,
            classification: .ambiguous, speakerAutomaticallyFinishes: false,
            clarificationDelay: { await sleeper.sleep(for: $0) })
        let turn = Task { await harness.completeUnengagedTurn("今日の天気はどう？ ", at: 0) }
        let speaking = await harness.waitUntil { await harness.speaker.texts.count == 1 }
        let scheduled = await harness.waitUntil { await sleeper.durations.count == 1 }
        XCTAssertTrue(speaking)
        XCTAssertTrue(scheduled)
        guard speaking, scheduled else {
            await harness.sut.shutdown()
            await sleeper.releaseAll()
            await turn.value
            return
        }
        let durations = await sleeper.durations
        XCTAssertEqual(durations, [.seconds(15)])
        // The pending context expires while the question is still being spoken.
        await sleeper.release(0)
        for _ in 0..<20 { await Task.yield() }
        let savesDuringSpeech = await store.saveCount
        XCTAssertEqual(savesDuringSpeech, 0)
        await harness.speaker.yield(.started)
        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        let saved = await store.snapshot?.turns
        let saves = await store.saveCount
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: ClarificationContext.question)])
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(client.prompts.isEmpty, "The clarification must not invoke generation")
        XCTAssertEqual(starts, 2, "Listening resumes after the question")
        let events = harness.latency.events
        guard case let .began(token, _, _, _, _) = events.first else {
            await harness.sut.shutdown()
            await sleeper.releaseAll()
            return XCTFail("Expected a latency turn")
        }
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .ambiguous, at: 1.2)))
        XCTAssertFalse(events.contains {
            switch $0 {
            case .caption, .speech: true
            default: false
            }
        })
        XCTAssertEqual(sink.events.filter { $0.point == .finished }.map(\.outcome), [.ambiguous])
        XCTAssertFalse(sink.events.contains { [.firstCaption, .speechEnqueued, .speechStarted, .speechFinished].contains($0.point) })

        // Before the 15-second deadline by the clock, so only the expiry task can have cleared the context.
        await harness.classifier.setResult(.notAddressed)
        await harness.completeUnengagedTurn("うん", at: 3)
        let requests = await harness.classifier.requests
        XCTAssertEqual(requests.last, .init(utterance: "うん"))
        await harness.sut.shutdown()
        await sleeper.releaseAll()
    }

    func testPauseWhileSavingClarificationDoesNotResumeOldCapture() async {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(saveGate: gate)
        let service = makeClaudeService(store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        let turn = Task { await harness.completeUnengagedTurn("今日の天気はどう？", at: 0) }
        let saving = await harness.waitUntil { await store.saveCount == 1 }
        XCTAssertTrue(saving)
        guard saving else {
            await gate.open()
            await turn.value
            await harness.sut.shutdown()
            return
        }
        let stopping = Task { await harness.sut.sceneBecameInactive() }
        let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
        XCTAssertTrue(paused)
        await gate.open()
        await stopping.value
        await turn.value

        let starts = await harness.recognizer.startCount
        let saved = await store.snapshot?.turns
        XCTAssertEqual(starts, 1, "An old save completion must not reopen the microphone")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？")])
        await harness.sut.shutdown()
    }

    func testForgetWhileSavingClarificationCannotRestoreDeletedContext() async {
        let gate = ConversationTestGate()
        let store = MemoryStoreFake(saveGate: gate)
        let factory = StubSessionFactory()
        let service = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        let turn = Task { await harness.completeUnengagedTurn("今日の天気はどう？", at: 0) }
        let saving = await harness.waitUntil { await store.saveCount == 1 }
        XCTAssertTrue(saving)
        guard saving else {
            await gate.open()
            await turn.value
            await harness.sut.shutdown()
            return
        }
        let forgetting = Task { await harness.sut.forgetConversation() }
        let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
        XCTAssertTrue(paused)
        await gate.open()
        await forgetting.value
        await turn.value

        let saved = await store.snapshot
        let events = await store.events
        let starts = await harness.recognizer.startCount
        XCTAssertNil(saved)
        XCTAssertEqual(events, ["save", "clear"])
        XCTAssertEqual(starts, 1)
        await harness.sut.submitTypedText("新しい質問")
        let instructions = await factory.sessions.last?.configuration.instructions ?? ""
        XCTAssertFalse(instructions.contains("今日の天気はどう？"))
        XCTAssertEqual(instructions, ConversationInstructions.fixedPrefix,
                       "The new session has no memory sections after forgetting; the fixed guidance still names the clarification")
        await harness.sut.shutdown()
    }

    func testClarificationSaveFailurePreservesContextAndCanBeRetried() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["天気のお話だね。保存を再試行するよ。"])])
        let service = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
        let warned = await harness.waitUntil { harness.sut.viewState.memoryState == .unsaved }
        XCTAssertTrue(warned)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        await harness.classifier.setResult(.addressed)
        await harness.completeUnengagedTurn("言ったよ", at: 3)
        let instructions = await factory.sessions.last?.configuration.instructions ?? ""
        XCTAssertTrue(instructions.contains("利用者: 今日の天気はどう？\n猫: 今の、ぼくに言った？"))
        await store.setSaveFailure(false)
        try await service.retryMemoryOperation()
        let saved = await store.snapshot?.turns
        let state = await service.memoryState()
        XCTAssertEqual(saved, [
            .init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？"),
            .init(prompt: "言ったよ", response: "天気のお話だね。保存を再試行するよ。")
        ])
        XCTAssertEqual(state, .ready)
        await harness.sut.shutdown()
    }

    func testNegativeReplyCommitsActualFollowupOnce() async {
        // 短い否定も言い方の違う否定も、聞き返しへの答えとして実際の発言で1回だけ返答し、往復として残す。
        for followup in ["ううん", "いいえ、あなたには言ってない"] {
            let client = ScriptedSessionClient(chunks: ["そっか、わかった。"])
            let factory = StubSessionFactory(scripts: [client])
            let store = MemoryStoreFake()
            let service = makeClaudeService(factory, store: store)
            let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
            await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
            await harness.classifier.setResult(.addressed)
            await harness.completeUnengagedTurn(followup, at: 3)

            let requests = await harness.classifier.requests
            let instructions = await factory.sessions.last?.configuration.instructions ?? ""
            let saved = await store.snapshot?.turns
            XCTAssertEqual(requests.last, .init(utterance: followup, clarification: .init(originalUtterance: "今日の天気はどう？")), followup)
            XCTAssertEqual(client.prompts, [followup], followup)
            XCTAssertEqual(instructions.components(separatedBy: "今日の天気はどう？").count - 1, 1,
                           "The restored history carries the original exactly once: \(followup)")
            XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？"),
                                   .init(prompt: followup, response: "そっか、わかった。")], followup)
            await harness.sut.shutdown()
        }
    }

    func testStillAmbiguousFollowupKeepsOnlyTheClarificationTurn() async {
        let store = MemoryStoreFake()
        let service = makeClaudeService(store: store)
        let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous)
        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
        await harness.completeUnengagedTurn("明日の予定は？", at: 3)

        let requests = await harness.classifier.requests
        let saved = await store.snapshot?.turns
        let spoken = await harness.speaker.texts
        XCTAssertEqual(requests.last, .init(utterance: "明日の予定は？", clarification: .init(originalUtterance: "今日の天気はどう？")))
        XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？")])
        XCTAssertEqual(spoken, ["今の、ぼくに言った？"])
        await harness.sut.shutdown()
    }

    func testSpeechFailureOrCancellationAfterCommitKeepsHistory() async {
        enum Ending: CaseIterable { case speechFailure, cancelled }
        for ending in Ending.allCases {
            let store = MemoryStoreFake()
            let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["そっか、わかった。"])])
            let service = makeClaudeService(factory, store: store)
            let harness = ConversationHarness(replyOverride: service, memory: service, classification: .ambiguous,
                                              speakerAutomaticallyFinishes: false)
            let original = Task { await harness.completeUnengagedTurn("今日の天気はどう？", at: 0) }
            await harness.speaker.waitUntilTextCount(1)
            await harness.speaker.yield(.started)
            await harness.speaker.yield(.finished)
            await harness.speaker.finish()
            await original.value
            await harness.classifier.setResult(.addressed)

            let followup = Task { await harness.completeUnengagedTurn("ううん", at: 3) }
            let committed = await harness.waitUntil {
                let turns = await store.snapshot?.turns.count
                let spoken = await harness.speaker.texts.count
                return turns == 2 && spoken == 2
            }
            XCTAssertTrue(committed, "\(ending): the generated reply commits before its playback ends")
            switch ending {
            case .speechFailure: await harness.speaker.fail(run: 1, with: .speechSynthesisFailed)
            case .cancelled: await harness.sut.sceneBecameInactive()
            }
            await followup.value

            let saved = await store.snapshot?.turns
            XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？"),
                                   .init(prompt: "ううん", response: "そっか、わかった。")], "\(ending)")
            await harness.sut.shutdown()
        }
    }

    func testContextStaysOutOfPromptAndHistory() async {
        let prior = ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")
        let client = ScriptedSessionClient(chunks: ["傘はいらないよ。"])
        let store = MemoryStoreFake(snapshot: .init(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
                                                    revision: 1, savedAt: Date(), summary: "", turns: [prior]))
        let service = makeClaudeService(StubSessionFactory(scripts: [client]), store: store)
        let base = FakeAddressClassifier(result: .addressed, log: ConversationTestCallLog())
        let harness = ConversationHarness(replyOverride: service, memory: service,
                                          classifierOverride: ContextualAddressClassifier(base: base, history: service))

        await harness.completeUnengagedTurn("それで、あしたは？", at: 0)
        await harness.waitUntil { await store.snapshot?.turns.count == 2 }

        let requests = await base.requests
        let saved = await store.snapshot?.turns
        XCTAssertEqual(requests, [.init(utterance: "それで、あしたは？", recentTurns: [prior])], "The context reaches only the classifier")
        XCTAssertEqual(client.prompts, ["それで、あしたは？"], "The reply prompt is the utterance alone, without the context")
        XCTAssertEqual(saved, [prior, .init(prompt: "それで、あしたは？", response: "傘はいらないよ。")],
                       "History keeps the actual turns only; the context turns are not duplicated")
        await harness.sut.shutdown()
    }

    func testPendingReplyFailureSpeaksGuidanceAndSavesNothing() async {
        let store = MemoryStoreFake()
        let factory = StubSessionFactory(scripts: [ScriptedSessionClient(chunks: [" \n"], failure: URLError(.notConnectedToInternet))])
        let primary = makeClaudeService(factory, store: store)
        let harness = ConversationHarness(replyOverride: primary, memory: primary, classification: .ambiguous)
        await harness.completeUnengagedTurn("今日の天気はどう？", at: 0)
        await harness.classifier.setResult(.addressed)
        await harness.completeUnengagedTurn("うん", at: 3)
        let saved = await store.snapshot?.turns
        let texts = await harness.speaker.texts
        XCTAssertEqual(texts.last, ConversationFailureGuidance.unreachable)
        XCTAssertEqual(saved, [.init(prompt: "今日の天気はどう？", response: "今の、ぼくに言った？")])
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnreachable))
        await harness.sut.shutdown()
    }

    func testNewConversationAfterMicrophoneDenialDropsStoredContextBeforeTypedReply() async {
        let store = InMemoryConversationMemoryStore(snapshot: .init(
            schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: "前の会話の要約",
            turns: [.init(prompt: "前の質問", response: "前の返答")]))
        let factory = StubSessionFactory()
        let service = makeClaudeService(factory, store: store)
        let h = ConversationHarness(microphoneAllowed: false)
        let sut = ConversationViewModel(dependencies: ConversationDependencies(
            microphonePermission: h.microphone, modelAvailability: h.modelAvailability,
            recognizer: h.recognizer, classifier: h.classifier, reply: service,
            speaker: h.speaker, audioSession: h.audio, latency: h.latency, memory: service))
        await sut.startConversation()
        let beforeReset = await service.memoryState()
        XCTAssertEqual(beforeReset, .unprepared)
        await sut.startNewConversation()
        await sut.submitTypedText("新しい質問")
        let sessions = await factory.sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions.first?.configuration.instructions.contains("前の会話の要約") ?? true)
        XCTAssertFalse(sessions.first?.configuration.instructions.contains("前の質問") ?? true)
        XCTAssertFalse(sut.viewState.caption.isEmpty)
        await sut.shutdown()
        await h.sut.shutdown()
    }

    func testRestoreFailureBlocksVoiceAndTypedReply() async {
        for typed in [false, true] {
            let memory = FakeConversationMemoryManager(state: .restoreFailed(.invalidData))
            let harness = ConversationHarness(memory: memory)
            if typed { await harness.sut.submitTypedText("こんにちは") }
            else { await harness.sut.startConversation() }
            XCTAssertEqual(harness.sut.viewState.phase, .paused)
            XCTAssertEqual(harness.sut.viewState.memoryState, .restoreFailed(.invalidData))
            XCTAssertFalse(harness.calls.values.contains(.startRecognizer))
            let prompts = await harness.reply.prompts
            XCTAssertTrue(prompts.isEmpty)
            await harness.sut.shutdown()
        }
    }
    func testUnsavedWarningSurvivesReplyAndPauseAndRetry() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("こんにちは")
        XCTAssertFalse(harness.sut.viewState.caption.isEmpty)
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        await harness.sut.sceneBecameInactive()
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        await harness.sut.retryMemoryOperation()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }
    func testWarningSurvivesGenerationFailure() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory, replySnapshots: nil)
        let turn = Task { await harness.sut.submitTypedText("こんにちは") }
        await harness.reply.waitUntilPromptCount(1)
        await harness.reply.fail(.modelGenerationFailed)
        await turn.value
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        XCTAssertNotNil(ConversationMemoryPresentation(state: harness.sut.viewState.memoryState).message)
        await harness.sut.shutdown()
    }

    func testForgetConfirmationAndSuccessfulForgetClearVisibleText() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("こんにちは")
        harness.sut.updateTypedText("送信前の文")
        let before = await memory.forgets
        XCTAssertEqual(before, 0)
        XCTAssertFalse(harness.sut.viewState.caption.isEmpty)
        await harness.sut.forgetConversation()
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.typedText, "")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertNotNil(harness.sut.viewState.memoryNotice)
        let after = await memory.forgets
        XCTAssertEqual(after, 1)
        await harness.sut.shutdown()
    }
    func testFailedForgetDoesNotAnnounceSuccessAndRetryClearsText() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("覚えて")
        await memory.setForgetFailure(true)
        await harness.sut.forgetConversation()
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertEqual(harness.sut.viewState.memoryState, .forgetFailed(.deleteFailed))
        XCTAssertFalse(harness.sut.viewState.allowsTypedSubmission)
        await memory.setForgetFailure(false)
        await harness.sut.retryMemoryOperation()
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }
}
