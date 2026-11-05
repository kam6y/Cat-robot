import XCTest
@testable import CatRobot

final class AudioTurnEndSignalTests: XCTestCase {
    func testStrictThresholdUsesOnlyACompletionProbability() {
        XCTAssertFalse(AudioTurnEndSignal(probability: 0.5, requestedAt: 10).isValid(at: 10))
        XCTAssertTrue(AudioTurnEndSignal(probability: 0.5001, requestedAt: 10).isValid(at: 10))
    }

    func testFreshCompleteSignalRequiresProcessedAudioAndUnchangedSpeech() {
        let gate = AudioTurnEndGate()
        let signal = AudioTurnEndSignal(probability: 0.7, requestedAt: 10, gate: gate)
        XCTAssertTrue(signal.isValid(at: 10))
        XCTAssertTrue(signal.isValid(at: 10.3))
        XCTAssertFalse(signal.isValid(at: 10.301))
        XCTAssertFalse(signal.isValid(at: 9.99))
        XCTAssertTrue(gate.beginAudio())
        XCTAssertFalse(signal.isValid(at: 10.1), "Audio waiting for VAD is not evidence of silence")
        gate.endAudio()
        XCTAssertFalse(signal.isValid(at: 10.1), "Any later raw chunk permanently retires an issued signal")
        gate.noteSpeech()
        XCTAssertFalse(signal.isValid(at: 10.1))
        let next = AudioTurnEndSignal(probability: 0.9, requestedAt: 10.1, gate: gate)
        XCTAssertTrue(next.isValid(at: 10.2))
        gate.invalidate()
        XCTAssertFalse(next.isValid(at: 10.2))
        XCTAssertFalse(gate.beginAudio())
    }

    func testProbabilityAndTimestampMustBeFiniteAndInRange() {
        for p: Float in [.nan, .infinity, -.infinity, -1, 0, 0.5, 1.001] {
            XCTAssertFalse(AudioTurnEndSignal(probability: p, requestedAt: 1).isValid(at: 1.1))
        }
        for t in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(AudioTurnEndSignal(probability: 1, requestedAt: t).isValid(at: 1))
            XCTAssertFalse(AudioTurnEndSignal(probability: 1, requestedAt: 1).isValid(at: t))
        }
    }
}
