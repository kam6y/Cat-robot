import FoundationModels

protocol ReplyModelClient: Sendable {
    func prewarm() async
    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error>
}

actor FoundationModelReplyService: ReplyGenerating {
    private let clientFactory: @Sendable () -> any ReplyModelClient
    private var client: (any ReplyModelClient)?
    private var isGenerating = false

    init() {
        clientFactory = { LiveReplyModelClient() }
    }

    init(clientFactory: @escaping @Sendable () -> any ReplyModelClient) {
        self.clientFactory = clientFactory
    }

    func prewarm() async {
        let client = currentClient()
        await client.prewarm()
    }

    func streamReply(
        to utterance: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard !isGenerating else {
            throw ConversationServiceError.modelBusy
        }

        let client = currentClient()
        isGenerating = true
        let source = await client.snapshots(for: utterance)

        do {
            try Task.checkCancellation()
        } catch {
            isGenerating = false
            throw FoundationModelErrorMapper.map(error)
        }

        return AsyncThrowingStream { continuation in
            let forwardingTask = Task {
                await self.forward(source, to: continuation)
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
            }
        }
    }

    func reset() async {
        let replacement = clientFactory()
        client = replacement
        await replacement.prewarm()
    }

    private func currentClient() -> any ReplyModelClient {
        if let client {
            return client
        }

        let created = clientFactory()
        client = created
        return created
    }

    private func forward(
        _ source: AsyncThrowingStream<String, Error>,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var completionError: ConversationServiceError?
        defer {
            isGenerating = false
            if let completionError {
                continuation.finish(throwing: completionError)
            } else {
                continuation.finish()
            }
        }

        do {
            for try await snapshot in source {
                try Task.checkCancellation()
                continuation.yield(snapshot)
            }
            try Task.checkCancellation()
        } catch let error as ConversationServiceError {
            completionError = error
        } catch {
            completionError = FoundationModelErrorMapper.map(error)
        }
    }
}

private final class LiveReplyModelClient: ReplyModelClient, @unchecked Sendable {
    private let session: LanguageModelSession

    init() {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        session = LanguageModelSession(model: model) {
            """
            あなたは親しみやすいAIの猫「Cat Robot」です。日本語で自然に話します。
            通常は音声で聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
            訂正されたら短く認めて会話を続けます。自分を人間だと偽りません。
            """
        }
    }

    func prewarm() async {
        session.prewarm()
    }

    func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let response = session.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            temperature: 0.5,
                            maximumResponseTokens: 160
                        )
                    )
                    for try await snapshot in response {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: FoundationModelErrorMapper.map(error)
                    )
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
