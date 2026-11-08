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

    func testOwnerMatchesOnlyItsGenerationAndActiveTurnOrCapture() {
        let cases: [(owner: ConversationTurnOwner, generation: UInt64, turnID: UInt64?, captureID: UInt64?, expected: Bool)] = [
            (.lifecycle(generation: 2), 2, nil, nil, true),
            (.lifecycle(generation: 2), 2, 7, 5, true),
            (.lifecycle(generation: 2), 3, 7, 5, false),
            (.turn(generation: 2, turnID: 7), 2, 7, nil, true),
            (.turn(generation: 2, turnID: 7), 2, 7, 5, true),
            (.turn(generation: 2, turnID: 7), 3, 7, 5, false),
            (.turn(generation: 2, turnID: 7), 2, 6, 5, false),
            (.turn(generation: 2, turnID: 7), 2, nil, 7, false),
            (.capture(generation: 2, captureID: 5), 2, nil, 5, true),
            (.capture(generation: 2, captureID: 5), 2, 7, 5, true),
            (.capture(generation: 2, captureID: 5), 3, 7, 5, false),
            (.capture(generation: 2, captureID: 5), 2, 7, 4, false),
            (.capture(generation: 2, captureID: 5), 2, 5, nil, false),
        ]
        for (index, row) in cases.enumerated() {
            XCTAssertEqual(row.owner.isOwned(generation: row.generation, turnID: row.turnID, captureID: row.captureID),
                           row.expected, "row \(index)")
        }
    }

    private func cancellations(in latency: FakeConversationLatencyTracker) -> [ConversationLatencyCancellation] {
        latency.events.compactMap {
            if case .cancelled(_, let reason, _) = $0 { reason } else { nil }
        }
    }
}
