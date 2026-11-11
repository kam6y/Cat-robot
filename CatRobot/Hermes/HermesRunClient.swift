import Foundation

/// Hermes run API の最小クライアント。HTTPS だけを話し、SSE は使わない（最終出力は poll で受け取る）。
/// 取消は stop を送って poll し、Hermes が報告した terminal をそのまま返す（cancelled を作らない）。
actor HermesRunClient {
    /// API の base（profile の path prefix を含んでよい）。各 path はこの後ろにつなぐ。
    private let endpoint: URL
    private let credential: HermesCredential
    private let transport: any HermesTransport
    private let clock: any HermesClock
    private let idempotencyKey: @Sendable () async -> UUID
    private let requestTimeout: TimeInterval
    private let pollInterval: Duration

    init(endpoint: URL,
         credential: HermesCredential,
         transport: any HermesTransport,
         clock: any HermesClock = SystemHermesClock(),
         idempotencyKey: @escaping @Sendable () async -> UUID = { UUID() },
         requestTimeout: TimeInterval = 15,
         pollInterval: Duration = .seconds(1)) {
        self.endpoint = endpoint
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
        try await postRun(RunInput(input: input), idempotencyKey: await idempotencyKey())
    }

    /// 明示 session の続き。同じターンの再送は同じ key と同じ body にする（Hermes は body 全体で同一性を判定する）。
    /// 履歴は Hermes が session から読むので、端末の会話は送らない。
    /// instructions は Hermes の ephemeral system prompt（その run だけに重ねる）。nil なら送らない。
    func createRun(input: String, sessionID: String, idempotencyKey: UUID, instructions: String? = nil) async throws -> HermesRunHandle {
        guard Self.isValidRunID(sessionID) else { throw HermesClientError.invalidSessionID }
        return try await postRun(SessionRunInput(input: input, session_id: sessionID, instructions: instructions),
                                 idempotencyKey: idempotencyKey)
    }

    /// Hermes が正本の会話履歴の最新ページ（古い順）。応答の session_id は圧縮後の tip を指すことがある。
    /// Hermes に行が無い session（初回 run 前の新しい id、または Hermes 側で消えた session）は sessionNotFound。
    func history(sessionID: String, limit: Int = 100) async throws -> HermesSessionHistory {
        guard Self.isValidRunID(sessionID) else { throw HermesClientError.invalidSessionID }
        let query = [URLQueryItem(name: "order", value: "latest"), URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "inline_images", value: "false")]
        let response = try await exchange("GET", path: "api/sessions/\(sessionID)/messages", query: query)
        if response.statusCode == 404,
           (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error.code == "session_not_found" {
            throw HermesClientError.sessionNotFound
        }
        guard response.statusCode == 200 else { throw HermesClientError.httpStatus(response.statusCode) }
        guard let payload = try? JSONDecoder().decode(HistoryPayload.self, from: response.body),
              Self.isValidRunID(payload.session_id) else {
            throw HermesClientError.malformedResponse
        }
        return HermesSessionHistory(sessionID: payload.session_id, messages: payload.data)
    }

    private func postRun(_ input: some Encodable, idempotencyKey: UUID) async throws -> HermesRunHandle {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let response = try await send("POST", path: "v1/runs", expectedStatus: 202,
                                      headers: ["Content-Type": "application/json", "Idempotency-Key": idempotencyKey.uuidString],
                                      body: encoder.encode(input))
        let payload = try Self.decodeRun(response.body)
        return HermesRunHandle(runID: payload.run_id, status: .init(rawValue: payload.status), replayed: payload.replayed ?? false)
    }

    func run(id: String) async throws -> HermesRunState {
        guard Self.isValidRunID(id) else { throw HermesClientError.invalidRunID }
        let response = try await send("GET", path: "v1/runs/\(id)", expectedStatus: 200)
        let payload = try Self.decodeRun(response.body)
        guard payload.run_id == id else { throw HermesClientError.malformedResponse }
        return HermesRunState(runID: id, status: .init(rawValue: payload.status), sessionID: payload.session_id, output: payload.output)
    }

    /// stop の応答が告げた status（stopping、またはすでに終わっていた run の terminal）。応答に無ければ nil。
    @discardableResult
    func stop(id: String) async throws -> HermesRunStatus? {
        guard Self.isValidRunID(id) else { throw HermesClientError.invalidRunID }
        let response = try await send("POST", path: "v1/runs/\(id)/stop")
        guard !response.body.isEmpty else { return nil }
        guard let payload = try? JSONDecoder().decode(StopPayload.self, from: response.body),
              payload.run_id == nil || payload.run_id == id else { throw HermesClientError.malformedResponse }
        return payload.status.map { HermesRunStatus(rawValue: $0) }
    }

    func awaitTerminal(id: String, deadline: Duration) async throws -> HermesRunState {
        let start = await clock.now()
        let limit = TimeInterval(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        var lastStatus: String?
        while true {
            try Task.checkCancellation()
            guard await clock.now().timeIntervalSince(start) < limit else {
                throw HermesClientError.deadlineExceeded(lastStatus: lastStatus)
            }
            let state = try await run(id: id)
            lastStatus = state.status.rawValue
            // 期限前に出した poll で観測した terminal は、応答が期限をまたいでも捨てない（取消の記録にも使う）。
            if state.status.isTerminal { return state }
            let remaining = limit - (await clock.now().timeIntervalSince(start))
            guard remaining > 0 else { throw HermesClientError.deadlineExceeded(lastStatus: lastStatus) }
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
        let response = try await exchange(method, path: path, headers: headers, body: body)
        if response.statusCode == 404,
           (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error.code == "run_not_found" {
            throw HermesClientError.runNotFound
        }
        guard expectedStatus.map({ $0 == response.statusCode }) ?? (200..<300).contains(response.statusCode) else {
            throw HermesClientError.httpStatus(response.statusCode)
        }
        return response
    }

    /// 認証付きの 1 往復。401 だけはここで専用のエラーにし、他の status の判定は呼び出し側に任せる。
    private func exchange(_ method: String, path: String, headers: [String: String] = [:], body: Data? = nil,
                          query: [URLQueryItem] = []) async throws -> HermesHTTPResponse {
        try Task.checkCancellation()
        var authenticated = headers
        authenticated["Authorization"] = "Bearer \(credential.apiKey)"
        var url = endpoint.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        let request = HermesHTTPRequest(method: method, url: url,
                                        headers: authenticated, body: body, timeout: requestTimeout)
        let response = try await transport.send(request)
        if response.statusCode == 401 { throw HermesClientError.unauthorized }
        return response
    }

    private struct RunInput: Encodable { let input: String }
    private struct StopPayload: Decodable { let run_id: String?; let status: String? }
    private struct SessionRunInput: Encodable { let input: String; let session_id: String; let instructions: String? }
    private struct HistoryPayload: Decodable { let session_id: String; let data: [HermesSessionMessage] }
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String? }
        let error: Detail
    }
    private struct RunPayload: Decodable {
        let run_id: String
        let status: String
        let replayed: Bool?
        let session_id: String?
        let output: String?
    }

    private static func decodeRun(_ body: Data) throws -> RunPayload {
        guard let payload = try? JSONDecoder().decode(RunPayload.self, from: body), isValidRunID(payload.run_id) else {
            throw HermesClientError.malformedResponse
        }
        return payload
    }

    private static func isValidRunID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct HermesSessionHistory: Equatable, Sendable {
    let sessionID: String
    let messages: [HermesSessionMessage]
}

/// Hermes の会話 1 行。本文は文字列か、型付き part の配列（text part だけをつなぐ）。reasoning は読まない。
struct HermesSessionMessage: Decodable, Equatable, Sendable {
    let role: String
    let content: String?
    let displayKind: String?
    /// tool 呼び出しを運ぶ assistant 行（最終の返事ではない）。
    let hasToolCalls: Bool

    init(role: String, content: String?, displayKind: String? = nil, hasToolCalls: Bool = false) {
        self.role = role
        self.content = content
        self.displayKind = displayKind
        self.hasToolCalls = hasToolCalls
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        displayKind = try? container.decodeIfPresent(String.self, forKey: .displayKind)
        let text: String?
        if let plain = try? container.decodeIfPresent(String.self, forKey: .content) {
            text = plain
        } else if let parts = try? container.decodeIfPresent([Part].self, forKey: .content) {
            text = parts.compactMap(\.text).joined()
        } else {
            text = nil
        }
        content = text?.isEmpty == false ? text : nil
        let calls = try? container.decodeIfPresent([Ignored].self, forKey: .toolCalls)
        hasToolCalls = !(calls ?? []).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case displayKind = "display_kind"
        case toolCalls = "tool_calls"
    }

    private struct Part: Decodable {
        let text: String?
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let type = try? container.decodeIfPresent(String.self, forKey: .type)
            text = type == "text" ? try? container.decodeIfPresent(String.self, forKey: .text) : nil
        }
        private enum Key: String, CodingKey { case type, text }
    }

    /// 形を問わず 1 要素として読み飛ばす。
    private struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
