import XCTest
@testable import CatRobot

final class ConversationInstructionsTests: XCTestCase {
    func testLookGuidanceRequiresVisualNeedAndRejectsClaimsWhenUnavailable() {
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("look:"))
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("静止画像を1枚"))
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("視覚情報が必要"))
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("見えたと主張しません"))
    }

    func testMoveHeadGuidanceExplainsReservationAndDoesNotEmbedConnectionState() {
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("move_head"))
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("予約"))
        XCTAssertTrue(ConversationInstructions.toolGuidance.contains("発話"))
        for status in [RobotConnectionStatus.connected, .disconnected, .reconnecting] {
            XCTAssertFalse(ConversationInstructions.fixedPrefix.contains(status.message), "\(status)")
        }
    }

    func testFixedPrefixDoesNotChangeWithMemory() {
        let empty = ConversationInstructions(longTermFacts: "", summary: "", recentTurns: [])
        let full = ConversationInstructions(
            longTermFacts: "覚えていること:\n- [好み] ほうじ茶", summary: "旅行の相談をした",
            recentTurns: [.init(prompt: "こんにちは", response: "やあ")])
        let prefix = Array(ConversationInstructions.fixedPrefix.utf8)
        XCTAssertEqual(Array(empty.text.utf8), prefix)
        XCTAssertEqual(Array(full.text.utf8.prefix(prefix.count)), prefix)
        XCTAssertEqual(ConversationInstructions.fixedPrefix,
                       ConversationInstructions.persona + "\n\n" + ConversationInstructions.toolGuidance)
    }

    func testSectionsAppearInOrderAndEmptyOnesAreOmitted() throws {
        let text = ConversationInstructions(
            longTermFacts: "覚えていること:\n- [人] さくら", summary: "",
            recentTurns: [.init(prompt: "p", response: "r")]).text
        let facts = try XCTUnwrap(text.range(of: "覚えていること"))
        let recent = try XCTUnwrap(text.range(of: "直近の会話"))
        XCTAssertLessThan(facts.lowerBound, recent.lowerBound)
        XCTAssertFalse(text.contains("これまでの会話の要約"))
        XCTAssertTrue(text.hasSuffix("利用者: p\n猫: r"))

        let full = ConversationInstructions(
            longTermFacts: "覚えていること:\n- [人] さくら", summary: "旅行の相談",
            recentTurns: [.init(prompt: "p1", response: "r1"), .init(prompt: "p2", response: "r2")]).text
        XCTAssertTrue(full.hasSuffix("""
        覚えていること:
        - [人] さくら

        これまでの会話の要約（最近の利用者の訂正を優先）:
        旅行の相談

        直近の会話:
        利用者: p1
        猫: r1
        利用者: p2
        猫: r2
        """))
        let summaryOnly = ConversationInstructions(longTermFacts: "", summary: "旅行の相談", recentTurns: []).text
        XCTAssertFalse(summaryOnly.contains("覚えていること"))
        XCTAssertFalse(summaryOnly.contains("直近の会話"))
        XCTAssertTrue(summaryOnly.hasSuffix("これまでの会話の要約（最近の利用者の訂正を優先）:\n旅行の相談"))
    }

    func testSummaryRequestPromptListsEvictedTurnsOnly() {
        let request = ConversationSummaryRequest(
            previousSummary: "前の記憶",
            evictedTurns: [.init(prompt: "A", response: "B"), .init(prompt: "C", response: "D")],
            characterLimit: 600)
        XCTAssertEqual(request.prompt, """
        これまでの記憶:
        前の記憶
        追加の会話:
        利用者: A
        AI: B
        利用者: C
        AI: D
        更新後の記憶だけを600文字以内で出力してください。
        """)
        let withoutPreviousSummary = ConversationSummaryRequest(
            previousSummary: "", evictedTurns: [.init(prompt: "E", response: "F")], characterLimit: 120)
        XCTAssertEqual(withoutPreviousSummary.prompt, """
        これまでの記憶:
        なし
        追加の会話:
        利用者: E
        AI: F
        更新後の記憶だけを120文字以内で出力してください。
        """)
    }
}
