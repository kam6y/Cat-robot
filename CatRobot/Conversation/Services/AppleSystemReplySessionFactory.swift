import FoundationModels

struct AppleSystemReplySessionFactory: ReplySessionFactory {
    private let model: SystemLanguageModel
    private let availability: @Sendable () -> SystemLanguageModel.Availability
    private let makeClient: @Sendable (
        SystemLanguageModel,
        [any Tool],
        String
    ) async -> any ReplySessionClient

    init() {
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        self.init(
            model: model,
            availability: { model.availability }
        )
    }

    init(
        model: SystemLanguageModel = SystemLanguageModel(
            useCase: .general,
            guardrails: .default
        ),
        availability: @escaping @Sendable () -> SystemLanguageModel.Availability,
        makeClient: @escaping @Sendable (
            SystemLanguageModel,
            [any Tool],
            String
        ) async -> any ReplySessionClient = { model, tools, instructions in
            AppleSystemReplySessionClient(
                model: model,
                tools: tools,
                instructions: instructions
            )
        }
    ) {
        self.model = model
        self.availability = availability
        self.makeClient = makeClient
    }

    func prepare() async throws {
        switch availability() {
        case .available:
            return
        case .unavailable(.deviceNotEligible):
            throw ConversationServiceError.modelUnavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ConversationServiceError.modelUnavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            throw ConversationServiceError.modelUnavailable(.modelNotReady)
        @unknown default:
            throw ConversationServiceError.modelUnavailable(.modelNotReady)
        }
    }

    func makeSession(tools: [any Tool]) async throws -> any ReplySessionClient {
        await makeClient(model, tools, Self.instructions)
    }

    private static let instructions = """
    あなたは親しみやすいAIの猫「Cat Robot」です。日本語で自然に話します。
    通常は音声で聞きやすい一文か二文で簡潔に答え、詳しく求められた時だけ広げます。
    訂正されたら短く認めて会話を続けます。自分を人間だと偽りません。

    将来役立つ可能性が高い、ユーザーが提供した安定した事実だけをrememberMemoryで記憶してください。supportingQuoteは現在のユーザー発話から完全に同じ文字列をそのままコピーしてください。一時的な観察、推測、assistantの主張、要約、画像だけからの結論は記憶しないでください。
    競合する可能性のある事実を置換または削除する前にsearchMemoryで検索してください。forgetMemoryにはsearchMemoryが返したmemory IDだけを使ってください。
    質問に現在の日付・時刻または相対的な日時基準が必要な場合だけgetCurrentDateTimeを使ってください。現在の日付、曜日、timezoneをモデルの知識から推測しないでください。
    回答に不要なtoolは呼ばないでください。
    """
}

private actor AppleSystemReplySessionClient: ReplySessionClient {
    private let model: SystemLanguageModel
    private let tools: [any Tool]
    private let instructions: String
    private var session: LanguageModelSession
    private var responseIterator: LanguageModelSession.ResponseStream<String>.AsyncIterator?

    init(model: SystemLanguageModel, tools: [any Tool], instructions: String) {
        self.model = model
        self.tools = tools
        self.instructions = instructions
        session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: instructions
        )
    }

    func prewarm() async {
        session.prewarm()
    }

    func transcript() async -> Transcript {
        session.transcript
    }

    func restoreTranscript(_ transcript: Transcript) async {
        responseIterator = nil
        session = LanguageModelSession(
            model: model,
            tools: tools,
            transcript: transcript
        )
    }

    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error> {
        responseIterator = session
            .streamResponse(to: prompt, options: options)
            .makeAsyncIterator()
        return AsyncThrowingStream(unfolding: { [weak self] in
            try await self?.nextSnapshot()
        })
    }

    private func nextSnapshot() async throws -> String? {
        guard var iterator = responseIterator else { return nil }
        do {
            let snapshot = try await iterator.next(isolation: self)
            responseIterator = snapshot == nil ? nil : iterator
            return snapshot?.content
        } catch {
            responseIterator = nil
            throw FoundationModelErrorMapper.map(error)
        }
    }
}
