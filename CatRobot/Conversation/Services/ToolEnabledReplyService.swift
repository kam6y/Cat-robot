import Foundation
import FoundationModels

actor ToolEnabledReplyService {
    private struct ToolRuntime: Sendable {
        let store: LocalMemoryStore
        let context: MemoryToolContext
        let budget: ReplyToolCallBudget
        let tools: [any Tool]
    }

    private enum PrivateMemoryNotice {
        case remembered
        case forgotten

        init(_ notice: MemoryNotice) {
            switch notice {
            case .remembered:
                self = .remembered
            case .forgotten:
                self = .forgotten
            }
        }
    }

    private enum PipelineFailure: Error {
        case toolRuntime
    }

    private let sessionFactory: any ReplySessionFactory
    private let makeMemoryStore: @Sendable () throws -> LocalMemoryStore
    private let dateTimeProvider: any CurrentDateTimeProviding

    private var runtime: ToolRuntime?
    private var client: (any ReplySessionClient)?
    private var preparationTask: Task<any ReplySessionClient, Error>?
    private var activePreparationID: UUID?
    private var isGenerating = false
    private var activeProducer: Task<Void, Never>?
    private var activeProducerID: UUID?

    init(
        sessionFactory: any ReplySessionFactory,
        makeMemoryStore: @escaping @Sendable () throws -> LocalMemoryStore = {
            try LocalMemoryStore.applicationSupport()
        },
        dateTimeProvider: any CurrentDateTimeProviding = LiveCurrentDateTimeProvider()
    ) {
        self.sessionFactory = sessionFactory
        self.makeMemoryStore = makeMemoryStore
        self.dateTimeProvider = dateTimeProvider
    }

    func prepare() async throws {
        guard client == nil else { return }

        let task: Task<any ReplySessionClient, Error>
        let preparationID: UUID
        if let existingTask = preparationTask,
           let existingID = activePreparationID {
            task = existingTask
            preparationID = existingID
        } else {
            preparationID = UUID()
            let createdTask = Task<any ReplySessionClient, Error> {
                try await self.makePreparedClient()
            }
            preparationTask = createdTask
            activePreparationID = preparationID
            task = createdTask
        }

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        let stillOwnsPreparation = activePreparationID == preparationID
        if stillOwnsPreparation {
            preparationTask = nil
            activePreparationID = nil
        }

        switch result {
        case let .success(preparedClient):
            guard stillOwnsPreparation else {
                if client != nil { return }
                throw ConversationServiceError.cancelled
            }
            client = preparedClient
        case let .failure(error):
            throw mapPreparationError(error)
        }
    }

    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error> {
        guard !isGenerating else {
            throw ConversationServiceError.modelBusy
        }
        isGenerating = true

        var checkpoint: Transcript?
        var turnContext: MemoryToolContext?

        do {
            try await prepare()
            try Task.checkCancellation()

            guard let client, let runtime else {
                throw ConversationServiceError.modelGenerationFailed
            }

            checkpoint = await client.transcript()
            try Task.checkCancellation()

            turnContext = runtime.context
            await runtime.context.beginTurn(id: request.turnID, userText: request.userText)
            try Task.checkCancellation()

            await runtime.budget.beginTurn(id: request.turnID)
            try Task.checkCancellation()

            let source = await client.snapshots(
                for: request.userText,
                options: ReplyGenerationPolicy.live.makeOptions()
            )
            try Task.checkCancellation()

            let producerID = UUID()
            var capturedContinuation: AsyncThrowingStream<ReplyStreamEvent, Error>.Continuation?
            let stream = AsyncThrowingStream<ReplyStreamEvent, Error> { continuation in
                capturedContinuation = continuation
            }
            guard let continuation = capturedContinuation else {
                throw ConversationServiceError.modelGenerationFailed
            }

            let producer = Task {
                await self.produce(
                    source: source,
                    checkpoint: checkpoint,
                    client: client,
                    runtime: runtime,
                    producerID: producerID,
                    continuation: continuation
                )
            }
            activeProducerID = producerID
            activeProducer = producer
            continuation.onTermination = { _ in
                producer.cancel()
            }
            return stream
        } catch {
            if let turnContext {
                await turnContext.rollbackTurn()
            }
            if let checkpoint, let client {
                await client.restoreTranscript(checkpoint)
            }
            isGenerating = false
            throw mapPipelineError(error)
        }
    }

    func cancelActiveReply() async {
        guard let producer = activeProducer else { return }
        producer.cancel()
        await producer.value
    }

    func reset() async {
        if let producer = activeProducer {
            producer.cancel()
            await producer.value
        }

        let preparationToCancel = preparationTask
        let preparationIDToCancel = activePreparationID
        preparationToCancel?.cancel()
        if let preparationToCancel {
            _ = await preparationToCancel.result
        }
        if activePreparationID == preparationIDToCancel {
            preparationTask = nil
            activePreparationID = nil
        }

        client = nil
        do {
            try await prepare()
        } catch {
            client = nil
            preparationTask = nil
            activePreparationID = nil
        }
    }

    private func makePreparedClient() async throws -> any ReplySessionClient {
        try Task.checkCancellation()
        try await sessionFactory.prepare()
        try Task.checkCancellation()

        let runtime = try currentRuntime()
        try Task.checkCancellation()
        let preparedClient = try await sessionFactory.makeSession(tools: runtime.tools)
        try Task.checkCancellation()
        await preparedClient.prewarm()
        try Task.checkCancellation()
        return preparedClient
    }

    private func currentRuntime() throws -> ToolRuntime {
        if let runtime {
            return runtime
        }

        do {
            let created = try makeRuntime()
            runtime = created
            return created
        } catch let error as ConversationServiceError {
            throw error
        } catch {
            throw ConversationServiceError.toolRuntimeFailed
        }
    }

    private func makeRuntime() throws -> ToolRuntime {
        let store = try makeMemoryStore()
        let context = MemoryToolContext(store: store)
        let budget = ReplyToolCallBudget()
        return ToolRuntime(
            store: store,
            context: context,
            budget: budget,
            tools: [
                RememberMemoryTool(context: context, budget: budget),
                ForgetMemoryTool(context: context, budget: budget),
                SearchMemoryTool(context: context, budget: budget),
                CurrentDateTimeTool(provider: dateTimeProvider, budget: budget),
            ]
        )
    }

    private func produce(
        source: AsyncThrowingStream<String, Error>,
        checkpoint: Transcript?,
        client: any ReplySessionClient,
        runtime: ToolRuntime,
        producerID: UUID,
        continuation: AsyncThrowingStream<ReplyStreamEvent, Error>.Continuation
    ) async {
        var didCommit = false

        do {
            var finalText: String?
            for try await snapshot in source {
                try Task.checkCancellation()
                continuation.yield(.draft(snapshot))
                await Task.yield()
                if !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = snapshot
                }
            }
            try Task.checkCancellation()

            guard let finalText else {
                throw ConversationServiceError.modelGenerationFailed
            }

            let notices: [MemoryNotice]
            do {
                notices = try await runtime.context.commitTurn()
            } catch {
                throw PipelineFailure.toolRuntime
            }
            didCommit = true
            continuation.yield(
                .committed(
                    ReplyTurnCommit(
                        finalText: finalText,
                        memoryChange: aggregate(notices)
                    )
                )
            )
            continuation.finish()
        } catch {
            if !didCommit {
                await runtime.context.rollbackTurn()
                if let checkpoint {
                    await client.restoreTranscript(checkpoint)
                }
            }
            continuation.finish(throwing: mapPipelineError(error))
        }

        if activeProducerID == producerID {
            activeProducer = nil
            activeProducerID = nil
            isGenerating = false
        }
    }

    private func aggregate(_ notices: [MemoryNotice]) -> ReplyMemoryChange? {
        var remembered = false
        var forgotten = false
        for notice in notices.map(PrivateMemoryNotice.init) {
            switch notice {
            case .remembered:
                remembered = true
            case .forgotten:
                forgotten = true
            }
        }

        switch (remembered, forgotten) {
        case (false, false):
            return nil
        case (true, false):
            return .remembered
        case (false, true):
            return .forgotten
        case (true, true):
            return .updated
        }
    }

    private func mapPreparationError(_ error: any Error) -> ConversationServiceError {
        if error is CancellationError {
            return .cancelled
        }
        if let serviceError = error as? ConversationServiceError {
            return serviceError
        }
        return FoundationModelErrorMapper.map(error)
    }

    private func mapPipelineError(_ error: any Error) -> ConversationServiceError {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let serviceError = error as? ConversationServiceError {
            return serviceError
        }
        if error is ReplyToolCallLimitExceeded || error is PipelineFailure {
            return .toolRuntimeFailed
        }
        return FoundationModelErrorMapper.map(error)
    }
}
