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
    private struct RunningCapture {
        let id: UUID
        let driver: any SpeechCaptureDriving
        let continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation
    }

    private enum State {
        case unprepared
        case prepared(any SpeechCaptureDriving)
        case running(RunningCapture)
        case stopping(UUID)
    }

    private let assetPreparer: SpeechAssetPreparer
    private let driverFactory: @Sendable () -> any SpeechCaptureDriving
    private var state: State = .unprepared
    private var preparationTask: Task<any SpeechCaptureDriving, Error>?
    private var stoppingWaiters: [CheckedContinuation<Void, Never>] = []

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
        case .running, .stopping:
            throw ConversationServiceError.speechCaptureAlreadyRunning
        case .unprepared, .prepared:
            break
        }

        let driver = try await preparedDriver()
        guard case .prepared = state else {
            throw ConversationServiceError.speechCaptureAlreadyRunning
        }

        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream()
        state = .running(
            RunningCapture(id: id, driver: driver, continuation: continuation)
        )
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                await self?.consumerTerminated(captureID: id)
            }
        }

        do {
            try await driver.start(
                onEvent: { event in
                    _ = continuation.yield(event)
                },
                onFailure: { [weak self] error in
                    Task {
                        await self?.captureFailed(error, captureID: id)
                    }
                }
            )
            return stream
        } catch {
            state = .stopping(id)
            await driver.cancel()
            let mappedError = Self.mapCaptureError(error)
            continuation.finish(throwing: mappedError)
            finishStopping()
            throw mappedError
        }
    }

    func stop() async {
        if case .stopping = state {
            await waitUntilStoppingCompletes()
            return
        }
        guard case .running(let capture) = state else { return }
        state = .stopping(capture.id)

        do {
            try await capture.driver.stop()
            capture.continuation.finish()
        } catch {
            await capture.driver.cancel()
            capture.continuation.finish(
                throwing: Self.mapCaptureError(error)
            )
        }
        finishStopping()
    }

    func shutdown() async {
        if case .stopping = state {
            await waitUntilStoppingCompletes()
        }

        switch state {
        case .running(let capture):
            state = .stopping(capture.id)
            do {
                try await capture.driver.stop()
                capture.continuation.finish()
            } catch {
                await capture.driver.cancel()
                capture.continuation.finish(
                    throwing: Self.mapCaptureError(error)
                )
            }
        case .prepared(let driver):
            state = .stopping(UUID())
            await driver.cancel()
        case .stopping:
            break
        case .unprepared:
            state = .stopping(UUID())
        }

        if let preparationTask {
            preparationTask.cancel()
            _ = await preparationTask.result
        }
        preparationTask = nil
        await assetPreparer.releaseReservation()
        finishStopping()
    }

    private func preparedDriver() async throws -> any SpeechCaptureDriving {
        switch state {
        case .prepared(let driver):
            return driver
        case .running(let capture):
            return capture.driver
        case .stopping:
            throw ConversationServiceError.speechCaptureAlreadyRunning
        case .unprepared:
            break
        }

        if let preparationTask {
            let driver = try await preparationTask.value
            if case .unprepared = state {
                state = .prepared(driver)
            }
            return driver
        }

        let driver = driverFactory()
        let task = Task<any SpeechCaptureDriving, Error> {
            let transcriber = try await assetPreparer.makePreparedTranscriber()
            try await driver.prepare(with: transcriber)
            return driver
        }
        preparationTask = task
        do {
            let prepared = try await task.value
            preparationTask = nil
            if case .unprepared = state {
                state = .prepared(prepared)
            }
            return prepared
        } catch {
            preparationTask = nil
            if case .stopping = state {
                // Shutdown owns this state until reservation release completes.
            } else {
                state = .unprepared
            }
            throw Self.mapCaptureError(error)
        }
    }

    private func captureFailed(
        _ error: ConversationServiceError,
        captureID: UUID
    ) async {
        guard case .running(let capture) = state,
              capture.id == captureID else { return }
        state = .stopping(captureID)
        await capture.driver.cancel()
        capture.continuation.finish(throwing: error)
        finishStopping()
    }

    private func consumerTerminated(captureID: UUID) async {
        guard case .running(let capture) = state,
              capture.id == captureID else { return }
        state = .stopping(captureID)
        await capture.driver.cancel()
        finishStopping()
    }

    private func waitUntilStoppingCompletes() async {
        guard case .stopping = state else { return }
        await withCheckedContinuation { continuation in
            stoppingWaiters.append(continuation)
        }
    }

    private func finishStopping() {
        state = .unprepared
        let waiters = stoppingWaiters
        stoppingWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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
    private var isPrepared = false
    private var isStarted = false
    private var isStopping = false
    private var tapInstalled = false
    private var didImmediateTeardown = false

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
        guard !isPrepared else { return }

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
        isPrepared = true
    }

    func start(
        onEvent: @escaping @Sendable (SpeechRecognitionEvent) -> Void,
        onFailure: @escaping @Sendable (ConversationServiceError) -> Void
    ) async throws {
        guard isPrepared,
              !isStarted,
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
        isStarted = true

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
        guard isPrepared else { return }
        isStopping = true

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
        guard !didImmediateTeardown else { return }
        didImmediateTeardown = true
        isStopping = true

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
        guard isStarted, !isStopping else { return }
        eventHandler?(event)
    }

    private func backgroundFailed(_ error: ConversationServiceError) {
        guard isStarted, !isStopping else { return }
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
        isPrepared = false
        isStarted = false
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
