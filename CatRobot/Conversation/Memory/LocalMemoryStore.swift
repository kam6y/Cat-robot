import Foundation

protocol MemoryPersisting: Sendable {
    func load() throws -> [MemoryFact]
    func save(_ facts: [MemoryFact]) throws
}

struct AtomicJSONMemoryPersistence: MemoryPersisting {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [MemoryFact] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try JSONDecoder().decode([MemoryFact].self, from: Data(contentsOf: fileURL))
    }

    func save(_ facts: [MemoryFact]) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let orderedFacts = facts.sorted { lhs, rhs in
            lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        try encoder.encode(orderedFacts).write(to: temporaryURL)
        try applyProductionMetadata(to: temporaryURL)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    private func applyProductionMetadata(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}

actor LocalMemoryStore {
    private let persistence: any MemoryPersisting
    private var facts: [MemoryFact]

    init(fileURL: URL) throws {
        try self.init(persistence: AtomicJSONMemoryPersistence(fileURL: fileURL))
    }

    init(persistence: any MemoryPersisting) throws {
        self.persistence = persistence
        facts = try persistence.load()
    }

    static func applicationSupport() throws -> LocalMemoryStore {
        let rootURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = rootURL.appendingPathComponent("CatRobot", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return try LocalMemoryStore(fileURL: directoryURL.appendingPathComponent("memories.json"))
    }

    func committedFacts() -> [MemoryFact] {
        facts
    }

    func replaceCommittedFacts(_ facts: [MemoryFact]) throws {
        try Task.checkCancellation()
        try persistence.save(facts)
        self.facts = facts
    }
}
