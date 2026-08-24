import Foundation
import XCTest
@testable import CatRobot

private final class FailingMemoryPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFacts: [MemoryFact]
    private var shouldFailSave = false

    init(facts: [MemoryFact] = []) {
        storedFacts = facts
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { storedFacts }
    }

    func save(_ facts: [MemoryFact]) throws {
        try lock.withLock {
            if shouldFailSave {
                throw CocoaError(.fileWriteUnknown)
            }
            storedFacts = facts
        }
    }

    func failFutureSaves() {
        lock.withLock { shouldFailSave = true }
    }
}

final class LocalMemoryStoreTests: XCTestCase {
    func testMissingFileStartsWithNoCommittedFacts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LocalMemoryStore(fileURL: directory.appendingPathComponent("memories.json"))

        let facts = await store.committedFacts()
        XCTAssertEqual(facts, [])
    }

    func testRestartReloadsOnlySuccessfullyCommittedFacts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories.json")
        let firstFact = makeFact(id: "00000000-0000-0000-0000-000000000001")
        let first = try LocalMemoryStore(fileURL: url)
        try await first.replaceCommittedFacts([firstFact])

        let restarted = try LocalMemoryStore(fileURL: url)

        let facts = await restarted.committedFacts()
        XCTAssertEqual(facts, [firstFact])
    }

    func testPersistenceEncodesFactsInLowercaseUUIDOrderRegardlessOfInputOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories.json")
        let lowerIDFact = makeFact(id: "00000000-0000-0000-0000-000000000001")
        let higherIDFact = makeFact(id: "00000000-0000-0000-0000-000000000002")
        let store = try LocalMemoryStore(fileURL: url)

        try await store.replaceCommittedFacts([higherIDFact, lowerIDFact])
        let firstEncoding = try Data(contentsOf: url)
        try await store.replaceCommittedFacts([lowerIDFact, higherIDFact])
        let secondEncoding = try Data(contentsOf: url)

        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(try JSONDecoder().decode([MemoryFact].self, from: secondEncoding), [lowerIDFact, higherIDFact])
    }

    func testSaveFailureDoesNotChangeCommittedState() async throws {
        let firstFact = makeFact(id: "00000000-0000-0000-0000-000000000001")
        let replacementFact = makeFact(id: "00000000-0000-0000-0000-000000000002")
        let persistence = FailingMemoryPersistence(facts: [firstFact])
        let store = try LocalMemoryStore(persistence: persistence)
        persistence.failFutureSaves()

        do {
            try await store.replaceCommittedFacts([replacementFact])
            XCTFail("Expected the injected save failure")
        } catch {}

        let facts = await store.committedFacts()
        XCTAssertEqual(facts, [firstFact])
    }

    func testProductionPersistenceAppliesCompleteProtectionAndBackupExclusion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories.json")
        let store = try LocalMemoryStore(fileURL: url)

        try await store.replaceCommittedFacts([makeFact(id: "00000000-0000-0000-0000-000000000001")])

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(values.fileProtection, .complete)
    }

    func testReplacingExistingMemoryFileRetainsCompleteProtectionAndBackupExclusion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories.json")
        let store = try LocalMemoryStore(fileURL: url)

        try await store.replaceCommittedFacts([makeFact(id: "00000000-0000-0000-0000-000000000001")])
        try await store.replaceCommittedFacts([makeFact(id: "00000000-0000-0000-0000-000000000002")])

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(values.fileProtection, .complete)
    }

    func testReplacingExistingFileOverridesWeakMetadataWithProductionMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memories.json")
        let existingFact = makeFact(id: "00000000-0000-0000-0000-000000000001")
        try JSONEncoder().encode([existingFact]).write(to: url)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
        var weakMetadata = URLResourceValues()
        weakMetadata.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(weakMetadata)

        let initialValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        XCTAssertEqual(initialValues.isExcludedFromBackup, false)
        XCTAssertNotEqual(initialValues.fileProtection, .complete)

        let store = try LocalMemoryStore(fileURL: url)
        try await store.replaceCommittedFacts([makeFact(id: "00000000-0000-0000-0000-000000000002")])

        let finalValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey, .fileProtectionKey])
        XCTAssertEqual(finalValues.isExcludedFromBackup, true)
        XCTAssertEqual(finalValues.fileProtection, .complete)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFact(id: String) -> MemoryFact {
        MemoryFact(
            id: UUID(uuidString: id)!,
            fact: "青が好き",
            supportingQuote: "青が好き",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            sourceTurnID: 1
        )
    }
}
