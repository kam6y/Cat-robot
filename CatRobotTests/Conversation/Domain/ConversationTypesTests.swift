import XCTest
@testable import CatRobot

final class ConversationTypesTests: XCTestCase {
    func testFailurePhaseRetainsActionableCause() {
        XCTAssertEqual(
            ConversationPhase.failed(.modelUnavailable(.hermesUnauthorized)),
            .failed(.modelUnavailable(.hermesUnauthorized))
        )
    }

    func testFailurePhaseRetainsSpeechSynthesisCause() {
        XCTAssertEqual(
            ConversationPhase.failed(.speechSynthesisFailed),
            .failed(.speechSynthesisFailed)
        )
    }

    func testRecognitionEventsDistinguishProvisionalAndFinalText() {
        XCTAssertNotEqual(
            SpeechRecognitionEvent.provisional("ねこ"),
            .finalized("ねこ")
        )
    }
}
