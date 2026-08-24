import Foundation
import FoundationModels

actor ToolEnabledReplyService: ReplyGenerating {
    struct TestHooks: Sendable {
        let publicPrepareEnteredDuringReset: (@Sendable () async -> Void)?
        let originalResetOwnerResumed: (@Sendable () async -> Void)?
        let concurrentResetJoined: (@Sendable () async -> Void)?

        init(
            publicPrepareEnteredDuringReset: (@Sendable () async -> Void)? = nil,
            originalResetOwnerResumed: (@Sendable () async -> Void)? = nil,
            concurrentResetJoined: (@Sendable () async -> Void)? = nil
        ) {
            self.publicPrepareEnteredDuringReset = publicPrepareEnteredDuringReset
            self.originalResetOwnerResumed = originalResetOwnerResumed
            self.concurrentResetJoined = concurrentResetJoined
        }
    }

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

    private actor SetupSignal {
        private var result: Result<Void, ConversationServiceError>?
        private var waiter: CheckedContinuation<Result<Void, ConversationServiceError>, Never>?

        func wait() async -> Result<Void, ConversationServiceError> {
            if let result {
                return result
            }
            return await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }

        func resolve(_ result: Result<Void, ConversationServiceError>) {
            guard self.result == nil else { return }
            self.result = result
            waiter?.resume(returning: result)
            waiter = nil
        }
    }

    private let sessionFactory: any ReplySessionFactory
    private let makeMemoryStore: @Sendable () throws -> LocalMemoryStore
    private let dateTimeProvider: any CurrentDateTimeProviding
    private let testHooks: TestHooks

    private var runtime: ToolRuntime?
    private var client: (any ReplySessionClient)?
    private var preparationTask: Task<any ReplySessionClient, Error>?
    private var activePreparationID: UUID?
    private var isGenerating = false
    private var activeReplyOperation: Task<Void, Never>?
    private var activeReplyOperationID: UUID?
    private var resetTask: Task<Void, Never>?
    private var activeResetID: UUID?

    init(
        sessionFactory: any ReplySessionFactory,
        makeMemoryStore: @escaping @Sendable () throws -> LocalMemoryStore = {
            try LocalMemoryStore.applicationSupport()
        },
        dateTimeProvider: any CurrentDateTimeProviding = LiveCurrentDateTimeProvider(),
        testHooks: TestHooks = TestHooks()
    ) {
        self.sessionFactory = sessionFactory
        self.makeMemoryStore = makeMemoryStore
        self.dateTimeProvider = dateTimeProvider
        self.testHooks = testHooks
    }

    func prepare() async throws {
        while let resetTask {
            if let hook = testHooks.publicPrepareEnteredDuringReset {
                await hook()
            }
            await resetTask.value
            guard !Task.isCancelled else {
                throw ConversationServiceError.cancelled
            }
        }

        try await prepareClientIfNeeded()
    }

    private func prepareClientIfNeeded() async throws {
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
        guard !isGenerating, resetTask == nil else {
            throw ConversationServiceError.modelBusy
        }
        isGenerating = true

        let operationID = UUID()
        let setupSignal = SetupSignal()
        var capturedContinuation: AsyncThrowingStream<ReplyStreamEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<ReplyStreamEvent, Error> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            isGenerating = false
            throw ConversationServiceError.modelGenerationFailed
        }

        let operation = Task {
            await self.runReplyOperation(
                request: request,
                operationID: operationID,
                setupSignal: setupSignal,
                continuation: continuation
            )
        }
        activeReplyOperationID = operationID
        activeReplyOperation = operation
        continuation.onTermination = { _ in
            operation.cancel()
        }

        let setupResult = await withTaskCancellationHandler {
            await setupSignal.wait()
        } onCancel: {
            operation.cancel()
        }
        if Task.isCancelled {
            operation.cancel()
            await operation.value
            throw ConversationServiceError.cancelled
        }

        switch setupResult {
        case .success:
            return stream
        case let .failure(error):
            await operation.value
            throw error
        }
    }

    func cancelActiveReply() async {
        guard let operation = activeReplyOperation else { return }
        operation.cancel()
        await operation.value
    }

    func reset() async {
        if let resetTask {
            if let hook = testHooks.concurrentResetJoined {
                await hook()
            }
            await resetTask.value
            return
        }

        let resetID = UUID()
        let task = Task {
            await self.performResetAndRelease(resetID: resetID)
        }
        resetTask = task
        activeResetID = resetID
        await task.value
        if let hook = testHooks.originalResetOwnerResumed {
            await hook()
        }
    }

    private func performResetAndRelease(resetID: UUID) async {
        await performReset()
        if activeResetID == resetID {
            resetTask = nil
            activeResetID = nil
        }
    }

    private func performReset() async {
        if let operation = activeReplyOperation {
            operation.cancel()
            await operation.value
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
            try await prepareClientIfNeeded()
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

    private func runReplyOperation(
        request: ReplyTurnRequest,
        operationID: UUID,
        setupSignal: SetupSignal,
        continuation: AsyncThrowingStream<ReplyStreamEvent, Error>.Continuation
    ) async {
        var checkpoint: Transcript?
        var turnContext: MemoryToolContext?
        var preparedClient: (any ReplySessionClient)?
        var didCommit = false
        var didResolveSetup = false

        do {
            try await prepareClientIfNeeded()
            try Task.checkCancellation()

            guard let client, let runtime else {
                throw ConversationServiceError.modelGenerationFailed
            }
            preparedClient = client

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

            didResolveSetup = true
            await setupSignal.resolve(.success(()))

            var finalText: String?
            for try await snapshot in source {
                try Task.checkCancellation()
                continuation.yield(.draft(snapshot))
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
                if let turnContext {
                    await turnContext.rollbackTurn()
                }
                if let checkpoint, let preparedClient {
                    await preparedClient.restoreTranscript(checkpoint)
                }
            }
            let mappedError = mapPipelineError(error)
            continuation.finish(throwing: mappedError)
            finishReplyOperation(id: operationID)
            if !didResolveSetup {
                await setupSignal.resolve(.failure(mappedError))
            }
            return
        }

        finishReplyOperation(id: operationID)
    }

    private func finishReplyOperation(id: UUID) {
        if activeReplyOperationID == id {
            activeReplyOperation = nil
            activeReplyOperationID = nil
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
