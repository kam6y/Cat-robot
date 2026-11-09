#if DEBUG
import Foundation

/// Hermes run API（契約 r3 §2.4）の最小クライアント。relay 経由の HTTPS だけを話し、SSE は使わない。
/// 取消は stop を送って poll し、Hermes が報告した terminal をそのまま返す（cancelled を作らない）。
actor HermesRunClient {
    private let configuration: HermesProbeConfiguration
    private let credential: HermesCredential
    private let transport: any HermesTransport
    private let clock: any HermesClock
    private let idempotencyKey: @Sendable () async -> UUID
    private let requestTimeout: TimeInterval
    private let pollInterval: Duration

    init(configuration: HermesProbeConfiguration,
         credential: HermesCredential,
         transport: any HermesTransport,
         clock: any HermesClock = SystemHermesClock(),
         idempotencyKey: @escaping @Sendable () async -> UUID = { UUID() },
         requestTimeout: TimeInterval = 15,
         pollInterval: Duration = .seconds(1)) {
        self.configuration = configuration
        self.credential = credential
        self.transport = transport
        self.clock = clock
        self.idempotencyKey = idempotencyKey
        self.requestTimeout = requestTimeout
        self.pollInterval = pollInterval
    }

    func capabilities() async throws -> HermesCapabilities {
        let response = try await send("GET", path: "v1/capabilities", expectedStatus: 200)
        return HermesCapabilities(raw: response.body)
    }

    func createRun(input: String) async throws -> HermesRunHandle {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let response = try await send("POST", path: "v1/runs", expectedStatus: 202,
                                      headers: ["Content-Type": "application/json", "Idempotency-Key": await idempotencyKey().uuidString],
                                      body: encoder.encode(RunInput(input: input)))
        let payload = try Self.decodeRun(response.body)
        return HermesRunHandle(runID: payload.run_id, status: .init(rawValue: payload.status), replayed: payload.replayed ?? false)
    }

    func run(id: String) async throws -> HermesRunState {
        guard Self.isValidRunID(id) else { throw HermesProbeError.invalidRunID }
        let response = try await send("GET", path: "v1/runs/\(id)", expectedStatus: 200)
        let payload = try Self.decodeRun(response.body)
        guard payload.run_id == id else { throw HermesProbeError.malformedResponse }
        return HermesRunState(runID: id, status: .init(rawValue: payload.status), sessionID: payload.session_id, output: payload.output)
    }

    func stop(id: String) async throws {
        guard Self.isValidRunID(id) else { throw HermesProbeError.invalidRunID }
        _ = try await send("POST", path: "v1/runs/\(id)/stop")
    }

    func awaitTerminal(id: String, deadline: Duration) async throws -> HermesRunState {
        let start = await clock.now()
        let limit = TimeInterval(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        var lastStatus: String?
        while true {
            try Task.checkCancellation()
            guard await clock.now().timeIntervalSince(start) < limit else {
                throw HermesProbeError.deadlineExceeded(lastStatus: lastStatus)
            }
            let state = try await run(id: id)
            lastStatus = state.status.rawValue
            // 期限前に出した poll で観測した terminal は、応答が期限をまたいでも捨てない（取消の記録にも使う）。
            if state.status.isTerminal { return state }
            let remaining = limit - (await clock.now().timeIntervalSince(start))
            guard remaining > 0 else { throw HermesProbeError.deadlineExceeded(lastStatus: lastStatus) }
            try await clock.sleep(for: min(pollInterval, .seconds(remaining)))
        }
    }

    /// 通信側の停止処理。端末の世代失効とbridgeのrevokeは呼出元が先に行う。
    func cancel(id: String, deadline: Duration) async throws -> HermesRunState {
        try await stop(id: id)
        return try await awaitTerminal(id: id, deadline: deadline)
    }

    private func send(_ method: String, path: String, expectedStatus: Int? = nil,
                      headers: [String: String] = [:], body: Data? = nil) async throws -> HermesHTTPResponse {
        try Task.checkCancellation()
        var authenticated = headers
        authenticated["Authorization"] = "Bearer \(credential.apiKey)"
        let request = HermesHTTPRequest(method: method, url: configuration.endpoint.appending(path: path),
                                        headers: authenticated, body: body, timeout: requestTimeout)
        let response = try await transport.send(request)
        if response.statusCode == 401 { throw HermesProbeError.unauthorized }
        guard expectedStatus.map({ $0 == response.statusCode }) ?? (200..<300).contains(response.statusCode) else {
            throw HermesProbeError.httpStatus(response.statusCode)
        }
        return response
    }

    private struct RunInput: Encodable { let input: String }
    private struct RunPayload: Decodable {
        let run_id: String
        let status: String
        let replayed: Bool?
        let session_id: String?
        let output: String?
    }

    private static func decodeRun(_ body: Data) throws -> RunPayload {
        guard let payload = try? JSONDecoder().decode(RunPayload.self, from: body), isValidRunID(payload.run_id) else {
            throw HermesProbeError.malformedResponse
        }
        return payload
    }

    private static func isValidRunID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
#endif
