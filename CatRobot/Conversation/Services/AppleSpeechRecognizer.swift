import AVFAudio
import Foundation
import Speech

protocol SpeechCaptureDriving: Sendable {
    func prepare(with transcriber: SpeechTranscriber) async throws
    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws
    func stop() async throws
    func cancel() async
}

actor AppleSpeechRecognizer: SpeechRecognizing {
    private struct Preparation {
        let id: UUID
        let driver: any SpeechCaptureDriving
        let task: Task<any SpeechCaptureDriving, Error>
    }

    private struct PreparedCapture {
        let preparationID: UUID
        let driver: any SpeechCaptureDriving
    }

    private struct RunningCapture {
        let id: UUID
        let preparationID: UUID
        let driver: any SpeechCaptureDriving
        let output: SpeechCaptureOutputGate
        let startTask: Task<Void, Error>
    }

    private enum State {
        case unprepared
        case preparing(Preparation)
        case prepared(PreparedCapture)
        case starting(RunningCapture)
        case running(RunningCapture)
        case stopping(UUID)
        case shuttingDown(UUID)
    }

    private let assetPreparer: SpeechAssetPreparer
    private let driverFactory: @Sendable () -> any SpeechCaptureDriving
    private var state: State = .unprepared
    private var shutdownOwnedPreparationIDs: Set<UUID> = []
    private var startTeardownOwnership = SpeechStartTeardownOwnership()
    private var failureOwnedStarts: [UUID: ConversationServiceError] = [:]
    private var lifecycleWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(assetPreparer: SpeechAssetPreparer = SpeechAssetPreparer()) {
        self.assetPreparer = assetPreparer
        driverFactory = {
            LiveSpeechCaptureDriver()
        }
    }

    init(
        assetPreparer: SpeechAssetPreparer = SpeechAssetPreparer(),
        driverFactory: @escaping @Sendable () -> any SpeechCaptureDriving
    ) {
        self.assetPreparer = assetPreparer
        self.driverFactory = driverFactory
    }

    func prepare() async throws {
        _ = try await preparedDriver()
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        switch state {
        case .starting, .running, .stopping, .shuttingDown:
            throw ConversationServiceError.speechCaptureAlreadyRunning
        case .unprepared, .preparing, .prepared:
            break
        }

        let prepared = try await preparedDriver()
        if case .shuttingDown = state {
            throw ConversationServiceError.cancelled
        }
        guard case .prepared(let current) = state,
              current.preparationID == prepared.preparationID else {
            throw ConversationServiceError.speechCaptureAlreadyRunning
        }

        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream()
        let output = SpeechCaptureOutputGate(continuation: continuation)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.consumerTerminated(captureID: id)
            }
        }
        let startTask = Task {
            try await prepared.driver.start(
                onEvent: { event in
                    output.yield(event)
                },
                onFailure: { [weak self] error in
                    Task {
                        await self?.captureFailed(error, captureID: id)
                    }
                }
            )
        }
        let capture = RunningCapture(
            id: id,
            preparationID: prepared.preparationID,
            driver: prepared.driver,
            output: output,
            startTask: startTask
        )
        state = .starting(capture)

        let startResult = await startTask.result
        if let failure = failureOwnedStarts.removeValue(forKey: id) {
            await waitForLifecycle(id)
            throw failure
        }
        if let lifecycleID = startTeardownOwnership.takeLifecycleID(forStartID: id) {
            await waitForLifecycle(lifecycleID)
            throw ConversationServiceError.cancelled
        }

        switch startResult {
        case .success:
            guard case .starting(let active) = state,
                  active.id == id else {
                throw ConversationServiceError.cancelled
            }
            state = .running(capture)
            return stream
        case .failure(let error):
            let mappedError = Self.mapCaptureError(error)
            guard case .starting(let active) = state,
                  active.id == id else {
                throw mappedError
            }
            await handleStartFailure(
                mappedError,
                capture: capture
            )
            throw mappedError
        }
    }

    func stop() async {
        if case .stopping(let id) = state {
            await waitForLifecycle(id)
            return
        }
        if case .shuttingDown(let id) = state {
            await waitForLifecycle(id)
            return
        }
        if case .starting(let capture) = state {
            state = .stopping(capture.id)
            startTeardownOwnership.record(
                lifecycleID: capture.id,
                forStartID: capture.id
            )
            capture.output.beginGracefulFinalization()
            let startResult = await capture.startTask.result
            await stopCapture(capture, startResult: startResult)
            completeLifecycle(capture.id)
            return
        }
        guard case .running(let capture) = state else { return }
        state = .stopping(capture.id)
        capture.output.beginGracefulFinalization()
        await stopCapture(capture)
        completeLifecycle(capture.id)
    }

    func shutdown() async {
        waitForActiveLifecycle: while true {
            switch state {
            case .stopping(let id):
                await waitForLifecycle(id)
            case .shuttingDown(let id):
                await waitForLifecycle(id)
                return
            case .unprepared, .preparing, .prepared, .starting, .running:
                break waitForActiveLifecycle
            }
        }

        let shutdownID = UUID()
        switch state {
        case .starting(let capture):
            state = .shuttingDown(shutdownID)
            startTeardownOwnership.record(
                lifecycleID: shutdownID,
                forStartID: capture.id
            )
            capture.output.beginGracefulFinalization()
            let startResult = await capture.startTask.result
            await stopCapture(capture, startResult: startResult)
        case .running(let capture):
            state = .shuttingDown(shutdownID)
            capture.output.beginGracefulFinalization()
            await stopCapture(capture)
        case .prepared(let prepared):
            state = .shuttingDown(shutdownID)
            await prepared.driver.cancel()
        case .preparing(let preparation):
            state = .shuttingDown(shutdownID)
            shutdownOwnedPreparationIDs.insert(preparation.id)
            preparation.task.cancel()
            if case .success = await preparation.task.result {
                await preparation.driver.cancel()
            }
        case .unprepared:
            state = .shuttingDown(shutdownID)
        case .stopping, .shuttingDown:
            return
        }

        await assetPreparer.releaseReservation()
        completeLifecycle(shutdownID)
    }

    private func preparedDriver() async throws -> PreparedCapture {
        switch state {
        case .prepared(let prepared):
            return prepared
        case .preparing(let preparation):
            return try await resolvePreparation(preparation)
        case .running(let capture):
            return PreparedCapture(
                preparationID: capture.preparationID,
                driver: capture.driver
            )
        case .starting(let capture):
            return PreparedCapture(
                preparationID: capture.preparationID,
                driver: capture.driver
            )
        case .stopping, .shuttingDown:
            throw ConversationServiceError.speechCaptureAlreadyRunning
        case .unprepared:
            break
        }

        let preparationID = UUID()
        let driver = driverFactory()
        let task = Task<any SpeechCaptureDriving, Error> {
            let transcriber = try await assetPreparer.makePreparedTranscriber()
            try await driver.prepare(with: transcriber)
            return driver
        }
        let preparation = Preparation(
            id: preparationID,
            driver: driver,
            task: task
        )
        state = .preparing(preparation)
        return try await resolvePreparation(preparation)
    }

    private func resolvePreparation(
        _ preparation: Preparation
    ) async throws -> PreparedCapture {
        let result = await preparation.task.result
        guard !shutdownOwnedPreparationIDs.contains(preparation.id) else {
            throw ConversationServiceError.cancelled
        }
        switch result {
        case .success(let driver):
            let prepared = PreparedCapture(
                preparationID: preparation.id,
                driver: driver
            )
            switch state {
            case .preparing(let active) where active.id == preparation.id:
                state = .prepared(prepared)
                return prepared
            case .prepared(let active) where active.preparationID == preparation.id:
                return active
            case .running(let active) where active.preparationID == preparation.id:
                return prepared
            case .starting(let active) where active.preparationID == preparation.id:
                return prepared
            default:
                throw ConversationServiceError.cancelled
            }
        case .failure(let error):
            if case .preparing(let active) = state,
               active.id == preparation.id {
                state = .unprepared
            }
            throw Self.mapCaptureError(error)
        }
    }

    private func handleStartFailure(
        _ error: ConversationServiceError,
        capture: RunningCapture
    ) async {
        switch state {
        case .starting(let active) where active.id == capture.id:
            state = .stopping(capture.id)
            capture.output.beginImmediateCancellation()
            capture.output.finish(throwing: error)
            await capture.driver.cancel()
            completeLifecycle(capture.id)
        case .running(let active) where active.id == capture.id:
            state = .stopping(capture.id)
            capture.output.beginImmediateCancellation()
            capture.output.finish(throwing: error)
            await capture.driver.cancel()
            completeLifecycle(capture.id)
        case .stopping(let id) where id == capture.id:
            await waitForLifecycle(id)
        case .shuttingDown(let id):
            await waitForLifecycle(id)
        default:
            break
        }
    }

    private func captureFailed(
        _ error: ConversationServiceError,
        captureID: UUID
    ) async {
        switch state {
        case .starting(let capture) where capture.id == captureID:
            state = .stopping(captureID)
            failureOwnedStarts[captureID] = error
            capture.output.beginImmediateCancellation()
            capture.output.finish(throwing: error)
            _ = await capture.startTask.result
            await capture.driver.cancel()
            completeLifecycle(captureID)
        case .running(let capture) where capture.id == captureID:
            state = .stopping(captureID)
            capture.output.beginImmediateCancellation()
            capture.output.finish(throwing: error)
            await capture.driver.cancel()
            completeLifecycle(captureID)
        case .stopping(let id) where id == captureID:
            await waitForLifecycle(id)
        default:
            break
        }
    }

    private func consumerTerminated(captureID: UUID) async {
        guard case .running(let capture) = state,
              capture.id == captureID else { return }
        state = .stopping(captureID)
        capture.output.beginImmediateCancellation()
        await capture.driver.cancel()
        completeLifecycle(captureID)
    }

    private func waitForLifecycle(_ id: UUID) async {
        guard ownsLifecycle(id) else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters[id, default: []].append(continuation)
        }
    }

    private func stopCapture(
        _ capture: RunningCapture,
        startResult: Result<Void, Error>? = nil
    ) async {
        if let startResult, case .failure(let error) = startResult {
            capture.output.beginImmediateCancellation()
            await capture.driver.cancel()
            capture.output.finish(throwing: Self.mapCaptureError(error))
            return
        }

        do {
            try await capture.driver.stop()
            capture.output.finish()
        } catch {
            capture.output.beginImmediateCancellation()
            await capture.driver.cancel()
            capture.output.finish(throwing: Self.mapCaptureError(error))
        }
    }

    private func completeLifecycle(_ id: UUID) {
        guard ownsLifecycle(id) else { return }
        state = .unprepared
        let waiters = lifecycleWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ownsLifecycle(_ id: UUID) -> Bool {
        switch state {
        case .stopping(let activeID), .shuttingDown(let activeID):
            return activeID == id
        case .unprepared, .preparing, .prepared, .starting, .running:
            return false
        }
    }

    private static func mapCaptureError(_ error: any Error) -> ConversationServiceError {
        if let domainError = error as? ConversationServiceError {
            return domainError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .speechCaptureFailed
    }
}

struct SpeechStartTeardownOwnership: Sendable {
    private var lifecycleIDsByStartID: [UUID: UUID] = [:]

    mutating func record(
        lifecycleID: UUID,
        forStartID startID: UUID
    ) {
        lifecycleIDsByStartID[startID] = lifecycleID
    }

    mutating func takeLifecycleID(forStartID startID: UUID) -> UUID? {
        lifecycleIDsByStartID.removeValue(forKey: startID)
    }
}

struct SpeechCaptureRunPhase: Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case prepared
        case running
        case gracefullyFinalizing
        case immediatelyCancelling
        case finished
    }

    private var state: State = .idle

    var canPrepare: Bool {
        state == .idle
    }

    var isPrepared: Bool {
        state == .prepared
    }

    var canStart: Bool {
        state == .prepared
    }

    var canFinalize: Bool {
        state == .running
    }

    var acceptsEvents: Bool {
        state == .running || state == .gracefullyFinalizing
    }

    var acceptsFailures: Bool {
        state == .running
    }

    mutating func didPrepare() {
        guard state == .idle else { return }
        state = .prepared
    }

    mutating func didStart() {
        guard state == .prepared else { return }
        state = .running
    }

    mutating func beginGracefulFinalization() {
        guard state == .running else { return }
        state = .gracefullyFinalizing
    }

    mutating func beginImmediateCancellation() {
        guard state != .finished else { return }
        state = .immediatelyCancelling
    }

    mutating func finish() {
        state = .finished
    }
}

