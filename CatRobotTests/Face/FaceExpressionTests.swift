import XCTest
@testable import CatRobot

final class FaceExpressionTests: XCTestCase {
    func testAutomaticExpressionMatchesConversationPhase() {
        let cases: [(ConversationPhase, FaceExpression)] = [
            (.idle, .neutral), (.paused, .neutral),
            (.preparing, .thinking), (.classifying, .thinking), (.thinking, .thinking),
            (.listening, .neutral), (.clarifying, .curious), (.speaking, .speaking),
            (.failed(.modelBusy), .sorry), (.failed(.microphoneDenied), .sorry)
        ]
        for (phase, expected) in cases {
            XCTAssertEqual(FaceExpression.automatic(for: phase), expected, "\(phase)")
        }
    }

    func testExpressionNormalizationAcceptsKnownNamesAndDefaultsUnknownNames() {
        let cases: [(String, FaceExpression)] = [
            ("neutral", .neutral), (" HAPPY \n", .happy), ("CURIOUS", .curious),
            (" thinking ", .thinking), ("LiStEnInG", .neutral), ("speaking", .speaking),
            ("sleepy", .sleepy), ("surprised", .surprised), ("sorry", .sorry),
            ("", .neutral), (" \n", .neutral), ("angry", .neutral), ("happy now", .neutral),
            ("sleeping", .neutral), (" SLEEPING ", .neutral)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(FaceExpression.normalized(raw), expected, raw)
        }
    }

    /// sleeping は無活動の待機状態が表示する表情で、express ツールが予約できる集合には入らない。
    func testSleepingIsNotExpressibleByTheTool() {
        XCTAssertEqual(FaceExpression.expressible, FaceExpression.allCases.filter { $0 != .sleeping })
        XCTAssertFalse(FaceExpression.expressible.contains(.sleeping))
        XCTAssertEqual(FaceExpression.expressible.count, 8)
        XCTAssertTrue(FaceExpression.allCases.contains(.sleeping))
    }
}
