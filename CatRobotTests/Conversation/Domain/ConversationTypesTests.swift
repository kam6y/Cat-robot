import XCTest
@testable import CatRobot

final class ConversationTypesTests: XCTestCase {
    func testFailurePhaseRetainsActionableCause() {
        XCTAssertEqual(
            ConversationPhase.failed(.modelUnavailable(.modelNotReady)),
            .failed(.modelUnavailable(.modelNotReady))
        )
    }

    func testRecognitionEventsDistinguishProvisionalAndFinalText() {
        XCTAssertNotEqual(
            SpeechRecognitionEvent.provisional("ねこ"),
            .finalized("ねこ")
        )
    }
}
