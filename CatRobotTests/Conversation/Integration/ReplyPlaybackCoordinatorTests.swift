import XCTest
@testable import CatRobot

@MainActor
final class ReplyPlaybackCoordinatorTests: XCTestCase {
    func testSpeaksBeforeGenerationEndsAndCaptionsKeepUpdating() async throws {
        for speechFinishesFirst in [true, false] {
            let reply = ControlledReply()
            let speaker = ControlledSpeaker()
            let updates = PlaybackUpdates()
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
            let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
            await reply.waitUntilRequested()
            await reply.yield("こんにちは。元")
            await speaker.waitUntilCallCount(1)
            let first = await speaker.texts
            XCTAssertEqual(first, ["こんにちは。"])
            await speaker.emit(.started)
            await reply.yield("こんにちは。元気です。")
            await updates.waitForCaption("こんにちは。元気です。")
            await reply.yield("こんにちは。元気です。")
            if speechFinishesFirst {
                await speaker.complete()
                await updates.waitForFinishes(1)
                let texts = await speaker.texts
                XCTAssertEqual(texts.count, 1)
                await reply.finish()
            } else {
                await reply.finish()
                await speaker.complete()
            }
            await speaker.waitUntilCallCount(2)
            let all = await speaker.texts
            XCTAssertEqual(all, ["こんにちは。", "元気です。"])
            await speaker.complete()
            let result = try await run.value
            XCTAssertEqual(result, "こんにちは。元気です。")
            XCTAssertEqual(updates.finishes, [.first, .remainder])
        }
    }

