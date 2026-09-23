import Foundation
@testable import CatRobot

actor MemoryStoreFake: ConversationMemoryStore {
    private(set) var snapshot: ConversationMemorySnapshot?
    private(set) var loadCount = 0
    private(set) var clearCount = 0
    private(set) var saveCount = 0
    private let loadGate: ConversationTestGate?
    private var saveGate: ConversationTestGate?
    private var saveFailure = false
    private var clearFailure = false
    init(snapshot: ConversationMemorySnapshot? = nil, loadGate: ConversationTestGate? = nil,
         saveGate: ConversationTestGate? = nil) {
        self.snapshot = snapshot; self.loadGate = loadGate; self.saveGate = saveGate
    }
    func setSaveGate(_ gate: ConversationTestGate) { saveGate = gate }
    func setSaveFailure(_ enabled: Bool) { saveFailure = enabled }
    func setClearFailure(_ enabled: Bool) { clearFailure = enabled }
    func load() async throws -> ConversationMemorySnapshot? {
        loadCount += 1
        await loadGate?.wait()
        return snapshot
    }
    func save(_ snapshot: ConversationMemorySnapshot) async throws {
        saveCount += 1
        await saveGate?.wait()
        if saveFailure { throw ConversationMemoryError.writeFailed }
        self.snapshot = snapshot
    }
    func clear() throws {
        clearCount += 1
        if clearFailure { throw ConversationMemoryError.deleteFailed }
        snapshot = nil
    }
}
