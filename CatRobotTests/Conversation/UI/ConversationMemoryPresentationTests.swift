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
    /// Hermes に前の会話が無いときの出口は「新しい会話を始める」。新しい会話は削除や忘却を意味しない。
    func testRestoreFailureOffersANewConversationWithoutClaimingDeletion() {
        let failed = ConversationMemoryPresentation(state: .restoreFailed(.unavailable))
        XCTAssertTrue(failed.offersNewConversation)
        let message = failed.message ?? ""
        XCTAssertTrue(message.contains("新しい会話"), message)
        XCTAssertFalse(message.contains("消") || message.contains("削除"), message)
        for state in [ConversationMemoryState.ready, .unsaved, .loading, .unsupported] {
            XCTAssertFalse(ConversationMemoryPresentation(state: state).offersNewConversation, "\(state)")
        }
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
