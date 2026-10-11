import XCTest
@testable import CatRobot

@MainActor
final class ConversationNewSessionTests: XCTestCase {
    func testStartNewConversationResetsReplyServiceClearsCaptionAndPauses() async {
        let harness = ConversationHarness(memory: FakeConversationMemoryManager())
        await harness.sut.submitTypedText("こんにちは")
        XCTAssertEqual(harness.sut.viewState.caption, "わかったよ")
        await harness.sut.startNewConversation()
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "新しい会話を始めました")
        await harness.sut.shutdown()
    }
    func testCoordinatorActionReachesTheViewModel() async {
        let harness = ConversationHarness(memory: FakeConversationMemoryManager())
        let coordinator = ConversationAppCoordinator(viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        coordinator.makeActions(openSettings: {}).startNewConversation()
        await coordinator.waitForOperations()
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 1)
        await harness.sut.shutdown()
    }

    // --- 境界: 重複操作・長期/会話記憶の非削除・shutdown 後・返答中 ---

    func testStartNewConversationIgnoresDuplicatesAndKeepsConversationMemory() async {
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let memory = FakeConversationMemoryManager()
        let harness = ConversationHarness(memory: memory, replyResetGate: gate)
        let first = Task { await harness.sut.startNewConversation() }
        await gate.waitUntilEntered()               // reset の完了待ちで停止中
        await harness.sut.startNewConversation()    // 進行中なので何もしない
        await gate.open()
        await first.value
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 1, "重複した操作は reset を重ねない")
        let forgets = await memory.forgets
        XCTAssertEqual(forgets, 0, "新しい会話は forgetConversation を呼ばない")
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "新しい会話を始めました")
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        await harness.sut.shutdown()
    }

    func testStartNewConversationAfterShutdownDoesNothing() async {
        let harness = ConversationHarness(memory: FakeConversationMemoryManager())
        await harness.sut.shutdown()
        let before = await harness.reply.resetCount
        await harness.sut.startNewConversation()
        let after = await harness.reply.resetCount
        XCTAssertEqual(after, before)
        XCTAssertNil(harness.sut.viewState.memoryNotice)
    }

    func testStartNewConversationDuringReplyStopsItThenResets() async {
        let harness = ConversationHarness(memory: FakeConversationMemoryManager(), replySnapshots: nil)
        let turn = Task { await harness.sut.submitTypedText("考え中") }
        await harness.reply.waitUntilPromptCount(1) // 返答の生成中
        await harness.sut.startNewConversation()
        await turn.value
        let resets = await harness.reply.resetCount
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(harness.sut.viewState.phase, .paused)
        XCTAssertEqual(harness.sut.viewState.caption, "")
        XCTAssertEqual(harness.sut.viewState.memoryNotice, "新しい会話を始めました")
        await harness.sut.shutdown()
    }
}
