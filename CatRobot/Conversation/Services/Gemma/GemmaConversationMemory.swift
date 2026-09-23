import Foundation

enum GemmaMemoryCompatibility {
    static let current = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c-memory-v1"
}

struct GemmaConversationMemory: Sendable {
    var summary = ""
    var turns: [GemmaTurn] = []
    var rawTokens: Int { turns.reduce(0) { $0 + $1.rawTokens } }

    /// Retain at least 2K of raw text, rounding up to complete user/AI turns.
    var retentionStart: Int {
        var index = turns.count
        var retained = 0
        while index > 0, retained < GemmaContext.recentMinimum {
            index -= 1
            retained += turns[index].rawTokens
        }
        return index
    }
}
