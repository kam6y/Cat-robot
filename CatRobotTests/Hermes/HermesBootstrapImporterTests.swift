import Foundation
import XCTest
@testable import CatRobot

private actor BootstrapCredentials: HermesCredentialStore {
    enum Failure: Error { case simulated }
    var value: HermesCredential?
    var saves = 0
    var deletes = 0
    let failSave: Bool
    let failDelete: Bool
    init(failSave: Bool = false, failDelete: Bool = false) {
        self.failSave = failSave
        self.failDelete = failDelete
    }
    func load() -> HermesCredential? { value }
    func save(_ credential: HermesCredential) throws {
        saves += 1
        if failSave { throw Failure.simulated }
        value = credential
    }
    func delete() throws {
        deletes += 1
        if failDelete { throw Failure.simulated }
        value = nil
    }
}

@MainActor
final class HermesBootstrapImporterTests: XCTestCase {
    private let dummyKey = "test-only-bootstrap-key"
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("bootstrap.json") }
    private var suite: String!
    private var defaults: UserDefaults!
    private var configurations: HermesProbeConfigurationStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "com.kamby.CatRobot.hermes-probe.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        configurations = HermesProbeConfigurationStore(defaults: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func configuration() throws -> HermesProbeConfiguration {
        try HermesProbeConfiguration(endpoint: URL(string: "https://127.0.0.1:18644")!,
                                     pins: [String(repeating: "ab", count: 32)], deviceID: "test-device")
    }

    private func writeBootstrap(endpoint: String = "https://127.0.0.1:18644", key: String? = nil) throws {
        let object: [String: Any] = ["endpoint": endpoint, "pins": [String(repeating: "ab", count: 32)],
                                     "deviceID": "test-device", "apiKey": key ?? dummyKey]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testImportSavesKeyDeletesBootstrapAndPersistsOnlyNonsecretConfiguration() async throws {
        try writeBootstrap()
        let credentials = BootstrapCredentials()
        let result = await HermesBootstrapImporter(file: file, credentials: credentials,
                                                   configurations: configurations).import()
        XCTAssertEqual(result, .imported)
        XCTAssertTrue(result.permitsStoredCredentials)
        let saved = await credentials.load()
        XCTAssertEqual(saved, HermesCredential(apiKey: dummyKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let reopened = HermesProbeConfigurationStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.load(), try configuration())
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertFalse(String(describing: persisted).contains(dummyKey))
        XCTAssertFalse(String(describing: result).contains(dummyKey))
    }

    func testMissingFilePreservesStoredCredentialsAndConfigurationForReuse() async throws {
        let credentials = BootstrapCredentials()
        try await credentials.save(HermesCredential(apiKey: dummyKey))
        configurations.save(try configuration())
        let result = await HermesBootstrapImporter(file: file, credentials: credentials,
                                                   configurations: configurations).import()
        XCTAssertEqual(result, .notImported(.fileMissing))
        XCTAssertTrue(result.permitsStoredCredentials)
        let saved = await credentials.load()
        let saves = await credentials.saves
        XCTAssertEqual(saved, HermesCredential(apiKey: dummyKey))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(configurations.load(), try configuration())
    }

    func testMalformedOrInvalidBootstrapNeverWritesCredentialsAndStops() async throws {
        for data in [Data("invalid-json".utf8),
                     Data("{\"endpoint\":\"https://127.0.0.1\"}".utf8)] {
            try data.write(to: file)
            await assertInvalidBootstrap()
        }
        try writeBootstrap(endpoint: "http://127.0.0.1:18644")
        await assertInvalidBootstrap()
        try writeBootstrap(key: "")
        await assertInvalidBootstrap()
    }

    private func assertInvalidBootstrap() async {
        let credentials = BootstrapCredentials()
        let result = await HermesBootstrapImporter(file: file, credentials: credentials,
                                                   configurations: configurations).import()
        XCTAssertEqual(result, .notImported(.invalidFormat))
        XCTAssertFalse(result.permitsStoredCredentials)
        let saves = await credentials.saves
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(configurations.load())
    }

    func testUnreadableFileNeverWritesCredentials() async throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let credentials = BootstrapCredentials()
        let result = await HermesBootstrapImporter(file: file, credentials: credentials,
                                                   configurations: configurations).import()
        XCTAssertEqual(result, .notImported(.unreadableFile))
        XCTAssertFalse(result.permitsStoredCredentials)
        let saves = await credentials.saves
        XCTAssertEqual(saves, 0)
    }

    func testCredentialWriteFailureLeavesBootstrapAndConfigurationUntouched() async throws {
        try writeBootstrap()
        let credentials = BootstrapCredentials(failSave: true)
        let result = await HermesBootstrapImporter(file: file, credentials: credentials,
                                                   configurations: configurations).import()
        XCTAssertEqual(result, .notImported(.credentialWriteFailed))
        XCTAssertFalse(result.permitsStoredCredentials)
        let saved = await credentials.load()
        XCTAssertNil(saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(configurations.load())
    }

    func testFileRemovalRetriesOnceBeforeReportingSuccess() async throws {
        try writeBootstrap()
        var attempts = 0
        let credentials = BootstrapCredentials()
        let importer = HermesBootstrapImporter(file: file, credentials: credentials, configurations: configurations) {
            attempts += 1
            if attempts == 1 { throw BootstrapCredentials.Failure.simulated }
            try FileManager.default.removeItem(at: $0)
        }
        let result = await importer.import()
        XCTAssertEqual(result, .imported)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let saves = await credentials.saves
        XCTAssertEqual(saves, 1)
    }

    func testPermanentRemovalFailureRollsBackKeyAndStopsWithoutReplacingConfiguration() async throws {
        try writeBootstrap()
        let prior = try HermesProbeConfiguration(endpoint: URL(string: "https://localhost:18644")!,
                                                pins: ["previous"], deviceID: "previous")
        configurations.save(prior)
        let credentials = BootstrapCredentials()
        var attempts = 0
        let importer = HermesBootstrapImporter(file: file, credentials: credentials, configurations: configurations) { _ in
            attempts += 1
            throw BootstrapCredentials.Failure.simulated
        }
        let result = await importer.import()
        XCTAssertEqual(result, .importFailedBootstrapRemains(credentialRollbackSucceeded: true))
        XCTAssertFalse(result.permitsStoredCredentials)
        XCTAssertEqual(attempts, 2)
        let saved = await credentials.load()
        let deletes = await credentials.deletes
        XCTAssertNil(saved)
        XCTAssertEqual(deletes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(configurations.load(), prior)
    }

    func testRollbackFailureIsReportedHonestlyAndStillStops() async throws {
        try writeBootstrap()
        let credentials = BootstrapCredentials(failDelete: true)
        let importer = HermesBootstrapImporter(file: file, credentials: credentials, configurations: configurations) { _ in
            throw BootstrapCredentials.Failure.simulated
        }
        let result = await importer.import()
        XCTAssertEqual(result, .importFailedBootstrapRemains(credentialRollbackSucceeded: false))
        XCTAssertFalse(result.permitsStoredCredentials)
        let saved = await credentials.load()
        XCTAssertEqual(saved, HermesCredential(apiKey: dummyKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(configurations.load())
    }
}
