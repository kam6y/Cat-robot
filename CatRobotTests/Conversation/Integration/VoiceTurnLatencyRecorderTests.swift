import XCTest
@testable import CatRobot

@MainActor
final class VoiceTurnLatencyRecorderTests: XCTestCase {
    func testStaleOwnersCannotEndTheCurrentTurnMeasurement() {
        let latency = FakeConversationLatencyTracker()
        let sink = RecordingReplyTraceSink()
        let recorder = VoiceTurnLatencyRecorder(latency: latency, traceSink: sink, now: { 10 })
        recorder.begin(generation: 2, captureID: 5, turnID: 7,
                       boundaryAt: 9, lastASRActivityAt: 8.5, segmentationInterval: 1.2)

        recorder.cancel(reason: .failure, ifOwnedBy: .turn(generation: 2, turnID: 6))
        recorder.cancel(reason: .failure, ifOwnedBy: .capture(generation: 2, captureID: 4))
        recorder.cancel(reason: .failure, ifOwnedBy: .lifecycle(generation: 1))

        XCTAssertNotNil(recorder.trace)
        XCTAssertTrue(cancellations(in: latency).isEmpty)
        XCTAssertFalse(sink.events.contains { $0.point == .finished })
    }

    func testOwningCaptureEndsTheMeasurementOnceAsAGenerationFailure() {
        let latency = FakeConversationLatencyTracker()
        let sink = RecordingReplyTraceSink()
        let recorder = VoiceTurnLatencyRecorder(latency: latency, traceSink: sink, now: { 10 })
        recorder.begin(generation: 2, captureID: 5, turnID: 7,
                       boundaryAt: 9, lastASRActivityAt: nil, segmentationInterval: 1.2)

        recorder.cancel(reason: .failure, ifOwnedBy: .capture(generation: 2, captureID: 5))
        recorder.cancel(reason: .failure, ifOwnedBy: .capture(generation: 2, captureID: 5))

        XCTAssertNil(recorder.trace)
        XCTAssertEqual(cancellations(in: latency), [.failure])
        XCTAssertEqual(sink.events.filter { $0.point == .finished }.map(\.outcome), [.generationFailure])
    }

    private func cancellations(in latency: FakeConversationLatencyTracker) -> [ConversationLatencyCancellation] {
        latency.events.compactMap {
            if case .cancelled(_, let reason, _) = $0 { reason } else { nil }
        }
    }
}
