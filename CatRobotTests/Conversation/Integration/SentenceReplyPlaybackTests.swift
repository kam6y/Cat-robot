import XCTest
@testable import CatRobot

@MainActor
final class SentenceReplyPlaybackTests: XCTestCase {
    func testFirstSentenceSynthesisStartsBeforeGenerationCompletesButPlaybackWaitsForConfirmation() async throws {
        let synthesisStarted = expectation(description: "Prepare the completed first sentence while generation remains open")
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        let inputs = SynthesisInputs()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
            synthesize: { text, _ in
                await inputs.record(text)
                synthesisStarted.fulfill()
                return SpeechPCM(samples: [0.25], sampleRate: 24_000)
            })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "挨拶して", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("こんにちは。")
        await fulfillment(of: [synthesisStarted], timeout: 0.5)
        XCTAssertEqual(player.playCount, 0, "Preparation must not make unconfirmed text audible")
        await reply.finish()
        let response = try await run.value
        let synthesized = await inputs.inputs
        XCTAssertEqual(response, "こんにちは。")
        XCTAssertEqual(synthesized, ["こんにちは。"], "A matching prepared sentence must not be synthesized again")
        XCTAssertEqual(player.playCount, 1)
    }

    func testFirstPreparationReusesTrimmedInputButAuditsConfirmedOriginal() async throws {
        let synthesisStarted = expectation(description: "Prepare before trailing whitespace arrives")
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        let inputs = SynthesisInputs()
        var originals: [String] = []
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
            synthesize: { text, _ in
                await inputs.record(text)
                synthesisStarted.fulfill()
                return SpeechPCM(samples: [0.25], sampleRate: 24_000)
            })
        speaker.onInput = { original, _ in originals.append(original) }
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "挨拶して", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("こんにちは。")
        await fulfillment(of: [synthesisStarted], timeout: 0.5)
        XCTAssertTrue(originals.isEmpty, "Unconfirmed preparation is not a committed speech input")
        await reply.yield("こんにちは。 \n")
        await reply.finish()
        let response = try await run.value
        let synthesized = await inputs.inputs
        XCTAssertEqual(response, "こんにちは。 \n")
        XCTAssertEqual(originals, ["こんにちは。 \n"])
        XCTAssertEqual(synthesized, ["こんにちは。"])
        XCTAssertEqual(player.playCount, 1)
    }

    func testChangedCandidateCancelsAndDrainsBeforeSynthesisOfConfirmedText() async throws {
        let started = expectation(description: "Candidate inference entered")
        let cancelled = expectation(description: "Changed candidate is cancelled before it finishes")
        let gate = ConversationTestGate()
        let synthesis = PreparationSynthesisProbe(started: started, cancelled: cancelled, gate: gate)
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        var audited: [String] = []
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
            synthesize: { try await synthesis.make($0, voice: $1) })
        speaker.onInput = { original, _ in audited.append(original) }
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("仮の文。")
        await fulfillment(of: [started], timeout: 0.5)
        await reply.yield("確定した別の文。")
        await reply.finish()
        await fulfillment(of: [cancelled], timeout: 0.5)
        let beforeDrain = await synthesis.inputs
        XCTAssertEqual(beforeDrain, ["仮の文。"], "Final synthesis cannot overlap an uncooperative candidate")
        XCTAssertEqual(player.playCount, 0)
        await gate.open()
        let response = try await run.value
        let actual = await synthesis.inputs
        let maximumConcurrent = await synthesis.maximumConcurrent
        XCTAssertEqual(response, "確定した別の文。")
        XCTAssertEqual(actual, ["仮の文。", "確定した別の文。"])
        XCTAssertEqual(audited, ["確定した別の文。"])
        XCTAssertEqual(maximumConcurrent, 1)
        XCTAssertEqual(player.playCount, 1)
    }

    func testUnusedCandidateFailureDoesNotFailDifferentConfirmedSentence() async throws {
        let started = expectation(description: "Candidate fails while generation stays open")
        let synthesis = PreparationSynthesisProbe(started: started, failFirst: true)
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
            synthesize: { try await synthesis.make($0, voice: $1) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("仮の文。")
        await fulfillment(of: [started], timeout: 0.5)
        await reply.yield("別の確定文。")
        await reply.finish()
        let response = try await run.value
        let actual = await synthesis.inputs
        XCTAssertEqual(response, "別の確定文。")
        XCTAssertEqual(actual, ["仮の文。", "別の確定文。"])
        XCTAssertEqual(player.playCount, 1)
    }

    func testCancellationWaitsForCandidateInferenceAndNeverPlaysItsPCM() async throws {
        let started = expectation(description: "Candidate inference entered")
        let cancelled = expectation(description: "Cancellation reaches owned candidate task")
        let gate = ConversationTestGate()
        let synthesis = PreparationSynthesisProbe(started: started, cancelled: cancelled, gate: gate)
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
            synthesize: { try await synthesis.make($0, voice: $1) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("まだ確定していない文。")
        await fulfillment(of: [started], timeout: 0.5)
        var stopReturned = false
        let stop = Task { await sut.cancelAndWait(); stopReturned = true }
        await fulfillment(of: [cancelled], timeout: 0.5)
        XCTAssertFalse(stopReturned, "Stop must drain native inference even when cancellation is ignored")
        XCTAssertEqual(player.playCount, 0)
        await gate.open()
        await stop.value
        do { _ = try await run.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .cancelled) }
        XCTAssertTrue(stopReturned)
        XCTAssertEqual(player.playCount, 0)
        let next = Task { try await sut.run(prompt: "次の質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested(2)
        await reply.yield("新しい返答。")
        await reply.finish()
        let nextResponse = try await next.value
        let actual = await synthesis.inputs
        XCTAssertEqual(nextResponse, "新しい返答。")
        XCTAssertEqual(actual, ["まだ確定していない文。", "新しい返答。"])
        XCTAssertEqual(player.playCount, 1, "The next turn cannot play the cancelled candidate")
    }

    func testConfirmedOutputLimitIsCheckedBeforeTrimmingOnPreparationHit() async throws {
        let started = expectation(description: "Valid candidate is prepared")
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        let inputs = SynthesisInputs()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { original in
            original.hasSuffix(" ") ? String(repeating: " ", count: 2_000) + "ハイ。" : "ハイ。"
        }, voice: { .f1 }, synthesize: { text, _ in
            await inputs.record(text)
            started.fulfill()
            return SpeechPCM(samples: [1], sampleRate: 24_000)
        })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("はい。")
        await fulfillment(of: [started], timeout: 0.5)
        await reply.yield("はい。 ")
        await reply.finish()
        do { _ = try await run.value; XCTFail("Confirmed normalization must not bypass the output limit") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .speechSynthesisFailed) }
        let actual = await inputs.inputs
        XCTAssertEqual(actual, ["ハイ。"])
        XCTAssertEqual(player.playCount, 0)
    }

    func testGenerationFailureDiscardsReadyUnconfirmedPCMAndPreservesError() async throws {
        let started = expectation(description: "Candidate is synthesized before upstream fails")
        let reply = ControlledReply()
        let player = TestPCMPlayer()
        var audited: [String] = []
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in
            started.fulfill()
            return SpeechPCM(samples: [1], sampleRate: 24_000)
        })
        speaker.onInput = { original, _ in audited.append(original) }
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("未確定の返答。")
        await fulfillment(of: [started], timeout: 0.5)
        await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await run.value; XCTFail("Expected upstream failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        XCTAssertTrue(audited.isEmpty)
        XCTAssertEqual(player.playCount, 0)
    }

    func testUnstableOrProtectedIncompletePrefixDoesNotStartPreparation() async throws {
        for (text, stable) in [("仮の返答。", false), ("「閉じない引用。", true),
                               ("https://example.test/?q=a!", true), ("`閉じないコード。", true)] {
            let reply = ControlledReply(stablePrefix: stable)
            let player = TestPCMPlayer()
            let inputs = SynthesisInputs()
            let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { text, _ in
                await inputs.record(text)
                return SpeechPCM(samples: [1], sampleRate: 24_000)
            })
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
            let updates = PlaybackUpdates()
            let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
            await reply.waitUntilRequested()
            await reply.yield(text)
            await updates.waitForCaption(text)
            try await Task.sleep(for: .milliseconds(150))
            let before = await inputs.inputs
            XCTAssertTrue(before.isEmpty, text)
            await reply.finish()
            let response = try await run.value
            XCTAssertEqual(response, text)
            XCTAssertEqual(player.playCount, 1)
        }
    }

    func testVoiceCaptureWaitsForLastSentenceAndCaptionStaysOriginal() async throws {
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [0.1], sampleRate: 24_000) })
        let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker)
        let run = await harness.beginVoiceTurn()
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("iPhoneです。Bluetoothです。最後。")
        await harness.reply.finish()
        await player.waitForCalls(1)
        player.complete(0); await player.waitForCalls(2)
        player.complete(1); await player.waitForCalls(3)
        let before = await harness.recognizer.startCount
        XCTAssertEqual(before, 1)
        XCTAssertEqual(harness.viewModel.viewState.caption, "iPhoneです。Bluetoothです。最後。")
        player.complete(2); await run.value
        let after = await harness.recognizer.startCount
        XCTAssertEqual(after, 2)
        XCTAssertEqual(harness.traces.events.filter { $0.point == .speechStarted }.compactMap(\.sentenceOrdinal), [0, 1, 2])
        await harness.viewModel.shutdown()
    }
    func testSentenceFailureAndCancellationCloseMouthAndRejectOldPlayerEvents() async {
        for failure in [false, true] {
            let player = ControlledPCMPlayer()
            let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 },
                synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
            let harness = PlaybackIntegrationHarness(sentenceSpeaker: speaker)
            let run = Task { await harness.viewModel.submitTypedText("質問") }
            await harness.reply.waitUntilRequested()
            await harness.reply.yield("最初。続き")
            await player.waitForCalls(1)
            await robotDrain()
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .wide)
            if failure { player.fail(0) }
            else { await harness.viewModel.toggleListening() }
            await run.value
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
            XCTAssertEqual(harness.viewModel.viewState.phase, failure ? .failed(.speechSynthesisFailed) : .paused)
            let next = Task { await harness.viewModel.submitTypedText("次の質問") }
            await harness.reply.waitUntilRequested(2)
            player.emit(.started, index: 0)
            player.complete(0)
            await robotDrain()
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
            await harness.reply.yield("新しい返答。")
            await harness.reply.finish()
            await player.waitForCalls(2)
            await robotDrain()
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .wide, "New replies restart their own mouth sequence")
            player.emit(.finished, index: 0)
            await robotDrain()
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .wide)
            player.complete(1)
            await next.value
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
            await harness.viewModel.shutdown()
        }
    }

    func testGenerationFailureStopsPlaybackAndKeepsError() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested(); await reply.yield("一文目。続き")
        await player.waitForCalls(1)
        await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
        do { _ = try await run.value; XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed) }
        XCTAssertGreaterThan(player.stops, 0)
    }
    func testGenerationFailureNeverSynthesizesUnfinishedTailAfterFirstSentence() async throws {
        for failure in [ConversationServiceError.modelGenerationFailed, .inputTooLong] {
            let reply = ControlledReply()
            let firstFinished = expectation(description: "First sentence has finished")
            var synthesized: [String] = []
            let speaker = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {}, normalize: { $0 }, voice: { .f1 },
                synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
            speaker.onInput = { _, spoken in synthesized.append(spoken) }
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
            let run = Task {
                try await sut.run(prompt: "質問", trace: nil) { update in
                    if case .sentenceFinished(ordinal: 0) = update { firstFinished.fulfill() }
                }
            }
            await reply.waitUntilRequested()
            await reply.yield("最初。未確定の末尾")
            await fulfillment(of: [firstFinished], timeout: 1)
            if failure == .inputTooLong {
                await reply.yield("最初。" + String(repeating: "未", count: 2001))
            } else {
                await reply.finish(throwing: failure)
            }
            do { _ = try await run.value; XCTFail("Expected generation failure") }
            catch { XCTAssertEqual(error as? ConversationServiceError, failure) }
            XCTAssertEqual(synthesized, ["最初。"], "A failed generation cannot finalize its unfinished tail")
        }
    }
    func testGenerationFailureStopsPlaybackWhileSentenceQueueIsFull() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let stopped = expectation(description: "Generation failure ends playback without draining queued audio")
        var received: ConversationServiceError?
        let run = Task {
            do { _ = try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }); XCTFail("Expected failure") }
            catch { received = error as? ConversationServiceError }
            stopped.fulfill()
        }
        await reply.waitUntilRequested()
        await reply.yield("一文目。二文目。三文目。四文目。五文目。六文目。七文目。")
        await player.waitForCalls(1)
        await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
        await fulfillment(of: [stopped], timeout: 1)
        let stoppedBeforeCleanup = player.stops
        let failureBeforeCleanup = received
        await sut.cancelAndWait()
        await run.value
        XCTAssertGreaterThan(stoppedBeforeCleanup, 0)
        XCTAssertEqual(failureBeforeCleanup, .modelGenerationFailed)
        XCTAssertEqual(player.played.count, 1)
    }
    func testUnstableReplyWaitsForFinalAndMemoryKeepsOriginal() async throws {
        let reply = ControlledReply(stablePrefix: false)
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let updates = PlaybackUpdates()
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
        await reply.waitUntilRequested(); await reply.yield("仮の文。続き")
        await updates.waitForCaption("仮の文。続き")
        XCTAssertTrue(player.played.isEmpty)
        await reply.yield("確定。最後。"); await reply.finish()
        await player.waitForCalls(1); player.complete(0)
        await player.waitForCalls(2); player.complete(1)
        let result = try await run.value
        XCTAssertEqual(result, "確定。最後。")

        let store = InMemoryConversationMemoryStore()
        let claude = makeClaudeService(
            StubSessionFactory(scripts: [ScriptedSessionClient(chunks: ["iPhoneです。", "Bluetoothです。"])]), store: store)
        let immediate = SupertonicSentenceSpeaker(player: TestPCMPlayer(), prepare: {}, normalize: { try await JapanesePronunciationService.shared.normalize($0) }, voice: { .f1 }, synthesize: { text, _ in
            XCTAssertFalse(text.contains("iPhone")); XCTAssertFalse(text.contains("Bluetooth"))
            return SpeechPCM(samples: [1], sampleRate: 24_000)
        })
        let actual = ReplyPlaybackCoordinator(reply: claude, speaker: immediate)
        let original = try await actual.run(prompt: "説明して", trace: nil, onUpdate: { _ in })
        let saved = await store.load()
        XCTAssertEqual(original, "iPhoneです。Bluetoothです。")
        XCTAssertEqual(saved?.turns.last?.response, original)
    }
    func testNewestSnapshotsRetainAllSentencesWhilePlaybackIsBlocked() async throws {
        let reply = ControlledReply()
        let player = ControlledPCMPlayer()
        let speaker = SupertonicSentenceSpeaker(player: player, prepare: {}, normalize: { $0 }, voice: { .f1 }, synthesize: { _, _ in SpeechPCM(samples: [1], sampleRate: 24_000) })
        var spoken: [String] = []
        speaker.onInput = { original, _ in spoken.append(original) }
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker)
        let updates = PlaybackUpdates()
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
        await reply.waitUntilRequested()
        let sentences = (1...8).map { "文\($0)。" }
        await reply.yield(sentences.prefix(6).joined())
        await player.waitForCalls(1)
        let final = sentences.joined()
        for index in final.indices where String(final[...index]).count > sentences.prefix(6).joined().count {
            await reply.yield(String(final[...index]))
        }
        await reply.finish()
        await updates.waitForCaption(final)
        for index in sentences.indices {
            await player.waitForCalls(index + 1)
            player.complete(index)
        }
        let result = try await run.value
        XCTAssertEqual(result, final)
        XCTAssertEqual(spoken, sentences)
        XCTAssertEqual(updates.starts, [.full])
        XCTAssertEqual(updates.finishes, [.full])
        XCTAssertEqual(updates.sentenceStarts, Array(sentences.indices))
        XCTAssertEqual(updates.sentenceFinishes, Array(sentences.indices))
    }
    func testOldTraceDecodesWithoutSentenceOrdinal() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","point":"speechStarted","at":1,"part":"first"}"#.utf8)
        let event = try JSONDecoder().decode(ReplyTraceEvent.self, from: data)
        XCTAssertNil(event.sentenceOrdinal)
    }
}

/// Only the external synthesis boundary is controlled; parsing, transport,
/// ownership, validation and playback selection are the real product pipeline.
private actor PreparationSynthesisProbe {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation?
    let gate: ConversationTestGate?
    let failFirst: Bool
    private(set) var inputs: [String] = []
    private var active = 0
    private(set) var maximumConcurrent = 0

    init(started: XCTestExpectation, cancelled: XCTestExpectation? = nil,
         gate: ConversationTestGate? = nil, failFirst: Bool = false) {
        self.started = started; self.cancelled = cancelled; self.gate = gate; self.failFirst = failFirst
    }

    func make(_ text: String, voice: SpeechVoicePreset) async throws -> SpeechPCM {
        let index = inputs.count
        inputs.append(text)
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        if index == 0 {
            started.fulfill()
            let cancellation = cancelled
            await withTaskCancellationHandler {
                await gate?.wait()
            } onCancel: { cancellation?.fulfill() }
            try Task.checkCancellation()
            if failFirst { throw SupertonicError.inferenceFailed }
        }
        return SpeechPCM(samples: [Float(index + 1)], sampleRate: 24_000)
    }
}
