import Foundation

protocol ModelAvailabilityChecking: Sendable {
    func availability() async -> ModelAvailability
}

protocol AddressClassifying: Sendable {
    func classify(_ utterance: String) async throws -> AddressTarget
}

protocol ReplyGenerating: Sendable {
    var supportsStableReplyPrefix: Bool { get }
    func prewarm() async
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
    func interruptReply(_ interruption: ReplyInterruption) async
}

extension ReplyGenerating {
    var supportsStableReplyPrefix: Bool { false }
    func interruptReply(_ interruption: ReplyInterruption) async {}
}

protocol SpeechRecognizing: Sendable {
    /// True only when this capture path can reject the concurrent playback echo.
    var supportsConcurrentPlayback: Bool { get async }
    func prepare() async throws
    func start() async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
    func stop() async
}

protocol SpeechSpeaking: Sendable {
    func prepare() async throws
    func speak(_ text: String) async throws -> AsyncThrowingStream<SpeechEvent, Error>
    func stop() async
}

protocol AudioSessionControlling: Sendable {
    var events: AsyncStream<AudioSessionEvent> { get }
    func activate() async throws
    func activatePlaybackOnly() async throws
    func deactivate() async
}
