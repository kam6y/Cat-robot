import Foundation
import XCTest
@testable import CatRobot

final class ClaudeAddressClassifierTests: XCTestCase {
    func testMapsGeneratedTargetsAndForwardsTheWholeRequest() async throws {
        let request = AddressClassificationRequest(utterance: "うん", clarification: .init(originalUtterance: "今日の天気は？"))
        let cases: [(GeneratedAddressTarget, AddressTarget)] = [(.addressed, .addressed), (.ambiguous, .ambiguous), (.notAddressed, .notAddressed)]
        for (generated, expected) in cases {
            let client = AddressClientProbe(result: generated)
            let actual = try await ClaudeAddressClassifier(client: client).classify(request)
            let requests = await client.requests
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(requests, [request])
        }
    }

    func testMapsClientNetworkFailureWithoutRetry() async {
        let client = AddressClientProbe(error: URLError(.notConnectedToInternet))
        let request = AddressClassificationRequest(utterance: "ねこ、元気？")
        do {
            _ = try await ClaudeAddressClassifier(client: client).classify(request)
            XCTFail("The original cloud failure must propagate")
        } catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable) }
        let requests = await client.requests
        XCTAssertEqual(requests, [request])
    }

    private struct OrdinaryInput: Decodable, Equatable {
        struct Turn: Decodable, Equatable { let user: String; let cat: String }
        let recentTurns: [Turn]
        let utterance: String
    }

    private struct ClarificationInput: Decodable, Equatable {
        let recentTurns: [OrdinaryInput.Turn]
        let originalUtterance: String
        let clarification: String
        let utterance: String
    }

    func testOrdinaryInputIsJSONWithRecentTurns() throws {
        let turns = [ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ"),
                     ConversationMemoryTurn(prompt: "ありがとう", response: "どういたしまして")]
        let expectedTurns = [OrdinaryInput.Turn(user: "今日の天気はどう？", cat: "晴れだよ"),
                             OrdinaryInput.Turn(user: "ありがとう", cat: "どういたしまして")]
        // 続きと読める発話も、話題を変える発話も、履歴と今回の発話を別の値のまま同じ通常指示で送る。
        let utterances = ["  それで、あしたは？\n", "明日の予定は？", "ねこ、元気？"]
        for utterance in utterances {
            let input = try ClaudeAddressModelClient.requestInput(for: .init(utterance: utterance, recentTurns: turns))
            let decoded = try JSONDecoder().decode(OrdinaryInput.self, from: Data(input.prompt.utf8))
            XCTAssertEqual(decoded, .init(recentTurns: expectedTurns, utterance: utterance),
                           "the utterance is sent verbatim and the turns oldest first: \(utterance)")
            XCTAssertEqual(input.instructions, ClaudeAddressModelClient.instructions, utterance)
        }
        XCTAssertTrue(ClaudeAddressModelClient.instructions.contains("recentTurns"), "the ordinary instructions explain the context field")
    }

    func testEmptyContextStillSendsAnEmptyRecentTurnsArray() throws {
        let input = try ClaudeAddressModelClient.requestInput(for: .init(utterance: "ねこ、元気？"))
        let decoded = try JSONDecoder().decode(OrdinaryInput.self, from: Data(input.prompt.utf8))
        XCTAssertEqual(decoded, .init(recentTurns: [], utterance: "ねこ、元気？"))
    }

    func testClarificationInputCarriesRecentTurns() throws {
        let turns = [ConversationMemoryTurn(prompt: "ねこ、おはよう", response: "おはよう！")]
        let request = AddressClassificationRequest(utterance: "  いいえ。\nママに言ったの。  ",
            clarification: .init(originalUtterance: "「明日の予定」は？\nメモして"), recentTurns: turns)
        let input = try ClaudeAddressModelClient.requestInput(for: request)
        let decoded = try JSONDecoder().decode(ClarificationInput.self, from: Data(input.prompt.utf8))
        XCTAssertEqual(decoded, .init(recentTurns: [.init(user: "ねこ、おはよう", cat: "おはよう！")],
                                      originalUtterance: "「明日の予定」は？\nメモして",
                                      clarification: "今の、ぼくに言った？",
                                      utterance: "  いいえ。\nママに言ったの。  "))
        XCTAssertEqual(input.instructions, ClaudeAddressModelClient.clarificationInstructions)
        XCTAssertNotEqual(input.instructions, ClaudeAddressModelClient.instructions)
    }

    func testClaudeClientWithoutCredentialFailsWithoutNetwork() async {
        let sut = ClaudeAddressClassifier(client: ClaudeAddressModelClient(auth: .missing))
        do { _ = try await sut.classify(.init(utterance: "x")); XCTFail("expected credential failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.claudeCredentialMissing)) }
    }
}

private actor AddressClientProbe: AddressModelClient {
    let result: GeneratedAddressTarget
    let error: (any Error)?
    private(set) var requests: [AddressClassificationRequest] = []
    init(result: GeneratedAddressTarget = .addressed, error: (any Error)? = nil) { self.result = result; self.error = error }
    func classify(_ request: AddressClassificationRequest) throws -> GeneratedAddressTarget {
        requests.append(request)
        if let error { throw error }
        return result
    }
}
