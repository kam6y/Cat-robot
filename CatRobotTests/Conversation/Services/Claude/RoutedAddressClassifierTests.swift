import XCTest
@testable import CatRobot

final class RoutedAddressClassifierTests: XCTestCase {
    actor Recorder: AddressClassifying {
        let result: AddressTarget
        private(set) var utterances: [String] = []
        init(_ result: AddressTarget) { self.result = result }
        func classify(_ utterance: String) async throws -> AddressTarget { utterances.append(utterance); return result }
    }
    struct Availability: ModelAvailabilityChecking {
        let value: ModelAvailability
        func availability() async -> ModelAvailability { value }
    }
    func testUsesOnDeviceModelWhenAvailableOtherwiseClaude() async throws {
        let onDevice = Recorder(.notAddressed), claude = Recorder(.addressed)
        let available = RoutedAddressClassifier(onDevice: onDevice, onDeviceAvailability: Availability(value: .available), claude: claude)
        let first = try await available.classify("A")
        XCTAssertEqual(first, .notAddressed)
        let unavailable = RoutedAddressClassifier(onDevice: onDevice, onDeviceAvailability: Availability(value: .deviceNotEligible), claude: claude)
        let second = try await unavailable.classify("B")
        XCTAssertEqual(second, .addressed)
        let onDeviceCalls = await onDevice.utterances, claudeCalls = await claude.utterances
        XCTAssertEqual(onDeviceCalls, ["A"]); XCTAssertEqual(claudeCalls, ["B"])
    }
    func testClaudeClientWithoutCredentialFailsWithoutNetwork() async {
        let classifier = FoundationModelAddressClassifier(client: ClaudeAddressModelClient(auth: .missing))
        do { _ = try await classifier.classify("x"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.claudeCredentialMissing)) }
    }
}
