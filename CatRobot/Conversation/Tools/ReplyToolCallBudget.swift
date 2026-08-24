struct ReplyToolCallLimitExceeded: Error, Equatable, Sendable {}

actor ReplyToolCallBudget {
    static let maximumCallsPerTurn = 12

    private var activeTurnID: UInt64?
    private var consumedCalls = 0

    func beginTurn(id: UInt64) {
        guard activeTurnID != id else {
            return
        }

        activeTurnID = id
        consumedCalls = 0
    }

    func consumeCall() throws {
        guard consumedCalls < Self.maximumCallsPerTurn else {
            throw ReplyToolCallLimitExceeded()
        }

        consumedCalls += 1
    }
}
