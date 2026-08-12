import AVFAudio
import Foundation

@MainActor
protocol SpeechSynthesizerDriving: AnyObject {
    var onEvent: (@MainActor @Sendable (SpeechSynthesizerDriverEvent) -> Void)? { get set }

    func availableVoices() -> [SpeechVoiceDescriptor]
    func speak(
        _ text: String,
        voiceIdentifier: String,
        runID: UInt64
    ) throws
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

struct SpeechVoiceDescriptor: Equatable, Sendable {
    let identifier: String
    let language: String
}

enum SpeechSynthesizerDriverEvent: Sendable {
    case didStart(runID: UInt64)
    case willSpeak(runID: UInt64, range: NSRange)
    case didFinish(runID: UInt64)
    case didCancel(runID: UInt64)
}

@MainActor
final class AppleSpeechSynthesizer: SpeechSpeaking {
    private struct ActiveRun {
        let id: UInt64
        let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
        var isStopping = false
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let driver: any SpeechSynthesizerDriving
    private let language: String
    private var selectedVoice: SpeechVoiceDescriptor?
    private var nextRunID: UInt64 = 0
    private var activeRun: ActiveRun?

    convenience init(language: String = "ja-JP") {
        self.init(driver: LiveSpeechSynthesizerDriver(), language: language)
    }

    init(
        driver: any SpeechSynthesizerDriving,
        language: String = "ja-JP"
    ) {
        self.driver = driver
        self.language = language
        driver.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func prepare() async throws {
        guard selectedVoice == nil else { return }
        let voices = driver.availableVoices()
        let requestedLanguage = Locale.Language(identifier: language)
        let voice = voices.first {
            Locale.Language(identifier: $0.language) == requestedLanguage
        } ?? voices.first {
            Locale.Language(identifier: $0.language).languageCode == .japanese
        }
        guard let voice else {
            throw ConversationServiceError.speechVoiceUnavailable
        }
        selectedVoice = voice
    }

    func speak(
        _ text: String
    ) async throws -> AsyncThrowingStream<SpeechEvent, Error> {
        guard activeRun == nil else {
            throw ConversationServiceError.speechSynthesisFailed
        }
        try await prepare()
        guard let selectedVoice else {
            throw ConversationServiceError.speechVoiceUnavailable
        }

        nextRunID += 1
        let runID = nextRunID
        let pair = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        // This also runs after finish(); the captured run guards make normal or
        // delayed termination a no-op instead of stopping a later utterance.
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.stop(runID: runID)
            }
        }
        activeRun = ActiveRun(
            id: runID,
            continuation: pair.continuation
        )

        do {
            try driver.speak(
                text,
                voiceIdentifier: selectedVoice.identifier,
                runID: runID
            )
        } catch {
            failEnqueue(runID: runID)
            throw ConversationServiceError.speechSynthesisFailed
        }
        return pair.stream
    }

    func stop() async {
        guard let runID = activeRun?.id else { return }
        await stop(runID: runID)
    }

    private func stop(runID: UInt64) async {
        guard activeRun?.id == runID else { return }
        await withCheckedContinuation { waiter in
            guard var run = activeRun, run.id == runID else {
                waiter.resume()
                return
            }
            run.stopWaiters.append(waiter)
            guard !run.isStopping else {
                activeRun = run
                return
            }

            run.isStopping = true
            activeRun = run
            guard driver.stopSpeaking(at: .immediate) else {
                complete(runID: runID, with: .cancelled)
                return
            }
        }
    }

    private func handle(_ event: SpeechSynthesizerDriverEvent) {
        switch event {
        case let .didStart(runID):
            yield(.started, for: runID)
        case let .willSpeak(runID, range):
            yield(
                .willSpeak(
                    range: range.location..<(range.location + range.length)
                ),
                for: runID
            )
        case let .didFinish(runID):
            complete(runID: runID, with: .finished)
        case let .didCancel(runID):
            complete(runID: runID, with: .cancelled)
        }
    }

    private func yield(_ event: SpeechEvent, for runID: UInt64) {
        guard let run = activeRun, run.id == runID else { return }
        run.continuation.yield(event)
    }

    private func complete(runID: UInt64, with event: SpeechEvent) {
        guard let run = activeRun, run.id == runID else { return }
        activeRun = nil
        run.continuation.yield(event)
        run.continuation.finish()
        run.stopWaiters.forEach { $0.resume() }
    }

