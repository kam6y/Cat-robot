import Foundation
import XCTest
@testable import CatRobot

extension AddressClassifying {
    func classify(_ utterance: String) async throws -> AddressTarget {
        try await classify(AddressClassificationRequest(utterance: utterance))
    }
}

@MainActor
@discardableResult
func pollUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

enum ConversationTestCall: Equatable, Sendable {
    case requestMicrophone
    case checkAvailability
    case prepareSpeaker
    case activateAudio
    case prepareRecognizer
    case prewarmReply
    case startRecognizer
    case stopRecognizer
    case classify(String)
    case generateReply(String)
    case speak(String)
    case stopSpeaker
    case deactivateAudio
}

enum ConversationLatencyTestEvent: Equatable, Sendable {
    case began(
        token: ConversationLatencyToken,
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    )
    case asrActivity(token: ConversationLatencyToken, at: TimeInterval)
    case selected(token: ConversationLatencyToken, path: ConversationLatencyPath, at: TimeInterval)
    case caption(token: ConversationLatencyToken, at: TimeInterval)
    case speech(token: ConversationLatencyToken, at: TimeInterval)
    case cancelled(
        token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at: TimeInterval
    )
}

@MainActor
final class FakeConversationLatencyTracker: ConversationLatencyTracking {
    private struct Milestones {
        var pathWasSelected = false
        var captionWasRecorded = false
        var speechWasRecorded = false
    }

    private(set) var events: [ConversationLatencyTestEvent] = []
    private var milestones: [ConversationLatencyToken: Milestones] = [:]

    func beginVoiceTurn(
        turnID: UInt64,
        boundaryAt: TimeInterval,
        lastASRActivityAt: TimeInterval?,
        segmentationInterval: TimeInterval
    ) -> ConversationLatencyToken {
        let token = ConversationLatencyToken(rawValue: UUID())
        milestones[token] = Milestones()
        events.append(
            .began(
                token: token,
                turnID: turnID,
                boundaryAt: boundaryAt,
                lastASRActivityAt: lastASRActivityAt,
                segmentationInterval: segmentationInterval
            )
        )
        return token
    }

    func noteASRActivity(at timestamp: TimeInterval, for token: ConversationLatencyToken) {
        guard milestones[token] != nil else { return }
        events.append(.asrActivity(token: token, at: timestamp))
    }

    func selectPath(
        _ path: ConversationLatencyPath,
        for token: ConversationLatencyToken,
        at timestamp: TimeInterval
    ) {
        guard var state = milestones[token], !state.pathWasSelected else { return }
        state.pathWasSelected = true
        milestones[token] = state
        events.append(.selected(token: token, path: path, at: timestamp))
    }

    func firstCaptionVisible(for token: ConversationLatencyToken, at timestamp: TimeInterval) {
        guard var state = milestones[token],
              state.pathWasSelected,
              !state.captionWasRecorded else { return }
        state.captionWasRecorded = true
        milestones[token] = state
        events.append(.caption(token: token, at: timestamp))
    }

    func speechStarted(for token: ConversationLatencyToken, at timestamp: TimeInterval) {
        guard var state = milestones[token],
              state.pathWasSelected,
              !state.speechWasRecorded else { return }
        state.speechWasRecorded = true
        milestones[token] = state
        events.append(.speech(token: token, at: timestamp))
        if state.captionWasRecorded {
            milestones[token] = nil
        }
    }

    func cancel(
        _ token: ConversationLatencyToken,
        reason: ConversationLatencyCancellation,
        at timestamp: TimeInterval
    ) {
        guard milestones.removeValue(forKey: token) != nil else { return }
        events.append(.cancelled(token: token, reason: reason, at: timestamp))
    }
}

final class ConversationTestCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversationTestCall] = []

    var values: [ConversationTestCall] {
        lock.withLock { storage }
    }

    func append(_ call: ConversationTestCall) {
        lock.withLock { storage.append(call) }
    }
}

final class ConversationTestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(_ value: TimeInterval = 0) {
        storage = value
    }

    var value: TimeInterval {
        lock.withLock { storage }
    }

    func set(_ value: TimeInterval) {
        lock.withLock { storage = value }
    }
}

