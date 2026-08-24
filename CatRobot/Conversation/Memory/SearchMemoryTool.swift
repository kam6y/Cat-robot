import Foundation
import FoundationModels

@Generable
struct SearchMemoryArguments {
    var query: String
    var limit: Int
}

struct SearchMemoryTool: Tool {
    let name = "searchMemory"
    let description = "Search local committed and current-turn staged memories. Returns only memory IDs and fact text."

    private let context: MemoryToolContext
    private let budget: ReplyToolCallBudget

    init(context: MemoryToolContext, budget: ReplyToolCallBudget) {
        self.context = context
        self.budget = budget
    }

    func call(arguments: SearchMemoryArguments) async throws -> String {
        try await budget.consumeCall()
        guard arguments.limit > 0 else {
            return "Search rejected: limit must be positive."
        }

        let facts = await context.search(query: arguments.query, limit: arguments.limit)
        let results = facts.map {
            MemorySearchResult(id: $0.id.uuidString.lowercased(), fact: $0.fact)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(results)
        return String(decoding: data, as: UTF8.self)
    }
}