    private func failEnqueue(runID: UInt64) {
        guard let run = activeRun, run.id == runID else { return }
        activeRun = nil
        run.continuation.finish(
            throwing: ConversationServiceError.speechSynthesisFailed
        )
        run.stopWaiters.forEach { $0.resume() }
    }
}

@MainActor
final class LiveSpeechSynthesizerDriver: SpeechSynthesizerDriving {
    var onEvent: (@MainActor @Sendable (SpeechSynthesizerDriverEvent) -> Void)?

    private let synthesizer: AVSpeechSynthesizer
    private var voicesByIdentifier: [String: AVSpeechSynthesisVoice] = [:]
    private var activeUtterance: AVSpeechUtterance?
    private var activeRunID: UInt64?
    private lazy var delegateProxy = SpeechSynthesizerDelegateProxy {
        [weak self] event in
        self?.handle(event)
    }

    init() {
        synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = delegateProxy
    }

    func availableVoices() -> [SpeechVoiceDescriptor] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        voicesByIdentifier.removeAll(keepingCapacity: true)
        for voice in voices {
            voicesByIdentifier[voice.identifier] = voice
        }
        return voices.map {
            SpeechVoiceDescriptor(
                identifier: $0.identifier,
                language: $0.language
            )
        }
    }

    func speak(
        _ text: String,
        voiceIdentifier: String,
        runID: UInt64
    ) throws {
        guard let voice = voicesByIdentifier[voiceIdentifier] else {
            throw LiveSpeechSynthesizerDriverError.voiceNotLoaded
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        activeUtterance = utterance
        activeRunID = runID
        synthesizer.speak(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        synthesizer.stopSpeaking(at: boundary)
    }

    private func handle(_ event: SpeechSynthesizerDelegateEvent) {
        guard let activeUtterance,
              let activeRunID,
              event.utteranceToken == Self.token(for: activeUtterance) else {
            return
        }

        switch event {
        case .didStart:
            onEvent?(.didStart(runID: activeRunID))
        case let .willSpeak(_, range):
            onEvent?(.willSpeak(runID: activeRunID, range: range))
        case .didFinish:
            onEvent?(.didFinish(runID: activeRunID))
            self.activeUtterance = nil
            self.activeRunID = nil
        case .didCancel:
            onEvent?(.didCancel(runID: activeRunID))
            self.activeUtterance = nil
            self.activeRunID = nil
        }
    }

    private static func token(for utterance: AVSpeechUtterance) -> UInt {
        UInt(bitPattern: ObjectIdentifier(utterance))
    }
}

private enum LiveSpeechSynthesizerDriverError: Error {
    case voiceNotLoaded
}

private enum SpeechSynthesizerDelegateEvent: Sendable {
    case didStart(utteranceToken: UInt)
    case willSpeak(utteranceToken: UInt, range: NSRange)
    case didFinish(utteranceToken: UInt)
    case didCancel(utteranceToken: UInt)

    var utteranceToken: UInt {
        switch self {
        case let .didStart(token),
             let .willSpeak(token, _),
             let .didFinish(token),
             let .didCancel(token):
            token
        }
    }
}

private final class SpeechSynthesizerDelegateProxy:
    NSObject,
    AVSpeechSynthesizerDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let onEvent: @MainActor @Sendable (SpeechSynthesizerDelegateEvent) -> Void
    private var pendingEvents: [SpeechSynthesizerDelegateEvent] = []
    private var isDrainScheduled = false

    init(
        onEvent: @escaping @MainActor @Sendable (
            SpeechSynthesizerDelegateEvent
        ) -> Void
    ) {
        self.onEvent = onEvent
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        enqueue(.didStart(utteranceToken: Self.token(for: utterance)))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        enqueue(.willSpeak(
            utteranceToken: Self.token(for: utterance),
            range: characterRange
        ))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        enqueue(.didFinish(utteranceToken: Self.token(for: utterance)))
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        enqueue(.didCancel(utteranceToken: Self.token(for: utterance)))
    }

    private func enqueue(_ event: SpeechSynthesizerDelegateEvent) {
        let shouldSchedule = lock.withLock {
            pendingEvents.append(event)
            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        while let event = nextEvent() {
            onEvent(event)
        }
    }

    private func nextEvent() -> SpeechSynthesizerDelegateEvent? {
        lock.withLock {
            guard !pendingEvents.isEmpty else {
                isDrainScheduled = false
                return nil
            }
            return pendingEvents.removeFirst()
        }
    }

    private static func token(for utterance: AVSpeechUtterance) -> UInt {
        UInt(bitPattern: ObjectIdentifier(utterance))
    }
}
