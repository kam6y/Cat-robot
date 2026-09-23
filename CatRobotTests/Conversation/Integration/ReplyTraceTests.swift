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
    func testGemmaOwnedTaskKeepsTraceThroughGenerationAndSave() async throws {
        let sink = RecordingReplyTraceSink()
        let trace = ReplyTrace(sink: sink, now: { 0 })
        let service = GemmaConversationService(runtime: StubGemmaRuntime())
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
}
