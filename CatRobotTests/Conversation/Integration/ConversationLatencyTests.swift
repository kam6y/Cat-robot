import XCTest
@testable import CatRobot

@MainActor
final class ConversationLatencyTests: XCTestCase {
    func testFastGeneratedTurnRecordsBoundaryCaptionAndSpeechWithoutText() async {
        let harness = ConversationHarness(replySnapshots: ["途中", "最終"])
        await harness.sut.startConversation()

        await harness.emitCompletedUtterance("猫ちゃん、元気？", at: 10)

        let events = harness.latency.events
        guard case let .began(token, turnID, boundaryAt, lastASRActivityAt, segmentationInterval) = events.first else {
            return XCTFail("Expected a latency turn")
        }
        XCTAssertEqual(turnID, 1)
        XCTAssertEqual(boundaryAt, 11.2, accuracy: 0.0001)
        XCTAssertEqual(lastASRActivityAt, 10)
        XCTAssertEqual(segmentationInterval, 1.2)
        XCTAssertTrue(events.contains(.selected(token: token, path: .fast, at: 11.2)))
        XCTAssertTrue(events.contains(.caption(token: token, at: 11.2)))
        XCTAssertTrue(events.contains(.speech(token: token, at: 11.2)))
        XCTAssertFalse(String(describing: events).contains("元気"))
        XCTAssertFalse(String(describing: events).contains("最終"))
    }

    func testClassifiedAddressUsesClassifiedPath() async {
        let harness = ConversationHarness(classification: .addressed)

        await harness.completeUnengagedTurn("今日どう？", at: 20)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.selected(token: token, path: .classified, at: 21.2)))
        XCTAssertTrue(events.contains(.caption(token: token, at: 21.2)))
        XCTAssertTrue(events.contains(.speech(token: token, at: 21.2)))
    }

    func testWakeOnlyUsesFastLocalCaptionAndSpeechMilestones() async {
        let harness = ConversationHarness()

        await harness.completeTurn("猫ちゃん", at: 0)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.selected(token: token, path: .fast, at: 1.2)))
        XCTAssertTrue(events.contains(.caption(token: token, at: 1.2)))
        XCTAssertTrue(events.contains(.speech(token: token, at: 1.2)))
    }

    func testNotAddressedTurnEndsAsNoResponse() async {
        let harness = ConversationHarness(classification: .notAddressed)

        await harness.completeUnengagedTurn("テレビ消した？", at: 0)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.selected(token: token, path: .classified, at: 1.2)))
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .noResponse, at: 1.2)))
        XCTAssertFalse(events.contains { $0.isVisibleMilestone })
    }

    func testAmbiguousTurnCancelsBeforeLocalClarification() async {
        let harness = ConversationHarness(classification: .ambiguous)

        await harness.completeUnengagedTurn("明日の予定は？", at: 0)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .ambiguous, at: 1.2)))
        XCTAssertFalse(events.contains { $0.isVisibleMilestone })
    }

    func testReplyFailureCancelsTheSelectedTurn() async {
        let harness = ConversationHarness(replySnapshots: [])

        await harness.completeTurn("猫ちゃん、質問", at: 0)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.selected(token: token, path: .fast, at: 1.2)))
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .failure, at: 1.2)))
    }

    func testPauseCancelsAStreamingTurnAsLifecycle() async {
        let harness = ConversationHarness(replySnapshots: nil)
        await harness.sut.startConversation()
        await harness.emit(.finalized("猫ちゃん、質問"), at: 0)
        harness.now.set(1.2)
        let closing = Task { await harness.sut.flushSegmentation(at: 1.2) }
        await harness.reply.waitUntilPromptCount(1)

        let pause = Task { await harness.sut.sceneBecameInactive() }
        await harness.reply.finish()
        await pause.value
        await closing.value

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .lifecycle, at: 1.2)))
    }

    func testTypedReplacementDuringCaptureCloseCancelsVoiceLatency() async {
        let stopGate = ConversationTestGate()
        let harness = ConversationHarness(recognizerStopGate: stopGate)
        await harness.sut.startConversation()
        await harness.emit(.finalized("猫ちゃん、質問"), at: 0)
        harness.now.set(1.2)
        let closing = Task { await harness.sut.flushSegmentation(at: 1.2) }
        await stopGate.waitUntilEntered()

        let typed = Task { await harness.sut.submitTypedText("文字の質問") }
        await stopGate.open()
        await closing.value
        await typed.value

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .typedReplacement, at: 1.2)))
    }

    func testStopTailUpdatesLastASRActivityForTheSameToken() async {
        let harness = ConversationHarness(
            replySnapshots: [],
            recognizerTail: .finalized("追加")
        )
        await harness.sut.startConversation()

        await harness.emitCompletedUtterance("猫ちゃん、質問", at: 5)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.asrActivity(token: token, at: 6.2)))
    }

    func testProvisionalStopTailUpdatesLastASRActivityWithoutChangingReplyText() async {
        let harness = ConversationHarness(
            replySnapshots: [],
            recognizerTail: .provisional("まだ話している")
        )
        await harness.sut.startConversation()

        await harness.emitCompletedUtterance("猫ちゃん、質問", at: 5)

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        let prompts = await harness.reply.prompts
        XCTAssertTrue(events.contains(.asrActivity(token: token, at: 6.2)))
        XCTAssertEqual(prompts, ["質問"])
    }

    func testFinishedWithoutSpeechStartCancelsRemainingLatencyInterval() async {
        let harness = ConversationHarness(
            replySnapshots: ["返事"],
            speakerAutomaticallyFinishes: false
        )
        await harness.sut.startConversation()
        await harness.emit(.finalized("猫ちゃん、質問"), at: 0)
        harness.now.set(1.2)
        let turn = Task { await harness.sut.flushSegmentation(at: 1.2) }
        await harness.speaker.waitUntilTextCount(1)

        await harness.speaker.yield(.finished)
        await harness.speaker.finish()
        await turn.value

        let events = harness.latency.events
        let token = try! XCTUnwrap(events.first?.token)
        XCTAssertTrue(events.contains(.caption(token: token, at: 1.2)))
        XCTAssertFalse(events.contains(.speech(token: token, at: 1.2)))
        XCTAssertTrue(events.contains(.cancelled(token: token, reason: .failure, at: 1.2)))
    }

    func testSignpostTrackerBalancesFourUniqueIntervalsExactlyOnce() {
        let signposts = RecordingConversationLatencySignposter()
        let tracker = ConversationLatencyTracker(signposts: signposts)
        let token = tracker.beginVoiceTurn(
            turnID: 7,
            boundaryAt: 10,
            lastASRActivityAt: 8.8,
            segmentationInterval: 1.2
        )

        tracker.selectPath(.fast, for: token, at: 10.1)
        tracker.firstCaptionVisible(for: token, at: 10.2)
        tracker.firstCaptionVisible(for: token, at: 10.3)
        tracker.speechStarted(for: token, at: 10.4)
        tracker.cancel(token, reason: .failure, at: 10.5)

        XCTAssertEqual(signposts.begins.count, 4)
        XCTAssertEqual(Set(signposts.begins.map(\.handle)).count, 4)
        XCTAssertEqual(signposts.ends.count, 4)
        XCTAssertEqual(Set(signposts.ends.map(\.handle)).count, 4)
        XCTAssertEqual(signposts.ends.filter { $0.outcome == .success }.map(\.metric), [
            .fastFirstCaption,
            .fastSpeechStart
        ])
        XCTAssertEqual(
            Set(signposts.ends.filter { $0.outcome != .success }.map(\.metric)),
            Set([.classifiedFirstCaption, .classifiedSpeechStart])
        )
    }

    func testCancellationBeforePathSelectionBalancesAllIntervals() {
        let signposts = RecordingConversationLatencySignposter()
        let tracker = ConversationLatencyTracker(signposts: signposts)
        let token = tracker.beginVoiceTurn(
            turnID: 1,
            boundaryAt: 2,
            lastASRActivityAt: nil,
            segmentationInterval: 1.2
        )

        tracker.cancel(token, reason: .noResponse, at: 2.1)
        tracker.cancel(token, reason: .failure, at: 2.2)

        XCTAssertEqual(signposts.begins.count, 4)
        XCTAssertEqual(signposts.ends.count, 4)
        XCTAssertTrue(signposts.ends.allSatisfy { $0.outcome == .cancelled(.noResponse) })
    }
}

