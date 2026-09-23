import XCTest
@testable import CatRobot

final class ConversationMemoryPresentationTests: XCTestCase {
    func testSaveWarningAllowsConversationButRestoreAndForgetErrorsBlockIt() {
        let unsaved = ConversationMemoryPresentation(state: .unsaved)
        XCTAssertFalse(unsaved.blocksConversation)
        XCTAssertTrue(unsaved.canRetry)
        XCTAssertNotNil(unsaved.message)
        for state in [ConversationMemoryState.restoreFailed(.invalidData), .forgetFailed(.deleteFailed), .forgetting] {
            XCTAssertTrue(ConversationMemoryPresentation(state: state).blocksConversation)
        }
        XCTAssertFalse(ConversationMemoryPresentation(state: .unsupported).supportsForget)
    }
    func testWarningIsAnnouncedOnlyOnceNotForEveryCaption() {
        var old = ConversationViewState.idle
        old.phase = .paused
        var changed = old
        changed.memoryState = .unsaved
        XCTAssertNotNil(ConversationAnnouncementPolicy.announcement(from: old, to: changed))
        old = changed
        changed.caption = "次の文字"
        XCTAssertNil(ConversationAnnouncementPolicy.announcement(from: old, to: changed))
    }
}
