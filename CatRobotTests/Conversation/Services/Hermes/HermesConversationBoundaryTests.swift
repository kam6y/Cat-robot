import Foundation
import XCTest
@testable import CatRobot

/// Navigator の観測を正式な Driver の直列検証へ取り込んだ回帰試験。
final class HermesConversationBoundaryTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443/")!,
                                              credential: HermesCredential(apiKey: "client-key"))

    private func makeService(_ server: FakeHermesServer, records: InMemoryHermesSessionRecordStore = InMemoryHermesSessionRecordStore(),
                             sessionIDs: [String] = ["catrobot-s1", "catrobot-s2"]) -> HermesConversationService {
        let resolved = connection
        let ids = ProbeSequenced(sessionIDs)
        return HermesConversationService(connection: { resolved }, transport: server, records: records, clock: SteppingHermesClock(),
                                         timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: .seconds(10), submitRetryDelay: .seconds(1)),
                                         makeSessionID: { ids.next() }, makeIdempotencyKey: { UUID() })
    }

    /// 文字入力の置き換え・声の割り込みの直後: 取り消したターンの worker が要求の応答待ちでも、次のターンは busy で拒否されない。
    func testANewTurnRightAfterACancelledOneIsNotRefusedAsBusy() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-1"), hermesAccepted("run-2")],
                                      polls: ["run-1": [.gated("poll", hermesRun("run-1", "completed", output: "古い"))],
                                              "run-2": [hermesRun("run-2", "completed", output: "新しい")]])
        let service = makeService(server)
        let stream = try await service.streamReply(to: "古い質問")
        let consumer = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("poll")
        consumer.cancel()
        _ = try? await consumer.value
        let release = Task { try? await Task.sleep(for: .milliseconds(200)); await server.release("poll") }
        do {
            let outputs = try await probeCollect(try await service.streamReply(to: "新しい質問"))
            XCTAssertEqual(outputs, ["新しい"])
        } catch {
            XCTFail("next turn failed: \(error)")
        }
        _ = await release.value
    }

    /// installed Hermes 自身の表示は display_kind != "hidden"（api_server_openai_routes.py:1592）。それ以外の kind の行も消さない。
    func testOnlyRowsHermesHidesAreLeftOutOfTheTranscript() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(history: [.json(200, #"""
            {"object":"list","session_id":"catrobot-old","data":[
              {"role":"user","content":"こんにちは","display_kind":"message"},
              {"role":"assistant","content":"やあ","display_kind":"message"},
              {"role":"assistant","content":"","display_kind":"hidden"}
            ]}
            """#)])
        let transcript = try await makeService(server, records: records).transcript()
        XCTAssertEqual(transcript.map(\.text), ["こんにちは", "やあ"])
    }

    /// 履歴の応答の session_id（compaction の tip）が path に使えない値なら、記録の session を差し替えない。
    func testAnUnusableTipFromHistoryDoesNotReplaceTheSession() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old", hasTurns: true))
        let server = FakeHermesServer(runs: [hermesAccepted("run-1")], polls: ["run-1": [hermesRun("run-1", "completed", output: "うん")]],
                                      history: [.json(200, #"{"object":"list","session_id":"../escape","data":[]}"#)])
        let service = makeService(server, records: records)
        try await service.prepareMemory()
        let saved = await records.record
        XCTAssertEqual(saved?.sessionID, "catrobot-old")
    }

    /// 次のターンは取り消したターンの worker の終了を待つ。その worker は送信中の 1 本を終えたら後始末を続けない。
    func testCancellationDuringCleanupStopsAfterTheRequestInFlight() async throws {
        let records = InMemoryHermesSessionRecordStore(HermesSessionRecord(origin: connection.origin, sessionID: "catrobot-old",
                                                                         hasTurns: true, unsettledRunIDs: ["run-a", "run-b"]))
        let server = FakeHermesServer(runs: [hermesAccepted("run-never")],
                                      stops: ["run-a": [.gated("stop-a", .json(200, #"{"run_id":"run-a","status":"stopping"}"#))]])
        let service = makeService(server, records: records)
        let stream = try await service.streamReply(to: "ねえ")
        let consumer = Task { try await probeCollect(stream) }
        await server.waitUntilBlocked("stop-a")
        consumer.cancel()
        _ = try? await consumer.value
        await server.release("stop-a")
        try await Task.sleep(for: .milliseconds(200))
        let calls = await server.requests.map { "\($0.method) \($0.url.path)" }
        XCTAssertEqual(calls, ["POST /v1/runs/run-a/stop"], "no further cleanup and no submission once the turn is cancelled")
        let record = await records.record
        XCTAssertEqual(record?.unsettledRunIDs, ["run-a", "run-b"], "runs not confirmed ended stay recorded")
    }
}

private func probeCollect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}

private final class ProbeSequenced<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    init(_ values: [Value]) { self.values = values }
    func next() -> Value { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}
