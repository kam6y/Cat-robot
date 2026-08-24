import XCTest
@testable import CatRobot

final class ReplyToolCallBudgetTests: XCTestCase {
    func testConcurrentConsumersAllowExactlyTwelveCalls() async {
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 1)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        try await budget.consumeCall()
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var successCount = 0
            for await succeeded in group where succeeded {
                successCount += 1
            }
            return successCount
        }

        XCTAssertEqual(successes, 12)
    }

    func testThirteenthCallThrowsAndOnlyANewTurnResetsTheBudget() async throws {
        let budget = ReplyToolCallBudget()
        await budget.beginTurn(id: 41)

        for _ in 0..<12 {
            try await budget.consumeCall()
        }

        await budget.beginTurn(id: 41)
        do {
            try await budget.consumeCall()
            XCTFail("Expected the thirteenth call to throw")
        } catch {
            XCTAssertEqual(error as? ReplyToolCallLimitExceeded, .init())
        }

        await budget.beginTurn(id: 42)
        try await budget.consumeCall()
    }
}
