import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class FailureGuidanceTests: XCTestCase {
    private enum Origin: CaseIterable { case voice, typed, preflight }
    private enum Event: CaseIterable { case toggle, inactive, interruption, route, shutdown }

    private func perform(_ event: Event, on harness: ConversationHarness) async {
        switch event {
        case .toggle: await harness.sut.toggleListening()
        case .inactive: await harness.sut.sceneBecameInactive()
        case .interruption: harness.audio.emit(.interruptionBegan)
        case .route: harness.audio.emit(.routeChanged)
        case .shutdown: await harness.sut.shutdown()
        }
    }

    /// Old silent failures are terminal too, so RED need not wait a whole timeout for absent speech.
    private func guidanceStarted(_ harness: ConversationHarness, text: String) async -> Bool {
        await harness.waitUntil {
            let texts = await harness.speaker.texts
            if texts.contains(text) { return true }
            if case .failed = harness.sut.viewState.phase { return true }
            return harness.sut.viewState.phase == .paused && harness.sut.viewState.memoryPresentation.blocksConversation
        }
        let texts = await harness.speaker.texts
        return texts.contains(text)
    }

    private func completeSpeech(_ harness: ConversationHarness) async {
        let count = await harness.speaker.texts.count
        for index in 0..<count {
            await harness.speaker.yield(.started, run: index)
            await harness.speaker.yield(.finished, run: index)
            await harness.speaker.finish(run: index)
        }
    }

    /// 返事の通信失敗は「つながらない」、事前確認で Hermes が使えないときは「設定を確認して」を話す。
    private func guidance(for origin: Origin) -> String {
        origin == .preflight ? ConversationFailureGuidance.configuration : ConversationFailureGuidance.unreachable
    }

    private func beginFailure(_ origin: Origin, memory: (any ConversationMemoryManaging)? = nil,
                              speechStartGate: ConversationTestGate? = nil,
                              speakerAutomaticallyFinishes: Bool = false) async -> (ConversationHarness, Task<Void, Never>) {
        let harness = ConversationHarness(memory: memory, microphoneAllowed: origin != .typed,
            modelAvailabilityResult: origin == .preflight ? .hermesUnauthorized : .available,
            replySnapshots: nil, speakerAutomaticallyFinishes: speakerAutomaticallyFinishes)
        await harness.speaker.setSpeechStartGate(speechStartGate)
        if origin == .preflight { return (harness, Task { await harness.sut.startConversation() }) }
        if origin == .voice { await harness.sut.startConversation() }
        let turn = Task {
            if origin == .voice { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
            else { await harness.sut.submitTypedText("質問") }
        }
        let requested = await harness.waitUntil { await harness.reply.prompts.count == 1 }
        XCTAssertTrue(requested)
        await harness.reply.fail(.modelUnreachable)
        return (harness, turn)
    }

    func testLifecycleEventsWhileGuidanceStartsNeverStartSpeechLate() async {
        for origin in Origin.allCases {
            for event in Event.allCases {
                let gate = ConversationTestGate()
                let (harness, turn) = await beginFailure(origin, speechStartGate: gate,
                    speakerAutomaticallyFinishes: true)
                let entered = await harness.waitUntil { await harness.speaker.speakStartCount == 1 }
                let stops = await harness.speaker.stopCompletedCount
                let activations = await harness.audio.activateCount
                let action = Task { await self.perform(event, on: harness) }
                let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
                let stopped = await harness.waitUntil { await harness.speaker.stopCompletedCount > stops }
                // stop はまだ登録されていない読み上げを見つけられない。開始を解放するのは stop 完了の後。
                await gate.open()
                await action.value
                await turn.value
                let deactivated = await harness.waitUntil { await harness.audio.deactivateCount == 1 }

                let texts = await harness.speaker.texts
                let afterActivations = await harness.audio.activateCount
                let deactivations = await harness.audio.deactivateCount
                let active = await harness.audio.isActive
                XCTAssertTrue(entered, "\(origin), \(event)")
                XCTAssertTrue(paused, "\(origin), \(event)")
                XCTAssertTrue(stopped, "\(origin), \(event)")
                XCTAssertTrue(texts.isEmpty, "speech must not start after stop: \(origin), \(event)")
                XCTAssertEqual(afterActivations, activations)
                XCTAssertTrue(deactivated)
                XCTAssertEqual(deactivations, 1)
                XCTAssertFalse(active)
                XCTAssertFalse(harness.sut.viewState.isSpeakingFailureGuidance)
                XCTAssertNil(harness.sut.viewState.errorMessage)
                XCTAssertEqual(harness.sut.viewState.phase, .paused)
                if event != .shutdown { await harness.sut.shutdown() }
            }
        }
    }

    func testTypedReplacementWhileGuidanceStartsPreventsOldSpeech() async {
        let gate = ConversationTestGate()
        let (harness, turn) = await beginFailure(.voice, speechStartGate: gate,
            speakerAutomaticallyFinishes: true)
        let entered = await harness.waitUntil { await harness.speaker.speakStartCount == 1 }
        let stops = await harness.speaker.stopCompletedCount
        XCTAssertTrue(harness.sut.viewState.allowsTypedSubmission)
        let replacement = Task { await harness.sut.submitTypedText("今日は何日？") }
        let stopped = await harness.waitUntil { await harness.speaker.stopCompletedCount > stops }
        await gate.open()
        let requested = await harness.waitUntil { await harness.reply.prompts.count == 2 }
        XCTAssertTrue(entered)
        XCTAssertTrue(stopped)
        XCTAssertTrue(requested)
        guard requested else {
            await harness.sut.shutdown()
            await replacement.value
            await turn.value
            return
        }
        await harness.reply.yield("新しい返答", run: 1)
        await harness.reply.finish(run: 1)
        await replacement.value
        await turn.value

        let texts = await harness.speaker.texts, prompts = await harness.reply.prompts
        let activations = await harness.audio.activateCount, deactivations = await harness.audio.deactivateCount
        XCTAssertEqual(texts, ["新しい返答"], "the superseded failure must never start speaking")
        XCTAssertEqual(prompts.filter { $0 == "今日は何日？" }, ["今日は何日？"])
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(deactivations, 2)
        assertOrder(harness.calls.values, [.deactivateAudio, .activateAudio, .deactivateAudio])
        XCTAssertNil(harness.sut.viewState.errorMessage)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }

    func testLifecycleEventsDuringGuidanceTearDownOnce() async {
        for origin in Origin.allCases {
            for event in Event.allCases {
                let (harness, turn) = await beginFailure(origin)
                let started = await guidanceStarted(harness, text: guidance(for: origin))
                XCTAssertTrue(started, "\(origin), \(event)")
                XCTAssertTrue(harness.sut.viewState.isSpeakingFailureGuidance)
                let activations = await harness.audio.activateCount
                await perform(event, on: harness)
                let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
                await completeSpeech(harness)
                await turn.value

                let afterActivations = await harness.audio.activateCount, deactivations = await harness.audio.deactivateCount
                let texts = await harness.speaker.texts
                XCTAssertTrue(paused, "\(origin), \(event)")
                XCTAssertEqual(afterActivations, activations)
                XCTAssertEqual(deactivations, 1)
                XCTAssertEqual(texts, [guidance(for: origin)])
                XCTAssertNil(harness.sut.viewState.errorMessage)
                XCTAssertFalse(harness.sut.viewState.isSpeakingFailureGuidance)
                if event == .shutdown {
                    await harness.sut.startConversation()
                    let afterRestart = await harness.audio.activateCount
                    XCTAssertEqual(afterRestart, activations, "shutdown cannot start again")
                } else { await harness.sut.shutdown() }
            }
        }
    }

    func testLifecycleEventsWhileGuidancePreparesAudioNeverActivateLate() async {
        for stage in ["availability", "memory", "activate"] {
            for event in Event.allCases {
                let gate = ConversationTestGate()
                // Availability failure exits before memory. The memory gate therefore uses a restore failure.
                let memory = FakeConversationMemoryManager(state: stage == "memory" ? .restoreFailed(.unavailable) : .ready,
                    prepareGate: stage == "memory" ? gate : nil)
                let harness = ConversationHarness(memory: memory,
                    modelAvailabilityResult: stage == "memory" ? .available : .hermesUnauthorized,
                    availabilityGate: stage == "availability" ? gate : nil,
                    audioActivateGate: stage == "activate" ? gate : nil)
                let startup = Task { await harness.sut.startConversation() }
                await harness.waitUntil {
                    let count: Int
                    if stage == "availability" { count = await harness.modelAvailability.checkCount }
                    else if stage == "memory" { count = await memory.prepareCount }
                    else { count = await harness.audio.activateCount }
                    if count == 1 { return true }
                    if case .failed = harness.sut.viewState.phase { return true }
                    return false
                }
                let entryCount: Int
                if stage == "availability" { entryCount = await harness.modelAvailability.checkCount }
                else if stage == "memory" { entryCount = await memory.prepareCount }
                else { entryCount = await harness.audio.activateCount }
                let later = Task { await self.perform(event, on: harness) }
                let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
                await gate.open()
                await startup.value
                await later.value
                // interruption / route の一時停止は audio event の consumer で走り later.value が待たないので、後始末（deactivate 1 回）を有限時間で待つ。
                await harness.waitUntil { await harness.audio.deactivateCount == 1 }

                let texts = await harness.speaker.texts, activates = await harness.audio.activateCount
                let deactivates = await harness.audio.deactivateCount, starts = await harness.recognizer.startCount
                let active = await harness.audio.isActive
                XCTAssertEqual(entryCount, 1, "\(stage), \(event)")
                XCTAssertTrue(paused, "\(stage), \(event)")
                XCTAssertEqual(texts, [])
                XCTAssertEqual(activates, stage == "activate" ? 1 : 0)
                // availability / memory の gate 中はまだ失敗の操作が無く、通常の一時停止が audio を 1 回解除する。
                // activate の gate 中は失敗の操作が所有していて、試みた有効化を 1 回解除する。どちらも 1 回だけ。
                XCTAssertEqual(deactivates, 1, "\(stage), \(event)")
                XCTAssertEqual(starts, 0)
                XCTAssertFalse(active)
                XCTAssertEqual(harness.sut.viewState.phase, .paused)
                XCTAssertNil(harness.sut.viewState.errorMessage)
                if event != .shutdown { await harness.sut.shutdown() }
            }
        }
    }

    func testNewConversationAndForgetDuringGuidanceStopSpeakerWithoutFailure() async {
        for forget in [false, true] {
            let memory = FakeConversationMemoryManager()
            let (harness, turn) = await beginFailure(.voice, memory: memory)
            let ready = await harness.waitUntil { harness.sut.viewState.memoryState == .ready }
            let started = await guidanceStarted(harness, text: ConversationFailureGuidance.unreachable)
            XCTAssertTrue(ready)
            XCTAssertTrue(started)
            let beforeStops = await harness.speaker.stopCount
            let action = Task {
                if forget { await harness.sut.forgetConversation() }
                else { await harness.sut.startNewConversation() }
            }
            let stopped = await harness.waitUntil { await harness.speaker.stopCount > beforeStops }
            XCTAssertTrue(stopped)
            await completeSpeech(harness)
            await action.value
            await turn.value
            let texts = await harness.speaker.texts, stops = await harness.speaker.stopCount
            let forgets = await memory.forgets
            XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable])
            XCTAssertGreaterThanOrEqual(stops, 1)
            XCTAssertNil(harness.sut.viewState.errorMessage)
            XCTAssertEqual(forgets, forget ? 1 : 0)
            await harness.sut.shutdown()
        }
    }

    func testTypedSubmissionDuringGuidanceReplacesItWithoutStaleFailure() async {
        let (harness, turn) = await beginFailure(.voice)
        let started = await guidanceStarted(harness, text: ConversationFailureGuidance.unreachable)
        XCTAssertTrue(started)
        XCTAssertTrue(harness.sut.viewState.allowsTypedSubmission)
        let replacement = Task { await harness.sut.submitTypedText("今日は何日？") }
        let requested = await harness.waitUntil { await harness.reply.prompts.count == 2 }
        XCTAssertTrue(requested)
        await harness.reply.yield("わかったよ", run: 1)
        await harness.reply.finish(run: 1)
        let spoke = await harness.waitUntil { await harness.speaker.texts.count == 2 }
        XCTAssertTrue(spoke)
        await completeSpeech(harness)
        await replacement.value
        await turn.value
        let texts = await harness.speaker.texts, prompts = await harness.reply.prompts
        let activates = await harness.audio.activateCount, deactivates = await harness.audio.deactivateCount
        XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable, "わかったよ"])
        XCTAssertEqual(prompts.filter { $0 == "今日は何日？" }, ["今日は何日？"])
        XCTAssertEqual(activates, 2)
        XCTAssertEqual(deactivates, 2)
        assertOrder(harness.calls.values, [.deactivateAudio, .activateAudio, .deactivateAudio])
        XCTAssertNil(harness.sut.viewState.errorMessage)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }

    func testLaterLifecycleActionDuringTypedReplacementStopWins() async {
        for event in [Event.toggle, .inactive, .route] {
            let gate = ConversationTestGate()
            let (harness, turn) = await beginFailure(.voice)
            let started = await guidanceStarted(harness, text: ConversationFailureGuidance.unreachable)
            // 最初の返答失敗の後始末も speaker.stop を呼ぶので、gate は案内が始まってから付ける。
            await harness.speaker.setStopGate(gate)
            let beforeStops = await harness.speaker.stopCount, beforeActivations = await harness.audio.activateCount
            let replacement = Task { await harness.sut.submitTypedText("今日は何日？") }
            let entered = await harness.waitUntil { await harness.speaker.stopCount > beforeStops }
            let later = Task { await self.perform(event, on: harness) }
            let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }
            await gate.open()
            await completeSpeech(harness)
            await replacement.value
            await later.value
            await turn.value
            let prompts = await harness.reply.prompts, activates = await harness.audio.activateCount
            let deactivates = await harness.audio.deactivateCount
            XCTAssertTrue(started)
            XCTAssertTrue(entered)
            XCTAssertTrue(paused)
            XCTAssertFalse(prompts.contains("今日は何日？"))
            XCTAssertEqual(activates, beforeActivations)
            XCTAssertEqual(deactivates, 1)
            XCTAssertNil(harness.sut.viewState.errorMessage)
            XCTAssertEqual(harness.sut.viewState.phase, .paused)
            await harness.sut.shutdown()
        }
    }

    func testCaptureFailureWithPendingSegmentationDoesNotStartNewTurnDuringGuidance() async {
        let harness = ConversationHarness(speakerAutomaticallyFinishes: false)
        await harness.sut.startConversation()
        await harness.emit(.provisional("あのね"), at: 0)
        await harness.recognizer.fail(.speechCaptureFailed)
        let started = await guidanceStarted(harness, text: ConversationFailureGuidance.listening)
        XCTAssertTrue(started)
        harness.now.set(5)
        await harness.sut.flushSegmentation(at: 5)
        await completeSpeech(harness)
        await harness.waitUntil { harness.sut.viewState.phase == .failed(.speechCaptureFailed) }
        let calls = harness.calls.values, texts = await harness.speaker.texts
        let starts = await harness.recognizer.startCount
        XCTAssertFalse(calls.contains { if case .generateReply = $0 { true } else { false } })
        XCTAssertEqual(texts, [ConversationFailureGuidance.listening])
        XCTAssertEqual(starts, 1)
        await harness.sut.shutdown()
    }

    func testUnsavedWarningDoesNotSpeak() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.completeUnengagedTurn("ねこ、質問", at: 0)
        await memory.publish(.unsaved)
        let unsaved = await harness.waitUntil { harness.sut.viewState.memoryState == .unsaved }
        let texts = await harness.speaker.texts
        XCTAssertTrue(unsaved)
        XCTAssertFalse(texts.contains(ConversationFailureGuidance.memory))
        XCTAssertFalse(texts.contains(ConversationFailureGuidance.generationFailed))
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        await harness.sut.shutdown()
    }

    func testGuidanceIsNotRecordedOrTraced() async {
        let playback = PlaybackIntegrationHarness(service: UnreachableReply())
        let turn = Task { await playback.viewModel.submitTypedText("質問") }
        let reached = await playback.infrastructure.waitUntil {
            let texts = await playback.speaker.texts
            if !texts.isEmpty { return true }
            if case .failed = playback.viewModel.viewState.phase { return true }
            return false
        }
        let texts = await playback.speaker.texts
        XCTAssertTrue(reached)
        XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable])
        await playback.speaker.complete()
        await turn.value
        XCTAssertEqual(playback.traces.events.filter { $0.point == .speechStarted || $0.point == .speechEnqueued }.count, 0)
        XCTAssertEqual(playback.traces.events.filter { $0.point == .request }.count, 1)
        XCTAssertEqual(playback.viewModel.viewState.phase, .failed(.modelUnreachable))
        await playback.viewModel.shutdown()
    }

    func testOnlyFailureGuidanceAllowsTypedReplacementDuringSpeech() {
        var state = ConversationViewState.speaking(caption: "返事")
        XCTAssertFalse(state.allowsTypedSubmission)
        state.isSpeakingFailureGuidance = true
        XCTAssertTrue(state.allowsTypedSubmission)
        state.inactivity = .sleeping
        XCTAssertFalse(state.allowsTypedSubmission)
        state.inactivity = .awake
        state.memoryState = .restoreFailed(.unavailable)
        XCTAssertFalse(state.allowsTypedSubmission)
    }

    private func assertOrder(_ calls: [ConversationTestCall], _ expected: [ConversationTestCall],
                             file: StaticString = #filePath, line: UInt = #line) {
        var previous = -1
        for call in expected {
            guard let index = calls.indices.first(where: { $0 > previous && calls[$0] == call }) else {
                XCTFail("Missing or out-of-order call: \(call)", file: file, line: line)
                return
            }
            previous = index
        }
    }


    func testReplyFailureAfterPartialTextStillSpeaksGuidance() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        let requested = await harness.waitUntil { await harness.reply.prompts.count == 1 }
        XCTAssertTrue(requested)
        await harness.reply.yield("今日は")
        let partial = await harness.waitUntil { harness.sut.viewState.caption == "今日は" }
        XCTAssertTrue(partial)
        await harness.reply.fail(.modelGenerationFailed)
        await turn.value

        let texts = await harness.speaker.texts
        XCTAssertEqual(texts.last, ConversationFailureGuidance.generationFailed)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        await harness.sut.shutdown()
    }

    func testTypedReplyFailureSpeaksGuidanceAndDeactivatesOnce() async {
        let (harness, turn) = await beginFailure(.typed)
        let started = await guidanceStarted(harness, text: ConversationFailureGuidance.unreachable)
        XCTAssertTrue(started)
        await completeSpeech(harness)
        await turn.value
        let texts = await harness.speaker.texts, active = await harness.audio.isActive
        let deactivations = await harness.audio.deactivateCount, permissions = await harness.microphone.requestCount
        XCTAssertEqual(texts, [ConversationFailureGuidance.unreachable])
        XCTAssertFalse(active)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnreachable))
        await harness.sut.shutdown()
    }

    func testSpeechFailuresAndCancellationDoNotSpeakGuidance() async {
        let speech = ConversationHarness(speakerError: .speechSynthesisFailed)
        await speech.completeUnengagedTurn("ねこ、質問", at: 0)
        let speechTexts = await speech.speaker.texts
        XCTAssertFalse(speechTexts.contains(ConversationFailureGuidance.generationFailed))
        XCTAssertEqual(speech.sut.viewState.phase, .failed(.speechSynthesisFailed))
        await speech.sut.shutdown()

        let cancelled = ConversationHarness(replySnapshots: nil)
        await cancelled.sut.startConversation()
        let turn = Task { await cancelled.emitCompletedUtterance("ねこ、質問", at: 0) }
        let requested = await cancelled.waitUntil { await cancelled.reply.prompts.count == 1 }
        XCTAssertTrue(requested)
        await cancelled.reply.fail(.cancelled)
        await turn.value
        let texts = await cancelled.speaker.texts
        XCTAssertEqual(texts, [])
        await cancelled.sut.shutdown()
    }

    func testGuidanceSpeechFailureOrIncompleteStreamStillPublishesOriginalError() async {
        for fails in [true, false] {
            let (harness, turn) = await beginFailure(.voice)
            let started = await guidanceStarted(harness, text: ConversationFailureGuidance.unreachable)
            XCTAssertTrue(started)
            if fails { await harness.speaker.fail(run: 0, with: .speechSynthesisFailed) }
            else { await harness.speaker.finish(run: 0) } // No .finished event.
            await turn.value
            XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnreachable))
            assertOrder(harness.calls.values, [.stopSpeaker, .deactivateAudio])
            await harness.sut.retryRecovery()
            let next = Task { await harness.emitCompletedUtterance("ねこ、もう一度", at: 4) }
            let requested = await harness.waitUntil { await harness.reply.prompts.count == 2 }
            XCTAssertTrue(requested)
            await harness.reply.yield("また話せるよ。", run: 1)
            await harness.reply.finish(run: 1)
            let spoke = await harness.waitUntil { await harness.speaker.texts.count == 2 }
            XCTAssertTrue(spoke)
            await completeSpeech(harness)
            await next.value
            let texts = await harness.speaker.texts
            XCTAssertEqual(texts.last, "また話せるよ。")
            await harness.sut.shutdown()
        }
    }

    func testGuidanceSpeakerStartFailureStillPublishesOriginalError() async {
        let harness = ConversationHarness(modelAvailabilityResult: .hermesUnauthorized, speakerError: .speechSynthesisFailed)
        await harness.sut.startConversation()
        let prepares = await harness.speaker.prepareCount, activates = await harness.audio.activateCount
        let deactivates = await harness.audio.deactivateCount
        XCTAssertEqual(prepares, 1)
        XCTAssertEqual(activates, 1)
        XCTAssertEqual(deactivates, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnavailable(.hermesUnauthorized)))
        await harness.sut.shutdown()
    }

    func testPreflightMatrix() async {
        for voice in [true, false] {
            for memoryFails in [false, true] {
                for speechFails in [false, true] {
                    let memory = FakeConversationMemoryManager(state: memoryFails ? .restoreFailed(.unavailable) : .ready)
                    let harness = ConversationHarness(memory: memory, microphoneAllowed: voice,
                        modelAvailabilityResult: memoryFails ? .available : .hermesUnauthorized,
                        speakerAutomaticallyFinishes: !speechFails)
                    let turn = Task {
                        if voice { await harness.sut.startConversation() }
                        else { await harness.sut.submitTypedText("質問") }
                    }
                    let guidance = memoryFails ? ConversationFailureGuidance.memory : ConversationFailureGuidance.configuration
                    let started = await guidanceStarted(harness, text: guidance)
                    XCTAssertTrue(started, "voice=\(voice), memory=\(memoryFails), speech=\(speechFails)")
                    if speechFails { await harness.speaker.fail(run: 0, with: .speechSynthesisFailed) }
                    await turn.value

                    let texts = await harness.speaker.texts, active = await harness.audio.isActive
                    let deactivations = await harness.audio.deactivateCount, prompts = await harness.reply.prompts
                    XCTAssertEqual(texts, [guidance])
                    XCTAssertFalse(active)
                    XCTAssertEqual(deactivations, 1)
                    XCTAssertEqual(prompts, [], "a failed preflight never asks for a reply")
                    XCTAssertFalse(harness.calls.values.contains(.prepareRecognizer))
                    if !voice { XCTAssertFalse(harness.calls.values.contains(.requestMicrophone)) }
                    if memoryFails {
                        XCTAssertEqual(harness.sut.viewState.phase, .paused)
                        XCTAssertEqual(harness.sut.viewState.memoryState, .restoreFailed(.unavailable))
                        XCTAssertNil(harness.sut.viewState.errorMessage)
                        await harness.sut.retryMemoryOperation()
                        let restored = await memory.memoryState()
                        XCTAssertEqual(restored, .ready)
                    } else {
                        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnavailable(.hermesUnauthorized)))
                        assertOrder(harness.calls.values, [.checkAvailability, .prepareSpeaker, .activateAudio,
                                                          .speak(guidance), .stopSpeaker, .deactivateAudio])
                    }
                    await harness.sut.shutdown()
                }
            }
        }
    }

    func testGuidanceAudioPreparationFailureSkipsSpeech() async {
        for speakerFails in [true, false] {
            let harness = ConversationHarness(modelAvailabilityResult: .hermesUnauthorized,
                speakerPrepareError: speakerFails ? .speechVoiceUnavailable : nil,
                audioActivateError: speakerFails ? nil : .audioSessionFailed)
            await harness.sut.startConversation()
            let prepares = await harness.speaker.prepareCount, activates = await harness.audio.activateCount
            let deactivates = await harness.audio.deactivateCount, texts = await harness.speaker.texts
            XCTAssertEqual(prepares, 1)
            XCTAssertEqual(activates, speakerFails ? 0 : 1)
            XCTAssertEqual(deactivates, speakerFails ? 0 : 1)
            XCTAssertEqual(texts, [])
            XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelUnavailable(.hermesUnauthorized)))
            await harness.sut.shutdown()
        }
    }

    func testMicrophoneDenialDoesNotSpeakOrPrepareAudio() async {
        let harness = ConversationHarness(microphoneAllowed: false)
        await harness.sut.startConversation()
        let texts = await harness.speaker.texts, prepares = await harness.speaker.prepareCount
        let activates = await harness.audio.activateCount
        XCTAssertEqual(texts, [])
        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(activates, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.microphoneDenied))
        await harness.sut.shutdown()
    }

    func testOriginalSpeakerAndAudioFailuresAreNotRetried() async {
        for speakerFails in [true, false] {
            let harness = ConversationHarness(speakerPrepareError: speakerFails ? .speechVoiceUnavailable : nil,
                audioActivateError: speakerFails ? nil : .audioSessionFailed)
            await harness.sut.startConversation()
            let prepares = await harness.speaker.prepareCount, activates = await harness.audio.activateCount
            let deactivates = await harness.audio.deactivateCount, texts = await harness.speaker.texts
            XCTAssertEqual(prepares, 1)
            XCTAssertEqual(activates, speakerFails ? 0 : 1)
            XCTAssertEqual(deactivates, speakerFails ? 0 : 1)
            XCTAssertEqual(texts, [])
            XCTAssertEqual(harness.sut.viewState.phase, .failed(speakerFails ? .speechVoiceUnavailable : .audioSessionFailed))
            await harness.sut.shutdown()
        }
    }
}
