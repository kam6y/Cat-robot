import Foundation

/// Hermes API client の共通型。通常会話（本番）と DEBUG の接続プローブが共有する。
enum HermesClientError: Error, Equatable, Sendable {
    /// endpoint が https ではない。
    case insecureEndpoint
    /// 証明書 pin が 1 つも無い（DEBUG の診断用 pin 設定だけが使う）。
    case missingPins
    /// URL path に使えない run ID。
    case invalidRunID
    /// binding の作成順序に反する操作、または失効した bridge（DEBUG の診断 bridge だけが使う）。
    case invalidBridgeState
    /// 401。
    case unauthorized
    /// 2xx 以外（3xx を含む。redirect は追従しない）。
    case httpStatus(Int)
    /// JSON として読めない、または必須 field が無い。
    case malformedResponse
    /// 期限までに terminal な status にならなかった。未知の status は成功扱いしない。
    case deadlineExceeded(lastStatus: String?)
    /// transport 層の失敗（接続・TLS・タイムアウト）。secret を含めない短い説明。
    case transport(String)
    /// URL path に使えない session ID。
    case invalidSessionID
    /// Hermes に session の行が無い（404 session_not_found）。
    case sessionNotFound
    /// Hermes がその run を知らない（404 run_not_found。終端から時間が経って忘れられた run を含む）。
    case runNotFound
}

/// Windows 専用 API_SERVER_KEY。description にも debugDescription にも値を出さない。
struct HermesCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let apiKey: String
    var description: String { "HermesCredential(<redacted>)" }
    var debugDescription: String { description }
}

struct HermesHTTPRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval
}

struct HermesHTTPResponse: Equatable, Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

/// HTTP 1 往復。本番は標準 OS trust の URLSession、DEBUG の診断は pinned URLSession、試験は記録用 fake。
protocol HermesTransport: Sendable {
    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse
}

/// poll の間隔と期限のための時計。試験では仮想時刻に差し替える。
protocol HermesClock: Sendable {
    func now() async -> Date
    func sleep(for duration: Duration) async throws
}

struct SystemHermesClock: HermesClock {
    func now() -> Date { Date() }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Hermes が返す run の status。terminal の集合は installed api_server_runs.py の終端（completed / cancelled / failed と、
/// gateway 停止で永続化される interrupted）。stopping・unknown・waiting_for_approval は終端ではない。
struct HermesRunStatus: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let completed = HermesRunStatus(rawValue: "completed")
    static let cancelled = HermesRunStatus(rawValue: "cancelled")
    static let failed = HermesRunStatus(rawValue: "failed")
    static let interrupted = HermesRunStatus(rawValue: "interrupted")
    static let terminal: [HermesRunStatus] = [.completed, .cancelled, .failed, .interrupted]

    var isTerminal: Bool { Self.terminal.contains(self) }
}

struct HermesCapabilities: Equatable, Sendable {
    /// 応答本文そのまま。形は親の実測で追補されるまで解釈しない。
    let raw: Data
}

struct HermesRunHandle: Equatable, Sendable {
    let runID: String
    let status: HermesRunStatus
    let replayed: Bool
}

struct HermesRunState: Equatable, Sendable {
    let runID: String
    let status: HermesRunStatus
    let sessionID: String?
    let output: String?
}
