import Security
import XCTest
@testable import CatRobot

/// 通常会話の接続設定。接続先は https の root だけ、キーは接続先の origin ごとに保存し、ターンごとに読む。
@MainActor
final class HermesConnectionSettingsTests: XCTestCase {
    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let keys: HermesKeyStoresFake
        let settings: HermesConnectionSettings
        func tearDown() { defaults.removePersistentDomain(forName: name) }
    }

    private func makeFixture(endpoint: String? = nil, keys: HermesKeyStoresFake = HermesKeyStoresFake()) -> Fixture {
        let name = "hermes-connection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        if let endpoint { defaults.set(endpoint, forKey: HermesConnectionSettings.endpointKey) }
        return Fixture(name: name, defaults: defaults, keys: keys,
                       settings: HermesConnectionSettings(defaults: defaults, credentials: { keys.store(for: $0) }))
    }

    private func connection(_ endpoint: String, _ key: String) -> HermesConnection {
        HermesConnection(endpoint: URL(string: endpoint)!, credential: HermesCredential(apiKey: key))
    }

    func testRootHTTPSEndpointsAreNormalizedToOneOrigin() {
        let cases = [("https://Hermes.Example:8443", "https://hermes.example:8443"),
                     ("HTTPS://hermes.example/", "https://hermes.example"),
                     ("https://hermes.example:443/", "https://hermes.example"),
                     ("  https://192.168.0.202:18644\n", "https://192.168.0.202:18644")]
        for (input, expected) in cases {
            XCTAssertEqual(HermesConnectionSettings.endpoint(from: input)?.absoluteString, expected, input)
        }
    }

    func testEndpointsThatCouldSendTheKeySomewhereElseAreRefused() {
        let refused = ["http://hermes.example", "ftp://hermes.example", "hermes.example", "", "https://",
                       "https://user:pw@hermes.example", "https://@hermes.example",
                       "https://hermes.example/v1", "https://hermes.example//",
                       "https://hermes.example/?a=1", "https://hermes.example?", "https://hermes.example/#x", "https://hermes.example#",
                       "https://hermes.example:0", "https://hermes.example:99999", "https://[::1]:8443", "https://ho st"]
        for input in refused {
            XCTAssertNil(HermesConnectionSettings.endpoint(from: input), input)
        }
    }

    func testTheKeyIsSavedForTheEndpointOriginAndUsedOnlyThere() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        try await f.settings.save(endpointText: "https://hermes.example:8443", apiKey: "  key-a\n")
        let current = await f.settings.connection()
        XCTAssertEqual(current, connection("https://hermes.example:8443", "key-a"), "pasted whitespace is not part of the key")
        XCTAssertEqual(f.defaults.string(forKey: HermesConnectionSettings.endpointKey), "https://hermes.example:8443")
        let saved = await f.keys.savedKey(for: "https://hermes.example:8443")
        XCTAssertEqual(saved, HermesCredential(apiKey: "key-a"))
        XCTAssertEqual(f.keys.requestedOrigins, ["https://hermes.example:8443"])
        XCTAssertTrue(f.settings.hasSavedKey)
    }

    func testChangingTheOriginNeverSendsTheOldKey() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        try await f.settings.save(endpointText: "https://a.example", apiKey: "key-a")
        try await f.settings.save(endpointText: "https://b.example:8443", apiKey: "")
        let unconfigured = await f.settings.connection()
        XCTAssertNil(unconfigured, "the key saved for a.example must not go to b.example")
        XCTAssertFalse(f.settings.hasSavedKey)
        try await f.settings.save(endpointText: "https://b.example:8443", apiKey: "key-b")
        let b = await f.settings.connection()
        XCTAssertEqual(b, connection("https://b.example:8443", "key-b"))
        try await f.settings.save(endpointText: "https://a.example/", apiKey: "")
        let a = await f.settings.connection()
        XCTAssertEqual(a, connection("https://a.example", "key-a"), "an origin keeps the key saved for it")
    }

    func testARefusedEndpointChangesNothing() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        try await f.settings.save(endpointText: "https://a.example", apiKey: "key-a")
        do {
            try await f.settings.save(endpointText: "http://a.example", apiKey: "key-x")
            XCTFail("an insecure endpoint must be refused")
        } catch {
            XCTAssertEqual(error as? HermesConnectionSettings.SaveError, .invalidEndpoint)
        }
        XCTAssertEqual(f.settings.endpoint?.absoluteString, "https://a.example")
        XCTAssertEqual(f.keys.requestedOrigins, ["https://a.example"], "no key store is opened for a refused endpoint")
        let current = await f.settings.connection()
        XCTAssertEqual(current, connection("https://a.example", "key-a"))
    }

    func testAKeyThatCannotBeSentAsAHeaderIsRefusedWithTheEndpoint() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        for key in ["bad key", "bad\nkey", "鍵"] {
            do {
                try await f.settings.save(endpointText: "https://a.example", apiKey: key)
                XCTFail("\(key.debugDescription) must be refused")
            } catch {
                XCTAssertEqual(error as? HermesConnectionSettings.SaveError, .invalidKey, key.debugDescription)
            }
        }
        XCTAssertNil(f.settings.endpoint, "a refused save stores neither the endpoint nor the key")
        XCTAssertNil(f.defaults.string(forKey: HermesConnectionSettings.endpointKey))
        XCTAssertTrue(f.keys.requestedOrigins.isEmpty)
    }

    func testAKeyThatCannotBeStoredKeepsTheWorkingConnection() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        try await f.settings.save(endpointText: "https://a.example", apiKey: "key-a")
        f.keys.failSaves(for: "https://b.example")
        do {
            try await f.settings.save(endpointText: "https://b.example", apiKey: "key-b")
            XCTFail("the keychain failure must surface")
        } catch {
            XCTAssertNotNil(error as? HermesCredentialStoreError)
        }
        XCTAssertEqual(f.settings.endpoint?.absoluteString, "https://a.example")
        XCTAssertEqual(f.defaults.string(forKey: HermesConnectionSettings.endpointKey), "https://a.example")
        let current = await f.settings.connection()
        XCTAssertEqual(current, connection("https://a.example", "key-a"))
    }

    func testASavedEndpointAndItsKeyAreReadAtTheTurnAfterLaunch() async throws {
        let keys = HermesKeyStoresFake()
        try await keys.store(for: "https://a.example").save(HermesCredential(apiKey: "key-a"))
        let f = makeFixture(endpoint: "https://a.example", keys: keys); defer { f.tearDown() }
        XCTAssertEqual(f.settings.endpoint?.absoluteString, "https://a.example")
        let current = await f.settings.connection()
        XCTAssertEqual(current, connection("https://a.example", "key-a"), "no refresh is needed before the first turn")
    }

    func testAStoredEndpointThatIsNotARootHTTPSURLIsIgnored() async throws {
        let keys = HermesKeyStoresFake()
        try await keys.store(for: "http://a.example").save(HermesCredential(apiKey: "key-a"))
        let f = makeFixture(endpoint: "http://a.example", keys: keys); defer { f.tearDown() }
        XCTAssertNil(f.settings.endpoint)
        let current = await f.settings.connection()
        XCTAssertNil(current)
    }

    func testDeletingTheKeyLeavesTheEndpointWithoutAConnection() async throws {
        let f = makeFixture(); defer { f.tearDown() }
        try await f.settings.save(endpointText: "https://a.example", apiKey: "key-a")
        try await f.settings.deleteKey()
        let current = await f.settings.connection()
        XCTAssertNil(current)
        XCTAssertEqual(f.settings.endpoint?.absoluteString, "https://a.example")
        XCTAssertFalse(f.settings.hasSavedKey)
        let saved = await f.keys.savedKey(for: "https://a.example")
        XCTAssertNil(saved)
    }

    func testRefreshReportsWhetherTheEndpointHasAKeyWithoutReadingOtherOrigins() async throws {
        let keys = HermesKeyStoresFake()
        try await keys.store(for: "https://a.example").save(HermesCredential(apiKey: "key-a"))
        let f = makeFixture(endpoint: "https://a.example", keys: keys); defer { f.tearDown() }
        XCTAssertFalse(f.settings.hasSavedKey)
        await f.settings.refresh()
        XCTAssertTrue(f.settings.hasSavedKey)
        XCTAssertEqual(keys.requestedOrigins, ["https://a.example"])
    }
}

