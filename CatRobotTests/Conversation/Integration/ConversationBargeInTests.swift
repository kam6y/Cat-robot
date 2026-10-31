import XCTest
@testable import CatRobot

@MainActor
final class ConversationBargeInTests: XCTestCase {
    func testTypedReplacementBeforeClosingStartsStillStopsTheOldCapture() async {
        let harness = PlaybackIntegrationHarness()
        await harness.viewModel.startConversation()
        harness.infrastructure.now.set(0)
        await harness.recognizer.emit(.finalized("猫ちゃん、古い音声"))
        await harness.waitForState { $0.provisionalTranscript == "猫ちゃん、古い音声" }
        harness.infrastructure.now.set(1.2)

        // Both intents are queued before yielding the main actor. The first schedules
        // closing; typed submission supersedes its generation before that child runs.
        let closing = Task { @MainActor in await harness.viewModel.flushSegmentation(at: 1.2) }
        let typed = Task { @MainActor in await harness.viewModel.submitTypedText("文字の質問") }
        await harness.reply.waitUntilRequested()
        let prompts = await harness.reply.prompts
        let stillCapturing = await harness.recognizer.isRunning
        let stops = await harness.recognizer.stopCount
        XCTAssertEqual(prompts, ["文字の質問"])
        XCTAssertFalse(stillCapturing, "The displaced capture must be stopped before the typed reply starts")
        XCTAssertEqual(stops, 1, "A closing task still owns capture teardown after typed replacement")

        await harness.reply.yield("文字への返答。")
        await harness.reply.finish()
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.complete()
        await typed.value
        await closing.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 2)
        await harness.viewModel.shutdown()
    }

    func testPausedTypedReplyUsesPlaybackOnlyAudioWithoutStartingTheMicrophone() async {
        for microphoneAllowed in [false, true] {
            let infrastructure = ConversationHarness(microphoneAllowed: microphoneAllowed)
            let harness = PlaybackIntegrationHarness(infrastructure: infrastructure)
            await harness.recognizer.setConcurrentPlaybackSupported(true)
            let run = Task { await harness.viewModel.submitTypedText("文字だけで質問") }
            await harness.reply.waitUntilRequested()
            await harness.reply.yield("文字入力への返答。")
            await harness.reply.finish()
            await harness.speaker.waitUntilCallCount(1)
            let outputOnly = await infrastructure.audio.playbackOnlyActivateCount
            let captures = await harness.recognizer.startCount
            XCTAssertEqual(outputOnly, 1, "Paused typed replies must request an output-only session even when microphone permission exists")
            XCTAssertEqual(captures, 0)
            await harness.speaker.complete()
            await run.value
            XCTAssertEqual(harness.viewModel.viewState.phase, .paused)
            await harness.viewModel.shutdown()
        }
    }

    func testTypedReplyReplacingActiveListeningKeepsVoiceSessionForResume() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        await harness.viewModel.startConversation()
        let run = Task { await harness.viewModel.submitTypedText("文字でも質問") }
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("聞き取りへ戻るね。")
        await harness.reply.finish()
        await harness.speaker.waitUntilCallCount(1)
        let outputOnly = await harness.infrastructure.audio.playbackOnlyActivateCount
        XCTAssertEqual(outputOnly, 0)
        await harness.speaker.complete()
        await run.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        let running = await harness.recognizer.isRunning
        XCTAssertTrue(running)
        await harness.viewModel.shutdown()
    }

    func testEchoCancelledCaptureIsOpenDuringGenerationAndSurvivesNaturalPlayback() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await harness.beginVoiceTurn()
        await harness.reply.waitUntilRequested()
        let startsWhileGenerating = await harness.recognizer.startCount
        let runningWhileGenerating = await harness.recognizer.isRunning
        XCTAssertEqual(startsWhileGenerating, 2)
        XCTAssertTrue(runningWhileGenerating)
        XCTAssertEqual(harness.viewModel.viewState.phase, .thinking)
        await harness.reply.yield("返答です。")
        await harness.reply.finish()
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        await harness.waitForPhase(.speaking)
        let runningWhileSpeaking = await harness.recognizer.isRunning
        XCTAssertTrue(runningWhileSpeaking)
        await harness.speaker.complete()
        await run.value
        let startsAfterPlayback = await harness.recognizer.startCount
        XCTAssertEqual(startsAfterPlayback, 2, "Natural completion promotes the existing capture")
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        await harness.viewModel.shutdown()
    }

    func testFirstPartialInterruptsSpeechAndIsRetainedUntilTheFinalUtterance() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await harness.beginVoiceTurn()
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("古い返答。まだ続き")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        await harness.waitForPhase(.speaking)
        harness.infrastructure.now.set(20)
        await harness.recognizer.emit(.provisional("待って"))
        let interrupted = await harness.infrastructure.waitUntil {
            harness.viewModel.viewState.phase == .listening && harness.viewModel.viewState.provisionalTranscript == "待って"
        }
        XCTAssertTrue(interrupted, "The first recognized words must stop the reply before utterance finalization")
        guard interrupted else { await harness.viewModel.shutdown(); await run.value; return }
        XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
        XCTAssertTrue(harness.viewModel.hasPendingSpeech)
        await harness.recognizer.emit(.finalized("待って、明日の話をして"))
        let finalized = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == "待って、明日の話をして" }
        XCTAssertTrue(finalized)
        harness.infrastructure.now.set(21.2)
        let next = Task { await harness.viewModel.flushSegmentation(at: 21.2) }
        await harness.reply.waitUntilRequested(2)
        await harness.reply.yield("明日の話だね。")
        await harness.reply.finish()
        await harness.speaker.waitUntilCallCount(2)
        await harness.speaker.complete()
        await next.value
        await run.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        let spoken = await harness.speaker.texts
        XCTAssertEqual(spoken, ["古い返答。", "明日の話だね。"])
        await harness.viewModel.shutdown()
    }
    func testSpeechArrivingWhilePlaybackStopIsBlockedWaitsWithoutLosingWords() async {
        let gate = ConversationTestGate()
        let harness = PlaybackIntegrationHarness(speaker: ControlledSpeaker(stopGate: gate))
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await beginSpeaking(harness)
        harness.infrastructure.now.set(20)
        await harness.recognizer.emit(.provisional("待って"))
        await gate.waitUntilEntered()
        await harness.recognizer.emit(.finalized("待って、明日"))
        await harness.recognizer.emit(.finalized("の話をして"))
        let heard = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == "の話をして" }
        XCTAssertTrue(heard)
        harness.infrastructure.now.set(21.2)
        let next = Task { await harness.viewModel.flushSegmentation(at: 21.2) }
        let pending = await harness.infrastructure.waitUntil { harness.viewModel.hasPendingSpeech }
        XCTAssertTrue(pending)
        let before = await harness.reply.prompts
        XCTAssertEqual(before.count, 1, "The next model call must wait for the previous reply's teardown")
        let capturing = await harness.recognizer.isRunning
        XCTAssertTrue(capturing, "Capture must continue while the old reply is being stopped")
        await gate.open()
        await harness.reply.waitUntilRequested(2)
        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts.last, "待って、明日の話をして")
        await completeReply(harness, text: "明日のことだね。", count: 2)
        await next.value
        await run.value
        await harness.viewModel.shutdown()
    }

    func testRepeatedInterruptionsIgnoreOldGenerationAndPlaybackCallbacks() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        var tasks = [await beginSpeaking(harness)]
        for index in 0..<2 {
            let at = Double(20 + index * 10)
            harness.infrastructure.now.set(at)
            let correction = "訂正\(index + 1)を聞いて"
            await harness.recognizer.emit(.finalized(correction))
            let heard = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == correction }
            XCTAssertTrue(heard)
            harness.infrastructure.now.set(at + 1.2)
            tasks.append(Task { await harness.viewModel.flushSegmentation(at: at + 1.2) })
            await harness.reply.waitUntilRequested(index + 2)
            await harness.reply.yield("古い字幕が復活。", request: index)
            await harness.speaker.emit(.willSpeak(range: 0..<1), run: index)
            await harness.speaker.complete(run: index)
            XCTAssertFalse(harness.viewModel.viewState.caption.contains("古い字幕"))
            if index == 0 {
                await harness.reply.yield("二度目の返答。続き")
                await harness.speaker.waitUntilCallCount(2)
                await harness.speaker.emit(.started)
                await harness.waitForPhase(.speaking)
            }
        }
        await completeReply(harness, text: "最後の訂正だね。", count: 3)
        for task in tasks { await task.value }
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        let prompts = await harness.reply.prompts
        XCTAssertEqual(Array(prompts.suffix(2)), ["訂正1を聞いて", "訂正2を聞いて"])
        let receipts = await harness.reply.interruptions
        XCTAssertEqual(receipts.count, 2)
        XCTAssertNotEqual(receipts[0].id, receipts[1].id)
        await harness.viewModel.shutdown()
    }

    func testPauseDuringInterruptionTeardownNeverRestartsCapture() async {
        for reason in ["background", "route", "tap"] {
            let gate = ConversationTestGate()
            let harness = PlaybackIntegrationHarness(speaker: ControlledSpeaker(stopGate: gate))
            await harness.recognizer.setConcurrentPlaybackSupported(true)
            let run = await beginSpeaking(harness)
            await harness.recognizer.emit(.provisional("待って"))
            await gate.waitUntilEntered()
            let pause = Task {
                switch reason {
                case "background": await harness.viewModel.sceneBecameInactive()
                case "route": await harness.viewModel.handleAudioSessionEvent(.routeChanged)
                default: await harness.viewModel.toggleListening()
                }
            }
            let paused = await harness.infrastructure.waitUntil { harness.viewModel.viewState.phase == .paused }
            XCTAssertTrue(paused, reason)
            await harness.recognizer.emit(.finalized("遅れて届いた発話"))
            await gate.open()
            await pause.value
            await run.value
            let starts = await harness.recognizer.startCount
            let capturing = await harness.recognizer.isRunning
            XCTAssertEqual(starts, 2, reason)
            XCTAssertFalse(capturing, reason)
            XCTAssertEqual(harness.viewModel.viewState.phase, .paused, reason)
            XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed, reason)
            await harness.viewModel.shutdown()
        }
    }

    func testNoiseOnlyRecognitionDoesNotInterruptOrBecomePendingSpeech() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await beginSpeaking(harness)
        await harness.recognizer.emit(.provisional("  "))
        await harness.recognizer.emit(.finalized("…。"))
        // Enqueue a read behind the recognition callbacks rather than sleeping for a duration.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.viewModel.viewState.phase, .speaking)
        XCTAssertFalse(harness.viewModel.hasPendingSpeech)
        let stops = await harness.speaker.stopCount
        XCTAssertEqual(stops, 0)
        await harness.viewModel.shutdown()
        await run.value
    }

    func testWakeAcknowledgementCanBeInterruptedWithoutStartingAStaleReply() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await harness.beginVoiceTurn("猫ちゃん")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        harness.infrastructure.now.set(20)
        await harness.recognizer.emit(.finalized("明日の予定を教えて"))
        let heard = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == "明日の予定を教えて" }
        XCTAssertTrue(heard)
        harness.infrastructure.now.set(21.2)
        let next = Task { await harness.viewModel.flushSegmentation(at: 21.2) }
        await harness.reply.waitUntilRequested()
        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["明日の予定を教えて"])
        await completeReply(harness, text: "明日の予定だね。", count: 2)
        await next.value
        await run.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        await harness.viewModel.shutdown()
    }

    func testPlaybackFailureDuringDuplexCapturePreservesOriginalErrorAndCleansUpOnce() async {
        let gate = ConversationTestGate()
        let infrastructure = ConversationHarness(audioDeactivateGate: gate)
        let harness = PlaybackIntegrationHarness(infrastructure: infrastructure)
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await beginSpeaking(harness)
        await harness.speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
        await gate.waitUntilEntered()
        let duplicateCleanup = await infrastructure.waitUntil { await infrastructure.audio.deactivateCount > 1 }
        XCTAssertFalse(duplicateCleanup, "Closing the duplex recognition stream must not start a second failure cleanup")
        await gate.open()
        await run.value
        let failurePresented = await infrastructure.waitUntil { harness.viewModel.viewState.phase == .failed(.speechSynthesisFailed) }
        XCTAssertTrue(failurePresented, "The original playback error must survive normal capture teardown")
        let deactivations = await infrastructure.audio.deactivateCount
        XCTAssertEqual(deactivations, 1)
        await harness.viewModel.shutdown()
    }

    func testDuplexCaptureFailureStopsSpeechAndOffersRecovery() async {
        let harness = PlaybackIntegrationHarness()
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await beginSpeaking(harness)
        await harness.recognizer.fail(.speechCaptureFailed)
        let failed = await harness.infrastructure.waitUntil { harness.viewModel.viewState.phase == .failed(.speechCaptureFailed) }
        XCTAssertTrue(failed)
        await run.value
        let capturing = await harness.recognizer.isRunning
        let stopped = await harness.speaker.stopCount
        XCTAssertFalse(capturing)
        XCTAssertGreaterThan(stopped, 0)
        XCTAssertEqual(harness.viewModel.viewState.mouthPose, .closed)
        await harness.viewModel.shutdown()
    }

    func testAffirmativeDuringClarificationStillAnswersTheOriginalQuestion() async {
        let harness = PlaybackIntegrationHarness(infrastructure: ConversationHarness(classification: .ambiguous))
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await harness.beginVoiceTurn("明日の予定は？")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        harness.infrastructure.now.set(12)
        await harness.recognizer.emit(.finalized("うん"))
        let heard = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == "うん" }
        XCTAssertTrue(heard)
        harness.infrastructure.now.set(13.2)
        let next = Task { await harness.viewModel.flushSegmentation(at: 13.2) }
        await harness.reply.waitUntilRequested()
        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["明日の予定は？"], "The interrupted clarification must keep the question being confirmed")
        await completeReply(harness, text: "明日の予定だね。", count: 2)
        await next.value
        await run.value
        await harness.viewModel.shutdown()
    }

    func testNegativeDuringClarificationDismissesTheQuestionWithoutGeneratingAReply() async {
        let harness = PlaybackIntegrationHarness(infrastructure: ConversationHarness(classification: .ambiguous))
        await harness.recognizer.setConcurrentPlaybackSupported(true)
        let run = await harness.beginVoiceTurn("明日の予定は？")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        harness.infrastructure.now.set(12)
        await harness.recognizer.emit(.finalized("違う"))
        let heard = await harness.infrastructure.waitUntil { harness.viewModel.viewState.provisionalTranscript == "違う" }
        XCTAssertTrue(heard)
        harness.infrastructure.now.set(13.2)
        var finished = false
        let next = Task { await harness.viewModel.flushSegmentation(at: 13.2); finished = true }
        let settled = await harness.infrastructure.waitUntil {
            if finished { return true }
            return await !harness.reply.prompts.isEmpty
        }
        XCTAssertTrue(settled)
        let prompts = await harness.reply.prompts
        XCTAssertTrue(prompts.isEmpty)
        if !prompts.isEmpty { await completeReply(harness, text: "不要な返答。", count: 2) }
        await next.value
        await run.value
        XCTAssertEqual(harness.viewModel.viewState.phase, .listening)
        await harness.viewModel.shutdown()
    }

    private func beginSpeaking(_ harness: PlaybackIntegrationHarness) async -> Task<Void, Never> {
        let run = await harness.beginVoiceTurn()
        await harness.reply.waitUntilRequested()
        await harness.reply.yield("最初の返答。続き")
        await harness.speaker.waitUntilCallCount(1)
        await harness.speaker.emit(.started)
        await harness.waitForPhase(.speaking)
        return run
    }

    private func completeReply(_ harness: PlaybackIntegrationHarness, text: String, count: Int) async {
        await harness.reply.yield(text)
        await harness.reply.finish()
        await harness.speaker.waitUntilCallCount(count)
        await harness.speaker.complete()
    }

}
