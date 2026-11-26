import Foundation
import Security

protocol HermesCredentialStore: Sendable {
    func load() async throws -> HermesCredential?
    func save(_ credential: HermesCredential) async throws
    func delete() async throws
}

enum HermesCredentialStoreError: Error, Equatable, Sendable {
    case system(OSStatus)
    case invalidData
}

/// Keychain の generic password 1 件。service と account で範囲を決める。
actor KeychainHermesCredentialStore: HermesCredentialStore {
    /// 通常会話の API キー。account には接続先の origin を入れ、別の接続先へ古いキーを渡さない。
    static let conversationService = "com.kamby.CatRobot.hermes"
    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> HermesCredential? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HermesCredentialStoreError.system(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw HermesCredentialStoreError.invalidData
        }
        return HermesCredential(apiKey: key)
    }

    func save(_ credential: HermesCredential) throws {
        let values: [String: Any] = [
            kSecValueData as String: Data(credential.apiKey.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HermesCredentialStoreError.system(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesCredentialStoreError.system(status)
        }
    }
}

actor InMemoryHermesCredentialStore: HermesCredentialStore {
    private var credential: HermesCredential?
    func load() throws -> HermesCredential? { credential }
    func save(_ credential: HermesCredential) throws { self.credential = credential }
    func delete() throws { credential = nil }
}

#if DEBUG
extension KeychainHermesCredentialStore {
    /// DEBUG の接続プローブ専用の service。通常会話のキーとは混ざらない。
    static let probeService = "com.kamby.CatRobot.hermes-probe"

    init(account: String = "apiKey") {
        self.init(service: Self.probeService, account: account)
    }
}
#endif
