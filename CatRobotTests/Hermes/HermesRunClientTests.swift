import Foundation
import XCTest
@testable import CatRobot

/// 契約 r3 §2.4 / §4.1-1〜3: Hermes run API への wire を fake transport で厳密に確かめる。ネットワークには触れない。
final class HermesRunClientTests: XCTestCase {
    private let endpoint = URL(string: "https://192.168.0.202:18644")!

    private func makeClient(_ transport: any HermesTransport, clock: ManualHermesClock = ManualHermesClock(),
                            keys: [UUID]? = nil) throws -> HermesRunClient {
        let configuration = try HermesProbeConfiguration(endpoint: endpoint, pins: ["00"], deviceID: "sim-1")
        let generator = SequencedIdempotencyKeys(keys)
        return HermesRunClient(configuration: configuration, credential: HermesCredential(apiKey: "secret-key"),
                               transport: transport, clock: clock, idempotencyKey: { await generator.next() })
    }

    func testCapabilitiesSendsBearerAndReturnsRawBody() async throws {
        let transport = RecordingHermesTransport(responses: [.json(200, #"{"name":"hermes","tools":["echo"]}"#)])
        let client = try makeClient(transport)
        let capabilities = try await client.capabilities()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].url, URL(string: "https://192.168.0.202:18644/v1/capabilities"))
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer secret-key")
        XCTAssertNil(requests[0].body)
        XCTAssertEqual(capabilities.raw, Data(#"{"name":"hermes","tools":["echo"]}"#.utf8))
    }

    func testUnauthorizedIsReportedAsItsOwnError() async throws {
        let transport = RecordingHermesTransport(responses: [.json(401, #"{"error":"unauthorized"}"#)])
        let client = try makeClient(transport)
        do { _ = try await client.capabilities(); XCTFail("401 must throw") }
        catch { XCTAssertEqual(error as? HermesProbeError, .unauthorized) }
    }

    func testCreateRunSendsExactJSONBodyWithAFreshIdempotencyKeyPerCall() async throws {
        let keys = [UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, UUID(uuidString: "22222222-2222-4222-8222-222222222222")!]
        let transport = RecordingHermesTransport(responses: [
            .json(202, #"{"run_id":"run-1","status":"started","replayed":false,"extra":{"ignored":true}}"#),
            .json(202, #"{"run_id":"run-2","status":"started","replayed":true}"#)
        ])
        let client = try makeClient(transport, keys: keys)
        let first = try await client.createRun(input: "こんにちは")
        let second = try await client.createRun(input: "二回目")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(requests.map(\.url), Array(repeating: URL(string: "https://192.168.0.202:18644/v1/runs"), count: 2))
        XCTAssertEqual(requests[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer secret-key")
        XCTAssertEqual(requests[0].body, Data(#"{"input":"こんにちは"}"#.utf8), "body is exactly the documented JSON")
        XCTAssertEqual(requests[1].body, Data(#"{"input":"二回目"}"#.utf8))
        XCTAssertEqual(requests.map { $0.headers["Idempotency-Key"] }, keys.map(\.uuidString), "a new UUID per call")
        XCTAssertEqual(first, HermesRunHandle(runID: "run-1", status: HermesRunStatus(rawValue: "started"), replayed: false))
        XCTAssertEqual(second, HermesRunHandle(runID: "run-2", status: HermesRunStatus(rawValue: "started"), replayed: true))
    }

    func testRunStateDecodesKnownFieldsAndToleratesMissingOutput() async throws {
        let transport = RecordingHermesTransport(responses: [
            .json(200, #"{"run_id":"run-1","status":"running","session_id":"s-9","unknown":[1,2]}"#),
            .json(200, #"{"run_id":"run-1","status":"completed","session_id":"s-9","output":"にゃん 1234"}"#)
        ])
        let client = try makeClient(transport)
        let running = try await client.run(id: "run-1")
        let done = try await client.run(id: "run-1")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests[0].url, URL(string: "https://192.168.0.202:18644/v1/runs/run-1"))
        XCTAssertEqual(running, HermesRunState(runID: "run-1", status: HermesRunStatus(rawValue: "running"), sessionID: "s-9", output: nil))
        XCTAssertFalse(running.status.isTerminal)
        XCTAssertEqual(done.output, "にゃん 1234")
        XCTAssertTrue(done.status.isTerminal)
    }

    func testStopPostsWithoutABody() async throws {
        let transport = RecordingHermesTransport(responses: [.json(202, #"{"run_id":"run-1","status":"stopping"}"#)])
        let client = try makeClient(transport)
        try await client.stop(id: "run-1")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].url, URL(string: "https://192.168.0.202:18644/v1/runs/run-1/stop"))
        XCTAssertNil(requests[0].body)
        XCTAssertNil(requests[0].headers["Content-Type"])
    }

    func testAwaitTerminalPollsOncePerSecondUntilATerminalStatus() async throws {
        let transport = RecordingHermesTransport(responses: [
            .json(200, #"{"run_id":"run-1","status":"queued"}"#),
            .json(200, #"{"run_id":"run-1","status":"running"}"#),
            .json(200, #"{"run_id":"run-1","status":"completed","output":"done"}"#)
        ])
        let clock = ManualHermesClock()
        let client = try makeClient(transport, clock: clock)
        let state = try await client.awaitTerminal(id: "run-1", deadline: .seconds(30))
        let requests = await transport.requests
        let sleeps = await clock.sleeps
        XCTAssertEqual(state.status, HermesRunStatus(rawValue: "completed"))
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(1)], "sleep between polls, not after the terminal state")
    }

    func testAwaitTerminalTreatsUnknownStatusAsNotDoneAndReportsItAtTheDeadline() async throws {
        let transport = RecordingHermesTransport(responses: [.json(200, #"{"run_id":"run-1","status":"weird"}"#)], repeatLast: true)
        let clock = ManualHermesClock()
        let client = try makeClient(transport, clock: clock)
        do {
            _ = try await client.awaitTerminal(id: "run-1", deadline: .seconds(3))
            XCTFail("an unknown status must never count as success")
        } catch {
            XCTAssertEqual(error as? HermesProbeError, .deadlineExceeded(lastStatus: "weird"))
        }
        let requests = await transport.requests
        XCTAssertGreaterThanOrEqual(requests.count, 3)
        XCTAssertLessThanOrEqual(requests.count, 5, "polling stops at the deadline")
    }

    func testCancelStopsThenReportsTheObservedTerminalStatusWithoutInventingCancelled() async throws {
        let transport = RecordingHermesTransport(responses: [
            .json(202, #"{"run_id":"run-1","status":"stopping"}"#),
            .json(200, #"{"run_id":"run-1","status":"stopping"}"#),
            .json(200, #"{"run_id":"run-1","status":"completed","output":"finished first"}"#)
        ])
        let clock = ManualHermesClock()
        let client = try makeClient(transport, clock: clock)
        let state = try await client.cancel(id: "run-1", deadline: .seconds(30))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "GET"])
        XCTAssertEqual(requests[0].url.path, "/v1/runs/run-1/stop")
        XCTAssertEqual(state.status, HermesRunStatus(rawValue: "completed"), "record what Hermes reported")
    }

    func testMalformedJSONAndNon2xxAreDistinctErrors() async throws {
        let transport = RecordingHermesTransport(responses: [.json(200, "not json"), .json(503, "{}"), .json(302, "")])
        let client = try makeClient(transport)
        do { _ = try await client.run(id: "run-1"); XCTFail("malformed must throw") }
        catch { XCTAssertEqual(error as? HermesProbeError, .malformedResponse) }
        do { _ = try await client.run(id: "run-1"); XCTFail("503 must throw") }
        catch { XCTAssertEqual(error as? HermesProbeError, .httpStatus(503)) }
        do { _ = try await client.run(id: "run-1"); XCTFail("a redirect is an error, never followed") }
        catch { XCTAssertEqual(error as? HermesProbeError, .httpStatus(302)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3, "no follow-up request for the redirect")
    }

    func testTerminalStatusesAreExactlyCompletedCancelledFailed() {
        XCTAssertEqual(HermesRunStatus.terminal, [HermesRunStatus(rawValue: "completed"), HermesRunStatus(rawValue: "cancelled"), HermesRunStatus(rawValue: "failed")])
        XCTAssertFalse(HermesRunStatus(rawValue: "stopping").isTerminal)
        XCTAssertFalse(HermesRunStatus(rawValue: "error").isTerminal)
    }

    func testInsecureEndpointIsRejectedBeforeAnyRequest() {
        XCTAssertThrowsError(try HermesProbeConfiguration(endpoint: URL(string: "http://192.168.0.202:18644")!, pins: ["00"], deviceID: "d")) { error in
            XCTAssertEqual(error as? HermesProbeError, .insecureEndpoint)
        }
        XCTAssertThrowsError(try HermesProbeConfiguration(endpoint: endpoint, pins: [], deviceID: "d")) { error in
            XCTAssertEqual(error as? HermesProbeError, .missingPins)
        }
    }

    func testCredentialNeverPrintsItsSecret() {
        let credential = HermesCredential(apiKey: "super-secret-value")
        XCTAssertFalse(String(describing: credential).contains("super-secret-value"))
        XCTAssertFalse(String(reflecting: credential).contains("super-secret-value"))
    }

    func testInvalidRunIDsAreRejectedBeforeSending() async throws {
        let transport = RecordingHermesTransport(responses: [.json(200, #"{"run_id":"run-1","status":"running"}"#)], repeatLast: true)
        let client = try makeClient(transport)
        for id in ["", "..", "a/b", "a b", "a?b", "a%2Fb", "あ", String(repeating: "a", count: 129)] {
            do { _ = try await client.run(id: id); XCTFail("invalid ID must be refused") }
            catch { XCTAssertEqual(error as? HermesProbeError, .invalidRunID) }
            do { try await client.stop(id: id); XCTFail("invalid ID must be refused") }
            catch { XCTAssertEqual(error as? HermesProbeError, .invalidRunID) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMalformedCreatedIDAndMismatchedPolledIDAreRejected() async throws {
        let transport = RecordingHermesTransport(responses: [
            .json(202, #"{"run_id":"../other","status":"started","replayed":false}"#),
            .json(200, #"{"run_id":"other-run","status":"completed"}"#)
        ])
        let client = try makeClient(transport)
        do { _ = try await client.createRun(input: "hello"); XCTFail("malformed run ID must be refused") }
        catch { XCTAssertEqual(error as? HermesProbeError, .malformedResponse) }
        do { _ = try await client.run(id: "run-1"); XCTFail("another run must not satisfy this request") }
        catch { XCTAssertEqual(error as? HermesProbeError, .malformedResponse) }
    }

    func testCapabilitiesAndCreateRequireTheirDocumentedSuccessStatuses() async throws {
        let transport = RecordingHermesTransport(responses: [
            .json(201, "{}"), .json(200, #"{"run_id":"run-1","status":"started","replayed":false}"#)
        ])
        let client = try makeClient(transport)
        do { _ = try await client.capabilities(); XCTFail("capabilities requires 200") }
        catch { XCTAssertEqual(error as? HermesProbeError, .httpStatus(201)) }
        do { _ = try await client.createRun(input: "hello"); XCTFail("create requires 202") }
        catch { XCTAssertEqual(error as? HermesProbeError, .httpStatus(200)) }
    }

    func testNoPollIsSentAtOrAfterTheDeadline() async throws {
        let transport = RecordingHermesTransport(responses: [.json(200, #"{"run_id":"run-1","status":"running"}"#)], repeatLast: true)
        let client = try makeClient(transport)
        do { _ = try await client.awaitTerminal(id: "run-1", deadline: .seconds(3)); XCTFail("must reach deadline") }
        catch { XCTAssertEqual(error as? HermesProbeError, .deadlineExceeded(lastStatus: "running")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3, "poll at t=0,1,2 only")
    }

    func testTerminalObservedByAPollIssuedBeforeTheDeadlineIsReturnedEvenIfTheClockPassedIt() async throws {
        // 各 request が 1.5 s かかる。t=0 の poll は running（t=1.5）、sleep 1 s で t=2.5、期限 3 s の前に出した 2 回目の poll が
        // completed を返したときには t=4.0。期限前に出した poll で観測した terminal は捨てずに返す。
        let clock = ManualHermesClock()
        let transport = ClockAdvancingHermesTransport(clock: clock, advance: 1.5, responses: [
            .json(200, #"{"run_id":"run-1","status":"running"}"#),
            .json(200, #"{"run_id":"run-1","status":"completed","output":"late but real"}"#)
        ])
        let client = try makeClient(transport, clock: clock)
        let state = try await client.awaitTerminal(id: "run-1", deadline: .seconds(3))
        let requests = await transport.requests
        let sleeps = await clock.sleeps
        XCTAssertEqual(state.status, HermesRunStatus(rawValue: "completed"))
        XCTAssertEqual(state.output, "late but real")
        XCTAssertEqual(requests.count, 2, "no third poll after the terminal state")
        XCTAssertEqual(sleeps, [.seconds(1)], "no sleep after the terminal state")
    }
}

// MARK: - Test doubles

/// request のたびに仮想時刻を進める transport。遅い応答が期限をまたぐ状況を再現する。
actor ClockAdvancingHermesTransport: HermesTransport {
    private(set) var requests: [HermesHTTPRequest] = []
    private var responses: [RecordingHermesTransport.Scripted]
    private let clock: ManualHermesClock
    private let advance: TimeInterval

    init(clock: ManualHermesClock, advance: TimeInterval, responses: [RecordingHermesTransport.Scripted]) {
        self.clock = clock
        self.advance = advance
        self.responses = responses
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        requests.append(request)
        await clock.advance(by: advance)
        guard !responses.isEmpty else { throw HermesProbeError.transport("no scripted response") }
        switch responses.removeFirst() {
        case .json(let status, let body):
            return HermesHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }
}

actor RecordingHermesTransport: HermesTransport {
    enum Scripted {
        case json(Int, String)
    }
    private(set) var requests: [HermesHTTPRequest] = []
    private var responses: [Scripted]
    private let repeatLast: Bool

    init(responses: [Scripted], repeatLast: Bool = false) {
        self.responses = responses
        self.repeatLast = repeatLast
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw HermesProbeError.transport("no scripted response") }
        let next = repeatLast && responses.count == 1 ? responses[0] : responses.removeFirst()
        switch next {
        case .json(let status, let body):
            return HermesHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }
}

/// sleep を実際には待たず、呼び出された長さだけを記録し、仮想時刻を進める。
actor ManualHermesClock: HermesClock {
    private(set) var sleeps: [Duration] = []
    private var current = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { current }
    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
        current = current.addingTimeInterval(TimeInterval(duration.components.seconds))
    }
    /// request の所要時間など、sleep 以外で経過した時間を再現する。
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

actor SequencedIdempotencyKeys {
    private var keys: [UUID]?
    init(_ keys: [UUID]?) { self.keys = keys }
    func next() -> UUID {
        guard keys != nil, !keys!.isEmpty else { return UUID() }
        return keys!.removeFirst()
    }
}
