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
    }
    func testClaudeClientWithoutCredentialFailsWithoutNetwork() async {
        let classifier = FoundationModelAddressClassifier(client: ClaudeAddressModelClient(auth: .missing))
        do { _ = try await classifier.classify("x"); XCTFail("expected failure") }
        catch { XCTAssertEqual(error as? ConversationServiceError, .modelUnavailable(.claudeCredentialMissing)) }
    }
}
