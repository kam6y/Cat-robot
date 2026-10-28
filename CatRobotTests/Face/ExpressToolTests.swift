import XCTest
@testable import CatRobot

@MainActor
final class ExpressToolTests: XCTestCase {
    func testAllNineNamesReserveWithoutWaitingAndAppearAtSpeechStart() async throws {
        let cases: [(String, FaceExpression)] = [
            ("neutral", .neutral), (" HAPPY ", .happy), ("CURIOUS", .curious),
            ("thinking", .thinking), ("listening", .listening), ("speaking", .speaking),
            ("sleepy", .sleepy), ("surprised", .surprised), ("sorry", .sorry)
        ]
        for (raw, expected) in cases {
            let h = FaceExpressionHarness(), turn = MotionTurnID()
            h.sut.beginTurn(turn)
            let tool = ExpressTool(expressions: h.sut)
            XCTAssertEqual(tool.name, "express")
            let result = try await MotionTurnContext.$current.withValue(turn) {
                try await tool.call(arguments: .init(expression: raw, hold_seconds: nil))
            }
            XCTAssertTrue(result.contains("3秒予約しました"), raw)
            await h.clock.advance(by: 50)
            XCTAssertNil(h.sut.heldExpression)
            h.sut.speechStarted(turn)
            XCTAssertEqual(h.sut.heldExpression, expected)
            h.sut.reset()
        }
    }

    /// "sleeping" は表情名として存在するがツールの allowlist 外なので、不明な名前と同じく neutral になる。
    func testSleepingCannotBeReservedAndFallsBackToNeutral() async throws {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        let result = try await MotionTurnContext.$current.withValue(turn) {
            try await ExpressTool(expressions: h.sut).call(arguments: .init(expression: "sleeping", hold_seconds: nil))
        }
        XCTAssertTrue(result.contains("通常の表情を3秒予約しました"), result)
        h.sut.speechStarted(turn)
        XCTAssertEqual(h.sut.heldExpression, .neutral)
    }

    func testDefaultAndOutOfRangeDurationsUseAdoptedBoundedHold() async throws {
        let cases: [(Int?, Double)] = [(nil, 3), (0, 1), (Int.min, 1), (1, 1), (8, 8), (11, 10), (Int.max, 10)]
        for (raw, expectedSeconds) in cases {
            let h = FaceExpressionHarness(), turn = MotionTurnID()
            h.sut.beginTurn(turn)
            let result = try await MotionTurnContext.$current.withValue(turn) {
                try await ExpressTool(expressions: h.sut).call(arguments: .init(expression: "unknown", hold_seconds: raw))
            }
            XCTAssertTrue(result.contains("\(Int(expectedSeconds))秒予約しました"))
            h.sut.speechStarted(turn)
            XCTAssertEqual(h.sut.heldExpression, .neutral)
            await h.clock.advance(by: expectedSeconds - 0.01)
            XCTAssertEqual(h.sut.heldExpression, .neutral)
            await h.clock.advance(by: 0.01)
            XCTAssertNil(h.sut.heldExpression)
        }
    }

    func testMissingScopeAndCancelledCallCannotReserve() async throws {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        let tool = ExpressTool(expressions: h.sut)
        let missing = try await tool.call(arguments: .init(expression: "happy", hold_seconds: 3))
        XCTAssertFalse(missing.contains("予約しました"))
        let gate = ConversationTestGate()
        let cancelled = Task {
            try await MotionTurnContext.$current.withValue(turn) {
                await gate.wait()
                return try await tool.call(arguments: .init(expression: "happy", hold_seconds: 3))
            }
        }
        await gate.waitUntilEntered()
        cancelled.cancel()
        await gate.open()
        let result = try await cancelled.value
        XCTAssertFalse(result.contains("予約しました"))
        h.sut.speechStarted(turn)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testOldTurnCannotReserveForNewTurnAfterActorHop() async throws {
        let h = FaceExpressionHarness(), old = MotionTurnID()
        h.sut.beginTurn(old)
        let tool = ExpressTool(expressions: h.sut)
        let gate = ConversationTestGate()
        let late = Task {
            try await MotionTurnContext.$current.withValue(old) {
                await gate.wait()
                return try await tool.call(arguments: .init(expression: "happy", hold_seconds: 3))
            }
        }
        await gate.waitUntilEntered()
        let next = h.begin()
        await gate.open()
        let result = try await late.value
        XCTAssertFalse(result.contains("予約しました"))
        h.sut.speechStarted(next)
        XCTAssertNil(h.sut.heldExpression)
    }

    func testHiddenControllerReportsUnavailableWithoutClaimingAReservation() async throws {
        let h = FaceExpressionHarness(), turn = MotionTurnID()
        h.sut.beginTurn(turn)
        h.sut.setVisible(false)
        let result = try await MotionTurnContext.$current.withValue(turn) {
            try await ExpressTool(expressions: h.sut).call(arguments: .init(expression: "happy", hold_seconds: nil))
        }
        XCTAssertEqual(result, "今は表情を変えられません")
        XCTAssertNil(h.sut.heldExpression)
    }
}
