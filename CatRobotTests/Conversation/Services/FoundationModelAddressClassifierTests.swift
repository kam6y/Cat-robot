import FoundationModels
import XCTest
@testable import CatRobot

final class FoundationModelAddressClassifierTests: XCTestCase {
    func testClassificationForwardsEachPromptOnceAndMapsEveryTarget() async throws {
        let client = FakeAddressModelClient(outputs: [.addressed, .ambiguous, .notAddressed])
        let classifier = FoundationModelAddressClassifier(client: client)

        let addressed = try await classifier.classify("ねえ、今日どう？")
        let ambiguous = try await classifier.classify("それ置いといて")
        let notAddressed = try await classifier.classify("テレビ消した？")
        let requestCount = await client.requestCount
        let prompts = await client.prompts

        XCTAssertEqual(addressed, .addressed)
        XCTAssertEqual(ambiguous, .ambiguous)
        XCTAssertEqual(notAddressed, .notAddressed)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(prompts, ["ねえ、今日どう？", "それ置いといて", "テレビ消した？"])
    }

    func testClassificationMapsModelError() async {
        let client = FakeAddressModelClient(error: .guardrailViolation)
        let classifier = FoundationModelAddressClassifier(client: client)

        do {
            _ = try await classifier.classify("発話")
            XCTFail("Expected classification to throw")
        } catch {
            XCTAssertEqual(error as? ConversationServiceError, .guardrailViolation)
        }
    }
}

private enum FakeAddressModelError: Equatable, Sendable {
    case guardrailViolation
}

private actor FakeAddressModelClient: AddressModelClient {
    private var outputs: [GeneratedAddressTarget]
    private let error: FakeAddressModelError?
    private(set) var prompts: [String] = []

    init(outputs: [GeneratedAddressTarget]) {
        self.outputs = outputs
        error = nil
    }

    init(error: FakeAddressModelError) {
        outputs = []
        self.error = error
    }

    var requestCount: Int {
        prompts.count
    }

    func classify(_ utterance: String) throws -> GeneratedAddressTarget {
        prompts.append(utterance)

        if error == .guardrailViolation {
            throw LanguageModelSession.GenerationError.guardrailViolation(
                .init(debugDescription: "test guardrail violation")
            )
        }

        return outputs.removeFirst()
    }
}
