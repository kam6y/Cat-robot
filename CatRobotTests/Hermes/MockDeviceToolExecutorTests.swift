import XCTest
@testable import CatRobot

final class MockDeviceToolExecutorTests: XCTestCase {
    private let executor = MockDeviceToolExecutor()

    func testEchoReturnsExactTextIncludingEmptyAnd1024UnicodeCharacters() {
        for text in ["", "probe ねこ 🐈\n", String(repeating: "🐈", count: 1_024)] {
            XCTAssertEqual(executor.execute(tool: "echo", arguments: ["text": text]), .success(text))
        }
    }

    func testUnknownToolIsRejectedEvenWithValidText() {
        for tool in ["move", "speak", "camera", "Echo", "echo ", ""] {
            XCTAssertEqual(executor.execute(tool: tool, arguments: ["text": "probe"]), .rejected(.unknownTool))
        }
    }

    func testMissingAndOversizedTextAreRejected() {
        XCTAssertEqual(executor.execute(tool: "echo", arguments: [:]), .rejected(.missingText))
        XCTAssertEqual(executor.execute(tool: "echo", arguments: ["text": String(repeating: "猫", count: 1_025)]),
                       .rejected(.textTooLong))
    }
}