actor ConversationTestSleeper {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private(set) var durations: [Duration] = []
    private(set) var cancellationCount = 0

    func sleep(for duration: Duration) async {
        durations.append(duration)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() {
        cancellationCount += 1
    }

    func release(_ index: Int) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume()
    }

    func releaseAll() {
        let pending = continuations.compactMap { $0 }
        continuations = Array(repeating: nil, count: continuations.count)
        pending.forEach { $0.resume() }
    }
}

actor ConversationTestGate {
    private var isOpen: Bool
    private var entryCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        entryCount += 1
        resumeEntryWaiters()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeEntryWaiters() {
        let ready = entryWaiters.filter { entryCount >= $0.count }
        entryWaiters.removeAll { entryCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

enum ConversationPreflightRaceOutcome: Equatable {
    case freshPreflight
    case joinedExistingPreflight
}

actor ConversationPreflightRaceProbe {
    private var preflightStartCount = 0
    private var outcome: ConversationPreflightRaceOutcome?
    private var waiter: CheckedContinuation<ConversationPreflightRaceOutcome, Never>?

    func record(_ checkpoint: ConversationLifecycleCheckpoint) {
        switch checkpoint {
        case .preflightWillStart:
            preflightStartCount += 1
            if preflightStartCount == 2 {
                complete(with: .freshPreflight)
            }
        case .joiningExistingPreflight:
            complete(with: .joinedExistingPreflight)
        case .waitingForFailureCleanup, .preflightWillFinish:
            break
        }
    }

    func waitForOutcome() async -> ConversationPreflightRaceOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func complete(with outcome: ConversationPreflightRaceOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let waiter = waiter
        self.waiter = nil
        waiter?.resume(returning: outcome)
    }
}

actor FakeMicrophonePermission: MicrophoneAuthorizing {
    private let allowed: Bool
    private let gate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private(set) var requestCount = 0

    init(
        allowed: Bool,
        gate: ConversationTestGate?,
        log: ConversationTestCallLog
    ) {
        self.allowed = allowed
        self.gate = gate
        self.log = log
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        log.append(.requestMicrophone)
        await gate?.wait()
        return allowed
    }
}

actor FakeModelAvailability: ModelAvailabilityChecking {
    private var result: ModelAvailability
    private let gate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private(set) var checkCount = 0

    init(result: ModelAvailability = .available, gate: ConversationTestGate? = nil, log: ConversationTestCallLog) {
        self.result = result
        self.gate = gate
        self.log = log
    }

    func availability() async -> ModelAvailability {
        checkCount += 1
        log.append(.checkAvailability)
        await gate?.wait()
        return result
    }

    func setResult(_ result: ModelAvailability) {
        self.result = result
    }
}

actor FakeSpeechRecognizer: SpeechRecognizing {
    typealias Continuation = AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation

    private let log: ConversationTestCallLog
    private let prepareGate: ConversationTestGate?
    private let stopGate: ConversationTestGate?
    private let tailOnFirstStop: SpeechRecognitionEvent?
    private let prepareError: ConversationServiceError?
    private let startError: ConversationServiceError?
    private var continuations: [Continuation] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    init(
        log: ConversationTestCallLog,
        prepareGate: ConversationTestGate? = nil,
        stopGate: ConversationTestGate? = nil,
        tailOnFirstStop: SpeechRecognitionEvent? = nil,
        prepareError: ConversationServiceError? = nil,
        startError: ConversationServiceError? = nil
    ) {
        self.log = log
        self.prepareGate = prepareGate
        self.stopGate = stopGate
        self.tailOnFirstStop = tailOnFirstStop
        self.prepareError = prepareError
        self.startError = startError
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareRecognizer)
        await prepareGate?.wait()
        if let prepareError { throw prepareError }
    }

    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        startCount += 1
        log.append(.startRecognizer)
        if let startError { throw startError }
        let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        isRunning = true
        resumeStartWaiters()
        return pair.stream
    }

    func stop() async {
        stopCount += 1
        log.append(.stopRecognizer)
        let captureIndex = continuations.indices.last
        await stopGate?.wait()
        if stopCount == 1, let tailOnFirstStop, let captureIndex {
            continuations[captureIndex].yield(tailOnFirstStop)
        }
        if let captureIndex {
            continuations[captureIndex].finish()
        }
        isRunning = false
    }

    func emit(_ event: SpeechRecognitionEvent, capture index: Int? = nil) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(capture index: Int? = nil) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func fail(
        _ error: ConversationServiceError,
        capture index: Int? = nil
    ) {
        guard let index = index ?? continuations.indices.last,
              continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilStarted(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startCount >= $0.count }
        startWaiters.removeAll { startCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeAddressClassifier: AddressClassifying {
    private var result: AddressTarget
    private var error: ConversationServiceError?
    private let log: ConversationTestCallLog
    var calls: [String] { requests.map(\.utterance) }
    private(set) var requests: [AddressClassificationRequest] = []

    init(result: AddressTarget, log: ConversationTestCallLog) {
        self.result = result
        self.log = log
    }

    func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget {
        requests.append(request)
        log.append(.classify(request.utterance))
        if let error { throw error }
        return result
    }

    func setResult(_ result: AddressTarget) { self.result = result }
    func setError(_ error: ConversationServiceError?) { self.error = error }
}

/// ConversationHistoryReading の fake。読み取り回数を数え、gate があれば読み取りの途中で待つ。
actor FakeConversationHistory: ConversationHistoryReading {
    private var turns: [ConversationMemoryTurn]
    private let gate: ConversationTestGate?
    private(set) var readCount = 0

    init(turns: [ConversationMemoryTurn] = [], gate: ConversationTestGate? = nil) {
        self.turns = turns
        self.gate = gate
    }

    func recentTurns() async -> [ConversationMemoryTurn] {
        readCount += 1
        await gate?.wait()
        return turns
    }

    func set(_ turns: [ConversationMemoryTurn]) { self.turns = turns }
}

/// 本物の ClaudeAddressClassifier の下で、モデル呼び出しだけを置き換える。
actor RecordingAddressModelClient: AddressModelClient {
    private var result: GeneratedAddressTarget
    private let error: ConversationServiceError?
    /// 指定すると要求を記録した後にこのゲートで待つ（分類中の期限切れや停止を再現する）。
    private let gate: ConversationTestGate?
    private(set) var requests: [AddressClassificationRequest] = []

    init(result: GeneratedAddressTarget, error: ConversationServiceError? = nil, gate: ConversationTestGate? = nil) {
        self.result = result
        self.error = error
        self.gate = gate
    }

    func classify(_ request: AddressClassificationRequest) async throws -> GeneratedAddressTarget {
        requests.append(request)
        await gate?.wait()
        if let error { throw error }
        return result
    }

    func setResult(_ result: GeneratedAddressTarget) { self.result = result }
}

actor FakeReplyService: ReplyGenerating {
    typealias Continuation = AsyncThrowingStream<String, Error>.Continuation

    private let automaticSnapshots: [String]?
    private let resetGate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var promptWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var prompts: [String] = []
    private(set) var prewarmCount = 0
    private(set) var resetCount = 0

    init(
        automaticSnapshots: [String]?,
        resetGate: ConversationTestGate?,
        log: ConversationTestCallLog
    ) {
        self.automaticSnapshots = automaticSnapshots
        self.resetGate = resetGate
        self.log = log
    }

    func prewarm() async {
        prewarmCount += 1
        log.append(.prewarmReply)
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        prompts.append(utterance)
        log.append(.generateReply(utterance))
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        continuations.append(pair.continuation)
        resumePromptWaiters()
        if let automaticSnapshots {
            automaticSnapshots.forEach { pair.continuation.yield($0) }
            pair.continuation.finish()
        }
        return pair.stream
    }

    func reset() async {
        resetCount += 1
        await resetGate?.wait()
    }

    func yield(_ snapshot: String, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(snapshot)
    }

    func finish(run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    func fail(_ error: ConversationServiceError, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilPromptCount(_ count: Int) async {
        guard prompts.count < count else { return }
        await withCheckedContinuation { continuation in
            promptWaiters.append((count, continuation))
        }
    }

    private func resumePromptWaiters() {
        let ready = promptWaiters.filter { prompts.count >= $0.count }
        promptWaiters.removeAll { prompts.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeSpeechSpeaker: TestSentenceSpeaker {
    typealias Continuation = AsyncThrowingStream<SpeechEvent, Error>.Continuation

    private let automaticallyFinishes: Bool
    private var prepareError: ConversationServiceError?
    private let speakError: ConversationServiceError?
    private var stopGate: ConversationTestGate?
    private var speechStartGate: ConversationTestGate?
    private let log: ConversationTestCallLog
    private var continuations: [Continuation] = []
    private var textWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var texts: [String] = []
    private(set) var prepareCount = 0
    private(set) var stopCount = 0
    private(set) var stopCompletedCount = 0
    private(set) var speakStartCount = 0

    init(
        automaticallyFinishes: Bool,
        prepareError: ConversationServiceError?,
        speakError: ConversationServiceError?,
        stopGate: ConversationTestGate? = nil,
        log: ConversationTestCallLog
    ) {
        self.automaticallyFinishes = automaticallyFinishes
        self.prepareError = prepareError
        self.speakError = speakError
        self.stopGate = stopGate
        self.log = log
    }

    func prepare() async throws {
        prepareCount += 1
        log.append(.prepareSpeaker)
        if let prepareError { throw prepareError }
    }

    func setPrepareError(_ error: ConversationServiceError?) {
        prepareError = error
    }

    /// 以後の stop() をこの gate で止める（nil で解除）。案内が始まってから付けると、それ以前の後始末の stop は素通りする。
    func setStopGate(_ gate: ConversationTestGate?) {
        stopGate = gate
    }

    /// 本番の speak が active を登録する前の actor hop を再現する。
    func setSpeechStartGate(_ gate: ConversationTestGate?) {
        speechStartGate = gate
    }

    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        if let speakError { throw speakError }
        speakStartCount += 1
        if let speechStartGate {
            await speechStartGate.wait()
            try Task.checkCancellation()
        }
        texts.append(text)
        log.append(.speak(text))
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        continuations.append(pair.continuation)
        resumeTextWaiters()
        if automaticallyFinishes {
            pair.continuation.yield(.started)
            pair.continuation.yield(.willSpeak(range: 0..<max(1, text.count)))
            pair.continuation.yield(.finished)
            pair.continuation.finish()
        }
        return pair.stream
    }

    func stop() async {
        stopCount += 1
        log.append(.stopSpeaker)
        let old = continuations
        await stopGate?.wait()
        for continuation in old {
            continuation.yield(.cancelled)
            continuation.finish()
        }
        stopCompletedCount += 1
    }

    func yield(_ event: SpeechEvent, run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(run index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }

    /// 指定の読み上げだけを途中で失敗させる（それまでの読み上げは成功させられる）。
    func fail(run index: Int, with error: ConversationServiceError) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish(throwing: error)
    }

    func waitUntilTextCount(_ count: Int) async {
        guard texts.count < count else { return }
        await withCheckedContinuation { continuation in
            textWaiters.append((count, continuation))
        }
    }

    private func resumeTextWaiters() {
        let ready = textWaiters.filter { texts.count >= $0.count }
        textWaiters.removeAll { texts.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

actor FakeConversationAudioSession: AudioSessionControlling {
    nonisolated let events: AsyncStream<AudioSessionEvent>
    private nonisolated let eventContinuation: AsyncStream<AudioSessionEvent>.Continuation
    private let log: ConversationTestCallLog
    private let deactivateGate: ConversationTestGate?
    private let activateGate: ConversationTestGate?
    private let activateError: ConversationServiceError?
    private let volumeReadGate: ConversationTestGate?
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var isActive = false
    private var currentOutputVolume: Float = 1
    private(set) var volumeReadCount = 0
    var outputVolume: Float {
        get async {
            volumeReadCount += 1
            await volumeReadGate?.wait()
            return currentOutputVolume
        }
    }

    init(
        log: ConversationTestCallLog,
        activateGate: ConversationTestGate? = nil,
        activateError: ConversationServiceError? = nil,
        deactivateGate: ConversationTestGate? = nil,
        volumeReadGate: ConversationTestGate? = nil
    ) {
        let pair = AsyncStream<AudioSessionEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
        self.log = log
        self.activateGate = activateGate
        self.activateError = activateError
        self.deactivateGate = deactivateGate
        self.volumeReadGate = volumeReadGate
    }

    func activate() async throws {
        activateCount += 1
        log.append(.activateAudio)
        await activateGate?.wait()
        if let activateError { throw activateError }
        isActive = true
    }

    func setOutputVolume(_ volume: Float) { currentOutputVolume = volume }

    func deactivate() async {
        deactivateCount += 1
        log.append(.deactivateAudio)
        await deactivateGate?.wait()
        isActive = false
    }

    nonisolated func emit(_ event: AudioSessionEvent) {
        eventContinuation.yield(event)
    }
}

actor FakeServiceTeardown {
    private let gate: ConversationTestGate?
    private(set) var callCount = 0

    init(gate: ConversationTestGate? = nil) {
        self.gate = gate
    }

    func call() async {
        callCount += 1
        await gate?.wait()
    }
}

actor ConversationCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

@MainActor
final class ConversationTestAttention {
    var isFacingScreen = false
}

@MainActor
final class ConversationHarness {
    let attention = ConversationTestAttention()
    let calls: ConversationTestCallLog
    let now: ConversationTestNow
    let microphone: FakeMicrophonePermission
    let modelAvailability: FakeModelAvailability
    let recognizer: FakeSpeechRecognizer
    let classifier: FakeAddressClassifier
    let reply: FakeReplyService
    let speaker: FakeSpeechSpeaker
    let audio: FakeConversationAudioSession
    let teardownProbe: FakeServiceTeardown
    let latency: FakeConversationLatencyTracker
    let dependencies: ConversationDependencies
    let sut: ConversationViewModel

    init(
        recognizerOverride: (any SpeechRecognizing)? = nil,
        replyOverride: (any ReplyGenerating)? = nil,
        replyTraceSink: any ReplyTraceSink = NoopReplyTraceSink(),
        memory: (any ConversationMemoryManaging)? = nil,
        memoryPrepareGate: ConversationTestGate? = nil,
        classification: AddressTarget = .addressed,
        /// 指定すると fake の代わりにこの分類器（共有factoryの実routerなど）をVMへ渡す。
        classifierOverride: (any AddressClassifying)? = nil,
        isFacingScreen: (@MainActor @Sendable () -> Bool)? = nil,
        microphoneAllowed: Bool = true,
        modelAvailabilityResult: ModelAvailability = .available,
        /// 指定すると fake の代わりにこの availability（実の Hermes service など）を VM へ渡す。
        modelAvailabilityOverride: (any ModelAvailabilityChecking)? = nil,
        availabilityGate: ConversationTestGate? = nil,
        permissionGate: ConversationTestGate? = nil,
        replySnapshots: [String]? = ["わかったよ"],
        speakerAutomaticallyFinishes: Bool = true,
        speakerPrepareError: ConversationServiceError? = nil,
        speakerError: ConversationServiceError? = nil,
        speakerStopGate: ConversationTestGate? = nil,
        recognizerPrepareGate: ConversationTestGate? = nil,
        recognizerStopGate: ConversationTestGate? = nil,
        recognizerTail: SpeechRecognitionEvent? = nil,
        recognizerPrepareError: ConversationServiceError? = nil,
        recognizerStartError: ConversationServiceError? = nil,
        replyResetGate: ConversationTestGate? = nil,
        serviceTeardownGate: ConversationTestGate? = nil,
        audioDeactivateGate: ConversationTestGate? = nil,
        audioActivateError: ConversationServiceError? = nil,
        audioActivateGate: ConversationTestGate? = nil,
        audioVolumeReadGate: ConversationTestGate? = nil,
        latency: FakeConversationLatencyTracker? = nil,
        clarificationDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        noticeDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        lifecycleCheckpoint: @escaping @Sendable (ConversationLifecycleCheckpoint) async -> Void = { _ in }
    ) {
        let calls = ConversationTestCallLog()
        let now = ConversationTestNow()
        let microphone = FakeMicrophonePermission(
            allowed: microphoneAllowed,
            gate: permissionGate,
            log: calls
        )
        let modelAvailability = FakeModelAvailability(
            result: modelAvailabilityResult,
            gate: availabilityGate,
            log: calls
        )
        let recognizer = FakeSpeechRecognizer(
            log: calls,
            prepareGate: recognizerPrepareGate,
            stopGate: recognizerStopGate,
            tailOnFirstStop: recognizerTail,
            prepareError: recognizerPrepareError,
            startError: recognizerStartError
        )
        let classifier = FakeAddressClassifier(result: classification, log: calls)
        let reply = FakeReplyService(
            automaticSnapshots: replySnapshots,
            resetGate: replyResetGate,
            log: calls
        )
        let speaker = FakeSpeechSpeaker(
            automaticallyFinishes: speakerAutomaticallyFinishes,
            prepareError: speakerPrepareError,
            speakError: speakerError,
            stopGate: speakerStopGate,
            log: calls
        )
        let audio = FakeConversationAudioSession(
            log: calls,
            activateGate: audioActivateGate,
            activateError: audioActivateError,
            deactivateGate: audioDeactivateGate,
            volumeReadGate: audioVolumeReadGate
        )
        let teardownProbe = FakeServiceTeardown(gate: serviceTeardownGate)
        let latency = latency ?? FakeConversationLatencyTracker()
        let effectiveMemory: any ConversationMemoryManaging
        if let memory {
            effectiveMemory = memory
        } else if let memoryPrepareGate {
            effectiveMemory = FakeConversationMemoryManager(prepareGate: memoryPrepareGate)
        } else {
            effectiveMemory = UnsupportedConversationMemoryManager()
        }

        self.calls = calls
        self.now = now
        self.microphone = microphone
        self.modelAvailability = modelAvailability
        self.recognizer = recognizer
        self.classifier = classifier
        self.reply = reply
        self.speaker = speaker
        self.audio = audio
        self.teardownProbe = teardownProbe
        self.latency = latency
        let attention = self.attention
        let dependencies = ConversationDependencies(
            microphonePermission: microphone,
            modelAvailability: modelAvailabilityOverride ?? modelAvailability,
            recognizer: recognizerOverride ?? recognizer,
            classifier: classifierOverride ?? classifier,
            reply: replyOverride ?? reply,
            speaker: speaker,
            audioSession: audio,
            latency: latency,
            replyTraceSink: replyTraceSink,
            memory: effectiveMemory,
            isFacingScreen: isFacingScreen ?? { attention.isFacingScreen },
            now: { now.value },
            clarificationDelay: clarificationDelay,
            noticeDelay: noticeDelay,
            lifecycleCheckpoint: lifecycleCheckpoint,
            serviceTeardown: { await teardownProbe.call() }
        )
        self.dependencies = dependencies
        sut = ConversationViewModel(dependencies: dependencies)
    }

    func emit(_ event: SpeechRecognitionEvent, at timestamp: TimeInterval? = nil) async {
        if let timestamp { now.set(timestamp) }
        await recognizer.emit(event)
        await waitUntil {
            self.sut.viewState.provisionalTranscript == event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func emitCompletedUtterance(
        _ text: String,
        at timestamp: TimeInterval? = nil
    ) async {
        let eventTime = timestamp ?? now.value
        now.set(eventTime)
        await emit(.finalized(text), at: eventTime)
        now.set(eventTime + 1.2)
        await sut.flushSegmentation(at: eventTime + 1.2)
    }

    func completeTurn(_ text: String, at timestamp: TimeInterval) async {
        now.set(timestamp)
        if sut.viewState.phase == .idle || sut.viewState.phase == .paused {
            await sut.startConversation()
        }
        await emitCompletedUtterance(text, at: timestamp)
    }

    func completeUnengagedTurn(_ text: String, at timestamp: TimeInterval) async {
        await completeTurn(text, at: timestamp)
    }

    @discardableResult
    func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        await pollUntil(timeout: timeout, condition)
    }
}
