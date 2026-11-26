import Foundation
import XCTest
@testable import CatRobot

/// 通常会話の Hermes adapter。fake の Hermes API で、送るもの・採用する出力・取消・session の継続を確かめる。
final class HermesConversationServiceTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443/")!,
                                              credential: HermesCredential(apiKey: "client-key"))
    private let otherConnection = HermesConnection(endpoint: URL(string: "https://other.test/")!,
                                                   credential: HermesCredential(apiKey: "other-key"))
    private static let runNotFound =
        #"{"error":{"message":"Run not found: run-orphan","type":"invalid_request_error","param":null,"code":"run_not_found"}}"#
    private static let sessionNotFound = FakeHermesServer.Reply.json(404, #"{"error":{"code":"session_not_found"}}"#)

    private func makeService(_ server: FakeHermesServer,
                             records: InMemoryHermesSessionRecordStore = InMemoryHermesSessionRecordStore(),
                             connection: HermesConnection?? = nil,
                             provider: (@Sendable () async -> HermesConnection?)? = nil,
                             deadline: Duration = .seconds(10),
                             sessionIDs: [String] = ["catrobot-s1", "catrobot-s2", "catrobot-s3"],
                             keys: [UUID] = (0..<5).map { _ in UUID() },
                             clock: any HermesClock = SteppingHermesClock()) -> HermesConversationService {
        let resolved = connection ?? self.connection
        let current: @Sendable () async -> HermesConnection?
        if let provider { current = provider } else { current = { resolved } }
        let ids = Sequenced(sessionIDs), uuids = Sequenced(keys)
        return HermesConversationService(
            connection: current,
            transport: server,
            records: records,
            clock: clock,
            timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: deadline, submitRetryDelay: .seconds(1)),
            makeSessionID: { ids.next() },
            makeIdempotencyKey: { uuids.next() })
    }

    private func continued(_ sessionID: String = "catrobot-old", unsettled: [String] = []) -> InMemoryHermesSessionRecordStore {
        InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: sessionID,
                                                             hasTurns: true, unsettledRunIDs: unsettled))
    }

    private func failure(of stream: AsyncThrowingStream<String, Error>) async -> Error? {
        do { _ = try await collectReplies(stream); return nil } catch { return error }
    }

    // MARK: - 設定と availability

    func testMissingConnectionIsReportedWithoutAnyRequestOrFallback() async throws {
        let server = FakeHermesServer()
        let service = makeService(server, connection: .some(nil))
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesNotConfigured)
        do { _ = try await service.streamReply(to: "こんにちは"); XCTFail("no reply without a configured Hermes") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesNotConfigured)) }
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// 401 の後はアプリ内の設定へ案内する。鍵が変わるまでその案内を続ける。
    func testARejectedKeyIsReportedUntilTheKeyChanges() async throws {
        let box = ConnectionBox(connection)
        let server = FakeHermesServer(runs: [.json(401, #"{"error":{"code":"unauthorized"}}"#)])
        let service = makeService(server, provider: { box.get() })
        let error = await failure(of: try await service.streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let rejected = await service.availability()
        XCTAssertEqual(rejected, .hermesUnauthorized)
        box.set(HermesConnection(endpoint: connection.endpoint, credential: HermesCredential(apiKey: "new-key")))
        let renewed = await service.availability()
        XCTAssertEqual(renewed, .available)
    }

    /// 前のキーで始めたターンに遅れて届いた 401 は、今のキーの拒否の記録を上書きしない（拒否は接続ごとに覚える）。そのターンもそれ以上は送らない。
    func testALateRefusalForAnEarlierKeyDoesNotHideTheCurrentKeysRefusal() async throws {
        let box = ConnectionBox(connection)
        let unauthorized = FakeHermesServer.Reply.json(401, #"{"error":{"code":"unauthorized"}}"#)
        let server = FakeHermesServer(stops: ["run-old": [.gated("stop", unauthorized)]], history: [unauthorized])
        let service = makeService(server, records: continued(unsettled: ["run-old"]), provider: { box.get() })
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("stop")

        box.set(HermesConnection(endpoint: connection.endpoint, credential: HermesCredential(apiKey: "new-key")))
        do {
            _ = try await service.transcript()
            XCTFail("the new key is refused too")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        await server.release("stop")
        guard case .failure(let turnError) = await consumer.result else { return XCTFail("the earlier turn ends with the refusal") }
        XCTAssertEqual(turnError as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized, "the current key's refusal is kept")
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs/run-old/stop", "GET /api/sessions/catrobot-old/messages"],
                       "nothing more is sent with either refused key")
    }

    /// 401 を受けたときに今の接続を読めなくても（端末のロック中は Keychain を読めない）、その接続の拒否として覚える。
    func testARefusalWhileTheCurrentConnectionCannotBeReadIsStillRemembered() async throws {
        let box = ConnectionBox(connection)
        let unauthorized = FakeHermesServer.Reply.json(401, #"{"error":{"code":"unauthorized"}}"#)
        let server = FakeHermesServer(stops: ["run-old": [.gated("stop", unauthorized)]])
        let service = makeService(server, records: continued(unsettled: ["run-old"]), provider: { box.get() })
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("stop")

        box.set(nil)
        await server.release("stop")
        guard case .failure(let turnError) = await consumer.result else { return XCTFail("the turn ends with the refusal") }
        XCTAssertEqual(turnError as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        box.set(connection)
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized, "the refused key is not used again without an explicit check")
        do {
            _ = try await service.streamReply(to: "もう一度")
            XCTFail("nothing is sent with the refused key")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs/run-old/stop"])
    }

    /// 今の接続を読めないあいだに前のキーへ遅れて届いた 401 も、今のキーの拒否を消さない（読めないあいだはどちらのキーが今か分からない）。
    func testALateRefusalForAnEarlierKeyWhileTheConnectionCannotBeReadKeepsTheCurrentKeysRefusal() async throws {
        let box = ConnectionBox(connection)
        let newKey = HermesConnection(endpoint: connection.endpoint, credential: HermesCredential(apiKey: "new-key"))
        let unauthorized = FakeHermesServer.Reply.json(401, #"{"error":{"code":"unauthorized"}}"#)
        let server = FakeHermesServer(stops: ["run-old": [.gated("stop", unauthorized)]], history: [unauthorized])
        let service = makeService(server, records: continued(unsettled: ["run-old"]), provider: { box.get() })
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("stop")

        box.set(newKey)
        do {
            _ = try await service.transcript()
            XCTFail("the new key is refused too")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        box.set(nil)
        await server.release("stop")
        guard case .failure(let turnError) = await consumer.result else { return XCTFail("the earlier turn ends with the refusal") }
        XCTAssertEqual(turnError as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        box.set(newKey)
        let availability = await service.availability()
        XCTAssertEqual(availability, .hermesUnauthorized, "the current key's refusal is kept")
        do {
            _ = try await service.streamReply(to: "もう一度")
            XCTFail("nothing is sent with the refused key")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs/run-old/stop", "GET /api/sessions/catrobot-old/messages"],
                       "nothing more is sent with either refused key")
    }

    /// 設定はアプリを再起動せずに変わる。接続先と鍵はターンごとに読み、別の接続先には別の session を使う。
    func testEachTurnReadsTheCurrentConnectionAndAnotherOriginGetsItsOwnSession() async throws {
        let box = ConnectionBox(connection)
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "やあ")],
                                              "run-2": [hermesRun("run-2", "completed", output: "こんにちは")]])
        let service = makeService(server, records: records, provider: { box.get() })
        _ = try await collectReplies(try await service.streamReply(to: "やあ"))
        box.set(otherConnection)
        _ = try await collectReplies(try await service.streamReply(to: "こんにちは"))
        let posts = await server.runPosts
        XCTAssertEqual(posts.map { $0.url.host }, ["hermes.test", "other.test"])
        XCTAssertEqual(posts.map { $0.headers["Authorization"] }, ["Bearer client-key", "Bearer other-key"])
        XCTAssertEqual(posts.map { $0.jsonBody?["session_id"] }, ["catrobot-s1", "catrobot-s2"])
        let record = await records.record
        XCTAssertEqual(record?.origin, otherConnection.origin)
        XCTAssertEqual(record?.sessionID, "catrobot-s2")
    }

    // MARK: - 1 ターン

    func testTurnPostsOneFixedIdentityAndYieldsOnlyTheCompletedOutput() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "running", output: "途中"),
                                                        hermesRun("run-1", "completed", output: "にゃん、元気だよ")]])
        let service = makeService(server)
        XCTAssertFalse(service.supportsStableReplyPrefix, "interim text must never reach speech")
        let outputs = try await collectReplies(try await service.streamReply(to: "  元気？ "))
        XCTAssertEqual(outputs, ["にゃん、元気だよ"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1)
        let body = try XCTUnwrap(posts.first?.jsonBody)
        XCTAssertEqual(body["input"], "元気？")
        XCTAssertEqual(body["session_id"], "catrobot-s1")
        XCTAssertEqual(body["instructions"], HermesConversationInstructions.persona)
        XCTAssertEqual(Set(body.keys), ["input", "session_id", "instructions"], "the local transcript is never uploaded")
        XCTAssertEqual(posts.first?.headers["Authorization"], "Bearer client-key")
        XCTAssertNotNil(posts.first?.headers["Idempotency-Key"])
        try await Task.sleep(for: .milliseconds(100))
        let stops = await server.stops
        XCTAssertTrue(stops.isEmpty, "a turn that finished normally is never stopped")
    }

    func testAnUtteranceOverTheLimitIsRefusedBeforeSending() async throws {
        let server = FakeHermesServer()
        let service = makeService(server)
        do { _ = try await service.streamReply(to: String(repeating: "あ", count: 4_001)); XCTFail("too long to send") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .inputTooLong) }
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// 読み上げは 2000 字まで（SentenceReplyPlayback の上限）。超える返事は収まる最後の文末で切り、全文は Hermes の履歴に残る。
    func testAReplyTooLongToSpeakIsCutAtTheLastSentenceEndThatFits() async throws {
        let sentence = "あいうえお。"
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: String(repeating: sentence, count: 400))]])
        let outputs = try await collectReplies(try await makeService(server).streamReply(to: "長く話して"))
        // 失敗表示が 2000 字にならないよう、長さと一致を分けて確かめる。
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.count, 1_998, "the longest run of whole sentences within 2000 characters")
        XCTAssertTrue(outputs.first == String(repeating: sentence, count: 333), "a prefix of the reply, cut at a sentence end")
    }

    func testLostAcceptanceIsRetriedWithTheSameKeyAndTheSameBody() async throws {
        let server = FakeHermesServer(runs: [.transportFailure, hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "うん")]])
        let outputs = try await collectReplies(try await makeService(server).streamReply(to: "ねえ"))
        XCTAssertEqual(outputs, ["うん"])
        let posts = await server.runPosts
        guard posts.count == 2 else { return XCTFail("expected one resend of the same submission, got \(posts.count) posts") }
        XCTAssertEqual(posts.first?.headers["Idempotency-Key"], posts.last?.headers["Idempotency-Key"])
        XCTAssertEqual(posts.first?.body, posts.last?.body)
    }

    /// 受付が分からないまま期限を過ぎたら「返事の期限切れ」（宛先判定の通信断や Hermes の 429・503 と区別し、新しい会話の出口を出せる）。
    func testASubmissionThatNeverGetsAnAnswerTimesOutAndStaysUncertain() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer()
        let error = await failure(of: try await makeService(server, records: records, deadline: .seconds(5)).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        let posts = await server.runPosts
        XCTAssertGreaterThan(posts.count, 1, "a lost acceptance is resent")
        XCTAssertEqual(Set(posts.map { $0.headers["Idempotency-Key"] }).count, 1, "every resend is the same submission")
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, true, "nobody knows whether Hermes admitted it")
        XCTAssertEqual(record?.hasTurns, false)
    }

    func testRefusedAdmissionFailsWithoutSendingANewKey() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [.json(409, #"{"error":{"code":"idempotency_key_conflict"}}"#)])
        let error = await failure(of: try await makeService(server, records: records).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1)
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, false, "a refusal is an answer: nothing was admitted")
    }

    /// Hermes の 429 は同時実行の上限。既存の対応と同じく「少し待って」の案内にし、そのターンでは再送しない。
    func testABusyHermesIsReportedAsUnreachableForNowWithoutResending() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [.json(429, #"{"error":{"code":"rate_limit_exceeded"}}"#), hermesAccepted("run-never")])
        let error = await failure(of: try await makeService(server, records: records).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable)
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1)
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, false)
    }

    func testPollDisconnectsAreNotTreatedAsTheEndOfTheRun() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [.transportFailure, .transportFailure, hermesRun("run-1", "completed", output: "届いた")]])
        let outputs = try await collectReplies(try await makeService(server).streamReply(to: "ねえ"))
        XCTAssertEqual(outputs, ["届いた"])
    }

    func testInterruptedFailedAndRemoteCancelledRunsAreFailures() async throws {
        for status in ["interrupted", "failed", "cancelled"] {
            let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", status, output: "部分")]])
            let error = await failure(of: try await makeService(server).streamReply(to: "ねえ"))
            XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed, status)
        }
    }

    func testCompletedWithoutTextIsAFailure() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: " ")]])
        let error = await failure(of: try await makeService(server).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
    }

    func testDeadlineStopsTheRunAndReportsThatTheReplyDidNotArrive() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "running")]])
        let error = await failure(of: try await makeService(server, records: records, deadline: .seconds(5)).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .replyTimedOut)
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        let stops = await server.stops
        XCTAssertEqual(stops.map(\.url.path), ["/v1/runs/run-1/stop"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1"], "stopping is not an end; a later turn confirms it")
    }

    func testApprovalCannotBeAnsweredFromTheRobotSoTheRunIsStopped() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "waiting_for_approval")]])
        let error = await failure(of: try await makeService(server, records: records).streamReply(to: "ねえ"))
        XCTAssertEqual(error as? ConversationServiceError, .modelGenerationFailed)
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        let stops = await server.stops
        XCTAssertEqual(stops.map(\.url.path), ["/v1/runs/run-1/stop"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1"])
    }

    // MARK: - 取消と遅延応答

    func testConsumerCancellationStopsTheRunAtOnceAndNeverAdoptsItsLateOutput() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [.gated("poll", hermesRun("run-1", "completed", output: "遅い返事"))]])
        let records = InMemoryHermesSessionRecordStore()
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("poll")
        let whileRunning = await records.record
        XCTAssertEqual(whileRunning?.unsettledRunIDs, ["run-1"], "an accepted run is remembered before it is polled")
        XCTAssertEqual(whileRunning?.hasTurns, true, "Hermes accepted the turn, so its session holds the user's words")
        consumer.cancel()
        let consumed = try? await consumer.value
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        let stopsWhileThePollIsOpen = await server.stops
        XCTAssertEqual(stopsWhileThePollIsOpen.map(\.url.path), ["/v1/runs/run-1/stop"], "stop goes out at once, not after the next poll")
        await server.release("poll")
        await records.waitUntil { $0?.unsettledRunIDs.isEmpty == true }
        XCTAssertEqual(consumed ?? [], [])
        let stops = await server.stops
        XCTAssertEqual(stops.count, 1)
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, [], "a cancelled turn is not adopted locally")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, [], "the terminal status seen after the stop settles the run")
        XCTAssertEqual(record?.hasTurns, true)
    }

    /// poll の待ちの途中で取り消したら、次の照会を出さずに終わる（次のターンはこの worker の終わりを待つので、余計な往復を足さない）。
    func testCancellingDuringThePollWaitSendsNoFurtherPollBeforeTheNextTurn() async throws {
        let clock = GatedSleepHermesClock()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [hermesRun("run-1", "running")],
                                              "run-2": [hermesRun("run-2", "completed", output: "うん")]])
        let service = makeService(server, clock: clock)
        let first = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(first) }
        await clock.waitUntilAsleep()
        consumer.cancel()
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        await clock.wake()
        _ = try? await consumer.value
        let outputs = try await collectReplies(try await service.streamReply(to: "もう一度"))
        XCTAssertEqual(outputs, ["うん"])
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/runs/run-1", "POST /v1/runs/run-1/stop",
                                  "POST /v1/runs/run-1/stop", "GET /v1/runs/run-1", "POST /v1/runs", "GET /v1/runs/run-2"],
                       "no poll after the cancellation; the next turn only cleans up and sends")
    }

    // MARK: - 拒否を記録した後は、並行する worker もその接続で送らない

    private static let refused = FakeHermesServer.Reply.json(401, #"{"error":{"code":"unauthorized"}}"#)

    /// 前のターン（run-1 の照会が応答待ち）を取り消して新しい会話へ移る。「新しい会話」と同じく、前の worker の応答は待たない。
    private func moveToANewConversationWhileThePreviousPollIsPending(_ service: HermesConversationService,
                                                                      _ server: FakeHermesServer) async throws -> Task<[String], Error> {
        let first = try await service.streamReply(to: "ねえ")
        let previous = Task { try await collectReplies(first) }
        await server.waitUntilBlocked("previous-poll")
        previous.cancel()
        await server.waitForRequest { $0.url.path.hasSuffix("/run-1/stop") }
        await service.reset()
        return previous
    }

    private func waitUntilRefused(_ service: HermesConversationService) async {
        for _ in 0..<400 {
            if await service.availability() == .hermesUnauthorized { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 新しい会話へ移った後、前の worker の照会に遅れて 401 が届いたら、新しい worker は poll の待ちが明けても同じ接続ではもう照会しない。
    func testAPreviousWorkersRefusalStopsTheNewWorkersNextPoll() async throws {
        let clock = GatedSleepHermesClock()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [.gated("previous-poll", Self.refused), hermesRun("run-1", "running")],
                                              "run-2": [hermesRun("run-2", "running"), Self.refused]])
        let records = InMemoryHermesSessionRecordStore()
        let service = makeService(server, records: records, clock: clock)
        let previous = try await moveToANewConversationWhileThePreviousPollIsPending(service, server)
        let next = Task { try await collectReplies(try await service.streamReply(to: "もう一度")) }
        await clock.waitUntilAsleep()

        await server.release("previous-poll")
        _ = try? await previous.value
        await waitUntilRefused(service)
        await clock.wake()
        guard case .failure(let error) = await next.result else { return XCTFail("the new turn ends with the refusal") }
        XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/runs/run-1", "POST /v1/runs/run-1/stop",
                                  "POST /v1/runs/run-1/stop", "GET /v1/runs/run-1", "POST /v1/runs", "GET /v1/runs/run-2"],
                       "no poll with the refused key after the wait")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1", "run-2"], "unfinished runs stay recorded")
    }

    /// 同じく、新しい worker が受付の分からない送信の再送を待つあいだに届いた 401 の後は、もう送らない（受付の分からない記録は残す）。
    func testAPreviousWorkersRefusalStopsTheNewWorkersResubmission() async throws {
        let clock = GatedSleepHermesClock()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), .transportFailure, Self.refused],
                                      polls: ["run-1": [.gated("previous-poll", Self.refused), hermesRun("run-1", "running")]])
        let records = InMemoryHermesSessionRecordStore()
        let service = makeService(server, records: records, clock: clock)
        let previous = try await moveToANewConversationWhileThePreviousPollIsPending(service, server)
        let next = Task { try await collectReplies(try await service.streamReply(to: "もう一度")) }
        await clock.waitUntilAsleep()

        await server.release("previous-poll")
        _ = try? await previous.value
        await waitUntilRefused(service)
        await clock.wake()
        guard case .failure(let error) = await next.result else { return XCTFail("the new turn ends with the refusal") }
        XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/runs/run-1", "POST /v1/runs/run-1/stop",
                                  "POST /v1/runs/run-1/stop", "GET /v1/runs/run-1", "POST /v1/runs"],
                       "the uncertain submission is not resent with the refused key")
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, true, "nobody knows whether Hermes admitted the first attempt")
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1"])
    }

    /// 後始末の stop の応答を待つあいだに、別の要求（設定の履歴）が同じ接続の 401 を記録したら、後始末は次の照会を送らずにそのターンを終える。
    func testARefusalRecordedDuringCleanupStopsTheCleanupsNextRequest() async throws {
        let server = FakeHermesServer(stops: ["run-old": [.gated("cleanup-stop", hermesRun("run-old", "stopping"))]],
                                      history: [Self.refused])
        let records = continued(unsettled: ["run-old"])
        let service = makeService(server, records: records)
        let turn = Task { try await collectReplies(try await service.streamReply(to: "ねえ")) }
        await server.waitUntilBlocked("cleanup-stop")

        do {
            _ = try await service.transcript()
            XCTFail("the key is refused")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        await server.release("cleanup-stop")
        guard case .failure(let error) = await turn.result else { return XCTFail("the turn ends with the refusal") }
        XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs/run-old/stop", "GET /api/sessions/catrobot-old/messages"],
                       "the cleanup sends nothing more with the refused key")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-old"])
    }

    /// poll の応答を待つあいだに別の要求が同じ接続の 401 を記録したら、その後の承認待ちの stop も送らない（run は未終端のまま記録に残す）。
    func testARefusalRecordedDuringAPollStopsTheFollowingStop() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [.gated("poll", hermesRun("run-1", "waiting_for_approval"))]],
                                      history: [Self.refused])
        let service = makeService(server, records: records)
        let turn = Task { try await collectReplies(try await service.streamReply(to: "ねえ")) }
        await server.waitUntilBlocked("poll")

        do {
            _ = try await service.transcript()
            XCTFail("the key is refused")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.hermesUnauthorized))
        }
        await server.release("poll")
        _ = await turn.result
        let requests = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(requests, ["POST /v1/runs", "GET /v1/runs/run-1", "GET /api/sessions/catrobot-s1/messages"],
                       "no stop with the refused key")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-1"], "the run stays recorded until it can be confirmed")
    }

    func testCancellationDuringSubmitWaitsForTheAcceptanceAndStopsThatRun() async throws {
        let server = FakeHermesServer(runs: [.gated("post", hermesAccepted("run-late"))])
        let records = InMemoryHermesSessionRecordStore()
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("post")
        consumer.cancel()
        _ = try? await consumer.value
        await server.release("post")
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        let stops = await server.stops
        XCTAssertEqual(stops.map(\.url.path), ["/v1/runs/run-late/stop"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1)
        let record = await records.record
        XCTAssertEqual(record?.hasTurns, true)
        XCTAssertEqual(record?.hasUncertainSubmission, false)
        XCTAssertEqual(record?.unsettledRunIDs, ["run-late"], "a stop answered with stopping does not settle the run")
    }

    func testCancellationAfterAnUncertainSubmitNeverReplaysIt() async throws {
        let server = FakeHermesServer(runs: [.gated("post", .transportFailure), hermesAccepted("run-replayed")])
        let records = InMemoryHermesSessionRecordStore()
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await collectReplies(stream) }
        await server.waitUntilBlocked("post")
        let whileSending = await records.record
        XCTAssertEqual(whileSending?.sessionID, "catrobot-s1")
        XCTAssertEqual(whileSending?.hasUncertainSubmission, true, "a kill during the POST must leave a trace")
        consumer.cancel()
        _ = try? await consumer.value
        await server.release("post")
        try await Task.sleep(for: .milliseconds(100))
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 1, "a replay after cancellation could admit work nobody waits for")
        let record = await records.record
        XCTAssertEqual(record?.hasUncertainSubmission, true)
        XCTAssertEqual(record?.hasTurns, false)
    }

    // MARK: - 終端を確かめていない run（取消・期限・アプリの終了で残ったもの）

    func testARunLeftByAKilledProcessIsStoppedBeforeTheNextTurnAndForgottenOnceEnded() async throws {
        let records = continued(unsettled: ["run-orphan"])
        let server = FakeHermesServer(runs: [hermesAccepted("run-2")],
                                      polls: ["run-2": [hermesRun("run-2", "completed", output: "続き")]],
                                      stops: ["run-orphan": [hermesRun("run-orphan", "cancelled")]])
        let outputs = try await collectReplies(try await makeService(server, records: records).streamReply(to: "続けて"))
        XCTAssertEqual(outputs, ["続き"])
        let calls = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(calls.first, "POST /v1/runs/run-orphan/stop", "the orphan is stopped before new work is admitted")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, [], "the terminal status in the stop answer settles it")
    }

    /// Hermes は同じ session の新しい run を古い run の後ろに並べる。端末は古い run の終わりを待たない。
    func testAnOrphanStillStoppingIsKeptWithoutHoldingUpTheTurn() async throws {
        let records = continued(unsettled: ["run-orphan"])
        let server = FakeHermesServer(runs: [hermesAccepted("run-2")],
                                      polls: ["run-orphan": [hermesRun("run-orphan", "stopping")],
                                              "run-2": [hermesRun("run-2", "completed", output: "続き")]])
        let outputs = try await collectReplies(try await makeService(server, records: records).streamReply(to: "続けて"))
        XCTAssertEqual(outputs, ["続き"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-orphan"])
    }

    func testAnOrphanHermesHasForgottenIsSettled() async throws {
        let notActive = #"{"error":{"message":"Run is not active","type":"invalid_request_error","param":null,"code":"run_not_active"}}"#
        let cases: [(stop: FakeHermesServer.Reply, poll: FakeHermesServer.Reply?)] = [
            (.json(404, Self.runNotFound), nil),
            (.json(409, notActive), .json(404, Self.runNotFound))
        ]
        for (index, script) in cases.enumerated() {
            let records = continued(unsettled: ["run-orphan"])
            var polls: [String: [FakeHermesServer.Reply]] = ["run-2": [hermesRun("run-2", "completed", output: "続き")]]
            if let poll = script.poll { polls["run-orphan"] = [poll] }
            let server = FakeHermesServer(runs: [hermesAccepted("run-2")], polls: polls, stops: ["run-orphan": [script.stop]])
            let outputs = try await collectReplies(try await makeService(server, records: records).streamReply(to: "続けて"))
            XCTAssertEqual(outputs, ["続き"], "case \(index)")
            let record = await records.record
            XCTAssertEqual(record?.unsettledRunIDs, [], "case \(index): Hermes no longer knows the run")
        }
    }

    func testAnUnexplained404DoesNotSettleAnOrphan() async throws {
        let unexplained = FakeHermesServer.Reply.json(404, #"{"detail":"not routed"}"#)
        let records = continued(unsettled: ["run-orphan"])
        let server = FakeHermesServer(runs: [hermesAccepted("run-2")],
                                      polls: ["run-orphan": [unexplained], "run-2": [hermesRun("run-2", "completed", output: "続き")]],
                                      stops: ["run-orphan": [unexplained]])
        let outputs = try await collectReplies(try await makeService(server, records: records).streamReply(to: "続けて"))
        XCTAssertEqual(outputs, ["続き"])
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-orphan"], "a relay or proxy 404 says nothing about the run")
    }

    // MARK: - session と再起動

    func testTheSessionContinuesAfterARestartAndOnlyItsIdentifiersAreKept() async throws {
        let records = InMemoryHermesSessionRecordStore()
        let first = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "はじめまして")]])
        _ = try await collectReplies(try await makeService(first, records: records).streamReply(to: "はじめまして"))
        let saved = await records.record
        XCTAssertEqual(saved, HermesSessionRecord(origin: "https://hermes.test:8443", sessionID: "catrobot-s1", hasTurns: true))

        let second = FakeHermesServer(runs: [hermesAccepted("run-2")], polls: ["run-2": [hermesRun("run-2", "completed", output: "覚えてるよ")]])
        _ = try await collectReplies(try await makeService(second, records: records, sessionIDs: ["catrobot-new"]).streamReply(to: "覚えてる？"))
        let body = await second.runPosts.first?.jsonBody
        XCTAssertEqual(body?["session_id"], "catrobot-s1")
        XCTAssertEqual(body?["input"], "覚えてる？", "history comes from the Hermes session, not from the phone")
    }

    func testANewConversationSwitchesSessionsWithoutDeletingAnythingRemotely() async throws {
        let records = continued(unsettled: ["run-old"])
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "新しいね")]])
        let service = makeService(server, records: records, sessionIDs: ["catrobot-fresh"])
        await service.reset()
        _ = try await collectReplies(try await service.streamReply(to: "こんにちは"))
        let body = await server.runPosts.first?.jsonBody
        XCTAssertEqual(body?["session_id"], "catrobot-fresh")
        let stops = await server.stops
        XCTAssertEqual(stops.map(\.url.path), ["/v1/runs/run-old/stop"], "a run left by the old conversation is still stopped")
        let methods = await server.requests.map(\.method)
        XCTAssertFalse(methods.contains("DELETE"))
    }

    func testAnotherOriginNeverReceivesTheOldSession() async throws {
        let records = continued(unsettled: ["run-old"])
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "やあ")]])
        _ = try await collectReplies(try await makeService(server, records: records, connection: .some(otherConnection),
                                                    sessionIDs: ["catrobot-other"]).streamReply(to: "やあ"))
        let post = await server.runPosts.first
        XCTAssertEqual(post?.url.host, "other.test")
        XCTAssertEqual(post?.jsonBody?["session_id"], "catrobot-other")
        XCTAssertEqual(post?.headers["Authorization"], "Bearer other-key")
        let stops = await server.stops
        XCTAssertTrue(stops.isEmpty, "run ids of another server are never sent here")
        let record = await records.record
        XCTAssertEqual(record?.origin, otherConnection.origin)
        XCTAssertEqual(record?.unsettledRunIDs, [])
    }

    // MARK: - 聞き返し

    func testAClarificationExchangeReachesOnlyTheNextTurnAsInstructions() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "明日は晴れだよ")],
                                              "run-2": [hermesRun("run-2", "completed", output: "どういたしまして")]])
        let service = makeService(server)
        await service.recordExternalTurn(prompt: "明日の天気は", response: ClarificationContext.question)
        _ = try await collectReplies(try await service.streamReply(to: "うん"))
        _ = try await collectReplies(try await service.streamReply(to: "ありがとう"))
        let bodies = await server.runPosts.compactMap(\.jsonBody)
        XCTAssertEqual(bodies.map { $0["input"] }, ["うん", "ありがとう"], "the clarification is never sent as a fake turn")
        let first = try XCTUnwrap(bodies.first?["instructions"])
        XCTAssertTrue(first.hasPrefix(HermesConversationInstructions.persona))
        XCTAssertTrue(first.contains("利用者: 明日の天気は"))
        XCTAssertTrue(first.contains("猫: \(ClarificationContext.question)"))
        XCTAssertEqual(bodies.last?["instructions"], HermesConversationInstructions.persona)
    }

    // MARK: - 宛先判定用の直近の会話と履歴

    func testRecentTurnsComeFromTheHermesHistoryAndGrowWithAdoptedTurns() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "三毛猫だよ")]],
                                      history: [.json(200, #"""
            {"object":"list","session_id":"catrobot-old","data":[
              {"role":"user","content":"天気を調べて"},
              {"role":"assistant","content":"調べるね","tool_calls":[{"id":"c1"}]},
              {"role":"tool","content":"晴れ","tool_call_id":"c1"},
              {"role":"assistant","content":"晴れだよ"},
              {"role":"assistant","content":"","display_kind":"hidden"}
            ]}
            """#)])
        let service = makeService(server, records: continued())
        try await service.prepareMemory()
        let restored = await service.recentTurns()
        XCTAssertEqual(restored, [ConversationMemoryTurn(prompt: "天気を調べて", response: "晴れだよ")])
        _ = try await collectReplies(try await service.streamReply(to: "君は何猫？"))
        let grown = await service.recentTurns()
        XCTAssertEqual(grown.last, ConversationMemoryTurn(prompt: "君は何猫？", response: "三毛猫だよ"))
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
    }

    func testAFreshSessionDoesNotReadHistoryAtPreparation() async throws {
        let server = FakeHermesServer()
        let service = makeService(server)
        try await service.prepareMemory()
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAContinuedSessionThatHermesNoLongerHasIsReportedNotSilentlyReplaced() async throws {
        let records = continued("catrobot-gone")
        let server = FakeHermesServer(history: [Self.sessionNotFound])
        let service = makeService(server, records: records, sessionIDs: ["catrobot-next"])
        do { try await service.prepareMemory(); XCTFail("a lost session must be explicit") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .unavailable) }
        let failed = await service.memoryState()
        XCTAssertEqual(failed, .restoreFailed(.unavailable))
        await service.reset()
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-next")
    }

    func testRetryingAFailedRestoreReadsTheHistoryAgain() async throws {
        let server = FakeHermesServer(history: [Self.sessionNotFound, .json(200, #"""
            {"object":"list","session_id":"catrobot-old","data":[
              {"role":"user","content":"ただいま"},
              {"role":"assistant","content":"おかえり"}
            ]}
            """#)])
        let service = makeService(server, records: continued())
        do { try await service.prepareMemory(); XCTFail("the first read finds no session") } catch {}
        try await service.retryMemoryOperation()
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, [ConversationMemoryTurn(prompt: "ただいま", response: "おかえり")])
    }

    /// 受付の分からない送信しかない session は、Hermes に無くても失われたのではなく、まだ始まっていない。
    func testASubmissionThatNeverArrivedIsAFreshSessionNotALostOne() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-s1",
                                                                         hasUncertainSubmission: true))
        let service = makeService(FakeHermesServer(history: [Self.sessionNotFound, Self.sessionNotFound]), records: records)
        try await service.prepareMemory()
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        let transcript = try await service.transcript()
        XCTAssertEqual(transcript, [])
    }

    func testASubmissionThatMayHaveArrivedIsShownInTheTranscript() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-s1",
                                                                         hasUncertainSubmission: true))
        let server = FakeHermesServer(history: [.json(200, #"""
            {"object":"list","session_id":"catrobot-s1","data":[{"role":"user","content":"落ちる前の発言"}]}
            """#)])
        let transcript = try await makeService(server, records: records).transcript()
        XCTAssertEqual(transcript, [HermesTranscriptEntry(speaker: .user, text: "落ちる前の発言")])
    }

    func testAHistoryOutageDoesNotBlockTheConversation() async throws {
        let service = makeService(FakeHermesServer(history: [.transportFailure]), records: continued())
        try await service.prepareMemory()
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        let turns = await service.recentTurns()
        XCTAssertEqual(turns, [])
    }

    func testTheTranscriptShowsTheUserAndTheFinalCatTextOnly() async throws {
        let server = FakeHermesServer(history: [.json(200, #"""
            {"object":"list","session_id":"catrobot-old","data":[
              {"role":"user","content":"天気を調べて"},
              {"role":"assistant","content":"調べるね","tool_calls":[{"id":"c1"}],"reasoning":"private"},
              {"role":"tool","content":"晴れ","tool_call_id":"c1"},
              {"role":"assistant","content":"晴れだよ"},
              {"role":"user","content":"止めた発言"}
            ]}
            """#)])
        let transcript = try await makeService(server, records: continued()).transcript()
        XCTAssertEqual(transcript, [HermesTranscriptEntry(speaker: .user, text: "天気を調べて"),
                                    HermesTranscriptEntry(speaker: .cat, text: "晴れだよ"),
                                    HermesTranscriptEntry(speaker: .user, text: "止めた発言")])
    }

    func testTheTranscriptOfAConversationThatHasNotStartedIsEmpty() async throws {
        let server = FakeHermesServer()
        let transcript = try await makeService(server).transcript()
        XCTAssertEqual(transcript, [])
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// 受付の分からない最初の送信のあとでも、Hermes に会話があると読めたら受付済みとして残す（後で失われたら明示する）。
    func testAConversationFoundAfterAnUncertainFirstSubmissionIsReportedWhenLaterLost() async throws {
        let found = FakeHermesServer.Reply.json(200, #"""
            {"object":"list","session_id":"catrobot-s1","data":[{"role":"user","content":"落ちる前の発言"},{"role":"assistant","content":"やあ"}]}
            """#)
        for readsTranscript in [false, true] {
            let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-s1",
                                                                             hasUncertainSubmission: true))
            let first = makeService(FakeHermesServer(history: [found]), records: records)
            if readsTranscript { _ = try await first.transcript() } else { try await first.prepareMemory() }
            let record = await records.record
            XCTAssertEqual(record?.hasTurns, true, "Hermes has the conversation (transcript: \(readsTranscript))")
            XCTAssertEqual(record?.hasUncertainSubmission, true, "the uncertainty is not cleared without proof")

            let reconstructed = makeService(FakeHermesServer(history: [Self.sessionNotFound]), records: records)
            do {
                if readsTranscript { _ = try await reconstructed.transcript() } else { try await reconstructed.prepareMemory() }
                XCTFail("a conversation Hermes had must not silently become a new one (transcript: \(readsTranscript))")
            } catch {
                XCTAssertEqual(error as? ConversationMemoryError, .unavailable)
            }
            let state = await reconstructed.memoryState()
            XCTAssertEqual(state, .restoreFailed(.unavailable))
        }
    }

    /// 新しい会話に移った後に届いた、前の session の「見つからない」は、新しい会話を止めない。
    func testALateLostSessionAnswerForTheOldConversationDoesNotBlockTheNewOne() async throws {
        let records = continued("catrobot-old")
        let server = FakeHermesServer(history: [.gated("history", Self.sessionNotFound)])
        let service = makeService(server, records: records, sessionIDs: ["catrobot-next"])
        let reading = Task { try await service.transcript() }
        await server.waitUntilBlocked("history")
        await service.reset()
        await server.release("history")
        let transcript = try? await reading.value
        XCTAssertEqual(transcript, [], "the old conversation's answer is not shown for the new one")
        let state = await service.memoryState()
        XCTAssertEqual(state, .ready)
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-next")
    }

    // MARK: - 記憶の操作

    /// 会話の正本は Hermes。端末から Hermes の履歴は消さず、裏で session も切り替えない。
    func testForgettingIsNotOfferedBecauseHermesKeepsTheConversation() async throws {
        let records = continued()
        let server = FakeHermesServer()
        let service = makeService(server, records: records)
        do { try await service.forgetConversation(); XCTFail("the phone cannot delete the Hermes history") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .unsupported) }
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        let record = await records.record
        XCTAssertEqual(record?.sessionID, "catrobot-old")
    }

    func testMemoryUpdatesStartWithTheCurrentState() async throws {
        let service = makeService(FakeHermesServer())
        try await service.prepareMemory()
        var updates = await service.memoryUpdates().makeAsyncIterator()
        let first = await updates.next()
        XCTAssertEqual(first, .ready)
    }
}

private func collectReplies(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}

/// 試験で決まった値を順に返す。尽きたら最後の値をくり返す。
private final class Sequenced<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    init(_ values: [Value]) { self.values = values }
    func next() -> Value {
        lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
    }
}

/// 設定画面での変更を模す。service はターンごとにこれを読む。
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HermesConnection?
    init(_ value: HermesConnection?) { self.value = value }
    func get() -> HermesConnection? { lock.withLock { value } }
    func set(_ newValue: HermesConnection?) { lock.withLock { value = newValue } }
}
