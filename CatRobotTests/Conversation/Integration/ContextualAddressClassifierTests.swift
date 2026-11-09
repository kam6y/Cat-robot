import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ContextualAddressClassifierTests: XCTestCase {
    private func turn(_ userCount: Int, _ catCount: Int, tag: String) -> ConversationMemoryTurn {
        .init(prompt: String(repeating: tag, count: userCount), response: String(repeating: "答", count: catCount))
    }

    func testKeepsNewestTurnsWithinLimitByWholeTurns() {
        // 5 往復 × 1,000 字。新しい 4 往復でちょうど 4,000 字なので 4 往復を残し、最古を除く。
        let turns = ["A", "B", "C", "D", "E"].map { turn(500, 500, tag: $0) }
        let kept = ContextualAddressClassifier.contextTurns(turns, clarification: nil, characterLimit: 4_000)
        XCTAssertEqual(kept, Array(turns[1...]))
        // 4 番目に新しい往復が 1 字長いと合計 4,001 字になるので、その往復から含めない。
        var longer = turns
        longer[1] = turn(501, 500, tag: "B")
        let keptLonger = ContextualAddressClassifier.contextTurns(longer, clarification: nil, characterLimit: 4_000)
        XCTAssertEqual(keptLonger, Array(longer[2...]))
    }

    func testOversizedNewestTurnYieldsEmptyContext() {
        let oversized = [turn(100, 100, tag: "A"), turn(2_001, 2_000, tag: "B")]
        XCTAssertEqual(ContextualAddressClassifier.contextTurns(oversized, clarification: nil, characterLimit: 4_000), [])
        let fits = [turn(100, 100, tag: "A"), turn(2_000, 2_000, tag: "B")]
        XCTAssertEqual(ContextualAddressClassifier.contextTurns(fits, clarification: nil, characterLimit: 4_000), [fits[1]])
    }

    func testDropsTrailingClarificationPairOnlyWhenItMatches() {
        let older = ConversationMemoryTurn(prompt: "ねこ、おはよう", response: "おはよう！")
        let pair = ConversationMemoryTurn(prompt: "今日の天気はどう？", response: ClarificationContext.question)
        let other = ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")
        let pending = ClarificationContext(originalUtterance: "今日の天気はどう？")
        XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, pair], clarification: pending, characterLimit: 4_000), [older])
        XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, other], clarification: pending, characterLimit: 4_000), [older, other])
        XCTAssertEqual(ContextualAddressClassifier.contextTurns([older, pair], clarification: nil, characterLimit: 4_000), [older, pair])
    }

    func testReadsHistoryOnceAndPassesContextToBase() async throws {
        let turns = [ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")]
        let history = FakeConversationHistory(turns: turns)
        let base = FakeAddressClassifier(result: .addressed, log: ConversationTestCallLog())
        let sut = ContextualAddressClassifier(base: base, history: history)

        let target = try await sut.classify(.init(utterance: "それで、あしたは？"))

        let requests = await base.requests, reads = await history.readCount
        XCTAssertEqual(target, .addressed)
        XCTAssertEqual(requests, [.init(utterance: "それで、あしたは？", recentTurns: turns)])
        XCTAssertEqual(reads, 1)
    }

    func testCancellationWhileReadingHistorySkipsBase() async {
        let gate = ConversationTestGate()
        let history = FakeConversationHistory(turns: [], gate: gate)
        let base = FakeAddressClassifier(result: .addressed, log: ConversationTestCallLog())
        let sut = ContextualAddressClassifier(base: base, history: history)

        // gate の待機は無期限なので、history の読み取り回数を有限時間で待ち、失敗しても必ず cancel → open → join で後始末する。
        let task = Task { try await sut.classify(.init(utterance: "ねこ、元気？")) }
        let entered = await pollUntil { await history.readCount == 1 }
        task.cancel()
        await gate.open()
        let result = await task.result

        let requests = await base.requests
        XCTAssertTrue(entered, "the decorator reads the history before anything else")
        XCTAssertEqual(requests, [], "a classification cancelled while reading history must not reach Haiku")
        switch result {
        case .success: XCTFail("a cancelled classification must not produce a target")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError || (error as? ConversationServiceError) == .cancelled, "\(error)")
        }
    }

    /// gate で止まる処理を await すると先へ進めないので、ターンも操作も Task で起動し、同期の無効化（phase == .paused）を見てから gate を開く。
    /// 待機はすべて有限時間（pollUntil）で、assertion が失敗しても gate を開いて join し、hang させない。
    func testLifecycleActionsWhileHistoryIsGatedNeverReachHaiku() async {
        let turns = [ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")]
        for action in ["pause", "newConversation", "forget", "shutdown"] {
            let gate = ConversationTestGate()
            let history = FakeConversationHistory(turns: turns, gate: gate)
            let base = FakeAddressClassifier(result: .addressed, log: ConversationTestCallLog())
            let memory = FakeConversationMemoryManager()
            let harness = ConversationHarness(memory: memory,
                                              classifierOverride: ContextualAddressClassifier(base: base, history: history))
            await harness.sut.startConversation()
            let ready = await harness.waitUntil { harness.sut.viewState.memoryState == .ready }   // forget は .unsupported だと何もしない
            let turn = Task { await harness.emitCompletedUtterance("ねこ、元気？", at: 0) }   // history.recentTurns() で止まる
            let entered = await harness.waitUntil { await history.readCount == 1 }
            let lifecycle = Task {
                switch action {
                case "pause": await harness.sut.toggleListening()
                case "newConversation": await harness.sut.startNewConversation()
                case "forget": await harness.sut.forgetConversation()
                default: await harness.sut.shutdown()
                }
            }
            let paused = await harness.waitUntil { harness.sut.viewState.phase == .paused }   // invalidateForPause は同期
            await gate.open()   // 失敗時も gate を開いて join し、hang させない
            await turn.value
            await lifecycle.value
            XCTAssertTrue(ready, action)
            XCTAssertTrue(entered, action)
            XCTAssertTrue(paused, action)

            let requests = await base.requests, texts = await harness.speaker.texts
            XCTAssertEqual(requests, [], action)
            XCTAssertEqual(texts, [], action)
            XCTAssertFalse(harness.calls.values.contains(.generateReply("ねこ、元気？")), action)
            XCTAssertNil(harness.sut.viewState.errorMessage, action)
            if action != "shutdown" { await harness.sut.shutdown() }
        }
    }
}
