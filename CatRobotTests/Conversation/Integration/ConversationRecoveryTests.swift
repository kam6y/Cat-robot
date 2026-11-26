import XCTest
@testable import CatRobot

@MainActor
final class ConversationRecoveryTests: XCTestCase {
    func testOperationOwnershipRejectsAnOlderCompletionAfterReplacement() {
        var ownership = ConversationOperationOwnership()
        let first = ownership.begin()
        let second = ownership.begin()

        XCTAssertFalse(ownership.finish(first))
        XCTAssertEqual(ownership.activeID, second)
        XCTAssertTrue(ownership.finish(second))
        XCTAssertNil(ownership.activeID)
    }

    func testEmptyFinalShowsInlineRecoveryWhileCaptureKeepsRunning() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()

        await harness.emit(.finalized(""))
        // An empty transcript already equals the harness's initial value;
        // wait for the actual recovery presentation before asserting or retrying.
        let didReceiveEmptyFinal = await harness.waitUntil { harness.sut.viewState.errorMessage != nil }
        XCTAssertTrue(didReceiveEmptyFinal)

        let startsBeforeRetry = await harness.recognizer.startCount
        let isRunning = await harness.recognizer.isRunning
        XCTAssertEqual(harness.sut.viewState.errorMessage, "うまく聞き取れませんでした")
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry, .showTypedInput])
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertEqual(startsBeforeRetry, 1)
        XCTAssertTrue(isRunning)

        await harness.sut.retryRecovery()

        let startsAfterRetry = await harness.recognizer.startCount
        XCTAssertNil(harness.sut.viewState.errorMessage)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertEqual(startsAfterRetry, 1)
    }

    func testPauseInactiveInterruptionAndRouteChangeAllStopWithoutAutoResume() async {
        enum Trigger {
            case pause
            case inactive
            case interruption
            case routeChange
        }

        for trigger in [Trigger.pause, .inactive, .interruption, .routeChange] {
            let harness = ConversationHarness()
            await harness.sut.startConversation()

            switch trigger {
            case .pause:
                await harness.sut.toggleListening()
            case .inactive:
                await harness.sut.sceneBecameInactive()
            case .interruption:
                await harness.sut.handleAudioSessionEvent(.interruptionBegan)
            case .routeChange:
                await harness.sut.handleAudioSessionEvent(.routeChanged)
            }

            await harness.sut.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))

            let startCount = await harness.recognizer.startCount
            let stopCount = await harness.recognizer.stopCount
            let speakerStopCount = await harness.speaker.stopCount
            let deactivateCount = await harness.audio.deactivateCount
            let teardownCount = await harness.teardownProbe.callCount
            XCTAssertEqual(harness.sut.viewState.phase, .paused)
            XCTAssertEqual(startCount, 1)
            XCTAssertEqual(stopCount, 1)
            XCTAssertEqual(speakerStopCount, 1)
            XCTAssertEqual(deactivateCount, 1)
            XCTAssertEqual(teardownCount, 0)
        }
    }

    func testExplicitResumeRunsFreshActivatePrepareStartPreflight() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.sut.handleAudioSessionEvent(.routeChanged)

        await harness.sut.toggleListening()

        let availabilityChecks = await harness.modelAvailability.checkCount
        let speakerPrepares = await harness.speaker.prepareCount
        let audioActivations = await harness.audio.activateCount
        let recognizerPrepares = await harness.recognizer.prepareCount
        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(availabilityChecks, 2)
        XCTAssertEqual(speakerPrepares, 2)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertEqual(recognizerPrepares, 2)
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        let calls = harness.calls.values
        let secondActivation = calls.indices.filter { calls[$0] == .activateAudio }[1]
        let secondPreparation = calls.indices.filter { calls[$0] == .prepareRecognizer }[1]
        let secondStart = calls.indices.filter { calls[$0] == .startRecognizer }[1]
        XCTAssertLessThan(secondActivation, secondPreparation)
        XCTAssertLessThan(secondPreparation, secondStart)
    }

    func testMicrophoneDeniedTypedTurnUsesOnlyTypedPreflightAndRetainsCaption() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            replySnapshots: ["こんにちは", "こんにちは、会えてうれしいよ"]
        )
        await harness.sut.startConversation()

        harness.sut.showTypedInput()
        harness.sut.updateTypedText("こんにちは")
        await harness.sut.submitTypedText("こんにちは")

        let permissionRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let replyPrewarms = await harness.reply.prewarmCount
        let replyPrompts = await harness.reply.prompts
        let speakerPrepares = await harness.speaker.prepareCount
        let spokenTexts = await harness.speaker.texts
        let audioActivations = await harness.audio.activateCount
        let audioIsActive = await harness.audio.isActive
        let recognizerPrepares = await harness.recognizer.prepareCount
        let recognizerStarts = await harness.recognizer.startCount

        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(availabilityChecks, 1)
        XCTAssertEqual(replyPrewarms, 1)
        XCTAssertEqual(replyPrompts, ["こんにちは"])
        XCTAssertEqual(speakerPrepares, 1)
        XCTAssertEqual(spokenTexts, ["こんにちは、会えてうれしいよ"])
        XCTAssertEqual(audioActivations, 1)
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(recognizerPrepares, 0)
        XCTAssertEqual(recognizerStarts, 0)

        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertEqual(harness.sut.viewState.caption, "こんにちは、会えてうれしいよ")
        XCTAssertEqual(harness.sut.viewState.typedText, "")
        XCTAssertTrue(harness.sut.viewState.showsTypedInput, "送信しても入力欄は閉じない")
    }

    func testTypedTurnClosesCaptureLosslesslyDiscardsTailAndResumesVoiceOnce() async {
        let harness = ConversationHarness(
            recognizerTail: .finalized("古い音声")
        )
        await harness.sut.startConversation()
        harness.sut.updateTypedText("文字の質問")

        await harness.sut.submitTypedText("文字の質問")

        let replyPrompts = await harness.reply.prompts

        let recognizerStops = await harness.recognizer.stopCount
        let recognizerStarts = await harness.recognizer.startCount
        let recognizerPrepares = await harness.recognizer.prepareCount
        XCTAssertEqual(replyPrompts, ["文字の質問"])

        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(recognizerPrepares, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertEqual(harness.sut.viewState.typedText, "")
    }

    func testDuplicateTypedSubmissionWhileBusyIsIgnored() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            replySnapshots: nil
        )
        await harness.sut.startConversation()
        let first = Task { await harness.sut.submitTypedText("最初") }
        await harness.reply.waitUntilPromptCount(1)
        XCTAssertFalse(harness.sut.viewState.allowsTypedSubmission)

        harness.sut.showTypedInput()
        harness.sut.updateTypedText("二つ目")
        await harness.sut.submitTypedText("二つ目")
        XCTAssertTrue(harness.sut.viewState.showsTypedInput)
        XCTAssertEqual(harness.sut.viewState.typedText, "二つ目")

        await harness.reply.yield("最初の返事")
        await harness.reply.finish()
        await first.value

        let replyPrompts = await harness.reply.prompts
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(replyPrompts, ["最初"])
        XCTAssertEqual(spokenTexts, ["最初の返事"])
        XCTAssertFalse(spokenTexts.contains(ConversationFailureGuidance.generationFailed))
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertTrue(harness.sut.viewState.showsTypedInput)
        XCTAssertEqual(harness.sut.viewState.typedText, "二つ目")
    }

    func testTypedInputTooLongPreservesReplyMemory() async {
        let harness = ConversationHarness(microphoneAllowed: false, replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task { await harness.sut.submitTypedText("長すぎる入力") }
        await harness.reply.waitUntilPromptCount(1)
        await harness.reply.fail(.inputTooLong)
        await turn.value
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.inputTooLong))
        XCTAssertFalse(harness.sut.viewState.errorMessage?.contains("リセットしました") ?? true)
    }

    func testVoiceInputTooLongPreservesReplyMemory() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("猫ちゃん、長すぎる入力", at: 0) }
        await harness.reply.waitUntilPromptCount(1)
        await harness.reply.fail(.inputTooLong)
        await turn.value
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.inputTooLong))
    }

    func testConcurrentShutdownCallsJoinOneTeardown() async {
        let teardownGate = ConversationTestGate()
        let harness = ConversationHarness(serviceTeardownGate: teardownGate)
        let secondCompletion = ConversationCompletionProbe()
        await harness.sut.startConversation()

        let first = Task { await harness.sut.shutdown() }
        await teardownGate.waitUntilEntered()
        let second = Task {
            await harness.sut.shutdown()
            await secondCompletion.complete()
        }
        for _ in 0..<20 { await Task.yield() }

        let completedBeforeTeardown = await secondCompletion.isComplete
        XCTAssertFalse(completedBeforeTeardown)
        await teardownGate.open()
        await first.value
        await second.value

        let teardownCount = await harness.teardownProbe.callCount
        let completedAfterTeardown = await secondCompletion.isComplete
        XCTAssertEqual(teardownCount, 1)
        XCTAssertTrue(completedAfterTeardown)
    }

    func testTypedSubmissionSnapshotsArgumentBeforeEditorDismissAndPreservesNewDraft() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            replySnapshots: nil
        )
        await harness.sut.startConversation()
        harness.sut.showTypedInput()
        harness.sut.updateTypedText("送信する質問")
        let submitted = harness.sut.viewState.typedText
        let turn = Task { await harness.sut.submitTypedText(submitted) }
        harness.sut.hideTypedInput()
        await harness.reply.waitUntilPromptCount(1)

        harness.sut.showTypedInput()
        harness.sut.updateTypedText("次の下書き")
        await harness.reply.yield("返事")
        await harness.reply.finish()
        await turn.value

        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["送信する質問"])
        XCTAssertEqual(harness.sut.viewState.typedText, "次の下書き")
        XCTAssertTrue(harness.sut.viewState.showsTypedInput)
        XCTAssertEqual(harness.sut.viewState.caption, "返事")
    }

    func testRetryRerunsPreflightAndNeverPretendsUnavailableModelIsListening() async {
        let harness = ConversationHarness(
            modelAvailabilityResult: .hermesUnauthorized
        )
        await harness.sut.startConversation()

        await harness.sut.retryRecovery()

        let checksWhileUnavailable = await harness.modelAvailability.checkCount
        let startsWhileUnavailable = await harness.recognizer.startCount
        XCTAssertEqual(checksWhileUnavailable, 2)
        XCTAssertEqual(startsWhileUnavailable, 0)
        XCTAssertEqual(
            harness.sut.viewState.phase,
            .failed(.modelUnavailable(.hermesUnauthorized))
        )

        await harness.modelAvailability.setResult(.available)
        await harness.sut.retryRecovery()

        let totalChecks = await harness.modelAvailability.checkCount
        let startCount = await harness.recognizer.startCount
        XCTAssertEqual(totalChecks, 3)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testTypedCaptureCloseDoesNotEraseNewDraftEnteredWhileStopping() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()
        harness.sut.updateTypedText("送信する質問")
        let turn = Task { await harness.sut.submitTypedText("送信する質問") }
        await stopGate.waitUntilEntered()

        harness.sut.showTypedInput()
        harness.sut.updateTypedText("次の下書き")
        await stopGate.open()
        await turn.value

        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["送信する質問"])
        XCTAssertEqual(harness.sut.viewState.typedText, "次の下書き")
        XCTAssertTrue(harness.sut.viewState.showsTypedInput)
    }

    func testTypedSubmissionWaitsForInFlightLifecycleCleanup() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()
        let pause = Task { await harness.sut.sceneBecameInactive() }
        await stopGate.waitUntilEntered()

        let typed = Task { await harness.sut.submitTypedText("文字の質問") }
        for _ in 0..<20 { await Task.yield() }

        let promptsBeforeCleanup = await harness.reply.prompts
        XCTAssertTrue(promptsBeforeCleanup.isEmpty)
        await stopGate.open()
        await pause.value
        await typed.value

        let promptsAfterCleanup = await harness.reply.prompts
        XCTAssertEqual(promptsAfterCleanup, ["文字の質問"])
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testTypedSubmissionDuringCaptureClosingDoesNotBlockNextVoiceTurn() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()
        await harness.emit(.finalized("猫ちゃん、古い音声"), at: 0)
        harness.now.set(1.2)
        let closing = Task { await harness.sut.flushSegmentation(at: 1.2) }
        await stopGate.waitUntilEntered()

        let typed = Task { await harness.sut.submitTypedText("文字の質問") }
        for _ in 0..<20 { await Task.yield() }
        await stopGate.open()
        await closing.value
        await typed.value
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        await harness.emitCompletedUtterance("猫ちゃん、新しい質問", at: 3)

        let prompts = await harness.reply.prompts
        XCTAssertEqual(prompts, ["文字の質問", "猫ちゃん、新しい質問"])
    }

    func testTypedNoResumeRetainsOwnershipUntilAudioDeactivationCompletes() async {
        let deactivateGate = ConversationTestGate()
        let harness = ConversationHarness(audioDeactivateGate: deactivateGate)
        let typed = Task { await harness.sut.submitTypedText("文字の質問") }
        await deactivateGate.waitUntilEntered()

        XCTAssertEqual(harness.sut.viewState.phase, .thinking)
        XCTAssertEqual(harness.sut.viewState.mouthPose, .closed)
        await harness.sut.startConversation()
        let startsBeforeDeactivation = await harness.recognizer.startCount
        XCTAssertEqual(startsBeforeDeactivation, 0)

        await deactivateGate.open()
        await typed.value
        let audioAfterTypedTurn = await harness.audio.isActive
        XCTAssertFalse(audioAfterTypedTurn)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)

        await harness.sut.startConversation()
        let startsAfterExplicitResume = await harness.recognizer.startCount
        let audioAfterExplicitResume = await harness.audio.isActive
        XCTAssertEqual(startsAfterExplicitResume, 1)
        XCTAssertTrue(audioAfterExplicitResume)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testTypedGenerationFailureStopsSpeakerAndDeactivatesBeforePublishingFailure() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            replySnapshots: nil
        )
        await harness.sut.startConversation()
        let stopsBeforeTurn = await harness.speaker.stopCount   // マイク拒否の後始末も stop を数える
        let typed = Task { await harness.sut.submitTypedText("文字の質問") }
        await harness.reply.waitUntilPromptCount(1)

        await harness.reply.fail(.modelGenerationFailed)
        await typed.value

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let deactivations = await harness.audio.deactivateCount
        XCTAssertFalse(audioIsActive)
        XCTAssertGreaterThanOrEqual(speakerStops - stopsBeforeTurn, 1)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry, .showTypedInput])
        let calls = harness.calls.values
        XCTAssertLessThan(
            calls.lastIndex(of: .stopSpeaker)!,
            calls.lastIndex(of: .deactivateAudio)!
        )
    }

    func testTypedSpeechFailureStopsSpeakerAndDeactivatesBeforePublishingFailure() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            speakerError: .speechSynthesisFailed
        )
        await harness.sut.startConversation()
        let stopsBeforeTurn = await harness.speaker.stopCount

        await harness.sut.submitTypedText("文字の質問")

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let deactivations = await harness.audio.deactivateCount
        XCTAssertFalse(audioIsActive)
        XCTAssertGreaterThanOrEqual(speakerStops - stopsBeforeTurn, 1)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry])
        let calls = harness.calls.values
        XCTAssertLessThan(
            calls.lastIndex(of: .stopSpeaker)!,
            calls.lastIndex(of: .deactivateAudio)!
        )
    }

    func testTypedModelUnavailableAfterVoiceCaptureCleansUpInheritedAudio() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.modelAvailability.setResult(.hermesUnauthorized)

        await harness.sut.submitTypedText("文字の質問")

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let recognizerStops = await harness.recognizer.stopCount
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(speakerStops, 1)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(
            harness.sut.viewState.phase,
            .failed(.modelUnavailable(.hermesUnauthorized))
        )
        let calls = harness.calls.values
        guard let stopSpeaker = calls.lastIndex(of: .stopSpeaker),
              let deactivateAudio = calls.lastIndex(of: .deactivateAudio) else {
            return XCTFail("typed failure must stop the speaker and deactivate audio")
        }
        XCTAssertLessThan(stopSpeaker, deactivateAudio)
    }

    func testTypedSpeakerPreparationFailureAfterVoiceCaptureCleansUpInheritedAudio() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.speaker.setPrepareError(.speechSynthesisFailed)

        await harness.sut.submitTypedText("文字の質問")

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let recognizerStops = await harness.recognizer.stopCount
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(speakerStops, 1)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry, .showTypedInput])
        let calls = harness.calls.values
        guard let stopSpeaker = calls.lastIndex(of: .stopSpeaker),
              let deactivateAudio = calls.lastIndex(of: .deactivateAudio) else {
            return XCTFail("typed failure must stop the speaker and deactivate audio")
        }
        XCTAssertLessThan(stopSpeaker, deactivateAudio)
    }

    func testSingleEmittedInterruptionAllowsQueuedExplicitResumeExactlyOnce() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()

        harness.audio.emit(.interruptionBegan)
        await stopGate.waitUntilEntered()
        let resume = Task { await harness.sut.startConversation() }
        for _ in 0..<20 { await Task.yield() }

        await stopGate.open()
        await resume.value

        let recognizerStarts = await harness.recognizer.startCount
        let recognizerStops = await harness.recognizer.stopCount
        let audioActivations = await harness.audio.activateCount
        let audioDeactivations = await harness.audio.deactivateCount
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertEqual(audioDeactivations, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testRecognizerPreflightFailuresCleanUpVoiceAudioBeforePublishingFailure() async {
        enum Stage {
            case prepare
            case start
        }

        for stage in [Stage.prepare, .start] {
            let expectedError: ConversationServiceError = stage == .prepare
                ? .speechLocaleUnsupported
                : .speechCaptureFailed
            let harness = ConversationHarness(
                recognizerPrepareError: stage == .prepare ? expectedError : nil,
                recognizerStartError: stage == .start ? expectedError : nil
            )

            await harness.sut.startConversation()

            let audioIsActive = await harness.audio.isActive
            let recognizerStops = await harness.recognizer.stopCount
            let speakerStops = await harness.speaker.stopCount
            let audioDeactivations = await harness.audio.deactivateCount
            let texts = await harness.speaker.texts
            XCTAssertEqual(texts, [ConversationFailureGuidance.listening], "stage: \(stage)")
            XCTAssertFalse(audioIsActive, "stage: \(stage)")
            XCTAssertEqual(recognizerStops, 1, "stage: \(stage)")
            XCTAssertEqual(speakerStops, 1, "stage: \(stage)")
            XCTAssertEqual(audioDeactivations, 1, "stage: \(stage)")
            XCTAssertEqual(harness.sut.viewState.phase, .failed(expectedError))

            let calls = harness.calls.values
            guard let stopRecognizer = calls.lastIndex(of: .stopRecognizer),
                  let guidance = calls.lastIndex(of: .speak(ConversationFailureGuidance.listening)),
                  let stopSpeaker = calls.lastIndex(of: .stopSpeaker),
                  let deactivateAudio = calls.lastIndex(of: .deactivateAudio) else {
                XCTFail("voice preflight failure must stop services before deactivation")
                await harness.sut.shutdown()
                continue
            }
            XCTAssertLessThan(stopRecognizer, guidance)
            XCTAssertLessThan(guidance, stopSpeaker)
            XCTAssertLessThan(stopRecognizer, deactivateAudio)
            XCTAssertLessThan(stopSpeaker, deactivateAudio)
            await harness.sut.shutdown()
        }
    }

    func testVoiceGenerationFailureCleansUpAudioBeforePublishingFailure() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task {
            await harness.emitCompletedUtterance("猫ちゃん、質問", at: 0)
        }
        await harness.reply.waitUntilPromptCount(1)

        await harness.reply.fail(.modelGenerationFailed)
        await turn.value

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let audioDeactivations = await harness.audio.deactivateCount
        XCTAssertFalse(audioIsActive)
        XCTAssertGreaterThanOrEqual(speakerStops, 1, "返答の後始末と案内の後の停止で複数回になりうる")
        XCTAssertEqual(audioDeactivations, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        let calls = harness.calls.values
        guard let stopSpeaker = calls.lastIndex(of: .stopSpeaker),
              let deactivateAudio = calls.lastIndex(of: .deactivateAudio) else {
            return XCTFail("generation failure must stop speech before deactivation")
        }
        XCTAssertLessThan(stopSpeaker, deactivateAudio)
    }

    func testVoiceSpeechFailureSerializesCleanupBeforeQueuedRetry() async {
        let deactivateGate = ConversationTestGate()
        let harness = ConversationHarness(
            speakerError: .speechSynthesisFailed,
            audioDeactivateGate: deactivateGate
        )
        await harness.sut.startConversation()
        let turn = Task {
            await harness.emitCompletedUtterance("猫ちゃん、質問", at: 0)
        }
        let didBeginCleanup = await harness.waitUntil {
            await harness.audio.deactivateCount == 1
        }
        guard didBeginCleanup else {
            await turn.value
            return XCTFail("speech failure must begin audio cleanup")
        }

        XCTAssertNotEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        let retry = Task { await harness.sut.startConversation() }
        for _ in 0..<20 { await Task.yield() }
        let activationsDuringCleanup = await harness.audio.activateCount
        let startsDuringCleanup = await harness.recognizer.startCount
        XCTAssertEqual(activationsDuringCleanup, 1)
        XCTAssertEqual(startsDuringCleanup, 1)

        await deactivateGate.open()
        await turn.value
        await retry.value

        let audioIsActive = await harness.audio.isActive
        let speakerStops = await harness.speaker.stopCount
        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        XCTAssertTrue(audioIsActive)
        XCTAssertGreaterThanOrEqual(speakerStops, 1)
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        let calls = harness.calls.values
        let deactivation = calls.lastIndex(of: .deactivateAudio)!
        let activations = calls.indices.filter { calls[$0] == .activateAudio }
        XCTAssertEqual(activations.count, 2)
        XCTAssertLessThan(deactivation, activations[1])
    }

    func testCaptureStreamFailureStopsServicesAndDeactivatesAudio() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()

        await harness.recognizer.fail(.speechCaptureFailed)
        let didFail = await harness.waitUntil {
            harness.sut.viewState.phase == .failed(.speechCaptureFailed)
        }

        let audioIsActive = await harness.audio.isActive
        let recognizerStops = await harness.recognizer.stopCount
        let speakerStops = await harness.speaker.stopCount
        let audioDeactivations = await harness.audio.deactivateCount
        XCTAssertTrue(didFail)
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(speakerStops, 1)
        XCTAssertEqual(audioDeactivations, 1)
    }

    func testRetryQueuedDuringPreflightFailureCleanupStartsFreshPreflight() async {
        let deactivateGate = ConversationTestGate()
        let waitingForCleanupSignal = ConversationTestGate(isOpen: true)
        let preflightFinishGate = ConversationTestGate()
        let raceProbe = ConversationPreflightRaceProbe()
        let harness = ConversationHarness(
            recognizerPrepareError: .speechLocaleUnsupported,
            audioDeactivateGate: deactivateGate,
            lifecycleCheckpoint: { checkpoint in
                await raceProbe.record(checkpoint)
                switch checkpoint {
                case .waitingForFailureCleanup:
                    await waitingForCleanupSignal.wait()
                case .preflightWillFinish:
                    await preflightFinishGate.wait()
                case .preflightWillStart, .joiningExistingPreflight:
                    break
                }
            }
        )
        let firstStart = Task {
            await harness.sut.startConversation()
        }
        let didBeginCleanup = await harness.waitUntil {
            await harness.audio.deactivateCount == 1
        }
        XCTAssertTrue(didBeginCleanup)

        let retry = Task {
            await harness.sut.startConversation()
        }
        await waitingForCleanupSignal.waitUntilEntered()
        let preparesDuringCleanup = await harness.recognizer.prepareCount
        XCTAssertEqual(preparesDuringCleanup, 1)

        await deactivateGate.open()
        await preflightFinishGate.waitUntilEntered()
        let outcome = await raceProbe.waitForOutcome()
        XCTAssertEqual(outcome, .freshPreflight)

        await preflightFinishGate.open()
        await firstStart.value
        await retry.value

        let permissionRequests = await harness.microphone.requestCount
        let audioActivations = await harness.audio.activateCount
        let recognizerPrepares = await harness.recognizer.prepareCount
        XCTAssertEqual(permissionRequests, 2)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertEqual(recognizerPrepares, 2)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechLocaleUnsupported))
    }

    func testPauseDuringFailureCleanupCannotEraseQueuedResumeOwnership() async {
        let deactivateGate = ConversationTestGate()
        let harness = ConversationHarness(
            speakerError: .speechSynthesisFailed,
            audioDeactivateGate: deactivateGate
        )
        await harness.sut.startConversation()
        let failedTurn = Task(priority: .low) {
            await harness.emitCompletedUtterance("猫ちゃん、質問", at: 0)
        }
        await deactivateGate.waitUntilEntered()
        let deactivationsDuringCleanup = await harness.audio.deactivateCount
        XCTAssertEqual(deactivationsDuringCleanup, 1)

        let pause = Task(priority: .low) {
            await harness.sut.sceneBecameInactive()
        }
        let didPublishPause = await harness.waitUntil {
            harness.sut.viewState.phase == .paused
        }
        XCTAssertTrue(didPublishPause)
        let resume = Task(priority: .high) {
            await harness.sut.startConversation()
        }
        for _ in 0..<20 { await Task.yield() }
        let startsDuringCleanup = await harness.recognizer.startCount
        XCTAssertEqual(startsDuringCleanup, 1)

        await deactivateGate.open()
        await failedTurn.value
        await pause.value
        await resume.value

        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        let audioIsActive = await harness.audio.isActive
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertTrue(audioIsActive)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testShortTypedReplyOpensWideOnSentenceStartAndClosesAfterFinish() async {
        let harness = ConversationHarness(
            microphoneAllowed: false,
            speakerAutomaticallyFinishes: false
        )
        await harness.sut.startConversation()
        let turn = Task { await harness.sut.submitTypedText("こんにちは") }
        await harness.speaker.waitUntilTextCount(1)

        await harness.speaker.yield(.started)
        let didShowWide = await harness.waitUntil {
            harness.sut.viewState.mouthPose == .wide
        }
        XCTAssertTrue(didShowWide)
        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        XCTAssertEqual(harness.sut.viewState.mouthPose, .closed)
    }
}
