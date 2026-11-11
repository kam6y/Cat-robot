import Foundation
import Observation

/// 通常会話の接続設定。接続先は https の root（scheme・host・port）だけを UserDefaults に置き、
/// API キーは Keychain に接続先の origin ごとに置く（別の接続先へ古いキーを送らない）。
/// 会話はターンごとに `connection()` を読む。保存直後のターンからそのまま効く。
@MainActor @Observable
final class HermesConnectionSettings {
    enum SaveError: Error, Equatable { case invalidEndpoint, invalidKey }

    static let endpointKey = "hermesConversationEndpoint"

    /// 保存済みの接続先。未設定なら nil。
    private(set) var endpoint: URL?
    /// 保存済みの接続先の origin にキーがあるか（値は持たない。表示用で、会話はこれを見ない）。
    private(set) var hasSavedKey = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: @Sendable (String) -> any HermesCredentialStore

    init(defaults: UserDefaults = .standard,
         credentials: @escaping @Sendable (String) -> any HermesCredentialStore = { HermesConnectionSettings.keychainStore(origin: $0) }) {
        self.defaults = defaults
        self.credentials = credentials
        endpoint = defaults.string(forKey: Self.endpointKey).flatMap(Self.endpoint(from:))
    }

    nonisolated static func keychainStore(origin: String) -> any HermesCredentialStore {
        KeychainHermesCredentialStore(service: KeychainHermesCredentialStore.conversationService, account: origin)
    }

    /// https の root だけを受け付け、scheme と host を小文字に、既定の 443 を省いた形にそろえる（同じ相手に origin を 1 つ）。
    /// userinfo・path・query・fragment、IPv6 リテラル、範囲外の port は受け付けない（キーを別の場所へ送らないため）。
    nonisolated static func endpoint(from text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host?.lowercased(), isHostName(host) else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        var root = URLComponents()
        root.scheme = "https"
        root.host = host
        root.port = parts.port == 443 ? nil : parts.port
        return root.url
    }

    private nonisolated static func isHostName(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.hasPrefix("-") && !host.contains("..")
            && host.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
    }

    /// HTTP の header にそのまま入る可視 ASCII だけ。前後の空白と改行は貼り付けの名残として落とす。空なら nil。
    private nonisolated static func credential(from text: String) throws -> HermesCredential? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        guard key.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw SaveError.invalidKey }
        return HermesCredential(apiKey: key)
    }

    /// 接続先とキーを確かめ、入力されたキーをその origin に保存してから接続先を保存する。
    /// キーを保存できなければ接続先も変えない（動いていた設定を残す）。空のキーは、その origin に保存済みのキーをそのまま使う。
    func save(endpointText: String, apiKey: String) async throws {
        guard let url = Self.endpoint(from: endpointText) else { throw SaveError.invalidEndpoint }
        let credential = try Self.credential(from: apiKey)
        let store = credentials(HermesConnection.origin(of: url))
        if let credential { try await store.save(credential) }
        defaults.set(url.absoluteString, forKey: Self.endpointKey)
        endpoint = url
        hasSavedKey = (try? await store.load()) != nil
    }

    /// 保存済みの接続先の origin のキーを消す。接続先は残る（キーを入れ直せば使える）。
    func deleteKey() async throws {
        guard let endpoint else { return }
        try await credentials(HermesConnection.origin(of: endpoint)).delete()
        if self.endpoint == endpoint { hasSavedKey = false }
    }

    /// 表示用に、保存済みの接続先にキーがあるかを読み直す。
    func refresh() async {
        guard let endpoint else { hasSavedKey = false; return }
        let saved = (try? await credentials(HermesConnection.origin(of: endpoint)).load()) != nil
        if self.endpoint == endpoint { hasSavedKey = saved }
    }

    /// そのターンの接続。接続先と、その origin に保存されたキーがそろっていなければ nil（未設定）。
    func connection() async -> HermesConnection? {
        guard let endpoint else { return nil }
        guard let credential = try? await credentials(HermesConnection.origin(of: endpoint)).load() else { return nil }
        return HermesConnection(endpoint: endpoint, credential: credential)
    }
}
