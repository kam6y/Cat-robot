import XCTest
@testable import CatRobot

/// 同じ会話が回復しないときの出口。通常の画面から「新しい会話を始める」で新しい Hermes の session へ移れる。
/// 新しい会話は session id を替えるだけで、前の run の停止・履歴の削除・忘却を意味しない。
@MainActor
final class HermesConversationExitTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443")!,
                                              credential: HermesCredential(apiKey: "client-key"))

    private func makeService(_ server: FakeHermesServer, records: InMemoryHermesSessionRecordStore) -> HermesConversationService {
        let resolved = connection
        let ids = ExitTestSequence(["catrobot-s1", "catrobot-s2", "catrobot-s3"])
        return HermesConversationService(connection: { resolved }, transport: server, records: records, clock: SteppingHermesClock(),
                                         timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: .seconds(5),
                                                                          submitRetryDelay: .seconds(1)),
                                         makeSessionID: { ids.next() }, makeIdempotencyKey: { UUID() })
    }

    private func makeCoordinator(_ harness: ConversationHarness) -> ConversationAppCoordinator {
        ConversationAppCoordinator(viewModel: harness.sut,
                                   wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
    }

    /// installed Hermes の unknown run が同じ session の後続を止めても、期限切れの繰り返しで終わらない。
    func testAnUnansweredTurnOffersANewConversationThatMovesToAFreshSession() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [hermesRun("run-1", "running")],
                                              "run-2": [hermesRun("run-2", "completed", output: "やあ")]])
        let records = InMemoryHermesSessionRecordStore()
        let hermes = makeService(server, records: records)
        let harness = ConversationHarness(replyOverride: hermes, memory: hermes)
        let coordinator = makeCoordinator(harness)
        let actions = coordinator.makeActions(openSettings: { XCTFail("the iOS Settings app is not the exit") })

        await harness.sut.submitTypedText("ねえ")
        let failed = await harness.waitUntil(timeout: .seconds(3)) { harness.sut.viewState.phase == .failed(.replyTimedOut) }
        XCTAssertTrue(failed, "\(harness.sut.viewState.phase)")
        let exit = try XCTUnwrap(harness.sut.viewState.recoveries.first { $0.action == .startNewConversation })
        XCTAssertEqual(exit.title, "新しい会話を始める")

        actions.performRecovery(exit.action)
        await coordinator.waitForOperations()
        let notice = try XCTUnwrap(harness.sut.viewState.memoryNotice)
        XCTAssertFalse(notice.contains("削除") || notice.contains("消"), "a new conversation does not claim deletion: \(notice)")

        await harness.sut.submitTypedText("もう一度")
        let answered = await harness.waitUntil(timeout: .seconds(3)) { harness.sut.viewState.caption == "やあ" }
        XCTAssertTrue(answered, harness.sut.viewState.caption)
        let posts = await server.runPosts
        XCTAssertEqual(posts.compactMap { $0.jsonBody?["session_id"] }, ["catrobot-s1", "catrobot-s2"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1"], "the old run is not claimed stopped")
        await harness.sut.shutdown()
    }

    /// Hermes に前の session が無い（restoreFailed）ときも、同じ出口で新しい session へ移って会話を続けられる。
    func testALostSessionOffersANewConversationThatUnblocksTheConversation() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "はじめまして")]],
                                      history: [.json(404, #"{"error":{"code":"session_not_found"}}"#)])
        let hermes = makeService(server, records: records)
        let harness = ConversationHarness(replyOverride: hermes, memory: hermes)
        let coordinator = makeCoordinator(harness)

        await harness.sut.submitTypedText("こんにちは")
        let blocked = await harness.waitUntil(timeout: .seconds(3)) { harness.sut.viewState.memoryState == .restoreFailed(.unavailable) }
        XCTAssertTrue(blocked, "\(harness.sut.viewState.memoryState)")
        let presentation = harness.sut.viewState.memoryPresentation
        XCTAssertTrue(presentation.blocksConversation)
        XCTAssertTrue(presentation.offersNewConversation)
        let message = try XCTUnwrap(presentation.message)
        XCTAssertFalse(message.contains("削除") || message.contains("消"), message)

        coordinator.makeActions(openSettings: {}).startNewConversation()
        await coordinator.waitForOperations()
        XCTAssertEqual(harness.sut.viewState.memoryState, .ready)
        XCTAssertFalse(harness.sut.viewState.memoryPresentation.blocksConversation)

        await harness.sut.submitTypedText("はじめまして")
        let answered = await harness.waitUntil(timeout: .seconds(3)) { harness.sut.viewState.caption == "はじめまして" }
        XCTAssertTrue(answered, harness.sut.viewState.caption)
        let posts = await server.runPosts
        XCTAssertEqual(posts.compactMap { $0.jsonBody?["session_id"] }, ["catrobot-s1"], "the lost session is never sent again")
        await harness.sut.shutdown()
    }
}

private final class ExitTestSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}
