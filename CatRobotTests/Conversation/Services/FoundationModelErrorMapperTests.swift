import FoundationModels
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

    func testMapsToolCallErrorsToGenericToolRuntimeFailure() {
        let error = LanguageModelSession.ToolCallError(
            tool: FoundationModelErrorMapperTestTool(),
            underlyingError: FoundationModelErrorMapperTestToolError.storageUnavailable
        )

        XCTAssertEqual(
            FoundationModelErrorMapper.map(error),
            .toolRuntimeFailed
        )
    }
}

@Generable
private struct FoundationModelErrorMapperTestArguments {
    var value: String
}

private struct FoundationModelErrorMapperTestTool: Tool {
    let name = "mapperTestTool"
    let description = "Test-only tool."

    func call(arguments: FoundationModelErrorMapperTestArguments) async throws -> String {
        arguments.value
    }
}

private enum FoundationModelErrorMapperTestToolError: Error {
    case storageUnavailable
}
