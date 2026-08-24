import FoundationModels

protocol ReplySessionFactory: Sendable {
    func prepare() async throws
    func makeSession(tools: [any Tool]) async throws -> any ReplySessionClient
}

protocol ReplySessionClient: Sendable {
    func prewarm() async
    func transcript() async -> Transcript
    func restoreTranscript(_ transcript: Transcript) async
    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error>
}

struct ReplyGenerationPolicy: Equatable, Sendable {
    static let live = Self(temperature: 0.5, maximumResponseTokens: 256)

    let temperature: Double
    let maximumResponseTokens: Int

    func makeOptions() -> GenerationOptions {
        if #available(iOS 27.0, *) {
            return GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maximumResponseTokens,
                toolCallingMode: .allowed
            )
        }
        return GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens
        )
    }
}
