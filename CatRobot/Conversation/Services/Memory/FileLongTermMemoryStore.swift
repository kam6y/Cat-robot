import Darwin
import Foundation

/// current.json と同じディレクトリに facts.json を置く。完全ファイル保護、バックアップ除外、rename による原子的な置換。
/// 短期記憶の current.json と memory-*.tmp には触れない（FileConversationMemoryStore と同じ扱い）。
actor FileLongTermMemoryStore: LongTermMemoryStore {
    private let directory: URL
    private let maximumBytes = 262_144
    private var file: URL { directory.appendingPathComponent("facts.json") }

    init(directory: URL) { self.directory = directory }

    func load() throws -> [LongTermFact] {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ConversationMemoryError.readFailed }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            if Self.isMissing(error) { return [] }
            throw ConversationMemoryError.readFailed
        }
        guard data.count <= maximumBytes else { throw ConversationMemoryError.tooLarge }
        guard let snapshot = try? JSONDecoder().decode(LongTermMemorySnapshot.self, from: data), snapshot.schemaVersion == 1 else {
            throw ConversationMemoryError.invalidData
        }
        return snapshot.facts
    }

    func save(_ facts: [LongTermFact]) throws {
        guard let data = try? JSONEncoder().encode(LongTermMemorySnapshot(facts: facts)) else { throw ConversationMemoryError.invalidData }
        guard data.count <= maximumBytes else { throw ConversationMemoryError.tooLarge }
        let temporary = directory.appendingPathComponent("facts-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try protectAndExclude(directory)
            try data.write(to: temporary, options: .completeFileProtection)
            try protectAndExclude(temporary)
            // POSIX rename は保護属性とバックアップ除外を保ったまま、ディレクトリ項目を原子的に置き換える。
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                file.withUnsafeFileSystemRepresentation { destination in Darwin.rename(source!, destination!) }
            }
            guard result == 0 else { throw ConversationMemoryError.writeFailed }
        } catch { throw ConversationMemoryError.writeFailed }
    }

    /// facts.json と書きかけの facts-*.tmp を消す。ディレクトリが無ければ消すものが無いので成功。
    func clear() throws {
        let contents: [URL]
        do { contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch {
            if Self.isMissing(error) { return }
            throw ConversationMemoryError.deleteFailed
        }
        do {
            for entry in contents where entry.lastPathComponent == "facts.json"
                || (entry.lastPathComponent.hasPrefix("facts-") && entry.pathExtension == "tmp") {
                try FileManager.default.removeItem(at: entry)
            }
        } catch { throw ConversationMemoryError.deleteFailed }
    }

    private func protectAndExclude(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var resource = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }
}
