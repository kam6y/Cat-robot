import Foundation
import Security
import XCTest
@testable import CatRobot

final class HermesCredentialStoreTests: XCTestCase {
    private func keychain(account: String = UUID().uuidString) -> KeychainHermesCredentialStore {
        let store = KeychainHermesCredentialStore(account: "test-\(account)")
        addTeardownBlock { try await store.delete() }
        return store
    }

    private func roundTrip(_ store: any HermesCredentialStore) async throws {
        let empty = try await store.load()
        XCTAssertNil(empty)
        try await store.save(HermesCredential(apiKey: "test-only-first"))
        let first = try await store.load()
        XCTAssertEqual(first, HermesCredential(apiKey: "test-only-first"))
        try await store.save(HermesCredential(apiKey: "test-only-rotated"))
        let rotated = try await store.load()
        XCTAssertEqual(rotated, HermesCredential(apiKey: "test-only-rotated"))
        try await store.delete()
        let deleted = try await store.load()
        XCTAssertNil(deleted)
        try await store.delete()
    }

    func testRealKeychainLoadsReplacesAndDeletesOnlyTheProbeEntry() async throws {
        try await roundTrip(keychain())
    }

    func testMemoryStoreHasTheSameCredentialLifecycle() async throws {
        try await roundTrip(InMemoryHermesCredentialStore())
    }

    func testKeychainDeletionPreservesAnotherAccountAndAnotherService() async throws {
        let account = UUID().uuidString
        let mine = keychain(account: account)
        let neighbor = keychain()
        try await neighbor.save(HermesCredential(apiKey: "test-only-neighbor"))
        let otherService: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kamby.CatRobot.hermes-probe.tests-other-service",
            kSecAttrAccount as String: "test-\(account)"
        ]
        var add = otherService
        add[kSecValueData as String] = Data("test-only-other-service".utf8)
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(otherService as CFDictionary) }

        try await mine.save(HermesCredential(apiKey: "test-only-mine"))
        try await mine.delete()

        let kept = try await neighbor.load()
        XCTAssertEqual(kept, HermesCredential(apiKey: "test-only-neighbor"))
        XCTAssertEqual(SecItemCopyMatching(otherService as CFDictionary, nil), errSecSuccess)
    }

    func testKeychainUsesWhenUnlockedThisDeviceOnlyAndTheDedicatedService() async throws {
        let account = UUID().uuidString
        let store = keychain(account: account)
        try await store.save(HermesCredential(apiKey: "test-only-attributes"))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kamby.CatRobot.hermes-probe",
            kSecAttrAccount as String: "test-\(account)",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
