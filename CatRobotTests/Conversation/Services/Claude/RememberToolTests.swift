import XCTest
@testable import CatRobot

final class RememberToolTests: XCTestCase {
    actor Writer: LongTermMemoryWriting {
        private(set) var calls: [(String, LongTermFactCategory)] = []
        var result: LongTermMemoryWriteResult = .saved
        func set(_ value: LongTermMemoryWriteResult) { result = value }
        func remember(_ text: String, category: LongTermFactCategory) -> LongTermMemoryWriteResult {
            calls.append((text, category)); return result
        }
    }

    func testToolParsesCategoryAndReportsOutcome() async throws {
        let writer = Writer()
        let tool = RememberTool(memory: writer)
        XCTAssertEqual(tool.name, "remember")
        let saved = try await tool.call(arguments: .init(fact: "ほうじ茶が好き", category: "Preference"))
        XCTAssertEqual(saved, "覚えました: ほうじ茶が好き")
        await writer.set(.duplicate)
        let duplicate = try await tool.call(arguments: .init(fact: "ほうじ茶が好き", category: "nonsense"))
        XCTAssertEqual(duplicate, "すでに覚えています: ほうじ茶が好き")
        await writer.set(.rejected)
        let rejected = try await tool.call(arguments: .init(fact: "古い会話の事実", category: "event"))
        XCTAssertEqual(rejected, "この記憶は保存できませんでした（会話がリセットされました）: 古い会話の事実")
        let calls = await writer.calls
        XCTAssertEqual(calls.map(\.1), [.preference, .other, .event])
    }

    func testProvidersExposeToolNames() {
        XCTAssertEqual(RememberToolProvider().tools(memory: Writer()).map(\.name), ["remember"])
        XCTAssertEqual(StaticToolProvider([]).tools(memory: Writer()).map(\.name), [])
    }
}