/// origin ごとの鍵置き場（Keychain の代わり）。どの origin の置き場が開かれたかを記録する。
final class HermesKeyStoresFake: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: InMemoryHermesCredentialStore] = [:]
    private var failing: Set<String> = []
    private var requested: Set<String> = []

    func store(for origin: String) -> any HermesCredentialStore {
        lock.withLock {
            requested.insert(origin)
            if failing.contains(origin) { return FailingHermesCredentialStore() }
            return existing(origin)
        }
    }

    /// 記録に残さずに保存済みのキーを読む（試験の確認用）。
    func savedKey(for origin: String) async -> HermesCredential? {
        let store = lock.withLock { stores[origin] }
        return try? await store?.load()
    }

    func failSaves(for origin: String) { lock.withLock { _ = failing.insert(origin) } }

    var requestedOrigins: [String] { lock.withLock { requested.sorted() } }

    private func existing(_ origin: String) -> InMemoryHermesCredentialStore {
        if let store = stores[origin] { return store }
        let store = InMemoryHermesCredentialStore()
        stores[origin] = store
        return store
    }
}

/// 端末がロック中などで Keychain に書けない置き場。
actor FailingHermesCredentialStore: HermesCredentialStore {
    func load() throws -> HermesCredential? { nil }
    func save(_ credential: HermesCredential) throws { throw HermesCredentialStoreError.system(errSecInteractionNotAllowed) }
    func delete() throws {}
}
