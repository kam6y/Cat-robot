import XCTest
@testable import CatRobot

final class ConversationAccessibilityTests: XCTestCase {
    func testPausedControlHasExplicitLabelAndValue() {
        let labels = ConversationAccessibility(phase: .paused)

        XCTAssertEqual(labels.listeningAction, "聞き取りを再開")
        XCTAssertEqual(labels.microphoneValue, "一時停止中")
    }

    func testClarificationIsAvailableWithoutMotion() {
        let labels = ConversationAccessibility(phase: .clarifying)

        XCTAssertEqual(labels.assistantStatus, "聞き返しています")
    }
}
