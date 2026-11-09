import Foundation
import XCTest
@testable import CatRobot

final class HermesBridgeClientTests: XCTestCase {
    private let bindingJSON = #"{"bindingID":"binding-1","generation":1,"expiresAt":2000}"#
    private let runJSON = #"{"runID":"run-1","sessionID":"s1","status":"running"}"#

    private func configuration() throws -> HermesProbeConfiguration {
        try HermesProbeConfiguration(endpoint: URL(string: "https://127.0.0.1:18644")!,
                                     pins: ["00"], deviceID: "test-device")
    }

    private func ready(_ replies: [RecordingHermesTransport.Scripted] = [],
                       clock: ManualHermesClock = ManualHermesClock()) async throws
        -> (HermesBridgeClient, RecordingHermesTransport) {
        let transport = RecordingHermesTransport(responses: [.json(201, bindingJSON), .json(202, runJSON)] + replies)
        let bridge = HermesBridgeClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                       transport: transport, clock: clock)
        _ = try await bridge.bind()
        _ = try await bridge.submitRun(input: "use echo")
        return (bridge, transport)
    }

    private func call() -> HermesDeviceCall {
        HermesDeviceCall(bindingID: "binding-1", runID: "run-1", sessionID: "s1", generation: 1,
                         callID: "call-1", tool: "echo", arguments: ["text": "nonce"],
                         expiresAt: Date(timeIntervalSince1970: 1010))
    }

    func testExactWireAndAcceptedEcho() async throws {
        let calls = #"{"calls":[{"bindingID":"binding-1","runID":"run-1","sessionID":"s1","generation":1,"callID":"call-1","tool":"echo","arguments":{"text":"nonce"},"expiresAt":1010}]}"#
        let (bridge, transport) = try await ready([.json(200, calls), .json(200, #"{"accepted":true}"#)])
        let polled = try await bridge.pollCalls()
        XCTAssertEqual(polled.count, 1)
        guard let call = polled.first else { XCTFail("expected one delivered call"); return }
        let outcome = await bridge.process(call)
        XCTAssertEqual(outcome, .accepted)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "POST", "GET", "POST"])
        XCTAssertEqual(requests.map(\.url.path), ["/bridge/bindings", "/bridge/bindings/binding-1/run",
                                                "/bridge/bindings/binding-1/calls",
                                                "/bridge/bindings/binding-1/calls/call-1/result"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "Bearer test-only-key" })
        let query = URLComponents(url: requests[2].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(Set(query?.map { "\($0.name)=\($0.value ?? "")" } ?? []), ["generation=1", "wait=10"])
        XCTAssertEqual(requests[0].body, Data(#"{"deviceID":"test-device"}"#.utf8))
        XCTAssertEqual(requests[1].body, Data(#"{"input":"use echo"}"#.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[3].body)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["runID", "generation", "ok", "text"])
        XCTAssertEqual(body["runID"] as? String, "run-1")
        XCTAssertEqual(body["generation"] as? Int, 1)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["text"] as? String, "nonce")
    }

    func testSubmitCarriesTheOuterBudgetAndOtherBridgeRequestsKeepTheSingleRoundTripTimeout() async throws {
        // 契約 r3 §2.5: relay は submit（capabilities 15 s + run 作成 15 s × 2）を 50 s の deadline で打ち切る。端末の submit 要求だけ
        // その外側で待つ（60 s）。他の bridge 要求は既存の 15 s を維持する。
        let calls = #"{"calls":[{"bindingID":"binding-1","runID":"run-1","sessionID":"s1","generation":1,"callID":"call-1","tool":"echo","arguments":{"text":"nonce"},"expiresAt":1010}]}"#
        let (bridge, transport) = try await ready([.json(200, calls), .json(200, #"{"accepted":true}"#), .json(200, "{}")])
        let polled = try await bridge.pollCalls()
        _ = await bridge.process(try XCTUnwrap(polled.first))
        try await bridge.revoke()
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.path), ["/bridge/bindings", "/bridge/bindings/binding-1/run",
                                                "/bridge/bindings/binding-1/calls",
                                                "/bridge/bindings/binding-1/calls/call-1/result",
                                                "/bridge/bindings/binding-1/revoke"])
        XCTAssertEqual(requests.map(\.timeout), [15, 60, 15, 15, 15])
        XCTAssertGreaterThan(requests[1].timeout, 50, "the device outlives the relay's 50 s submit deadline")
        XCTAssertEqual(HermesBridgeClient.submitRequestTimeout, 60)
        XCTAssertEqual(HermesBridgeClient.requestTimeout, 15)
    }

    func testMismatchedExpiredAndUnsafeCallsNeverPostResults() async throws {
        let (bridge, transport) = try await ready()
        var wrongBinding = call(); wrongBinding.bindingID = "other-binding"
        var wrongRun = call(); wrongRun.runID = "other-run"
        var wrongGeneration = call(); wrongGeneration.generation = 2
        var expired = call(); expired.expiresAt = Date(timeIntervalSince1970: 1000)
        var unsafe = call(); unsafe.callID = "../escape"
        for candidate in [wrongBinding, wrongRun, wrongGeneration, expired, unsafe] {
            let outcome = await bridge.process(candidate)
            XCTAssertEqual(outcome, .discarded)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testDuplicateDeliveryRetainsOriginalOutcomeWithoutReposting() async throws {
        let (bridge, transport) = try await ready([.json(200, #"{"accepted":true}"#)])
        let first = await bridge.process(call())
        let duplicate = await bridge.process(call())
        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(duplicate, first)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testLostAcknowledgementRemainsUnknownAndNeverRetries() async throws {
        // Exhausted fake response queue throws a transport failure AFTER recording the result request.
        let (bridge, transport) = try await ready()
        let first = await bridge.process(call())
        let duplicate = await bridge.process(call())
        XCTAssertEqual(first, .unknown)
        XCTAssertEqual(duplicate, .unknown)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testServerRefusalAndMalformedAcknowledgementNeverRetry() async throws {
        for status in [404, 409, 410] {
            let (bridge, transport) = try await ready([.json(status, "{}")])
            let first = await bridge.process(call())
            let duplicate = await bridge.process(call())
            XCTAssertEqual(first, .rejected(status))
            XCTAssertEqual(duplicate, first)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 3)
        }
        let (bridge, transport) = try await ready([.json(200, "{}")])
        let result = await bridge.process(call())
        let replay = await bridge.process(call())
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(replay, .unknown)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testReceiptExpiryDoesNotMakeAnExpiredCallExecutableAgain() async throws {
        let clock = ManualHermesClock()
        let (bridge, transport) = try await ready([.json(200, #"{"accepted":true}"#)], clock: clock)
        let first = await bridge.process(call())
        XCTAssertEqual(first, .accepted)
        await clock.advance(by: 601)
        let expired = await bridge.process(call())
        XCTAssertEqual(expired, .discarded)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCancelRevokesStopsThenReportsTheObservedCompletedState() async throws {
        let clock = ManualHermesClock()
        let (bridge, transport) = try await ready([
            .json(200, "{}"), .json(202, "{}"),
            .json(200, #"{"run_id":"run-1","status":"completed","output":"completed first"}"#)
        ], clock: clock)
        let runClient = HermesRunClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                        transport: transport, clock: clock)
        let result = try await bridge.cancel(using: runClient, deadline: .seconds(45))
        XCTAssertTrue(result.revokeAccepted)
        XCTAssertTrue(result.stopAccepted)
        XCTAssertEqual(result.terminal.status, .completed)
        let late = await bridge.process(call())
        XCTAssertEqual(late, .discarded)
        let requests = await transport.requests
        XCTAssertEqual(requests.suffix(3).map(\.url.path), ["/bridge/bindings/binding-1/revoke", "/v1/runs/run-1/stop", "/v1/runs/run-1"])
    }

    func testBindingRequiresTheExactStatusAndValidIdentityAndLifetime() async throws {
        for status in [200, 401, 503] {
            let transport = RecordingHermesTransport(responses: [.json(status, bindingJSON)])
            let bridge = HermesBridgeClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                           transport: transport, clock: ManualHermesClock())
            do { _ = try await bridge.bind(); XCTFail("unexpected bind status must fail") }
            catch { XCTAssertEqual(error as? HermesProbeError, status == 401 ? .unauthorized : .httpStatus(status)) }
        }
        for body in ["not json", #"{"bindingID":"../bad","generation":1,"expiresAt":2000}"#,
                     #"{"bindingID":"b","generation":0,"expiresAt":2000}"#,
                     #"{"bindingID":"b","generation":1,"expiresAt":1000}"#] {
            let transport = RecordingHermesTransport(responses: [.json(201, body)])
            let bridge = HermesBridgeClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                           transport: transport, clock: ManualHermesClock())
            do { _ = try await bridge.bind(); XCTFail("invalid bind body must fail") }
            catch { XCTAssertEqual(error as? HermesProbeError, .malformedResponse) }
        }
    }

    func testSubmissionRequires202AndASafeRunID() async throws {
        for (status, body) in [(200, runJSON), (202, #"{"runID":"../bad","status":"running"}"#), (202, "{}")] {
            let transport = RecordingHermesTransport(responses: [.json(201, bindingJSON), .json(status, body)])
            let bridge = HermesBridgeClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                           transport: transport, clock: ManualHermesClock())
            _ = try await bridge.bind()
            do { _ = try await bridge.submitRun(input: "x"); XCTFail("invalid submission must fail") }
            catch { XCTAssertEqual(error as? HermesProbeError, status == 200 ? .httpStatus(200) : .malformedResponse) }
        }
    }

    func testMockRejectionsArePostedAsErrorsWithNoText() async throws {
        for (tool, arguments, reason) in [("move", ["text": "x"], "unknownTool"), ("echo", [:], "missingText"),
                                          ("echo", ["text": String(repeating: "猫", count: 1_025)], "textTooLong")] {
            let (bridge, transport) = try await ready([.json(200, #"{"accepted":true}"#)])
            var rejected = call(); rejected.tool = tool; rejected.arguments = arguments
            let result = await bridge.process(rejected)
            XCTAssertEqual(result, .accepted, "acknowledges the rejection result")
            let requests = await transport.requests
            guard let body = requests.last?.body else { XCTFail("expected a result post"); continue }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["ok"] as? Bool, false)
            XCTAssertEqual(json["error"] as? String, reason)
            XCTAssertNil(json["text"])
        }
    }

    func testServerDuplicateAndContradictoryAcknowledgementsAreDistinct() async throws {
        for (body, expected) in [(#"{"accepted":false,"duplicate":true}"#, HermesCallOutcome.duplicate),
                                  (#"{"accepted":true,"duplicate":true}"#, HermesCallOutcome.unknown)] {
            let (bridge, _) = try await ready([.json(200, body)])
            let result = await bridge.process(call())
            XCTAssertEqual(result, expected)
        }
    }

    func testFailedRevokeOrStopStillPollsAndRecordsWhatWasAccepted() async throws {
        for (revokeStatus, stopStatus) in [(503, 202), (200, 409)] {
            let clock = ManualHermesClock()
            let (bridge, transport) = try await ready([
                .json(revokeStatus, "{}"), .json(stopStatus, "{}"),
                .json(200, #"{"run_id":"run-1","status":"cancelled"}"#)
            ], clock: clock)
            let run = HermesRunClient(configuration: try configuration(), credential: HermesCredential(apiKey: "test-only-key"),
                                      transport: transport, clock: clock)
            let result = try await bridge.cancel(using: run, deadline: .seconds(45))
            XCTAssertEqual(result.revokeAccepted, revokeStatus == 200)
            XCTAssertEqual(result.stopAccepted, stopStatus == 202)
            XCTAssertEqual(result.terminal.status, .cancelled)
            let requests = await transport.requests
            XCTAssertEqual(requests.suffix(3).map(\.url.path), ["/bridge/bindings/binding-1/revoke", "/v1/runs/run-1/stop", "/v1/runs/run-1"])
        }
    }

    func testLocalGenerationIsInvalidatedBeforeAwaitingRevoke() async throws {
        let paused = expectation(description: "revoke is in flight")
        let gate = ConversationTestGate()
        let clock = ManualHermesClock()
        let base = RecordingHermesTransport(responses: [.json(201, bindingJSON), .json(202, runJSON),
            .json(200, "{}"), .json(202, "{}"), .json(200, #"{"run_id":"run-1","status":"cancelled"}"#)])
        let transport = RevokeHoldingTransport(base: base, gate: gate, paused: paused)
        let configuration = try configuration()
        let credential = HermesCredential(apiKey: "test-only-key")
        let bridge = HermesBridgeClient(configuration: configuration, credential: credential, transport: transport, clock: clock)
        let run = HermesRunClient(configuration: configuration, credential: credential, transport: transport, clock: clock)
        _ = try await bridge.bind()
        _ = try await bridge.submitRun(input: "use echo")
        let cancellation = Task { try await bridge.cancel(using: run, deadline: .seconds(45)) }
        await fulfillment(of: [paused], timeout: 1)
        let late = await bridge.process(call())
        XCTAssertEqual(late, .discarded)
        let duringRevoke = await base.requests
        XCTAssertEqual(duringRevoke.count, 2, "no result is posted while revoke is suspended")
        await gate.open()
        let result = try await cancellation.value
        XCTAssertEqual(result.terminal.status, .cancelled)
    }

}

private actor RevokeHoldingTransport: HermesTransport {
    let base: RecordingHermesTransport
    let gate: ConversationTestGate
    let paused: XCTestExpectation

    init(base: RecordingHermesTransport, gate: ConversationTestGate, paused: XCTestExpectation) {
        self.base = base; self.gate = gate; self.paused = paused
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        if request.url.path.hasSuffix("/revoke") {
            paused.fulfill()
            await gate.wait()
        }
        return try await base.send(request)
    }
}
