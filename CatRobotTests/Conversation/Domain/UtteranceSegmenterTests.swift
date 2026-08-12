import XCTest
@testable import CatRobot

final class UtteranceSegmenterTests: XCTestCase {
    func testFinalTextClosesAfterSilence() {
        var sut = UtteranceSegmenter()
        sut.receive(.provisional("ねこ、"), at: 0)
        sut.receive(.finalized("ねこ、今日どう？"), at: 0.4)
        XCTAssertNil(sut.utteranceIfReady(at: 1.59))
        XCTAssertEqual(sut.utteranceIfReady(at: 1.6), "ねこ、今日どう？")
        XCTAssertNil(sut.utteranceIfReady(at: 2.0))
    }

    func testMaximumDurationClosesNoisyTurn() {
        var sut = UtteranceSegmenter()
        sut.receive(.finalized("長い話"), at: 5)
        sut.receive(.provisional("まだ続く"), at: 24.9)
        XCTAssertEqual(sut.utteranceIfReady(at: 25), "長い話")
    }

    func testMaximumDurationExpiresProvisionalOnlyTurnBeforeNextFinalizedTurn() {
        var sut = UtteranceSegmenter()
        sut.receive(.provisional("雑音"), at: 5)
        sut.receive(.provisional("まだ雑音"), at: 24.9)

        XCTAssertNil(sut.utteranceIfReady(at: 25))

        sut.receive(.finalized("新しい発話"), at: 26)
        XCTAssertNil(sut.utteranceIfReady(at: 26))
        XCTAssertNil(sut.utteranceIfReady(at: 27.19))
        XCTAssertEqual(sut.utteranceIfReady(at: 27.200_001), "新しい発話")
    }
}
