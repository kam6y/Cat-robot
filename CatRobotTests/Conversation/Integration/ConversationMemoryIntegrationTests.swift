import Foundation
import XCTest
@testable import CatRobot

actor FakeConversationMemoryManager: ConversationMemoryManaging {
    private var state: ConversationMemoryState
    private var listeners: [AsyncStream<ConversationMemoryState>.Continuation] = []
    private(set) var forgets = 0
    var failsForget = false
    init(state: ConversationMemoryState = .ready) { self.state = state }
    func setForgetFailure(_ value: Bool) { failsForget = value }
    func prepareMemory() throws {
        if case .restoreFailed(let error) = state { throw error }
        if case .forgetFailed = state { throw ConversationMemoryError.deleteFailed }
    }
    func memoryState() -> ConversationMemoryState { state }
    func memoryUpdates() -> AsyncStream<ConversationMemoryState> {
        let (stream, continuation) = AsyncStream<ConversationMemoryState>.makeStream()
        listeners.append(continuation); continuation.yield(state)
        return stream
    }
    func publish(_ value: ConversationMemoryState) {
        state = value
        for listener in listeners { listener.yield(value) }
    }
    func retryMemoryOperation() async throws {
        if case .forgetFailed = state { try await forgetConversation() }
        else { publish(.ready) }
    }
    func forgetConversation() async throws {
        forgets += 1
        if failsForget { publish(.forgetFailed(.deleteFailed)); throw ConversationMemoryError.deleteFailed }
        publish(.ready)
    }
}

@MainActor
final class ConversationMemoryIntegrationTests: XCTestCase {
    func testConfirmedCoordinatorDeletionSurvivesDialogDismissal() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("覚えて")
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        let actions = coordinator.makeActions(openSettings: {})
        actions.requestForget()
        actions.confirmForget()
        // SwiftUI dismisses its dialog before the scheduled action task runs.
        actions.cancelForget()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.caption, "")
        let forgets = await memory.forgets
        XCTAssertEqual(forgets, 1)
        await harness.sut.shutdown()
    }

    func testRestoreFailureBlocksVoiceAndTypedReply() async {
        for typed in [false, true] {
            let memory = FakeConversationMemoryManager(state: .restoreFailed(.invalidData))
            let harness = ConversationHarness(memory: memory)
            if typed { await harness.sut.submitTypedText("こんにちは") }
            else { await harness.sut.startConversation() }
            XCTAssertEqual(harness.sut.viewState.phase, .paused)
            XCTAssertEqual(harness.sut.viewState.memoryState, .restoreFailed(.invalidData))
            XCTAssertFalse(harness.calls.values.contains(.startRecognizer))
            let prompts = await harness.reply.prompts
            XCTAssertTrue(prompts.isEmpty)
            await harness.sut.shutdown()
        }
    }
    func testUnsavedWarningSurvivesReplyAndPauseAndRetry() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("こんにちは")
        XCTAssertFalse(harness.sut.viewState.caption.isEmpty)
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        await harness.sut.sceneBecameInactive()
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        await harness.sut.retryMemoryOperation()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }
    func testWarningSurvivesGenerationFailure() async {
        let memory = FakeConversationMemoryManager(state: .unsaved)
        let harness = ConversationHarness(memory: memory, replySnapshots: nil)
        let turn = Task { await harness.sut.submitTypedText("こんにちは") }
        await harness.reply.waitUntilPromptCount(1)
        await harness.reply.fail(.modelGenerationFailed)
        await turn.value
        XCTAssertEqual(harness.sut.viewState.phase, .failed(.modelGenerationFailed))
        XCTAssertEqual(harness.sut.viewState.memoryState, .unsaved)
        XCTAssertNotNil(ConversationMemoryPresentation(state: harness.sut.viewState.memoryState).message)
        await harness.sut.shutdown()
    }

    func testForgetConfirmationAndSuccessfulForgetClearVisibleText() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("こんにちは")
        harness.sut.updateTypedText("送信前の文")
        harness.sut.requestForgetConversation()
        harness.sut.cancelForgetConversation()
        let before = await memory.forgets
        XCTAssertEqual(before, 0)
        XCTAssertFalse(harness.sut.viewState.caption.isEmpty)
        harness.sut.requestForgetConversation()
        await harness.sut.confirmForgetConversation()
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.typedText, "")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertNotNil(harness.sut.viewState.memoryNotice)
        let after = await memory.forgets
        XCTAssertEqual(after, 1)
        await harness.sut.shutdown()
    }
    func testFailedForgetDoesNotAnnounceSuccessAndRetryClearsText() async {
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory)
        await harness.sut.submitTypedText("覚えて")
        await memory.setForgetFailure(true)
        harness.sut.requestForgetConversation()
        await harness.sut.confirmForgetConversation()
        XCTAssertNil(harness.sut.viewState.memoryNotice)
        XCTAssertEqual(harness.sut.viewState.memoryState, .forgetFailed(.deleteFailed))
        XCTAssertFalse(harness.sut.viewState.allowsTypedSubmission)
        await memory.setForgetFailure(false)
        await harness.sut.retryMemoryOperation()
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }
}
