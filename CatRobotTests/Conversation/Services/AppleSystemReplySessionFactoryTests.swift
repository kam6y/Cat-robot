import FoundationModels
import XCTest
@testable import CatRobot

final class AppleSystemReplySessionFactoryTests: XCTestCase {
    func testLivePolicyUsesTemperatureHalfAnd256Tokens() {
        let options = ReplyGenerationPolicy.live.makeOptions()

        XCTAssertEqual(options.temperature, 0.5)
        XCTAssertEqual(options.maximumResponseTokens, 256)
        if #available(iOS 27.0, *) {
            XCTAssertEqual(options.toolCallingMode, .allowed)
        }
    }

    func testPrepareMapsGeneralModelNotReadyWithoutRunningInference() async {
        let factory = AppleSystemReplySessionFactory(
            availability: { .unavailable(.modelNotReady) }
        )

        do {
            try await factory.prepare()
            XCTFail("Expected modelNotReady")
        } catch let error as ConversationServiceError {
            XCTAssertEqual(error, .modelUnavailable(.modelNotReady))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMakeSessionForwardsAllProvidedToolsInOrder() async throws {
        let recorder = AppleSessionConstructionRecorder()
        let tools = ReplySessionTestTool.makeFour()
        let factory = AppleSystemReplySessionFactory(
            availability: { .available },
            makeClient: { _, receivedTools, instructions in
                await recorder.record(
                    toolNames: receivedTools.map { $0.name },
                    instructions: instructions
                )
                return RecordingReplySessionClient()
            }
        )

        _ = try await factory.makeSession(tools: tools)

        let recordedToolNames = await recorder.toolNames
        let recordedInstructions = await recorder.instructions
        XCTAssertEqual(
            recordedToolNames,
            ["rememberMemory", "forgetMemory", "searchMemory", "getCurrentDateTime"]
        )
        XCTAssertTrue(recordedInstructions.contains("supportingQuote"))
        XCTAssertTrue(recordedInstructions.contains("現在の日付"))
    }
}

@Generable
private struct ReplySessionTestArguments {
    var value: String
}

private struct ReplySessionTestTool: Tool {
    let name: String
    let description = "Test-only tool."

    func call(arguments: ReplySessionTestArguments) async throws -> String {
        arguments.value
    }

    static func makeFour() -> [any Tool] {
        [
            Self(name: "rememberMemory"),
            Self(name: "forgetMemory"),
            Self(name: "searchMemory"),
            Self(name: "getCurrentDateTime"),
        ]
    }
}

private actor AppleSessionConstructionRecorder {
    private(set) var toolNames: [String] = []
    private(set) var instructions = ""

    func record(toolNames: [String], instructions: String) {
        self.toolNames = toolNames
        self.instructions = instructions
    }
}

private actor RecordingReplySessionClient: ReplySessionClient {
    func prewarm() async {}

    func transcript() async -> Transcript {
        Transcript()
    }

    func restoreTranscript(_ transcript: Transcript) async {}

    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
