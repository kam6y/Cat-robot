import XCTest
@testable import CatRobot

final class FoundationModelErrorMapperTests: XCTestCase {
    func testMapsGenerationFailuresWithoutLeakingDebugDescriptions() {
        let cases: [(FoundationModelFailureKind, ConversationServiceError)] = [
            (.guardrailViolation, .guardrailViolation),
            (.refusal, .refusal),
            (.exceededContextWindowSize, .contextExceeded),
            (.unsupportedLanguageOrLocale, .modelLocaleUnsupported),
            (.assetsUnavailable, .modelAssetsUnavailable),
            (.concurrentRequests, .modelBusy),
            (.unsupportedGuide, .modelGenerationFailed),
            (.decodingFailure, .modelGenerationFailed),
            (.rateLimited, .modelGenerationFailed),
            (.other, .modelGenerationFailed),
        ]

        for (failure, expected) in cases {
            XCTAssertEqual(FoundationModelErrorMapper.map(failure), expected)
        }
    }

    func testMapsCancellationBeforeModelFailures() {
        XCTAssertEqual(
            FoundationModelErrorMapper.map(CancellationError()),
            .cancelled
        )
    }
}
