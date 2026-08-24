import Foundation

struct ReplyTurnRequest: Equatable, Sendable {
    let turnID: UInt64
    let userText: String
}

enum ReplyMemoryChange: Equatable, Sendable {
    case remembered
    case forgotten
    case updated
}

struct ReplyTurnCommit: Equatable, Sendable {
    let finalText: String
    let memoryChange: ReplyMemoryChange?
}

enum ReplyStreamEvent: Equatable, Sendable {
    case draft(String)
    case committed(ReplyTurnCommit)
}
