import Foundation
import XCTest
@testable import CatRobot

/// 401 の後は、利用者が「もう一度確認」を押したときだけ、同じ接続先とキーで 1 回 Hermes に確かめる。
/// 確かな 401 なら拒否のまま、通れば同じ会話をそのまま続けられる。自動では送り直さず、端末の記録や履歴を回復の条件にしない。
@MainActor
final class HermesAuthorizationRecheckTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443")!,
                                              credential: HermesCredential(apiKey: "client-key"))
    private static let unauthorized = FakeHermesServer.Reply.json(401, #"{"error":{"code":"unauthorized"}}"#)
    private static let capabilities = FakeHermesServer.Reply.json(200, #"{"object":"hermes.api_server.capabilities"}"#)
    private static let oldConversation = FakeHermesServer.Reply.json(200, #"""
        {"object":"list","session_id":"catrobot-old","data":[{"role":"user","content":"ただいま"},{"role":"assistant","content":"おかえり"}]}
        """#)

    private func continued(unsettled: [String] = []) -> InMemoryHermesSessionRecordStore {
        InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                             hasTurns: true, unsettledRunIDs: unsettled))
    }

    private func makeService(_ server: FakeHermesServer,
                             records: InMemoryHermesSessionRecordStore = InMemoryHermesSessionRecordStore()) -> HermesConversationService {
        let resolved = connection
        let ids = RecheckSessionIDs(["catrobot-s1", "catrobot-s2"])
        return HermesConversationService(connection: { resolved }, transport: server, records: records, clock: SteppingHermesClock(),
                                         timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: .seconds(10),
                                                                          submitRetryDelay: .seconds(1)),
                                         makeSessionID: { ids.next() }, makeIdempotencyKey: { UUID() })
    }

    private func refuse(_ service: HermesConversationService) async {
        do {
            _ = try await recheckCollect(try await service.streamReply(to: "ねえ"))
            XCTFail("the first turn is refused")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
    }

    private func calls(_ server: FakeHermesServer) async -> [String] {
        await server.requests.map { "\($0.method) \($0.url.path)" }
    }

    func testAnExplicitRecheckLetsTheSameKeyContinueOnceHermesAcceptsItAgain() async throws {
        let server = FakeHermesServer(runs: [Self.unauthorized, hermesAccepted("run-2")],
                                      polls: ["run-2": [hermesRun("run-2", "completed", output: "おかえり")]],
                                      capabilities: [Self.capabilities])
        let service = makeService(server)
        await refuse(service)
        for _ in 0..<3 {
            let availability = await service.availability()
            XCTAssertEqual(availability, .hermesUnauthorized, "nothing is resent on its own")
        }
        let afterRefusal = await calls(server)
        XCTAssertEqual(afterRefusal, ["POST /v1/runs"])

        await service.recheckAvailability()
        let probe = await server.requests.dropFirst().map { "\($0.method) \($0.url.path) \($0.headers["Authorization"] ?? "")" }
        XCTAssertEqual(probe, ["GET /v1/capabilities Bearer client-key"], "one authenticated check with the same key")
        let availability = await service.availability()
        XCTAssertEqual(availability, .available)

        let outputs = try await recheckCollect(try await service.streamReply(to: "ねえ"))
        XCTAssertEqual(outputs, ["おかえり"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.compactMap { $0.jsonBody?["session_id"] }, ["catrobot-s1", "catrobot-s1"],
                       "recovery keeps the same Hermes session")
    }

    func testARecheckThatHermesStillRefusesKeepsTheKeyRejected() async {
        let server = FakeHermesServer(runs: [Self.unauthorized], capabilities: [Self.unauthorized])
        let service = makeService(server)
        await refuse(service)
        await service.recheckAvailability()
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized)
        let requests = await calls(server)
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/capabilities"])
    }

    /// 届かなかった確認は拒否の根拠にしない。次に利用者が話したときの Hermes の答えで決まる。
    func testARecheckThatCannotReachHermesLiftsTheRefusalForTheNextTurn() async {
        let server = FakeHermesServer(runs: [Self.unauthorized], capabilities: [.transportFailure])
        let service = makeService(server)
        await refuse(service)
        await service.recheckAvailability()
        let availability = await service.availability()
        XCTAssertEqual(availability, .available)
        let requests = await calls(server)
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/capabilities"], "one check, no retry loop")
    }

    /// 取り消された確認は拒否を外さない（確かめ終わっていない）。
    func testACancelledRecheckKeepsTheRefusal() async {
        let server = FakeHermesServer(runs: [Self.unauthorized], capabilities: [Self.capabilities])
        let service = makeService(server)
        await refuse(service)
        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.recheckAvailability()
        }
        await check.value
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized)
        let requests = await calls(server)
        XCTAssertEqual(requests, ["POST /v1/runs"])
    }

    /// 答えを待つ間に取り消された確認は、そのあと 200 が届いても拒否を外さない（確かめ終わっていない）。
    func testARecheckCancelledWhileHermesIsAnsweringKeepsTheRefusal() async {
        let server = FakeHermesServer(runs: [Self.unauthorized], capabilities: [.gated("capabilities", Self.capabilities)])
        let service = makeService(server)
        await refuse(service)
        let check = Task { await service.recheckAvailability() }
        await server.waitUntilBlocked("capabilities")
        check.cancel()
        await server.release("capabilities")
        await check.value
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized, "a late answer to an abandoned check changes nothing")
        let requests = await calls(server)
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/capabilities"])
    }

    // MARK: - どの経路の 401 も同じ接続の拒否として覚え、確かめ直すまで送らない

    /// 前の会話の読み込みで 401 を受けたら、空の会話として進まずに拒否を返す。回復した後は同じ会話を読み直す。
    func testARefusedHistoryReadIsRememberedUntilAnExplicitCheck() async throws {
        let records = continued()
        let server = FakeHermesServer(history: [Self.unauthorized, Self.oldConversation], capabilities: [Self.capabilities])
        let service = makeService(server, records: records)
        do {
            try await service.prepareMemory()
            XCTFail("a refused history read is not an empty conversation")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized)
        do {
            _ = try await service.streamReply(to: "ねえ")
            XCTFail("nothing is sent with the refused key")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        let refused = await calls(server)
        XCTAssertEqual(refused, ["GET /api/sessions/catrobot-old/messages"])

        await service.recheckAvailability()
        try await service.prepareMemory()
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, [ConversationMemoryTurn(prompt: "ただいま", response: "おかえり")],
                       "after recovery the same conversation is read again")
        let requests = await calls(server)
        XCTAssertEqual(requests, ["GET /api/sessions/catrobot-old/messages", "GET /v1/capabilities",
                                  "GET /api/sessions/catrobot-old/messages"])
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-old")
    }

    /// 前の run の後始末（stop か、その後の照会）で 401 を受けたら、後始末の続きも POST もせずに拒否を返す。記録は変えない。
    func testARefusedCleanupEndsTheTurnBeforeAnySubmission() async throws {
        let cases: [(stops: [String: [FakeHermesServer.Reply]], polls: [String: [FakeHermesServer.Reply]], sent: [String])] = [
            (["run-old": [Self.unauthorized]], [:], ["POST /v1/runs/run-old/stop"]),
            ([:], ["run-old": [Self.unauthorized]], ["POST /v1/runs/run-old/stop", "GET /v1/runs/run-old"]),
        ]
        for refusal in cases {
            let records = continued(unsettled: ["run-old"])
            let server = FakeHermesServer(polls: refusal.polls, stops: refusal.stops)
            let service = makeService(server, records: records)
            do {
                _ = try await recheckCollect(try await service.streamReply(to: "ねえ"))
                XCTFail("the turn ends with the refusal")
            } catch {
                XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
            }
            let requests = await calls(server)
            XCTAssertEqual(requests, refusal.sent, "nothing more is sent with the refused key")
            let availability = await service.availability()
            XCTAssertEqual(availability, .hermesUnauthorized)
            let record = await records.record
            XCTAssertEqual(record, HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                       hasTurns: true, unsettledRunIDs: ["run-old"]))
        }
    }

    /// 取り消したターンの stop で 401 を受けても、その接続の拒否として覚える。
    func testARefusedStopIsRemembered() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [.gated("poll", hermesRun("run-1", "running"))]],
                                      stops: ["run-1": [Self.unauthorized]])
        let service = makeService(server)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await recheckCollect(stream) }
        await server.waitUntilBlocked("poll")
        consumer.cancel()
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        await server.release("poll")
        _ = try? await consumer.value
        var availability = await service.availability()
        for _ in 0..<400 where availability != .hermesUnauthorized {
            try? await Task.sleep(for: .milliseconds(5))
            availability = await service.availability()
        }
        XCTAssertEqual(availability, .hermesUnauthorized)
        let stops = await server.stops.count
        XCTAssertEqual(stops, 1)
    }

    /// 設定の履歴で 401 を受けたら、その接続の拒否として覚え、確かめ直すまで読み直しても送らない。
    func testARefusedTranscriptIsRememberedAndAReloadDoesNotResendTheKey() async throws {
        let server = FakeHermesServer(history: [Self.unauthorized, Self.oldConversation])
        let service = makeService(server, records: continued())
        for _ in 0..<2 {
            do {
                _ = try await service.transcript()
                XCTFail("the refusal is reported")
            } catch {
                XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
            }
        }
        let requests = await calls(server)
        XCTAssertEqual(requests, ["GET /api/sessions/catrobot-old/messages"], "a reload does not resend the refused key")
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized)
    }

    func testARecheckWithoutARefusalSendsNothing() async {
        let server = FakeHermesServer()
        let service = makeService(server)
        await service.recheckAvailability()
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// 通常の画面: 401 の後、Hermes 側で同じキーが通るようになったら「もう一度確認」だけで同じ会話を続けられる。
    func testCheckAgainOnTheConversationScreenRecoversTheSameKeyAndSession() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [Self.unauthorized, hermesAccepted("run-2")],
                                      polls: ["run-2": [hermesRun("run-2", "completed", output: "おかえり")]],
                                      capabilities: [Self.capabilities])
        let hermes = makeService(server, records: records)
        let harness = ConversationHarness(replyOverride: hermes, memory: hermes, modelAvailabilityOverride: hermes)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        let actions = coordinator.makeActions(openSettings: { XCTFail("the iOS Settings app is not the recovery") })

        await harness.sut.submitTypedText("ねえ")
        let refused = await harness.waitUntil(timeout: .seconds(3)) {
            harness.sut.viewState.phase == .failed(.modelUnavailable(.hermesUnauthorized))
        }
        XCTAssertTrue(refused, "\(harness.sut.viewState.phase)")
        let checkAgain = try XCTUnwrap(harness.sut.viewState.recoveries.first { $0.title == "もう一度確認" })

        actions.performRecovery(checkAgain.action)
        await coordinator.waitForOperations()
        let retried = await harness.microphone.requestCount
        XCTAssertEqual(retried, 1, "the explicit retry ran the start")
        let probes = await server.requests.filter { $0.url.path.hasSuffix("/v1/capabilities") }.map { $0.headers["Authorization"] }
        XCTAssertEqual(probes, ["Bearer client-key"], "one explicit check with the same key")
        XCTAssertEqual(harness.sut.viewState.phase, .listening)

        await harness.sut.submitTypedText("ねえ")
        let answered = await harness.waitUntil(timeout: .seconds(3)) { harness.sut.viewState.caption == "おかえり" }
        XCTAssertTrue(answered, harness.sut.viewState.caption)
        let posts = await server.runPosts
        XCTAssertEqual(posts.compactMap { $0.jsonBody?["session_id"] }, ["catrobot-s1", "catrobot-s1"])
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-s1", "no local record is cleared to recover")
        await harness.sut.shutdown()
    }

    /// 確認の途中で設定を開いたら、遅れて届いた結果で聞き取りを始めない（確認も開始と同じ世代の中で待つ）。
    func testACheckStillRunningWhenTheSettingsOpenDoesNotStartListening() async throws {
        let server = FakeHermesServer(runs: [Self.unauthorized], capabilities: [.gated("capabilities", Self.capabilities)])
        let hermes = makeService(server)
        let harness = ConversationHarness(replyOverride: hermes, memory: hermes, modelAvailabilityOverride: hermes)
        let coordinator = ConversationAppCoordinator(
            viewModel: harness.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }))
        let actions = coordinator.makeActions(openSettings: {})

        await harness.sut.submitTypedText("ねえ")
        let refused = await harness.waitUntil(timeout: .seconds(3)) {
            harness.sut.viewState.phase == .failed(.modelUnavailable(.hermesUnauthorized))
        }
        XCTAssertTrue(refused, "\(harness.sut.viewState.phase)")
        let checkAgain = try XCTUnwrap(harness.sut.viewState.recoveries.first { $0.title == "もう一度確認" })

        actions.performRecovery(checkAgain.action)
        await server.waitUntilBlocked("capabilities")
        let checking = await server.isBlocked("capabilities")
        XCTAssertTrue(checking, "the explicit check is in flight")
        coordinator.openVoiceSettings()
        await server.release("capabilities")
        await coordinator.waitForOperations()

        XCTAssertNotEqual(harness.sut.viewState.phase, .listening)
        let starts = await harness.recognizer.startCount
        XCTAssertEqual(starts, 0, "a late check result does not start listening behind the settings")
        await harness.sut.shutdown()
    }
}

private final class RecheckSessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}

private func recheckCollect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}
