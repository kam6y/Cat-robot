import XCTest
@testable import CatRobot

final class FileLongTermMemoryStoreTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoundTripUsesFactsJSONNextToCurrentJSON() async throws {
        let dir = directory()
        // 短期記憶の current.json と同居しても、そちらには触れない。
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appendingPathComponent("current.json")
        let shortTerm = Data(#"{"short":true}"#.utf8)
        try shortTerm.write(to: current)
        let store = FileLongTermMemoryStore(directory: dir)
        let fact = LongTermFact(id: UUID(), category: .person, text: "名前はさくら", createdAt: Date(timeIntervalSince1970: 1))
        try await store.save([fact])
        let factsFile = dir.appendingPathComponent("facts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: factsFile.path))
        XCTAssertEqual(try factsFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
#if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: factsFile.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
#endif
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [fact])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "一時ファイルは置換後に残さない")
        try await store.clear()
        let empty = try await store.load()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try Data(contentsOf: current), shortTerm)
    }

    func testMissingFileIsEmptyAndCorruptFileIsInvalidData() async throws {
        let dir = directory()
        let store = FileLongTermMemoryStore(directory: dir)
        let missing = try await store.load()
        XCTAssertTrue(missing.isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("facts.json")
        try Data("{broken".utf8).write(to: file)
        do { _ = try await store.load(); XCTFail("expected invalidData") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .invalidData) }
        try Data(#"{"schemaVersion":2,"facts":[]}"#.utf8).write(to: file)
        do { _ = try await store.load(); XCTFail("expected invalidData for an unknown schema") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .invalidData) }
        try Data(count: 262_145).write(to: file)
        do { _ = try await store.load(); XCTFail("expected tooLarge") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .tooLarge) }
    }

    func testClearRemovesFactsAndLeftoverTemporariesButKeepsCurrentJSON() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appendingPathComponent("current.json")
        let shortTerm = Data(#"{"short":true}"#.utf8)
        try shortTerm.write(to: current)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("facts.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("facts-leftover.tmp"))
        // 短期記憶側の書きかけと無関係なファイルには触れない。
        let shortTermLeftover = dir.appendingPathComponent("memory-leftover.tmp")
        try Data("{}".utf8).write(to: shortTermLeftover)
        let unrelated = dir.appendingPathComponent("unrelated.txt")
        try Data("x".utf8).write(to: unrelated)
        let store = FileLongTermMemoryStore(directory: dir)
        try await store.clear()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining, ["current.json", "memory-leftover.tmp", "unrelated.txt"],
                       "facts.json と書きかけの facts-*.tmp だけを消し、短期記憶とその他は残す")
        XCTAssertEqual(try Data(contentsOf: current), shortTerm)
        XCTAssertEqual(try Data(contentsOf: shortTermLeftover), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("x".utf8))
        // ディレクトリが無ければ消すものが無いので成功。
        let absent = FileLongTermMemoryStore(directory: directory())
        try await absent.clear()
    }

    func testDirectoryAtFactsPathIsAReadError() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("facts.json"), withIntermediateDirectories: true)
        let store = FileLongTermMemoryStore(directory: dir)
        do { _ = try await store.load(); XCTFail("expected readFailed") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .readFailed) }
    }

    func testClearFailureOtherThanMissingDirectoryIsReported() async throws {
        // ディレクトリの位置に通常ファイルがあると列挙できない。不在ではないので成功扱いにしない。
        let parent = directory()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let notADirectory = parent.appendingPathComponent("memory")
        try Data("x".utf8).write(to: notADirectory)
        let store = FileLongTermMemoryStore(directory: notADirectory)
        do { try await store.clear(); XCTFail("expected deleteFailed") }
        catch { XCTAssertEqual(error as? ConversationMemoryError, .deleteFailed) }
    }
}
