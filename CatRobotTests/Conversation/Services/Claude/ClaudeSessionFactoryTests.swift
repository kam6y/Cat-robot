import ClaudeForFoundationModels
import XCTest
@testable import CatRobot

final class ClaudeSessionFactoryTests: XCTestCase {
    func testStructuredSummaryAcceptsOnlyExplicitNoContent() {
        XCTAssertEqual(try GeneratedConversationSummary(items: []).result(characterLimit: 1_200), .noContent)
        for items in [[""], [" \n"], ["残す項目", " "], ["", "残す項目"]] {
            XCTAssertThrowsError(try GeneratedConversationSummary(items: items).result(characterLimit: 1_200)) {
                XCTAssertEqual($0 as? ConversationServiceError, .modelGenerationFailed)
            }
        }
    }

    func testStructuredSummaryTrimsAndFormatsEveryItem() {
        XCTAssertEqual(try GeneratedConversationSummary(items: [" 紅茶が好き ", "明日待ち合わせ\n"]).result(characterLimit: 1_200),
                       .text("- 紅茶が好き\n- 明日待ち合わせ"))
    }

    func testStructuredSummaryCountsRenderedBulletCharacters() {
        let item = String(repeating: "あ", count: 1_198)
        XCTAssertEqual(try GeneratedConversationSummary(items: [item]).result(characterLimit: 1_200), .text("- " + item))
        XCTAssertThrowsError(try GeneratedConversationSummary(items: [item + "あ"]).result(characterLimit: 1_200))
    }

    func testNoContentPreservesPreviousSummaryWithoutTrimmingIt() {
        XCTAssertEqual(try ConversationSummaryResult.noContent.validatedText(
            previousSummary: "", characterLimit: 1_200), "")
        let previous = "\n- 好きな飲み物は紅茶\n"
        XCTAssertEqual(try ConversationSummaryResult.noContent.validatedText(previousSummary: previous, characterLimit: 1_200), previous)
        XCTAssertThrowsError(try ConversationSummaryResult.noContent.validatedText(
            previousSummary: String(repeating: "あ", count: 1_201), characterLimit: 1_200))
    }

    func testSummaryTextValidationKeepsLimitsAndAllowsReplacingPreviousSummary() {
        let limit = String(repeating: "あ", count: 1_200)
        XCTAssertEqual(try ConversationSummaryResult.text(" \n" + limit + "\n").validatedText(
            previousSummary: "", characterLimit: 1_200), limit)
        for text in ["", " \n", limit + "あ"] {
            XCTAssertThrowsError(try ConversationSummaryResult.text(text).validatedText(
                previousSummary: "", characterLimit: 1_200)) {
                XCTAssertEqual($0 as? ConversationServiceError, .modelGenerationFailed)
            }
        }
        XCTAssertEqual(try ConversationSummaryResult.text("- 好きな飲み物はコーヒー").validatedText(
            previousSummary: "- 好きな飲み物は紅茶", characterLimit: 1_200), "- 好きな飲み物はコーヒー")
    }

    func testChoicesMapToPackageConstantsAndEffort() {
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .opus5_5).id, "claude-opus-5-5")
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .sonnet5_5).id, "claude-sonnet-5-5")
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .haiku5_5).id, "claude-haiku-5-5")
        for effort in ConversationEffort.allCases {
            XCTAssertEqual(ClaudeSessionFactory.claudeEffort(for: effort).rawValue, effort.rawValue)
        }
        // 選べる全 effort を実際の写像で SDK 値にし、全モデルが受理することを確認する（SDK init の precondition 対策）。
        let selectable = ConversationEffort.allCases.map(ClaudeSessionFactory.claudeEffort(for:))
        for choice in ConversationModelChoice.allCases {
            let capabilities = ClaudeSessionFactory.claudeModel(for: choice).capabilities
            XCTAssertTrue(capabilities.effortLevels.isSuperset(of: selectable), "\(choice)")
            XCTAssertTrue(capabilities.imageInput)
        }
    }

    func testMissingCredentialFailsBeforeAnyNetworkCall() async {
        let factory = ClaudeSessionFactory(auth: .missing)
        do {
            try await factory.authenticateIfNeeded()
            XCTFail("expected missingCredential")
        } catch {
            XCTAssertEqual(ClaudeErrorMapper.map(error), .modelUnavailable(.claudeCredentialMissing))
        }
        let client = await factory.makeReplySession(
            .init(model: .opus5_5, effort: .low, instructions: "x"), tools: [])
        do {
            for try await _ in await client.snapshots(for: "hi") {
                XCTFail("missing credentials must not yield a reply")
            }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.claudeCredentialMissing))
        }
    }

    func testAPIKeyModeDoesNotAttest() async throws {
        // パッケージ 0.2.3 は App Attest 以外の authenticateIfNeeded で即座に戻り、ネットワークに出ない。
        try await ClaudeSessionFactory(auth: .apiKey("sk-test")).authenticateIfNeeded()
    }
}
