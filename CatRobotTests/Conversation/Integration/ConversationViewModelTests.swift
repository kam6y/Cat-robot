import XCTest
@testable import CatRobot

@MainActor
final class ConversationViewModelTests: XCTestCase {
    func testCommittedMemoryChangePublishesNoticeWithoutBlockingSpeech() async {
        let sleeper = ConversationTestSleeper()
        let speakGate = ConversationTestGate()
        let harness = ConversationHarness(
            replySnapshots: nil,
            speakerAutomaticallyFinishes: false,
            speakerSpeakGate: speakGate,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        await harness.sut.startConversation()
        let turn = Task {
            await harness.emitCompletedUtterance("ねこ、青が好き", at: 0)
        }
        await harness.reply.waitUntilRequestCount(1)

        await harness.reply.yield(
            .committed(.init(finalText: "覚えたよ", memoryChange: .remembered))
        )
        XCTAssertNil(harness.sut.viewState.memoryNotice)

        await harness.reply.finish()
        await speakGate.waitUntilEntered()
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")
        await speakGate.open()
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(spokenTexts, ["覚えたよ"])

        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        let didScheduleDismissal = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        XCTAssertTrue(didScheduleDismissal)

        await sleeper.release(0)
        let didCompleteDismissal = await harness.waitUntil {
            await sleeper.completionCount == 1
        }
        XCTAssertTrue(didCompleteDismissal)
        XCTAssertNil(harness.sut.viewState.memoryNotice)
    }

    func testSceneInactivityClearsCommittedNoticeAndCancelsOldExpiry() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("覚えて")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "覚えたよ", memoryChange: .remembered))
        )
        await harness.reply.finish()
        await submission.value
        let didSchedule = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        XCTAssertTrue(didSchedule)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")

        harness.sut.invalidateForSceneInactivity()
        let didCancel = await harness.waitUntil {
            await sleeper.cancellationCount == 1
        }
        XCTAssertTrue(didCancel)
        XCTAssertNil(harness.sut.viewState.memoryNotice)

        await sleeper.release(0)
        let didCompleteOldExpiry = await harness.waitUntil {
            await sleeper.completionCount == 1
        }
        XCTAssertTrue(didCompleteOldExpiry)
        XCTAssertNil(harness.sut.viewState.memoryNotice)
    }

    func testTypedDuplicateCommitPublishesNoNoticeOrSpeech() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("覚えて")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "最初", memoryChange: .remembered))
        )
        await harness.reply.yield(
            .committed(.init(finalText: "重複", memoryChange: .forgotten))
        )
        await harness.reply.finish()
        await submission.value

        let durations = await sleeper.durations
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertTrue(durations.isEmpty)
        XCTAssertTrue(spokenTexts.isEmpty)
        await drainScheduledMemoryNotices(sleeper, expectedCount: durations.count, harness: harness)
    }

    func testTypedCommitThenStreamFailurePublishesNoNoticeOrSpeech() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("覚えて")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "未確定", memoryChange: .remembered))
        )
        await harness.reply.fail(.toolRuntimeFailed)
        await submission.value

        let durations = await sleeper.durations
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.toolRuntimeFailed))
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertTrue(durations.isEmpty)
        XCTAssertTrue(spokenTexts.isEmpty)
        await drainScheduledMemoryNotices(sleeper, expectedCount: durations.count, harness: harness)
    }

    func testVoiceDuplicateCommitPublishesNoNoticeOrSpeech() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        await harness.sut.startConversation()
        let turn = Task {
            await harness.emitCompletedUtterance("ねこ、覚えて", at: 0)
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "最初", memoryChange: .remembered))
        )
        await harness.reply.yield(
            .committed(.init(finalText: "重複", memoryChange: .updated))
        )
        await harness.reply.finish()
        await turn.value

        let durations = await sleeper.durations
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertTrue(durations.isEmpty)
        XCTAssertTrue(spokenTexts.isEmpty)
        await drainScheduledMemoryNotices(sleeper, expectedCount: durations.count, harness: harness)
    }

    func testVoiceCommitThenStreamFailurePublishesNoNoticeOrSpeech() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        await harness.sut.startConversation()
        let turn = Task {
            await harness.emitCompletedUtterance("ねこ、覚えて", at: 0)
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "未確定", memoryChange: .remembered))
        )
        await harness.reply.fail(.toolRuntimeFailed)
        await turn.value

        let durations = await sleeper.durations
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.toolRuntimeFailed))
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertTrue(durations.isEmpty)
        XCTAssertTrue(spokenTexts.isEmpty)
        await drainScheduledMemoryNotices(sleeper, expectedCount: durations.count, harness: harness)
    }

    func testSearchOrDateOnlyCommitPublishesNoNotice() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("今日の予定は？")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "予定はありません", memoryChange: nil))
        )
        await harness.reply.finish()
        await submission.value

        let durations = await sleeper.durations
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertTrue(durations.isEmpty)
    }

    func testReplyFailureAndRollbackPublishNoNotice() async {
        let failureSleeper = ConversationTestSleeper()
        let failureHarness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await failureSleeper.sleep(for: duration)
            }
        )
        let failedSubmission = Task {
            await failureHarness.sut.submitTypedText("覚えて")
        }
        await failureHarness.reply.waitUntilRequestCount(1)
        await failureHarness.reply.fail(.modelGenerationFailed)
        await failedSubmission.value

        let rollbackSleeper = ConversationTestSleeper()
        let rollbackHarness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await rollbackSleeper.sleep(for: duration)
            }
        )
        let rolledBackSubmission = Task {
            await rollbackHarness.sut.submitTypedText("この内容を覚えて")
        }
        await rollbackHarness.reply.waitUntilRequestCount(1)
        await rollbackHarness.reply.yield(.draft("保存中"))
        await rollbackHarness.reply.fail(.toolRuntimeFailed)
        await rolledBackSubmission.value

        let failureDurations = await failureSleeper.durations
        let rollbackDurations = await rollbackSleeper.durations
        XCTAssertNil(failureHarness.sut.viewState.memoryNotice)
        XCTAssertNil(rollbackHarness.sut.viewState.memoryNotice)
        XCTAssertTrue(failureDurations.isEmpty)
        XCTAssertTrue(rollbackDurations.isEmpty)
    }

    func testNewMemoryNoticeReplacesPriorNoticeAndOldExpiryCannotClearIt() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )

        let first = Task { @MainActor in
            await harness.sut.submitTypedText("ひとつ")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "ひとつ", memoryChange: .remembered)),
            run: 0
        )
        await harness.reply.finish(run: 0)
        await first.value
        let didScheduleFirst = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        XCTAssertTrue(didScheduleFirst)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")

        let second = Task { @MainActor in
            await harness.sut.submitTypedText("ふたつ")
        }
        await harness.reply.waitUntilRequestCount(2)
        await harness.reply.yield(
            .committed(.init(finalText: "ふたつ", memoryChange: .forgotten)),
            run: 1
        )
        await harness.reply.finish(run: 1)
        await second.value
        let didScheduleSecond = await harness.waitUntil {
            (await sleeper.durations).count == 2
        }
        XCTAssertTrue(didScheduleSecond)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶を削除しました")

        await sleeper.release(0)
        let didCompleteOldExpiry = await harness.waitUntil {
            await sleeper.completionCount == 1
        }
        XCTAssertTrue(didCompleteOldExpiry)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶を削除しました")

        await sleeper.release(1)
        let didExpireCurrentNotice = await harness.waitUntil {
            harness.sut.viewState.memoryNotice == nil
        }
        XCTAssertTrue(didExpireCurrentNotice)
        XCTAssertNil(harness.sut.viewState.memoryNotice)
    }

    func testCurrentMemoryNoticeExpiresAfterConfiguredDelay() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("更新して")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "更新したよ", memoryChange: .updated))
        )
        await harness.reply.finish()
        await submission.value
        let didSchedule = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        let durations = await sleeper.durations
        XCTAssertTrue(didSchedule)
        XCTAssertEqual(durations, [.seconds(3)])
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶を更新しました")

        await sleeper.release(0)
        let didExpire = await harness.waitUntil {
            harness.sut.viewState.memoryNotice == nil
        }
        XCTAssertTrue(didExpire)
    }

    func testCommittedNoticeSurvivesLaterSpeechFailure() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            speakerError: .speechSynthesisFailed,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("覚えて")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "覚えたよ", memoryChange: .remembered))
        )
        await harness.reply.finish()
        await submission.value

        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")

        let didScheduleDismissal = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        XCTAssertTrue(didScheduleDismissal)

        await sleeper.release(0)
        let didCompleteDismissal = await harness.waitUntil {
            await sleeper.completionCount == 1
        }
        XCTAssertTrue(didCompleteDismissal)
        XCTAssertNil(harness.sut.viewState.memoryNotice)
    }

    func testShutdownCancelsMemoryNoticeDismissalWithoutClearingCommittedNotice() async {
        let sleeper = ConversationTestSleeper()
        let harness = ConversationHarness(
            replySnapshots: nil,
            memoryNoticeDelay: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        let submission = Task {
            await harness.sut.submitTypedText("覚えて")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(
            .committed(.init(finalText: "覚えたよ", memoryChange: .remembered))
        )
        await harness.reply.finish()
        await submission.value
        let didSchedule = await harness.waitUntil {
            (await sleeper.durations).count == 1
        }
        XCTAssertTrue(didSchedule)

        await harness.sut.shutdown()
        let didCancel = await harness.waitUntil {
            await sleeper.cancellationCount == 1
        }
        XCTAssertTrue(didCancel)

        await sleeper.release(0)
        let didComplete = await harness.waitUntil {
            await sleeper.completionCount == 1
        }
        XCTAssertTrue(didComplete)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "記憶しました")
    }

    func testTypedDraftUpdatesCaptionButDoesNotSpeakUntilCommitted() async {
        let harness = ConversationHarness(replySnapshots: nil)
        let submission = Task { @MainActor in
            await harness.sut.submitTypedText("青が好きです")
        }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(.draft("わかった"))
        await harness.waitUntil { harness.sut.viewState.caption == "わかった" }
        let textsBeforeCommit = await harness.speaker.texts
        XCTAssertEqual(harness.sut.viewState.caption, "わかった")
        XCTAssertEqual(textsBeforeCommit, [])

        await harness.reply.yield(
            .committed(.init(finalText: "わかった、覚えたよ", memoryChange: nil))
        )
        await harness.reply.finish()
        await submission.value
        let spokenTexts = await harness.speaker.texts
        let requests = await harness.reply.requests
        XCTAssertEqual(spokenTexts, ["わかった、覚えたよ"])
        XCTAssertEqual(
            requests,
            [.init(turnID: 1, userText: "青が好きです")]
        )
    }

    func testTypedRequestForwardsExistingTurnIDAndSubmittedText() async {
        let harness = ConversationHarness()

        await harness.sut.submitTypedText("  最初の質問  ")
        await harness.sut.submitTypedText("次の質問")

        let requests = await harness.reply.requests
        XCTAssertEqual(requests, [
            .init(turnID: 1, userText: "最初の質問"),
            .init(turnID: 2, userText: "次の質問"),
        ])
    }

    func testVoiceDraftUpdatesCaptionButDoesNotSpeakUntilCommitted() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        await harness.reply.waitUntilRequestCount(1)

        await harness.reply.yield(.draft("途中"))
        await harness.waitUntil { harness.sut.viewState.caption == "途中" }
        let textsBeforeCommit = await harness.speaker.texts
        XCTAssertEqual(textsBeforeCommit, [])

        await harness.reply.yield(
            .committed(.init(finalText: "最終回答", memoryChange: nil))
        )
        await harness.reply.finish()
        await turn.value
        let spokenTexts = await harness.speaker.texts
        let requests = await harness.reply.requests
        XCTAssertEqual(spokenTexts, ["最終回答"])
        XCTAssertEqual(requests, [.init(turnID: 1, userText: "質問")])
    }

    func testVoiceClassifierRunsBeforeToolEnabledReplyAndSpeech() async {
        let harness = ConversationHarness(classification: .addressed)

        await harness.completeUnengagedTurn("今日どう？", at: 0)

        let calls = harness.calls.values
        XCTAssertLessThan(
            calls.firstIndex(of: .classify("今日どう？"))!,
            calls.firstIndex(of: .generateReply("今日どう？"))!
        )
        XCTAssertLessThan(
            calls.firstIndex(of: .generateReply("今日どう？"))!,
            calls.firstIndex(of: .speak("わかったよ"))!
        )
    }

    func testCommittedFinalStartsSpeechExactlyOnce() async {
        let harness = ConversationHarness(replySnapshots: nil)
        let submission = Task { await harness.sut.submitTypedText("質問") }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(.draft("下書き1"))
        await harness.reply.yield(.draft("下書き2"))
        await harness.reply.yield(
            .committed(.init(finalText: "確定", memoryChange: nil))
        )
        await harness.reply.finish()
        await submission.value

        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(spokenTexts, ["確定"])
    }

    func testReplyFailureClearsUncommittedDraftWithoutSpeech() async {
        let harness = ConversationHarness(replySnapshots: nil)
        let submission = Task { await harness.sut.submitTypedText("質問") }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(.draft("未確定"))
        await harness.reply.fail(.modelGenerationFailed)
        await submission.value

        XCTAssertEqual(harness.sut.viewState.caption, "")
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(spokenTexts, [])
    }

    func testReplyCancellationClearsUncommittedDraftWithoutSpeech() async {
        let harness = ConversationHarness(replySnapshots: nil)
        let submission = Task { await harness.sut.submitTypedText("質問") }
        await harness.reply.waitUntilRequestCount(1)
        await harness.reply.yield(.draft("未確定"))
        await harness.reply.fail(.cancelled)
        await submission.value

        XCTAssertEqual(harness.sut.viewState.caption, "")
        let spokenTexts = await harness.speaker.texts
        XCTAssertEqual(spokenTexts, [])
    }

    func testWakeTurnSkipsClassifierReplacesCumulativeCaptionSpeaksFinalAndResumesOnce() async {
        let harness = ConversationHarness(replySnapshots: ["やあ", "やあ、元気だよ"])
        await harness.sut.startConversation()

        await harness.emitCompletedUtterance("猫ちゃん、元気？", at: 0)

        let classifierCalls = await harness.classifier.calls
        let replyPrompts = await harness.reply.prompts
        let spokenTexts = await harness.speaker.texts
        let startCount = await harness.recognizer.startCount
        XCTAssertEqual(classifierCalls, [])
        XCTAssertEqual(replyPrompts, ["元気？"])
        XCTAssertEqual(spokenTexts, ["やあ、元気だよ"])
        XCTAssertEqual(harness.sut.viewState.caption, "やあ、元気だよ")
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
        XCTAssertEqual(startCount, 2)
    }

    func testEngagedFollowUpAlsoSkipsClassifier() async {
        let harness = ConversationHarness()
        await harness.completeTurn("ねこ、質問", at: 0)
        await harness.completeTurn("もう少し教えて", at: 10)

        let classifierCalls = await harness.classifier.calls
        let replyPrompts = await harness.reply.prompts
        XCTAssertEqual(classifierCalls, [])
        XCTAssertEqual(replyPrompts, ["質問", "もう少し教えて"])
    }

    func testExplicitWakeDuringEngagementResetsFiveMinuteHardDeadline() async {
        let harness = ConversationHarness()
        await harness.completeTurn("ねこ、開始", at: 0)
        for timestamp in stride(from: 29.0, through: 290.0, by: 29.0) {
            await harness.completeTurn("続けて", at: timestamp)
        }

        await harness.completeTurn("ねこ、リセット", at: 295)
        await harness.completeTurn("まだ続けて", at: 310)

        let classifierCalls = await harness.classifier.calls
        XCTAssertTrue(classifierCalls.isEmpty)
    }

    func testWakeOnlyAcknowledgesLocallyAndArmsFastFollowUp() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.emitCompletedUtterance("猫ちゃん", at: 0)

        let firstSpokenTexts = await harness.speaker.texts
        let firstClassifierCalls = await harness.classifier.calls
        let firstReplyPrompts = await harness.reply.prompts
        XCTAssertEqual(firstSpokenTexts, ["なあに？"])
        XCTAssertTrue(firstClassifierCalls.isEmpty)
        XCTAssertTrue(firstReplyPrompts.isEmpty)

        await harness.completeTurn("今日どう？", at: 10)

        let classifierCallCount = await harness.classifier.calls.count
        let replyPrompts = await harness.reply.prompts
        XCTAssertEqual(classifierCallCount, 0)
        XCTAssertEqual(replyPrompts, ["今日どう？"])
    }

    func testClassifiedAddressRepliesAndArmsFastFollowUp() async {
        let harness = ConversationHarness(classification: .addressed)
        await harness.completeUnengagedTurn("今日どう？", at: 0)
        await harness.completeTurn("もう少し教えて", at: 10)

        let replyPrompts = await harness.reply.prompts
        let classifierCalls = await harness.classifier.calls
        XCTAssertEqual(replyPrompts, ["今日どう？", "もう少し教えて"])
        XCTAssertEqual(classifierCalls, ["今日どう？"])
    }

    func testUnrelatedSpeechReturnsToListeningWithoutReply() async {
        let harness = ConversationHarness(classification: .notAddressed)
        await harness.completeUnengagedTurn("テレビ消した？", at: 0)

        let replyPrompts = await harness.reply.prompts
        let speakerTexts = await harness.speaker.texts
        XCTAssertTrue(replyPrompts.isEmpty)
        XCTAssertTrue(speakerTexts.isEmpty)
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testAudioActivatesBeforeRouteBoundRecognizerPreparation() async {
        let harness = ConversationHarness()

        await harness.sut.startConversation()

        let calls = harness.calls.values
        XCTAssertLessThan(
            calls.firstIndex(of: .activateAudio)!,
            calls.firstIndex(of: .prepareRecognizer)!
        )
    }

    func testConcurrentStartsCoalesceAndInactivePreflightCannotPublishListening() async {
        let permissionGate = ConversationTestGate()
        let harness = ConversationHarness(permissionGate: permissionGate)
        let first = Task { await harness.sut.startConversation() }
        let second = Task { await harness.sut.startConversation() }
        await permissionGate.waitUntilEntered()

        let inactive = Task { await harness.sut.sceneBecameInactive() }
        await permissionGate.open()
        await first.value
        await second.value
        await inactive.value

        let requestCount = await harness.microphone.requestCount
        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(recognizerStarts, 0)
        XCTAssertEqual(audioActivations, 0)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testInactiveDuringRouteBoundPreparationCannotStartCaptureAfterLateCompletion() async {
        let prepareGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerPrepareGate: prepareGate)
        let start = Task { await harness.sut.startConversation() }
        await prepareGate.waitUntilEntered()

        let audioWasActive = await harness.audio.isActive
        let captureStartsBeforeInactive = await harness.recognizer.startCount
        XCTAssertTrue(audioWasActive)
        XCTAssertEqual(captureStartsBeforeInactive, 0)

        let inactive = Task { await harness.sut.sceneBecameInactive() }
        let didPublishPause = await harness.waitUntil {
            harness.sut.viewState.phase == .paused
        }
        XCTAssertTrue(didPublishPause)
        await prepareGate.open()
        await start.value
        await inactive.value

        let captureStarts = await harness.recognizer.startCount
        let recognizerStops = await harness.recognizer.stopCount
        let audioIsActive = await harness.audio.isActive
        XCTAssertEqual(captureStarts, 0)
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testPauseDuringReplyStreamingClearsUncommittedDraftAndDoesNotSpeakOrRestart() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        await harness.reply.waitUntilPromptCount(1)
        await harness.reply.yield(.draft("途中"))
        let didPublishFirstSnapshot = await harness.waitUntil {
            harness.sut.viewState.caption == "途中"
        }
        XCTAssertTrue(didPublishFirstSnapshot)

        await harness.sut.toggleListening()
        await harness.reply.yield(.draft("古い返事"))
        await harness.reply.finish()
        await turn.value

        let spokenTexts = await harness.speaker.texts
        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertTrue(spokenTexts.isEmpty)
        XCTAssertEqual(recognizerStarts, 1)
    }

    func testBackgroundDuringSpeechIgnoresLateFinishClearsEngagementAndDoesNotRestart() async {
        let harness = ConversationHarness(
            classification: .notAddressed,
            speakerAutomaticallyFinishes: false
        )
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        await harness.speaker.waitUntilTextCount(1)
        await harness.speaker.yield(.started)

        await harness.sut.sceneBecameInactive()
        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        let recognizerStartsBeforeResume = await harness.recognizer.startCount
        XCTAssertEqual(recognizerStartsBeforeResume, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)

        harness.now.set(2)
        await harness.sut.toggleListening()
        await harness.emitCompletedUtterance("続けて", at: 2)
        let classifierCalls = await harness.classifier.calls
        XCTAssertEqual(classifierCalls, ["続けて"])
    }

    func testStopTailIsFoldedIntoCurrentUtteranceExactlyOnceAndNeverStartsSecondTurn() async {
        let harness = ConversationHarness(
            recognizerTail: .finalized("元気？")
        )
        await harness.sut.startConversation()

        await harness.emitCompletedUtterance("猫ちゃん、", at: 0)
        for _ in 0..<20 { await Task.yield() }

        let replyPrompts = await harness.reply.prompts
        let classifierCalls = await harness.classifier.calls
        XCTAssertEqual(replyPrompts, ["元気？"])
        XCTAssertTrue(classifierCalls.isEmpty)
    }

    func testRapidPauseResumeWaitsForOldStopAndIgnoresOldCaptureCallback() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()

        let pause = Task { await harness.sut.sceneBecameInactive() }
        await stopGate.waitUntilEntered()
        let resume = Task { await harness.sut.toggleListening() }
        await harness.recognizer.emit(.provisional("古い音声"), capture: 0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotEqual(harness.sut.viewState.provisionalTranscript, "古い音声")
        let startsDuringOldStop = await harness.recognizer.startCount
        let preparesDuringOldStop = await harness.recognizer.prepareCount
        let activationsDuringOldStop = await harness.audio.activateCount
        let oldCaptureStillRunning = await harness.recognizer.isRunning
        XCTAssertEqual(startsDuringOldStop, 1)
        XCTAssertEqual(preparesDuringOldStop, 1)
        XCTAssertEqual(activationsDuringOldStop, 1)
        XCTAssertTrue(oldCaptureStillRunning)

        await stopGate.open()
        await pause.value
        await resume.value

        let recognizerStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        let audioIsActive = await harness.audio.isActive
        let newCaptureIsRunning = await harness.recognizer.isRunning
        let calls = harness.calls.values
        let activationIndices = calls.indices.filter { calls[$0] == .activateAudio }
        let deactivationIndices = calls.indices.filter { calls[$0] == .deactivateAudio }
        let preparationIndices = calls.indices.filter { calls[$0] == .prepareRecognizer }
        let startIndices = calls.indices.filter { calls[$0] == .startRecognizer }
        XCTAssertEqual(recognizerStarts, 2)
        XCTAssertEqual(audioActivations, 2)
        XCTAssertTrue(audioIsActive)
        XCTAssertTrue(newCaptureIsRunning)
        XCTAssertEqual(activationIndices.count, 2)
        XCTAssertEqual(deactivationIndices.count, 1)
        XCTAssertEqual(preparationIndices.count, 2)
        XCTAssertEqual(startIndices.count, 2)
        XCTAssertLessThan(deactivationIndices[0], activationIndices[1])
        XCTAssertLessThan(activationIndices[1], preparationIndices[1])
        XCTAssertLessThan(preparationIndices[1], startIndices[1])
        XCTAssertEqual(harness.sut.viewState.phase, .listening)
    }

    func testLaterInactiveSupersedesResumeQueuedBehindExistingStop() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()

        let firstInactive = Task { await harness.sut.sceneBecameInactive() }
        await stopGate.waitUntilEntered()
        let queuedResume = Task { await harness.sut.toggleListening() }
        for _ in 0..<20 { await Task.yield() }
        let laterInactive = Task { await harness.sut.sceneBecameInactive() }
        for _ in 0..<20 { await Task.yield() }

        await stopGate.open()
        await firstInactive.value
        await queuedResume.value
        await laterInactive.value

        let captureStarts = await harness.recognizer.startCount
        let audioActivations = await harness.audio.activateCount
        let audioIsActive = await harness.audio.isActive
        let permissionRequests = await harness.microphone.requestCount
        let availabilityChecks = await harness.modelAvailability.checkCount
        let speakerPreparations = await harness.speaker.prepareCount
        XCTAssertEqual(captureStarts, 1)
        XCTAssertEqual(audioActivations, 1)
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(availabilityChecks, 1)
        XCTAssertEqual(speakerPreparations, 1)
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testInactiveAfterCleanupCompletionStillSupersedesQueuedResume() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()

        let firstInactive = Task { await harness.sut.sceneBecameInactive() }
        await stopGate.waitUntilEntered()
        let queuedResume = Task(priority: .background) {
            await harness.sut.startConversation()
        }
        for _ in 0..<20 { await Task.yield() }

        await stopGate.open()
        await firstInactive.value
        await harness.sut.sceneBecameInactive()
        await queuedResume.value

        let captureStarts = await harness.recognizer.startCount
        let permissionRequests = await harness.microphone.requestCount
        let audioActivations = await harness.audio.activateCount
        let audioIsActive = await harness.audio.isActive
        XCTAssertEqual(captureStarts, 1)
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(audioActivations, 1)
        XCTAssertFalse(audioIsActive)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testDuplicateInactiveAndInterruptionEventsTeardownOnlyOnce() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()

        async let inactive: Void = harness.sut.sceneBecameInactive()
        async let duplicate: Void = harness.sut.handleAudioSessionEvent(.interruptionBegan)
        _ = await (inactive, duplicate)

        let recognizerStops = await harness.recognizer.stopCount
        let speakerStops = await harness.speaker.stopCount
        let audioDeactivations = await harness.audio.deactivateCount
        XCTAssertEqual(recognizerStops, 1)
        XCTAssertEqual(speakerStops, 1)
        XCTAssertEqual(audioDeactivations, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
    }

    func testContinuousActivityCannotDeferTwentySecondHardDeadline() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.emit(.finalized("ねこ、長い質問"), at: 0)
        await harness.emit(.provisional("ねこ、長い質問の途中"), at: 19)

        await harness.emit(.provisional("ねこ、まだ話している"), at: 20)
        let didRoute = await harness.waitUntil {
            await harness.reply.prompts.count == 1
        }

        let replyPrompts = await harness.reply.prompts
        XCTAssertTrue(didRoute)
        XCTAssertEqual(replyPrompts, ["長い質問"])
    }

    func testProvisionalOnlyHardExpiryDoesNotStealNextFinalSilenceTimer() async {
        let harness = ConversationHarness()
        await harness.sut.startConversation()
        await harness.emit(.provisional("テレビの音"), at: 0)

        harness.now.set(20)
        await harness.sut.flushSegmentation(at: 20)
        await harness.emit(.finalized("ねこ、質問"), at: 21)
        for _ in 0..<20 { await Task.yield() }
        let promptsBeforeSilence = await harness.reply.prompts
        XCTAssertTrue(promptsBeforeSilence.isEmpty)

        harness.now.set(22.2)
        let didRoute = await harness.waitUntil(timeout: .seconds(2)) {
            await harness.reply.prompts == ["質問"]
        }

        XCTAssertTrue(didRoute)
    }

    func testEmptyReplyShowsRecoveryWithoutSpeechOrEngagement() async {
        let harness = ConversationHarness(replySnapshots: ["", "   "])
        await harness.completeTurn("ねこ、質問", at: 0)

        let speakerTexts = await harness.speaker.texts
        XCTAssertTrue(speakerTexts.isEmpty)
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry, .showTypedInput])
    }

    func testSpeechFailureIsVisibleAndDoesNotResumeCapture() async {
        let harness = ConversationHarness(speakerError: .speechSynthesisFailed)
        await harness.completeTurn("ねこ、質問", at: 0)

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(recognizerStarts, 1)
    }

    func testCurrentSpeechCancellationIsVisibleAndDoesNotResumeCapture() async {
        let harness = ConversationHarness(speakerAutomaticallyFinishes: false)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        await harness.speaker.waitUntilTextCount(1)

        await harness.speaker.yield(.cancelled)
        await harness.speaker.finish()
        await turn.value

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry])
        XCTAssertEqual(recognizerStarts, 1)
    }

    func testSpeechStreamEndingWithoutFinishedEventIsVisibleAndDoesNotResumeCapture() async {
        let harness = ConversationHarness(speakerAutomaticallyFinishes: false)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("ねこ、質問", at: 0) }
        await harness.speaker.waitUntilTextCount(1)

        await harness.speaker.finish()
        await turn.value

        let recognizerStarts = await harness.recognizer.startCount
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.speechSynthesisFailed))
        XCTAssertEqual(harness.sut.viewState.recoveries.map(\.action), [.retry])
        XCTAssertEqual(recognizerStarts, 1)
    }

    func testShortVoiceReplyOpensWideOnFirstWordAndClosesAfterFinish() async {
        let harness = ConversationHarness(speakerAutomaticallyFinishes: false)
        await harness.sut.startConversation()
        let turn = Task { await harness.emitCompletedUtterance("猫ちゃん", at: 0) }
        await harness.speaker.waitUntilTextCount(1)

        await harness.speaker.yield(.started)
        let didShowSmall = await harness.waitUntil {
            harness.sut.viewState.mouthPose == .small
        }
        XCTAssertTrue(didShowSmall)
        await harness.speaker.yield(.willSpeak(range: 0..<3))
        let didShowWide = await harness.waitUntil {
            harness.sut.viewState.mouthPose == .wide
        }
        XCTAssertTrue(didShowWide)
        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        XCTAssertEqual(harness.sut.viewState.mouthPose, .closed)
    }

    private func drainScheduledMemoryNotices(
        _ sleeper: ConversationTestSleeper,
        expectedCount: Int,
        harness: ConversationHarness
    ) async {
        await sleeper.releaseAll()
        guard expectedCount > 0 else { return }
        let didComplete = await harness.waitUntil {
            await sleeper.completionCount == expectedCount
        }
        XCTAssertTrue(didComplete)
    }
}
