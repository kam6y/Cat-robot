import Foundation

protocol ModelAvailabilityChecking: Sendable {
    func availability() async -> ModelAvailability
}

protocol AddressClassifying: Sendable {
    func classify(_ utterance: String) async throws -> AddressTarget
}

protocol ReplyGenerating: Sendable {
    func prepare() async throws
    func streamReply(
        to request: ReplyTurnRequest
    ) async throws -> AsyncThrowingStream<ReplyStreamEvent, Error>
    func reset() async
}

protocol SpeechRecognizing: Sendable {
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
    func deactivate() async
}
