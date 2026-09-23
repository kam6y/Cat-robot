import Darwin
import Foundation

/// A single instance owns a conversation directory. Synchronous I/O inside the
/// actor prevents reentrancy between writing the temporary file and committing it.
actor FileConversationMemoryStore: ConversationMemoryStore {
    private let directory: URL
    private let compatibilityID: String
    private let maximumBytes = 1_048_576
    private var file: URL { directory.appendingPathComponent("current.json") }

    init(directory: URL, compatibilityID: String) {
        self.directory = directory
        self.compatibilityID = compatibilityID
    }

    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return try ConversationMemoryLocation.directory(applicationSupport: support,
                                                         environment: ProcessInfo.processInfo.environment)
    }

    func load() throws -> ConversationMemorySnapshot? {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ConversationMemoryError.readFailed
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            if Self.isMissing(error) { return nil }
            throw ConversationMemoryError.readFailed
        }
        guard data.count <= maximumBytes else { throw ConversationMemoryError.tooLarge }
        let snapshot: ConversationMemorySnapshot
        do { snapshot = try JSONDecoder().decode(ConversationMemorySnapshot.self, from: data) }
        catch { throw ConversationMemoryError.invalidData }
        try snapshot.validate(expectedCompatibilityID: compatibilityID)
        return snapshot
    }

    func save(_ snapshot: ConversationMemorySnapshot) throws {
        try snapshot.validate(expectedCompatibilityID: compatibilityID)
        let data: Data
        do { data = try JSONEncoder().encode(snapshot) }
        catch { throw ConversationMemoryError.invalidData }
        guard data.count <= maximumBytes else { throw ConversationMemoryError.tooLarge }
        let temporary = directory.appendingPathComponent("memory-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            try protectAndExclude(directory)
            try data.write(to: temporary, options: .completeFileProtection)
            try protectAndExclude(temporary)
            // POSIX rename replaces the directory entry atomically, preserving the
            // prepared file's protection and exclusion attributes. No post-commit
            // operation can turn a committed save into a reported write failure.
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                file.withUnsafeFileSystemRepresentation { destination in
                    Darwin.rename(source!, destination!)
                }
            }
            guard result == 0 else { throw ConversationMemoryError.writeFailed }
        } catch { throw ConversationMemoryError.writeFailed }
    }

    func clear() throws {
        let contents: [URL]
        do { contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch {
            if Self.isMissing(error) { return }
            throw ConversationMemoryError.deleteFailed
        }
        do {
            for entry in contents where entry.lastPathComponent == "current.json"
                || (entry.lastPathComponent.hasPrefix("memory-") && entry.pathExtension == "tmp") {
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

struct UnavailableConversationMemoryStore: ConversationMemoryStore {
    func load() async throws -> ConversationMemorySnapshot? { throw ConversationMemoryError.readFailed }
    func save(_ snapshot: ConversationMemorySnapshot) async throws { throw ConversationMemoryError.writeFailed }
    func clear() async throws { throw ConversationMemoryError.deleteFailed }
}
