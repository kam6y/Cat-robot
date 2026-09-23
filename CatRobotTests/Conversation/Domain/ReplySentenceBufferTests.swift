import XCTest
@testable import CatRobot

final class ReplySentenceBufferTests: XCTestCase {
    func testWaitsForClosingQuoteAndFollowingContent() throws {
        var buffer = ReplySentenceBuffer()
        XCTAssertNil(try buffer.receive("「こんにちは。"))
        XCTAssertNil(try buffer.receive("「こんにちは。」"))
        XCTAssertEqual(try buffer.receive("「こんにちは。」元"), "「こんにちは。」")
        XCTAssertNil(try buffer.receive("「こんにちは。」元"))
        XCTAssertEqual(try buffer.remainder(in: "「こんにちは。」元気です。"), "元気です。")
    }

    func testLiteralBoundariesPreserveEveryCharacterEvenWithCharacterByCharacterDelivery() throws {
        let cases: [(String, String?)] = [
            ("こんにちは。元気です。", "こんにちは。"),
            ("  はい！？ 次です。", "  はい！？ "),
            ("『「こんにちは。」』元気。", "『「こんにちは。」』"),
            ("（こんにちは！）次。", "（こんにちは！）"),
            ("(hello!)次。", "(hello!)"),
            ("“hello!”次。", "“hello!”"),
            (#""hello!"次。"#, #""hello!""#),
            (#""say \"hello!\" now!"次。"#, #""say \"hello!\" now!""#),
            ("👩🏽‍🚀とéです。次。", "👩🏽‍🚀とéです。"),
            ("3.14です。次。", "3.14です。"),
            ("U.S.A. hello. More", nil),
            ("https://example.com/a?q=cat! 続きです。次。", "https://example.com/a?q=cat! 続きです。"),
            ("http://example.com/?q=a!", nil),
            ("「閉じない。次です。", nil),
            ("はい。", nil), ("改行\nだけ", nil), ("！？ 。", nil), ("$!? 次", nil), ("", nil), (" \n", nil)
        ]
        for (text, expected) in cases {
            var buffer = ReplySentenceBuffer()
            var accumulated = ""
            var emitted: [String] = []
            for character in text {
                accumulated.append(character)
                if let first = try buffer.receive(accumulated) { emitted.append(first) }
            }
            XCTAssertEqual(emitted, expected.map { [$0] } ?? [], text)
            XCTAssertEqual((emitted.first ?? "") + (try buffer.remainder(in: text)), text)
        }
    }

    func testOnlySentPrefixIsImmutable() throws {
        var buffer = ReplySentenceBuffer()
        XCTAssertNil(try buffer.receive("途中の仮文"))
        XCTAssertEqual(try buffer.receive("確定。次"), "確定。")
        XCTAssertNil(try buffer.receive("確定。別の結末"))
        XCTAssertEqual(try buffer.remainder(in: "確定。終わり"), "終わり")
        XCTAssertThrowsError(try buffer.receive("改訂。終わり")) {
            XCTAssertEqual($0 as? ConversationServiceError, .modelGenerationFailed)
        }
        XCTAssertThrowsError(try buffer.remainder(in: "確定"))
    }
}
