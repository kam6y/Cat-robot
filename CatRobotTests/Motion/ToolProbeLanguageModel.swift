import Foundation
import FoundationModels
@testable import CatRobot

/// Exercises the framework's real tool dispatcher without a network or model service.
struct ToolProbeLanguageModel: LanguageModel {
    typealias Executor = ToolProbeExecutor
    var toolName = "context_probe"
    var argumentsJSON = "{\"message\":\"probe\"}"
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    var executorConfiguration: String { "offline-context-probe" }
}

struct ToolProbeExecutor: LanguageModelExecutor {
    typealias Model = ToolProbeLanguageModel
    init(configuration: String) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ToolProbeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // A cached session includes earlier outputs. Only this prompt's output ends its loop.
        var hasCurrentOutput = false
        for entry in request.transcript.reversed() {
            if case .prompt = entry { break }
            if case .toolOutput = entry { hasCurrentOutput = true }
        }
        if hasCurrentOutput {
            await channel.send(.response(action: .appendText("done", tokenCount: 0)))
        } else {
            await channel.send(.toolCalls(action: .toolCall(
                id: UUID().uuidString, name: model.toolName,
                action: .appendArguments(model.argumentsJSON, tokenCount: 0)
            )))
        }
    }
}

actor ToolContextProbe {
    private var turns: [MotionTurnID?] = []
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?

    func recordedTurns() -> [MotionTurnID?] { turns }
    func holdNextCall() { holdNext = true }

    func record(_ turn: MotionTurnID?) async {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        turns.append(turn)
    }

    func releaseHeldCall() {
        let continuation = held
        held = nil
        continuation?.resume()
    }

    func waitUntilHeld() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while held == nil {
            guard clock.now < deadline else { throw ProbeError.toolWasNotCalled }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum ProbeError: Error { case toolWasNotCalled }
}

private struct ContextProbeTool: Tool {
    let name = "context_probe"
    let description = "Records a calling turn for an offline integration test."
    let probe: ToolContextProbe

    @Generable
    struct Arguments { var message: String }

    func call(arguments: Arguments) async throws -> String {
        let turn = MotionTurnContext.current
        await probe.record(turn)
        return "recorded"
    }
}

@MainActor
func makeToolProbeSession() -> (session: LanguageModelSession, probe: ToolContextProbe) {
    let probe = ToolContextProbe()
    let session = LanguageModelSession(model: ToolProbeLanguageModel(),
                                       tools: [ContextProbeTool(probe: probe)])
    return (session, probe)
}
