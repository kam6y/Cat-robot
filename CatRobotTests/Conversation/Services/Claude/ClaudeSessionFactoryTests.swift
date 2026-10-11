import ClaudeForFoundationModels
import XCTest
@testable import CatRobot

final class ClaudeSessionFactoryTests: XCTestCase {
    func testChoicesMapToPackageConstantsAndEffort() {
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .opus5_5).id, "claude-opus-5-5")
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .sonnet5_5).id, "claude-sonnet-5-5")
        XCTAssertEqual(ClaudeSessionFactory.claudeModel(for: .haiku5_5).id, "claude-haiku-5-5")
        XCTAssertEqual(ClaudeSessionFactory.claudeEffort(for: .low), .low)
        XCTAssertEqual(ClaudeSessionFactory.claudeEffort(for: .medium), .medium)
        for choice in ConversationModelChoice.allCases {
            let capabilities = ClaudeSessionFactory.claudeModel(for: choice).capabilities
            XCTAssertTrue(capabilities.effortLevels.isSuperset(of: [.low, .medium]))
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
