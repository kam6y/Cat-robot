import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class ClaudePlaybackMemoryTests: XCTestCase {
    func testCancellingPlaybackMidStreamDoesNotCommitAndNextTurnWorks() async throws {
        let held = ScriptedSessionClient(chunks: nil)
        let store = InMemoryConversationMemoryStore()
        let sut = makeClaudeService(StubSessionFactory(scripts: [held, ScriptedSessionClient(chunks: ["次の返事。"])]), store: store)
        let speaker = FakeSpeechSpeaker(automaticallyFinishes: true, prepareError: nil, speakError: nil, log: ConversationTestCallLog())
        let coordinator = ReplyPlaybackCoordinator(reply: sut, speaker: speaker, mode: .sentencePrefetch)
        let run = Task { try await coordinator.run(prompt: "長い話", trace: nil, onUpdate: { _ in }) }
        await held.waitUntilStarted()
        held.yield("一文目。")
        await coordinator.cancelAndWait()
        _ = try? await run.value
        held.finish()
        let saved = await store.load()
        XCTAssertNil(saved)
        let next = try await coordinator.run(prompt: "次", trace: nil, onUpdate: { _ in })
        XCTAssertEqual(next, "次の返事。")
    }
    func testSaveWarningDoesNotFailTheSpokenReply() async throws {
        let store = MemoryStoreFake()
        await store.setSaveFailure(true)
        let sut = makeClaudeService(store: store)
        let speaker = FakeSpeechSpeaker(automaticallyFinishes: true, prepareError: nil, speakError: nil, log: ConversationTestCallLog())
        let coordinator = ReplyPlaybackCoordinator(reply: sut, speaker: speaker, mode: .completeResponse)
        let text = try await coordinator.run(prompt: "保存できない", trace: nil, onUpdate: { _ in })
        XCTAssertEqual(text, "にゃん。")
        let state = await sut.memoryState()
        XCTAssertEqual(state, .unsaved)
    }
}
