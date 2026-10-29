import Foundation
import XCTest
@testable import CatRobot

final class RecordingReplyTraceSink: ReplyTraceSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReplyTraceEvent] = []
    var events: [ReplyTraceEvent] { lock.withLock { storage } }
    func record(_ event: ReplyTraceEvent) { lock.withLock { storage.append(event) } }
}

final class ReplyTraceTests: XCTestCase {
    @MainActor
    func testClientToolTimingRecordsTypedNamesWithoutPrivateArguments() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 12.5 })
        try await ReplyTraceContext.$current.withValue(trace) {
            _ = try await RememberTool(memory: RememberToolTests.Writer()).call(arguments: .init(fact: "private-memory-content", category: "preference"))
            _ = try await MoveHeadTool(motion: NoopRobotMotionController()).call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
            _ = try await ExpressTool(expressions: NoopFaceExpressionController()).call(arguments: .init(expression: "happy", hold_seconds: 3))
            _ = try await LookTool(look: NoopLookController()).call(arguments: .init(purpose: "private-camera-purpose"))
        }
        let events = sink.events
        XCTAssertEqual(events.map { $0.point.rawValue }, ["toolStarted", "toolFinished", "toolStarted", "toolFinished", "toolStarted", "toolFinished", "toolStarted", "toolFinished"])
        let encoded = try JSONEncoder().encode(events)
        let rows = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        XCTAssertEqual(rows.compactMap { $0["tool"] as? String }, ["remember", "remember", "move_head", "move_head", "express", "express", "look", "look"])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-memory-content"))
        XCTAssertFalse(text.contains("private-camera-purpose"))
        XCTAssertEqual(Set(events.map(\.id)), [trace.id])
    }

    func testFailingClientToolStillClosesTimingInterval() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        do {
            _ = try await ReplyTraceContext.$current.withValue(trace) {
                try await RememberTool(memory: TraceFailingWriter()).call(arguments: .init(fact: "not-logged", category: "other"))
            }
            XCTFail("Expected storage failure")
        } catch { XCTAssertTrue(error is TraceStorageFailure) }
        XCTAssertEqual(sink.events.map { $0.point.rawValue }, ["toolStarted", "toolFinished"])
        XCTAssertEqual(sink.events.last?.outcome, .generationFailure)
    }

    @MainActor
    func testCancelledClientToolClosesTimingAsCancelled() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let tool = LookTool(look: NoopLookController())
        let task = Task {
            try await ReplyTraceContext.$current.withValue(trace) {
                try await tool.call(arguments: .init(purpose: "private-cancelled-purpose"))
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(sink.events.map { $0.point.rawValue }, ["toolStarted", "toolFinished"])
        XCTAssertEqual(sink.events.last?.outcome, .cancelled)
    }

    func testFirstCaptionAndTerminalAreRecordedOnce() {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 12.5 })
        trace.mark(.firstCaption)
        trace.mark(.firstCaption)
        trace.finish(.cancelled)
        trace.finish(.success)
        XCTAssertEqual(sink.events.map(\.point), [.firstCaption, .finished])
        XCTAssertEqual(sink.events.last?.outcome, .cancelled)
        XCTAssertEqual(sink.events.first?.at, 12.5)
    }
    func testSpeechFallbackIsDistinctAndCannotBeCountedAgain() {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        trace.mark(.speechStarted, part: .first, source: .willSpeakFallback)
        trace.mark(.speechStarted, part: .first, source: .started)
        trace.mark(.speechStarted, part: .remainder, source: .started)
        XCTAssertEqual(sink.events.count, 2)
        XCTAssertEqual(sink.events.first?.source, .willSpeakFallback)
    }
    func testLateIntervalEndAcceptedButNewMilestonesSuppressed() {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        trace.mark(.saveStarted)
        trace.finish(.cancelled)
        trace.mark(.firstCaption)
        trace.mark(.saveFinished, outcome: .success)
        trace.mark(.saveFinished, outcome: .success)
        trace.mark(.sessionStarted)
        XCTAssertEqual(sink.events.map(\.point), [.saveStarted, .finished, .saveFinished])
    }
    func testRepeatedIntervalsAndAllOutcomesHaveOneTerminal() throws {
        for outcome in [ReplyTraceOutcome.noResponse, .ambiguous, .generationFailure, .speechFailure, .success] {
            let sink = RecordingReplyTraceSink()
            let trace = ReplyTrace(sink: sink, now: { 0 })
            for _ in 0..<2 { trace.mark(.sessionStarted); trace.mark(.sessionFinished, outcome: .success) }
            trace.finish(outcome)
            trace.finish(.cancelled)
            XCTAssertEqual(sink.events.count, 5)
            XCTAssertEqual(sink.events.last?.outcome, outcome)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sink.events[0])) as! [String: Any]
            XCTAssertEqual(Set(json.keys), ["id", "point", "at"])
        }
    }
    func testClaudeOwnedTaskKeepsTraceThroughGenerationAndSave() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let service = makeClaudeService()
        try await ReplyTraceContext.$current.withValue(trace) {
            let stream = try await service.streamReply(to: "private prompt")
            for try await _ in stream {}
        }
        let events = sink.events
        XCTAssertEqual(Set(events.map(\.id)), [trace.id])
        XCTAssertEqual(events.map(\.point), [.sessionStarted, .sessionFinished, .generationFinished,
                                             .saveStarted, .saveFinished, .streamFinished])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("private prompt"))
    }
}

private enum TraceStorageFailure: Error { case failed }
private actor TraceFailingWriter: LongTermMemoryWriting {
    func remember(_ text: String, category: LongTermFactCategory) async throws -> LongTermMemoryWriteResult {
        throw TraceStorageFailure.failed
    }
}