actor SpeechCaptureCancellationCoordinator {
    private var cancellationTask: Task<Void, Never>?

    func cancel(
        operation: @escaping @Sendable () async -> Void
    ) async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }

        let task = Task {
            await operation()
        }
        cancellationTask = task
        await task.value
    }
}

private final class SpeechCaptureOutputGate: @unchecked Sendable {
    private enum State: Equatable {
        case running
        case gracefullyFinalizing
        case immediatelyCancelling
        case finished
    }

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation
    private var state: State = .running

    init(
        continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation
    ) {
        self.continuation = continuation
    }

    func yield(_ event: SpeechRecognitionEvent) {
        lock.withLock {
            guard state == .running || state == .gracefullyFinalizing else { return }
            _ = continuation.yield(event)
        }
    }

    func beginGracefulFinalization() {
        lock.withLock {
            guard state == .running else { return }
            state = .gracefullyFinalizing
        }
    }

    func beginImmediateCancellation() {
        lock.withLock {
            guard state != .finished else { return }
            state = .immediatelyCancelling
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        lock.withLock {
            guard state != .finished else { return }
            state = .finished
            continuation.finish(throwing: error)
        }
    }
}

private actor LiveSpeechCaptureDriver: SpeechCaptureDriving {
    typealias ConverterFactory = @Sendable (
        _ sourceFormat: AVAudioFormat,
        _ analyzerFormat: AVAudioFormat
    ) throws -> any SpeechAudioConverting

    private let converterFactory: ConverterFactory
    private let audioEngine = AVAudioEngine()

    private var inputNode: AVAudioInputNode?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerInputs: AsyncStream<AnalyzerInput>?
    private var sourceFormat: AVAudioFormat?
    private var tapBridge: SpeechTapBridge?
    private var analysisTask: Task<Void, Error>?
    private var resultTask: Task<Void, Error>?
    private var eventHandler: (@Sendable (SpeechRecognitionEvent) -> Void)?
    private var failureHandler: (@Sendable (ConversationServiceError) -> Void)?
    private var runPhase = SpeechCaptureRunPhase()
    private let cancellationCoordinator = SpeechCaptureCancellationCoordinator()
    private var tapInstalled = false

    init(
        converterFactory: @escaping ConverterFactory = { sourceFormat, analyzerFormat in
            try SpeechAudioConverter(
                sourceFormat: sourceFormat,
                analyzerFormat: analyzerFormat
            )
        }
    ) {
        self.converterFactory = converterFactory
    }

    func prepare(with transcriber: SpeechTranscriber) async throws {
        if runPhase.isPrepared { return }
        guard runPhase.canPrepare else {
            throw ConversationServiceError.speechCaptureFailed
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(
                priority: .userInitiated,
                modelRetention: .lingering
            )
        )
        let inputNode = audioEngine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: sourceFormat
        ) else {
            throw ConversationServiceError.speechAssetsUnavailable
        }
        let converter = try converterFactory(sourceFormat, analyzerFormat)
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let tapBridge = SpeechTapBridge(
            converter: converter,
            inputContinuation: inputContinuation,
            onFailure: { [weak self] error in
                Task {
                    await self?.backgroundFailed(error)
                }
            }
        )

        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
        } catch is CancellationError {
            throw ConversationServiceError.cancelled
        } catch {
            throw ConversationServiceError.speechCaptureFailed
        }

        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputNode = inputNode
        self.sourceFormat = sourceFormat
        analyzerInputs = inputs
        self.tapBridge = tapBridge
        runPhase.didPrepare()
    }

    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws {
        guard runPhase.canStart,
              let inputNode,
              let transcriber,
              let analyzer,
              let analyzerInputs,
              let sourceFormat,
              let tapBridge else {
            throw ConversationServiceError.speechCaptureFailed
        }

        eventHandler = onEvent
        failureHandler = onFailure
        runPhase.didStart()

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: sourceFormat
        ) { buffer, time in
            tapBridge.consume(buffer, at: time)
        }
        tapInstalled = true

        analysisTask = Task { [weak self, analyzer, analyzerInputs] in
            do {
                _ = try await analyzer.analyzeSequence(analyzerInputs)
            } catch {
                let mapped = Self.mapBackgroundError(error)
                await self?.backgroundFailed(mapped)
                throw mapped
            }
        }
        resultTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    let event = SpeechRecognitionEvent(
                        text: String(result.text.characters),
                        isFinal: result.isFinal
                    )
                    await self?.emit(event)
                }
            } catch {
                let mapped = Self.mapBackgroundError(error)
                await self?.backgroundFailed(mapped)
                throw mapped
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw ConversationServiceError.speechCaptureFailed
        }
    }

    func stop() async throws {
        guard runPhase.canFinalize else { return }
        runPhase.beginGracefulFinalization()

        removeTapIfNeeded()
        audioEngine.stop()
        audioEngine.reset()

        guard let tapBridge, let analyzer else {
            throw ConversationServiceError.speechCaptureFailed
        }
        do {
            try tapBridge.flushAndFinish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            if let analysisTask {
                try await analysisTask.value
            }
            if let resultTask {
                try await resultTask.value
            }
            clearRunState()
        } catch {
            throw Self.mapBackgroundError(error)
        }
    }

    func cancel() async {
        runPhase.beginImmediateCancellation()
        await cancellationCoordinator.cancel { [weak self] in
            await self?.performImmediateCancellation()
        }
    }

    private func performImmediateCancellation() async {
        removeTapIfNeeded()
        audioEngine.stop()
        audioEngine.reset()
        tapBridge?.finishWithoutFlush()
        analysisTask?.cancel()
        resultTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        clearRunState()
    }

    private func emit(_ event: SpeechRecognitionEvent) {
        guard runPhase.acceptsEvents else { return }
        eventHandler?(event)
    }

    private func backgroundFailed(_ error: ConversationServiceError) {
        guard runPhase.acceptsFailures else { return }
        failureHandler?(error)
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        inputNode?.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func clearRunState() {
        inputNode = nil
        transcriber = nil
        analyzer = nil
        analyzerInputs = nil
        sourceFormat = nil
        tapBridge = nil
        analysisTask = nil
        resultTask = nil
        eventHandler = nil
        failureHandler = nil
        runPhase.finish()
    }

    private static func mapBackgroundError(
        _ error: any Error
    ) -> ConversationServiceError {
        if let domainError = error as? ConversationServiceError {
            return domainError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .speechCaptureFailed
    }
}

private final class SpeechTapBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: any SpeechAudioConverting
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let onFailure: @Sendable (ConversationServiceError) -> Void
    private var isAcceptingBuffers = true
    private var didFinishInput = false
    private var didFail = false

    init(
        converter: any SpeechAudioConverting,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) {
        self.converter = converter
        self.inputContinuation = inputContinuation
        self.onFailure = onFailure
    }

    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        var failure: ConversationServiceError?
        lock.lock()
        if isAcceptingBuffers {
            do {
                for input in try converter.convert(buffer, at: time) {
                    _ = inputContinuation.yield(input)
                }
            } catch {
                isAcceptingBuffers = false
                didFail = true
                finishInputLocked()
                failure = .speechCaptureFailed
            }
        }
        lock.unlock()

        if let failure {
            onFailure(failure)
        }
    }

    func flushAndFinish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didFail else {
            throw ConversationServiceError.speechCaptureFailed
        }
        guard isAcceptingBuffers else {
            finishInputLocked()
            return
        }
        isAcceptingBuffers = false
        do {
            for input in try converter.flush() {
                _ = inputContinuation.yield(input)
            }
            finishInputLocked()
        } catch {
            finishInputLocked()
            throw ConversationServiceError.speechCaptureFailed
        }
    }

    func finishWithoutFlush() {
        lock.withLock {
            isAcceptingBuffers = false
            finishInputLocked()
        }
    }

    private func finishInputLocked() {
        guard !didFinishInput else { return }
        didFinishInput = true
        inputContinuation.finish()
    }
}