private extension ConversationLatencyTestEvent {
    var token: ConversationLatencyToken? {
        switch self {
        case .began(let token, _, _, _, _),
             .asrActivity(let token, _),
             .selected(let token, _, _),
             .caption(let token, _),
             .speech(let token, _),
             .cancelled(let token, _, _):
            token
        }
    }

    var isVisibleMilestone: Bool {
        switch self {
        case .caption, .speech:
            true
        default:
            false
        }
    }
}

@MainActor
private final class RecordingConversationLatencySignposter: ConversationLatencySignposting {
    struct Begin: Equatable {
        let handle: ConversationLatencySignpostHandle
        let metric: ConversationLatencyMetric
    }

    struct End: Equatable {
        let handle: ConversationLatencySignpostHandle
        let metric: ConversationLatencyMetric
        let outcome: ConversationLatencySignpostOutcome
    }

    private(set) var begins: [Begin] = []
    private(set) var ends: [End] = []

    func begin(_ metric: ConversationLatencyMetric, context: ConversationLatencySignpostContext) -> ConversationLatencySignpostHandle {
        let handle = ConversationLatencySignpostHandle(rawValue: UUID())
        begins.append(.init(handle: handle, metric: metric))
        return handle
    }

    func end(
        _ handle: ConversationLatencySignpostHandle,
        metric: ConversationLatencyMetric,
        context: ConversationLatencySignpostContext,
        outcome: ConversationLatencySignpostOutcome,
        at timestamp: TimeInterval
    ) {
        ends.append(.init(handle: handle, metric: metric, outcome: outcome))
    }
}
