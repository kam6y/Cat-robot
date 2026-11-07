import Foundation
import XCTest
@testable import CatRobot

final class RoutedAddressClassifierTests: XCTestCase {
    func testUsesOnDeviceModelWhenAvailableOtherwiseClaude() async throws {
        let log = ConversationTestCallLog()
        let onDevice = FakeAddressClassifier(result: .notAddressed, log: log)
        let claude = FakeAddressClassifier(result: .addressed, log: log)
        let available = RoutedAddressClassifier(onDevice: onDevice,
            onDeviceAvailability: FakeModelAvailability(result: .available, log: log), claude: claude)
        let first = try await available.classify("A")
        XCTAssertEqual(first, .notAddressed)
        let unavailable = RoutedAddressClassifier(onDevice: onDevice,
            onDeviceAvailability: FakeModelAvailability(result: .deviceNotEligible, log: log), claude: claude)
        let second = try await unavailable.classify("B")
        XCTAssertEqual(second, .addressed)
        let onDeviceCalls = await onDevice.calls, claudeCalls = await claude.calls
        XCTAssertEqual(onDeviceCalls, ["A"]); XCTAssertEqual(claudeCalls, ["B"])
        let onDeviceRequests = await onDevice.requests, claudeRequests = await claude.requests
        XCTAssertEqual(onDeviceRequests, [.init(utterance: "A")])
        XCTAssertEqual(claudeRequests, [.init(utterance: "B")])
    }

    func testPendingRequestUsesHaikuEvenWhenOnDeviceAvailable() async throws {
        let log = ConversationTestCallLog()
        let onDevice = FakeAddressClassifier(result: .notAddressed, log: log)
        let claude = FakeAddressClassifier(result: .addressed, log: log)
        let classifier = RoutedAddressClassifier(onDevice: onDevice,
            onDeviceAvailability: FakeModelAvailability(result: .available, log: log), claude: claude)
        let request = AddressClassificationRequest(utterance: "いいえ、あなたには言ってない",
            clarification: .init(originalUtterance: "今日の天気はどう？"))

        let target = try await classifier.classify(request)
        let onDeviceRequests = await onDevice.requests
        let claudeRequests = await claude.requests

        XCTAssertEqual(target, .addressed)
        XCTAssertEqual(onDeviceRequests, [])
        XCTAssertEqual(claudeRequests, [request])
    }

    func testPendingHaikuErrorDoesNotRetryOnDevice() async {
        let log = ConversationTestCallLog()
        let onDevice = FakeAddressClassifier(result: .notAddressed, log: log)
        let claude = FakeAddressClassifier(result: .addressed, log: log)
        await claude.setError(.modelUnreachable)
        let classifier = RoutedAddressClassifier(onDevice: onDevice,
            onDeviceAvailability: FakeModelAvailability(result: .available, log: log), claude: claude)
        let request = AddressClassificationRequest(utterance: "言ったよ",
            clarification: .init(originalUtterance: "今日の天気はどう？"))

        do {
            _ = try await classifier.classify(request)
            XCTFail("The contextual Haiku failure must propagate instead of using the on-device result")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .modelUnreachable)
        }
        let onDeviceRequests = await onDevice.requests
        let claudeRequests = await claude.requests
        XCTAssertEqual(onDeviceRequests, [])
        XCTAssertEqual(claudeRequests, [request])
    }

    func testContextualInputSeparatesActualUtteranceFromOriginalAndQuestion() throws {
        let request = AddressClassificationRequest(utterance: "  いいえ。\nママに言ったの。  ",
            clarification: .init(originalUtterance: "「明日の予定」は？\nメモして"))

        let input = try ClaudeAddressModelClient.requestInput(for: request)
        let fields = (try? JSONSerialization.jsonObject(with: Data(input.prompt.utf8))) as? [String: String]

        XCTAssertEqual(fields, [
            "originalUtterance": "「明日の予定」は？\nメモして",
            "clarification": "今の、ぼくに言った？",
            "utterance": "  いいえ。\nママに言ったの。  "
        ])
    }

    func testNormalHaikuInputRemainsTheActualUtterance() throws {
        let input = try ClaudeAddressModelClient.requestInput(
            for: .init(utterance: "  明日の予定は？\n  "))

        XCTAssertEqual(input.prompt, "  明日の予定は？\n  ")
        XCTAssertEqual(input.instructions, ClaudeAddressModelClient.instructions)
    }

    func testContextualHaikuInputUsesDedicatedInstructions() throws {
        let request = AddressClassificationRequest(utterance: "言ったよ",
            clarification: .init(originalUtterance: "今日の天気はどう？"))

        let input = try ClaudeAddressModelClient.requestInput(for: request)

        XCTAssertNotEqual(input.instructions, ClaudeAddressModelClient.instructions)
    }

    func testClaudeClientWithoutCredentialFailsWithoutNetwork() async {
        let classifier = FoundationModelAddressClassifier(client: ClaudeAddressModelClient(auth: .missing))
        do { _ = try await classifier.classify("x"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.claudeCredentialMissing)) }
    }
}
