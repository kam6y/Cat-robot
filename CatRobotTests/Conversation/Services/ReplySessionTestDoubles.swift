import Foundation
import FoundationModels
@testable import CatRobot

enum RecordingMemoryPersistenceError: Error {
    case saveFailed
}

final class RecordingMemoryPersistence: MemoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let timeline: ReplyServiceTimelineRecorder
    private var facts: [MemoryFact]
    private var shouldFailSave: Bool

    init(
        facts: [MemoryFact] = [],
        shouldFailSave: Bool = false,
        timeline: ReplyServiceTimelineRecorder
    ) {
        self.facts = facts
        self.shouldFailSave = shouldFailSave
        self.timeline = timeline
    }

    var savedFacts: [MemoryFact] {
        lock.withLock { facts }
    }

    func load() throws -> [MemoryFact] {
        lock.withLock { facts }
    }

    func save(_ facts: [MemoryFact]) throws {
        try lock.withLock {
            guard !shouldFailSave else {
                throw RecordingMemoryPersistenceError.saveFailed
            }
            self.facts = facts
        }
        timeline.append(.memorySaved)
    }
}

final class ReplyServiceTimelineRecorder: @unchecked Sendable {
    enum Event: Equatable { case draft, memorySaved, committed }
    private let lock = NSLock()
    private var storage: [Event] = []

    var values: [Event] {
        lock.withLock { storage }
    }

    func append(_ event: Event) {
        lock.withLock { storage.append(event) }
    }
}

actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

