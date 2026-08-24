import Foundation

struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var fact: String
    var supportingQuote: String
    let createdAt: Date
    var updatedAt: Date
    var sourceTurnID: UInt64
}

struct MemorySearchResult: Codable, Equatable, Sendable {
    let id: String
    let fact: String
}
