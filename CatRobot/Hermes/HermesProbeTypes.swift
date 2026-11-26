#if DEBUG
import Foundation

/// Hermes 接続プローブ（契約 r3）の非秘密の接続設定。診断専用で、通常の会話経路からは参照しない。
/// pin は証明書 DER 全体の SHA-256（小文字 hex）。
struct HermesProbeConfiguration: Equatable, Sendable {
    let endpoint: URL
    let pins: [String]
    let deviceID: String

    init(endpoint: URL, pins: [String], deviceID: String) throws {
        guard endpoint.scheme?.lowercased() == "https" else { throw HermesClientError.insecureEndpoint }
        let normalized = pins.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw HermesClientError.missingPins }
        self.endpoint = endpoint
        self.pins = normalized
        self.deviceID = deviceID
    }
}
#endif
