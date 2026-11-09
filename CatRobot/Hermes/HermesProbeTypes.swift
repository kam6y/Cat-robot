#if DEBUG
import Foundation

/// Hermes 接続プローブ（契約 r3）の共通型。診断専用で、通常の会話経路からは参照しない。
enum HermesProbeError: Error, Equatable, Sendable {
    /// endpoint が https ではない。
    case insecureEndpoint
    /// 証明書 pin が 1 つも無い。
    case missingPins
    /// URL path に使えない run ID。
    case invalidRunID
    /// binding の作成順序に反する操作、または失効した bridge。
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
}

/// 非秘密の接続設定。pin は証明書 DER 全体の SHA-256（小文字 hex）。
struct HermesProbeConfiguration: Equatable, Sendable {
    let endpoint: URL
    let pins: [String]
    let deviceID: String

    init(endpoint: URL, pins: [String], deviceID: String) throws {
        guard endpoint.scheme?.lowercased() == "https" else { throw HermesProbeError.insecureEndpoint }
        let normalized = pins.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw HermesProbeError.missingPins }
        self.endpoint = endpoint
        self.pins = normalized
        self.deviceID = deviceID
    }
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

/// HTTP 1 往復。本番は pinned URLSession、試験は記録用 fake。
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

/// Hermes が返す run の status。terminal の集合は installed terminal_run_status（completed / cancelled / failed）。
struct HermesRunStatus: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let completed = HermesRunStatus(rawValue: "completed")
    static let cancelled = HermesRunStatus(rawValue: "cancelled")
    static let failed = HermesRunStatus(rawValue: "failed")
    static let terminal: [HermesRunStatus] = [.completed, .cancelled, .failed]

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
#endif
