import XCTest
@testable import CatRobot

final class ConversationIdlePresentationTests: XCTestCase {
    func testSleepingOverridesHeldExpressionLookCaptionAndTypedInput() {
        var state = ConversationViewState.listening
        state.inactivity = .sleeping
        state.heldExpression = .happy
        state.isLooking = true
        state.caption = "前の返事"
        XCTAssertEqual(state.faceExpression.rawValue, "sleeping")
        XCTAssertNil(state.accessibleReply)
        XCTAssertEqual(state.displayedActivityStatus, "待機中・タップで起こす")
        XCTAssertFalse(state.allowsTypedSubmission)
    }

    func testSleepyOnlyOverridesTheIdleListeningFace() {
        var state = ConversationViewState.listening
        state.inactivity = .sleepy
        state.heldExpression = .happy
        XCTAssertEqual(state.faceExpression, .sleepy)
        state.phase = .thinking
        XCTAssertEqual(state.faceExpression, .happy)
        state.inactivity = .awake
        state.phase = .listening
        XCTAssertEqual(state.faceExpression, .happy)
    }

    func testSleepingAnnouncementAndAccessibleWakeAction() {
        var sleeping = ConversationViewState.listening
        sleeping.inactivity = .sleeping
        XCTAssertEqual(ConversationAnnouncementPolicy.announcement(from: .listening, to: sleeping), "待機中・タップで起こす")
        XCTAssertNil(ConversationAnnouncementPolicy.announcement(from: sleeping, to: sleeping))
        let accessibility = ConversationAccessibility(phase: .paused, inactivity: .sleeping)
        XCTAssertEqual(accessibility.listeningAction, "猫を起こす")
        XCTAssertEqual(accessibility.microphoneValue, "停止中")
    }
}
