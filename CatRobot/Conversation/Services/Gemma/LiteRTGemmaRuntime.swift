import Foundation
import LiteRTLM

actor LiteRTGemmaRuntime: GemmaRuntime {
    private var engine: Engine?
    private var loading: Task<Engine, Error>?

    func prepare() async throws { _ = try await loadedEngine() }

    func makeSession(_ kind: GemmaSessionKind) async throws -> any GemmaSession {
        let engine = try await loadedEngine()
        let conversation = try await engine.createConversation(with: ConversationConfig(
            systemMessage: Message(kind.instruction, role: .system),
            samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
            thinkingConfig: ThinkingConfig(enableThinking: false)
        ))
        return LiteRTGemmaSession(conversation: conversation)
    }

    private func loadedEngine() async throws -> Engine {
#if targetEnvironment(simulator)
        throw GemmaRuntimeFailure.unavailable
#else
        if let engine { return engine }
        if let loading { return try await loading.value }
        let task = Task<Engine, Error> {
            let model = try GemmaModelFile.installed()
            try model.validate()
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            let cache = caches.appendingPathComponent("Gemma4E2B-0.17.1-8192", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let engine = Engine(engineConfig: try EngineConfig(
                modelPath: model.url.path, backend: .gpu, maxNumTokens: 8192, cacheDir: cache.path
            ))
            try await engine.initialize()
            return engine
        }
        loading = task
        do {
            let result = try await task.value
            engine = result
            loading = nil
            return result
        } catch {
            loading = nil
            throw error
        }
#endif
    }
}

private struct LiteRTGemmaSession: GemmaSession {
    let conversation: Conversation
    func tokenCount() throws -> Int { try conversation.getTokenCount() }
    func cancel() { try? conversation.cancel() }

    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        // Start synchronously so cancellation cannot race ahead of native startup.
        let native = conversation.sendMessageStream(Message(prompt), maxOutputTokens: outputLimit)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        Task {
            do {
                for try await message in native { continuation.yield(message.toString) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        return stream
    }
}
