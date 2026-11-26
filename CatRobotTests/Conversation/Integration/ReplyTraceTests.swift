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
            _ = try await MoveHeadTool(motion: NoopRobotMotionController()).call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
            _ = try await ExpressTool(expressions: NoopFaceExpressionController()).call(arguments: .init(expression: "happy", hold_seconds: 3))
            _ = try await LookTool(look: NoopLookController()).call(arguments: .init(purpose: "private-camera-purpose"))
        }
        let events = sink.events
        XCTAssertEqual(events.map { $0.point.rawValue }, ["toolStarted", "toolFinished", "toolStarted", "toolFinished", "toolStarted", "toolFinished"])
        let encoded = try JSONEncoder().encode(events)
        let rows = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        XCTAssertEqual(rows.compactMap { $0["tool"] as? String }, ["move_head", "move_head", "express", "express", "look", "look"])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-camera-purpose"))
        XCTAssertEqual(Set(events.map(\.id)), [trace.id])
    }

    func testFailingClientToolStillClosesTimingInterval() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        do {
            _ = try await ReplyTraceContext.$current.withValue(trace) {
                try await ReplyTraceContext.withTool(.look) { () async throws -> Int in throw TraceStorageFailure.failed }
            }
            XCTFail("Expected the tool failure")
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
        for outcome in [ReplyTraceOutcome.noResponse, .generationFailure, .speechFailure, .success] {
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
}

private enum TraceStorageFailure: Error { case failed }
