import XCTest
@testable import CatRobot

@MainActor
final class ConversationSmartTurnTests: XCTestCase {
    func testProvisionalWordsCloseWithoutAnEndingRuleAndStopFinalIsUsedOnce() async {
        let h = ConversationHarness(recognizerTail: .finalized("ねこ、明日は"))
        await h.sut.startConversation()
        await h.emit(.provisional("ねこ、明日は"), at: 10)
        h.now.set(10.2)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.51, requestedAt: 10.2)))
        let replied = await h.waitUntil { await h.reply.prompts.count == 1 && h.sut.viewState.phase == .listening }
        XCTAssertTrue(replied)
        let prompts = await h.reply.prompts
        XCTAssertEqual(prompts, ["ねこ、明日は"])
        await h.sut.shutdown()
    }

    func testFinalizedPrefixAndStopFinalTailAreJoinedOnce() async {
        let h = ConversationHarness(recognizerTail: .finalized("昼から"))
        await h.sut.startConversation()
        await h.emit(.finalized("ねこ、明日は"), at: 10)
        await h.emit(.provisional("昼から"), at: 10.1)
        h.now.set(10.2)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 10.2)))
        let replied = await h.waitUntil { await h.reply.prompts.count == 1 && h.sut.viewState.phase == .listening }
        XCTAssertTrue(replied)
        let prompts = await h.reply.prompts
        XCTAssertEqual(prompts, ["ねこ、明日は昼から"])
        await h.sut.shutdown()
    }

    func testNoTextOrOnlyPunctuationCannotArmAnAudioTurn() async {
        for text in ["", "…！？"] {
            let h = ConversationHarness()
            await h.sut.startConversation()
            if !text.isEmpty { await h.emit(.provisional(text), at: 10) }
            h.now.set(10.2)
            await h.recognizer.emit(.audioEnded(.init(probability: 0.99, requestedAt: 10.2)))
            let stopped = await h.waitUntil(timeout: .milliseconds(40)) { await h.recognizer.stopCount > 0 }
            XCTAssertFalse(stopped)
            XCTAssertEqual(h.sut.viewState.phase, .listening)
            await h.sut.shutdown()
        }
    }

    func testOldLowConfidenceAndResumedAudioSignalsDoNotCloseCurrentWords() async {
        for kind in ["late", "threshold", "rawAudio", "speech"] {
            let h = ConversationHarness()
            await h.sut.startConversation()
            await h.emit(.finalized("ねこ、明日は"), at: 10)
            let gate = AudioTurnEndGate()
            let signal = AudioTurnEndSignal(probability: kind == "threshold" ? 0.5 : 0.99,
                requestedAt: kind == "late" ? 9 : 10.2, gate: gate)
            if kind == "rawAudio" { _ = gate.beginAudio(); gate.endAudio() }
            if kind == "speech" { gate.noteSpeech() }
            h.now.set(10.2)
            await h.recognizer.emit(.audioEnded(signal))
            let stopped = await h.waitUntil(timeout: .milliseconds(40)) { await h.recognizer.stopCount > 0 }
            XCTAssertFalse(stopped, kind)
            await h.sut.shutdown()
        }
    }

    func testReplyStaysHalfDuplexAndNextCaptureAcceptsANewAudioTurn() async {
        let h = ConversationHarness(replySnapshots: nil)
        await h.sut.startConversation()
        await h.emit(.finalized("ねこ、最初"), at: 10)
        h.now.set(10.2)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 10.2)))
        let first = await h.waitUntil { await h.reply.prompts.count == 1 }
        XCTAssertTrue(first)
        guard first else { await h.sut.shutdown(); return }
        let startsDuringReply = await h.recognizer.startCount
        let stopsDuringReply = await h.recognizer.stopCount
        XCTAssertEqual(startsDuringReply, 1)
        XCTAssertEqual(stopsDuringReply, 1)
        XCTAssertEqual(h.sut.viewState.phase, .thinking)
        await h.reply.yield("返答"); await h.reply.finish()
        let resumed = await h.waitUntil { h.sut.viewState.phase == .listening }
        XCTAssertTrue(resumed)
        let startsAfterReply = await h.recognizer.startCount
        XCTAssertEqual(startsAfterReply, 2)
        await h.emit(.finalized("次の質問"), at: 20)
        h.now.set(20.2)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 20.2)), capture: 0)
        let oldClosed = await h.waitUntil(timeout: .milliseconds(40)) { await h.reply.prompts.count > 1 }
        XCTAssertFalse(oldClosed)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 20.2)))
        let second = await h.waitUntil { await h.reply.prompts.count == 2 }
        XCTAssertTrue(second)
        let prompts = await h.reply.prompts
        XCTAssertEqual(prompts, ["ねこ、最初", "次の質問"])
        await h.sut.shutdown()
    }

    func testPauseRetiresOldAudioSignalsAndResumeCanClose() async {
        let h = ConversationHarness()
        await h.sut.startConversation()
        await h.emit(.finalized("ねこ、古い"), at: 10)
        await h.sut.handleAudioSessionEvent(.routeChanged)
        await h.sut.toggleListening()
        await h.emit(.finalized("ねこ、新しい"), at: 20)
        h.now.set(20.2)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 20.2)), capture: 0)
        let oldClosed = await h.waitUntil(timeout: .milliseconds(40)) { await h.reply.prompts.count > 0 }
        XCTAssertFalse(oldClosed)
        await h.recognizer.emit(.audioEnded(.init(probability: 0.9, requestedAt: 20.2)))
        let replied = await h.waitUntil { await h.reply.prompts.count == 1 }
        XCTAssertTrue(replied)
        let prompts = await h.reply.prompts
        XCTAssertEqual(prompts, ["ねこ、新しい"])
        await h.sut.shutdown()
    }

    func testEndpointFailureDuringPreparationOrListeningIsVisibleAndDoesNotReply() async {
        for failsPreparation in [true, false] {
            let h = ConversationHarness(recognizerPrepareError: failsPreparation ? .speechEndpointingFailed : nil)
            await h.sut.startConversation()
            if !failsPreparation {
                await h.emit(.finalized("ねこ、質問"), at: 10)
                await h.recognizer.fail(.speechEndpointingFailed)
            }
            let failed = await h.waitUntil { h.sut.viewState.phase == .failed(.speechEndpointingFailed) }
            XCTAssertTrue(failed)
            XCTAssertEqual(h.sut.viewState.errorMessage, ConversationErrorPresentation(.speechEndpointingFailed).message)
            XCTAssertTrue(h.sut.viewState.recoveries.contains { $0.action == .retry })
            let prompts = await h.reply.prompts
            XCTAssertTrue(prompts.isEmpty)
            await h.sut.shutdown()
        }
    }

}
