import Foundation
import XCTest
@testable import CatRobot

final class FileConversationMemoryStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func snapshot(_ revision: UInt64 = 1, summary: String = "ほうじ茶") -> ConversationMemorySnapshot {
        .init(schemaVersion: 1, memoryCompatibilityID: "test", revision: revision, savedAt: Date(),
              summary: summary, turns: [.init(prompt: "訂正です", response: "覚えたよ")])
    }
    func testMissingThenReplacementAndClearAcrossInstances() async throws {
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        let absent = try await store.load()
        XCTAssertNil(absent)
        try await store.save(snapshot())
        let second = snapshot(2, summary: "金沢")
        try await store.save(second)
        let other = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        let restored = try await other.load()
        XCTAssertEqual(restored, second)
        let url = directory.appendingPathComponent("current.json")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
#if !targetEnvironment(simulator)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.protectionKey] as? FileProtectionType, .complete)
#endif
        try await other.clear()
        try await other.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }
    func testInvalidReplacementLeavesPreviousSnapshot() async throws {
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        let first = snapshot()
        try await store.save(first)
        do {
            try await store.save(snapshot(2, summary: String(repeating: "x", count: 1_048_577)))
            XCTFail("Oversized memory must not replace the saved conversation")
        } catch { XCTAssertEqual(error as? ConversationMemoryError, .tooLarge) }
        let saved = try await store.load()
        XCTAssertEqual(saved, first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["current.json"])
    }
    func testFilesystemWriteFailurePreservesExistingBytes() async throws {
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        try await store.save(snapshot())
        let file = directory.appendingPathComponent("current.json")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        do { try await store.save(snapshot(2)); XCTFail("Expected filesystem write failure") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .writeFailed) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMalformedAndOversizedFilesAreNotTreatedAsMissing() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("current.json")
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        for (data, expected) in [(Data("{".utf8), ConversationMemoryError.invalidData),
                                 (Data(repeating: 32, count: 1_048_577), .tooLarge)] {
            try data.write(to: file)
            do { _ = try await store.load(); XCTFail("Must reject unreadable memory") }
            catch { XCTAssertEqual(error as? ConversationMemoryError, expected) }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
    func testDirectoryAtSnapshotPathIsAReadError() async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("current.json"), withIntermediateDirectories: true)
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        do { _ = try await store.load(); XCTFail("Not a missing file") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .readFailed) }
    }
    func testOrphanTemporaryFileIsNotRestoredAndIsRemovedByClear() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent("memory-\(UUID().uuidString).tmp")
        try JSONEncoder().encode(snapshot()).write(to: orphan)
        let store = FileConversationMemoryStore(directory: directory, compatibilityID: "test")
        let result = try await store.load()
        XCTAssertNil(result)
        try await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