    func testUnsupportedOrBaselineWaitsForFinalReplacementSnapshot() async throws {
        for (stable, mode) in [(false, ReplyPlaybackMode.firstSentence), (true, .completeResponse)] {
            let reply = ControlledReply(stablePrefix: stable)
            let speaker = ControlledSpeaker()
            let updates = PlaybackUpdates()
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: mode)
            let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
            await reply.waitUntilRequested()
            await reply.yield("仮の一文。続き")
            await updates.waitForCaption("仮の一文。続き")
            let early = await speaker.texts
            XCTAssertTrue(early.isEmpty)
            await reply.yield("完全に置換した回答")
            await reply.finish()
            await speaker.waitUntilCallCount(1)
            let texts = await speaker.texts
            XCTAssertEqual(texts, ["完全に置換した回答"])
            await speaker.complete()
            _ = try await run.value
        }
    }

    func testRewrittenSpokenPrefixStopsWithoutRepeating() async {
        let reply = ControlledReply()
        let speaker = ControlledSpeaker()
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
        let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("確定。次")
        await speaker.waitUntilCallCount(1)
        await reply.yield("別の文。次")
        await assertFailure(run, .modelGenerationFailed)
        let texts = await speaker.texts
        let stops = await speaker.stopCount
        XCTAssertEqual(texts, ["確定。"])
        XCTAssertGreaterThan(stops, 0)
    }

    func testGenerationFailureBeforeDuringAndAfterFirstSpeech() async {
        for stage in 0..<3 {
            let reply = ControlledReply()
            let speaker = ControlledSpeaker()
            let updates = PlaybackUpdates()
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
            let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: updates.record) }
            await reply.waitUntilRequested()
            if stage > 0 {
                await reply.yield("最初。次")
                await speaker.waitUntilCallCount(1)
            }
            if stage == 2 { await speaker.complete(); await updates.waitForFinishes(1) }
            await reply.finish(throwing: ConversationServiceError.modelGenerationFailed)
            await assertFailure(run, .modelGenerationFailed)
            let texts = await speaker.texts
            XCTAssertEqual(texts.count, stage == 0 ? 0 : 1)
        }
    }

    func testSpeechStartAndMidstreamFailuresCancelGenerationWithoutResettingMemory() async {
        for startFails in [true, false] {
            let reply = ControlledReply()
            let speaker = ControlledSpeaker(startError: startFails ? .speechSynthesisFailed : nil)
            let sink = RecordingReplyTraceSink()
            let trace = ReplyTrace(sink: sink, now: { 0 })
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
            let run = Task { try await sut.run(prompt: "質問", trace: trace, onUpdate: { _ in }) }
            await reply.waitUntilRequested()
            await reply.yield("最初。次")
            if !startFails {
                await speaker.waitUntilCallCount(1)
                await speaker.finish(throwing: ConversationServiceError.speechSynthesisFailed)
            }
            await assertFailure(run, .speechSynthesisFailed)
            await reply.cancellation.wait()
            let resets = await reply.resetCount
            XCTAssertEqual(resets, 0)
            XCTAssertEqual(sink.events.last?.outcome, .speechFailure)
        }
    }

    func testEmptyReplyAndSpeechWithoutFinishAreFailures() async {
        for empty in [true, false] {
            let reply = ControlledReply()
            let speaker = ControlledSpeaker()
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
            let run = Task { try await sut.run(prompt: "質問", trace: nil, onUpdate: { _ in }) }
            await reply.waitUntilRequested()
            await reply.yield(empty ? "  " : "一文です。")
            await reply.finish()
            if !empty { await speaker.waitUntilCallCount(1); await speaker.finish() }
            await assertFailure(run, empty ? .modelGenerationFailed : .speechSynthesisFailed)
        }
    }

    func testFallbackStartsOnlyOnceAndRemainderIsExact() async throws {
        let reply = ControlledReply()
        let speaker = ControlledSpeaker()
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
        let run = Task { try await sut.run(prompt: "質問", trace: trace, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("一文だけ。")
        await reply.finish()
        await speaker.waitUntilCallCount(1)
        await speaker.emit(.willSpeak(range: 0..<1))
        await speaker.emit(.started)
        await speaker.emit(.started)
        await speaker.complete()
        _ = try await run.value
        let starts = sink.events.filter { $0.point == .speechStarted }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.source, .willSpeakFallback)
    }

    func testCancellationJoinsCleanupBeforeAllowingNewRun() async throws {
        let stopGate = ConversationTestGate()
        let reply = ControlledReply()
        let speaker = ControlledSpeaker(stopGate: stopGate)
        let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
        let run = Task { try await sut.run(prompt: "古い", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested()
        await reply.yield("最初。次")
        await speaker.waitUntilCallCount(1)
        let cancel = Task { await sut.cancelAndWait() }
        await stopGate.waitUntilEntered()
        do { _ = try await sut.run(prompt: "早すぎる", trace: nil, onUpdate: { _ in }); XCTFail("Must remain busy") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelBusy) }
        let cancelAgain = Task { await sut.cancelAndWait() }
        await stopGate.open()
        await cancel.value
        await cancelAgain.value
        await assertFailure(run, .cancelled)
        let next = Task { try await sut.run(prompt: "新しい", trace: nil, onUpdate: { _ in }) }
        await reply.waitUntilRequested(2)
        await reply.yield("新しい返答。")
        await reply.finish()
        await speaker.waitUntilCallCount(2)
        await speaker.complete()
        let result = try await next.value
        XCTAssertEqual(result, "新しい返答。")
    }

    func testParentCancellationBeforeAndDuringSpeechJoinsBothChildren() async {
        for startsSpeech in [false, true] {
            let reply = ControlledReply()
            let speaker = ControlledSpeaker()
            let updates = PlaybackUpdates()
            let sink = RecordingReplyTraceSink()
            let sut = ReplyPlaybackCoordinator(reply: reply, speaker: speaker, mode: .firstSentence)
            let trace = ReplyTrace(sink: sink, now: { 0 })
            let run = Task { try await sut.run(prompt: "質問", trace: trace, onUpdate: updates.record) }
            await reply.waitUntilRequested()
            let text = startsSpeech ? "最初。次" : "途中"
            await reply.yield(text)
            await updates.waitForCaption(text)
            if startsSpeech { await speaker.waitUntilCallCount(1) }
            run.cancel()
            await assertFailure(run, .cancelled)
            await reply.cancellation.wait()
            let resets = await reply.resetCount
            XCTAssertEqual(resets, 0)
            XCTAssertEqual(sink.events.last?.outcome, .cancelled)
        }
    }

    private func assertFailure(_ run: Task<String, Error>, _ expected: ConversationServiceError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await run.value; XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? ConversationServiceError, expected, file: file, line: line) }
    }
}