actor FirstValue<Value: Sendable> {
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func resolve(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> Value {
        if let value {
            return value
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

actor ReplySessionSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

actor ReplySessionRestoreGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        didStart = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor ReplySessionBlockingGate {
    private var didStart = false
    private var didObserveCancellation = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationOrReleaseWaiters: [CheckedContinuation<Bool, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWaitIgnoringCancellation() async {
        await withTaskCancellationHandler {
            didStart = true
            let pending = startWaiters
            startWaiters.removeAll()
            pending.forEach { $0.resume() }

            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !didObserveCancellation else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func waitForCancellationOrRelease() async -> Bool {
        if didObserveCancellation { return true }
        if isReleased { return false }
        return await withCheckedContinuation { continuation in
            cancellationOrReleaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let lifecyclePending = cancellationOrReleaseWaiters
        cancellationOrReleaseWaiters.removeAll()
        lifecyclePending.forEach { $0.resume(returning: false) }
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func recordCancellation() {
        guard !didObserveCancellation else { return }
        didObserveCancellation = true
        let cancellationPending = cancellationWaiters
        cancellationWaiters.removeAll()
        cancellationPending.forEach { $0.resume() }
        let lifecyclePending = cancellationOrReleaseWaiters
        cancellationOrReleaseWaiters.removeAll()
        lifecyclePending.forEach { $0.resume(returning: true) }
    }
}

struct RecordedReplyGenerationOptions: Equatable, Sendable {
    let temperature: Double?
    let maximumResponseTokens: Int?

    init(_ options: GenerationOptions) {
        temperature = options.temperature
        maximumResponseTokens = options.maximumResponseTokens
    }
}

typealias ReplySessionSnapshotScript = @Sendable (
    _ tools: [any Tool],
    _ prompt: String,
    _ options: GenerationOptions,
    _ continuation: AsyncThrowingStream<String, Error>.Continuation
) async -> Void

protocol ReplySessionTestClient: ReplySessionClient {
    func install(tools: [any Tool]) async
}

actor ReplySessionClientSpy: ReplySessionTestClient {
    private let checkpoint: Transcript
    private let script: ReplySessionSnapshotScript
    private let restoreGate: ReplySessionRestoreGate?
    private let snapshotsGate: ReplySessionBlockingGate?
    private var tools: [any Tool] = []

    private(set) var prewarmCount = 0
    private(set) var transcriptCount = 0
    private(set) var restoreHistory: [Transcript] = []
    private(set) var prompts: [String] = []
    private(set) var options: [RecordedReplyGenerationOptions] = []

    init(
        checkpoint: Transcript = Transcript(),
        restoreGate: ReplySessionRestoreGate? = nil,
        snapshotsGate: ReplySessionBlockingGate? = nil,
        script: @escaping ReplySessionSnapshotScript
    ) {
        self.checkpoint = checkpoint
        self.restoreGate = restoreGate
        self.snapshotsGate = snapshotsGate
        self.script = script
    }

    var restoreCount: Int {
        restoreHistory.count
    }

    func install(tools: [any Tool]) {
        self.tools = tools
    }

    func prewarm() async {
        prewarmCount += 1
    }

    func transcript() async -> Transcript {
        transcriptCount += 1
        return checkpoint
    }

    func restoreTranscript(_ transcript: Transcript) async {
        restoreHistory.append(transcript)
        await restoreGate?.enterAndWait()
    }

    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        self.options.append(RecordedReplyGenerationOptions(options))
        let script = self.script
        let tools = self.tools
        await snapshotsGate?.enterAndWaitIgnoringCancellation()

        return AsyncThrowingStream { continuation in
            let task = Task {
                await script(tools, prompt, options, continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

typealias PullDrivenReplySessionStep = @Sendable (
    _ tools: [any Tool],
    _ prompt: String,
    _ index: Int
) async throws -> String?

private actor PullDrivenReplySessionState {
    private let tools: [any Tool]
    private let prompt: String
    private let step: PullDrivenReplySessionStep
    private var index = 0

    init(
        tools: [any Tool],
        prompt: String,
        step: @escaping PullDrivenReplySessionStep
    ) {
        self.tools = tools
        self.prompt = prompt
        self.step = step
    }

    func next() async throws -> String? {
        let currentIndex = index
        index += 1
        return try await step(tools, prompt, currentIndex)
    }
}

actor PullDrivenReplySessionClientSpy: ReplySessionTestClient {
    private let checkpoint: Transcript
    private let snapshotsGate: ReplySessionBlockingGate?
    private let step: PullDrivenReplySessionStep
    private var tools: [any Tool] = []

    private(set) var prewarmCount = 0
    private(set) var restoreHistory: [Transcript] = []
    private(set) var prompts: [String] = []

    init(
        checkpoint: Transcript = Transcript(),
        snapshotsGate: ReplySessionBlockingGate? = nil,
        step: @escaping PullDrivenReplySessionStep
    ) {
        self.checkpoint = checkpoint
        self.snapshotsGate = snapshotsGate
        self.step = step
    }

    var restoreCount: Int {
        restoreHistory.count
    }

    func install(tools: [any Tool]) {
        self.tools = tools
    }

    func prewarm() async {
        prewarmCount += 1
    }

    func transcript() async -> Transcript {
        checkpoint
    }

    func restoreTranscript(_ transcript: Transcript) async {
        restoreHistory.append(transcript)
    }

    func snapshots(
        for prompt: String,
        options: GenerationOptions
    ) async -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        await snapshotsGate?.enterAndWaitIgnoringCancellation()
        let state = PullDrivenReplySessionState(
            tools: tools,
            prompt: prompt,
            step: step
        )
        return AsyncThrowingStream(unfolding: {
            try await state.next()
        })
    }
}

actor ReplySessionFactorySpy: ReplySessionFactory {
    private let clients: [any ReplySessionTestClient]
    private let prepareError: (any Error)?
    private let makeSessionError: (any Error)?
    private let prepareGate: ReplySessionBlockingGate?
    private let gatedPrepareCall: Int?

    private(set) var receivedToolArrays: [[any Tool]] = []
    private(set) var makeCount = 0
    private(set) var prepareCount = 0

    init(
        clients: [any ReplySessionTestClient],
        prepareError: (any Error)? = nil,
        makeSessionError: (any Error)? = nil,
        prepareGate: ReplySessionBlockingGate? = nil,
        gatedPrepareCall: Int? = nil
    ) {
        self.clients = clients
        self.prepareError = prepareError
        self.makeSessionError = makeSessionError
        self.prepareGate = prepareGate
        self.gatedPrepareCall = gatedPrepareCall
    }

    func prepare() async throws {
        prepareCount += 1
        if let gatedPrepareCall, prepareCount == gatedPrepareCall {
            await prepareGate?.enterAndWaitIgnoringCancellation()
        }
        if let prepareError {
            throw prepareError
        }
    }

    func makeSession(tools: [any Tool]) async throws -> any ReplySessionClient {
        makeCount += 1
        receivedToolArrays.append(tools)
        if let makeSessionError {
            throw makeSessionError
        }

        let index = min(makeCount - 1, clients.count - 1)
        let client = clients[index]
        await client.install(tools: tools)
        return client
    }
}

final class RecordingDateTimeProvider: CurrentDateTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func snapshot(includeSeconds: Bool) -> CurrentDateTimeSnapshot {
        lock.withLock { storedCallCount += 1 }
        return CurrentDateTimeSnapshot(
            iso8601: includeSeconds ? "2026-08-24T12:34:56+09:00" : "2026-08-24T12:34+09:00",
            localDate: "2026-08-24",
            localTime: includeSeconds ? "12:34:56" : "12:34",
            isoWeekday: 1,
            timeZoneIdentifier: "Asia/Tokyo",
            utcOffsetSeconds: 32_400
        )
    }
}

protocol ToolEnabledReplyServiceHarnessing {
    var service: ToolEnabledReplyService { get }
    var client: ReplySessionClientSpy { get }
    var store: LocalMemoryStore { get }
    var persistence: RecordingMemoryPersistence { get }
    var timeline: ReplyServiceTimelineRecorder { get }
    func collect(request: ReplyTurnRequest) async throws -> [ReplyStreamEvent]
    func waitUntilRestoreStarted() async
    func releaseRestore() async
    var didEmitCommitted: Bool { get async }
}

final class ToolEnabledReplyServiceHarness: ToolEnabledReplyServiceHarnessing, @unchecked Sendable {
    let service: ToolEnabledReplyService
    let client: ReplySessionClientSpy
    let store: LocalMemoryStore
    let persistence: RecordingMemoryPersistence
    let timeline: ReplyServiceTimelineRecorder
    let factory: ReplySessionFactorySpy
    let restoreGate: ReplySessionRestoreGate

    init(
        facts: [MemoryFact] = [],
        shouldFailSave: Bool = false,
        blocksRestore: Bool = false,
        dateTimeProvider: any CurrentDateTimeProviding = RecordingDateTimeProvider(),
        script: @escaping ReplySessionSnapshotScript
    ) throws {
        let timeline = ReplyServiceTimelineRecorder()
        let persistence = RecordingMemoryPersistence(
            facts: facts,
            shouldFailSave: shouldFailSave,
            timeline: timeline
        )
        let store = try LocalMemoryStore(persistence: persistence)
        let restoreGate = ReplySessionRestoreGate()
        let client = ReplySessionClientSpy(
            restoreGate: blocksRestore ? restoreGate : nil,
            script: script
        )
        let factory = ReplySessionFactorySpy(clients: [client])

        self.timeline = timeline
        self.persistence = persistence
        self.store = store
        self.restoreGate = restoreGate
        self.client = client
        self.factory = factory
        service = ToolEnabledReplyService(
            sessionFactory: factory,
            makeMemoryStore: { store },
            dateTimeProvider: dateTimeProvider
        )
    }

    func collect(request: ReplyTurnRequest) async throws -> [ReplyStreamEvent] {
        let stream = try await service.streamReply(to: request)
        var events: [ReplyStreamEvent] = []
        for try await event in stream {
            events.append(event)
            switch event {
            case .draft:
                timeline.append(.draft)
            case .committed:
                timeline.append(.committed)
            }
        }
        return events
    }

    func waitUntilRestoreStarted() async {
        await restoreGate.waitUntilStarted()
    }

    func releaseRestore() async {
        await restoreGate.release()
    }

    var didEmitCommitted: Bool {
        get async {
            timeline.values.contains(.committed)
        }
    }
}
