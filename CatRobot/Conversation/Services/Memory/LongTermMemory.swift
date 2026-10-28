import Foundation

enum LongTermFactCategory: String, Codable, CaseIterable, Sendable {
    case person, preference, event, promise, other
    var label: String {
        switch self {
        case .person: "人"; case .preference: "好み"; case .event: "出来事"; case .promise: "約束"; case .other: "その他"
        }
    }
}

struct LongTermFact: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var category: LongTermFactCategory
    var text: String
    let createdAt: Date
}

struct LongTermMemorySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var facts: [LongTermFact]
}

protocol LongTermMemoryStore: Sendable {
    func load() async throws -> [LongTermFact]
    func save(_ facts: [LongTermFact]) async throws
    func clear() async throws
}

actor InMemoryLongTermMemoryStore: LongTermMemoryStore {
    private var facts: [LongTermFact]
    init(facts: [LongTermFact] = []) { self.facts = facts }
    func load() -> [LongTermFact] { facts }
    func save(_ value: [LongTermFact]) { facts = value }
    func clear() { facts = [] }
}

enum LongTermMemoryPolicy {
    static let maximumFacts = 200
    static let maximumCharacters = 4_000
    static let maximumFactLength = 60

    static func ordered(_ facts: [LongTermFact]) -> [LongTermFact] {
        facts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// 同じ事実集合なら常に同じバイト列を返す。日時は含めない（キャッシュ保護）。
    static func render(_ facts: [LongTermFact]) -> String {
        guard !facts.isEmpty else { return "" }
        return "覚えていること:\n" + ordered(facts).map { "- [\($0.category.label)] \($0.text)" }.joined(separator: "\n")
    }

    static func exceedsLimits(_ facts: [LongTermFact]) -> Bool {
        facts.count > maximumFacts || facts.reduce(0) { $0 + $1.text.count } > maximumCharacters
    }

    /// 統合に失敗したときの決定的な切り詰め: 最古の other → 最古の順に落とす。
    static func trimmed(_ facts: [LongTermFact]) -> [LongTermFact] {
        var remaining = ordered(facts)
        while exceedsLimits(remaining), !remaining.isEmpty {
            if let index = remaining.firstIndex(where: { $0.category == .other }) { remaining.remove(at: index) }
            else { remaining.removeFirst() }
        }
        return remaining
    }
}
