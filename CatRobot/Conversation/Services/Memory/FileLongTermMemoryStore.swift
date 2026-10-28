import Foundation

/// current.json と同じディレクトリに facts.json を置く。完全ファイル保護、バックアップ除外、rename による原子的な置換は
/// ProtectedMemoryFile が担う。短期記憶の current.json と memory-*.tmp には触れない（FileConversationMemoryStore と同じ扱い）。
actor FileLongTermMemoryStore: LongTermMemoryStore {
    private let file: ProtectedMemoryFile

    init(directory: URL) {
        file = ProtectedMemoryFile(directory: directory, name: "facts.json", temporaryPrefix: "facts-",
                                   maximumBytes: 262_144)
    }

    func load() throws -> [LongTermFact] {
        guard let data = try file.read() else { return [] }
        guard let snapshot = try? JSONDecoder().decode(LongTermMemorySnapshot.self, from: data), snapshot.schemaVersion == 1 else {
            throw ConversationMemoryError.invalidData
        }
        return snapshot.facts
    }

    func save(_ facts: [LongTermFact]) throws {
        guard let data = try? JSONEncoder().encode(LongTermMemorySnapshot(facts: facts)) else { throw ConversationMemoryError.invalidData }
        try file.write(data)
    }

    /// facts.json と書きかけの facts-*.tmp を消す。ディレクトリが無ければ消すものが無いので成功。
    func clear() throws {
        try file.clear()
    }
}
