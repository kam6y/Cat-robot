import Foundation

protocol ModelAvailabilityChecking: Sendable {
    func availability() async -> ModelAvailability
    /// 利用者が明示的に確かめ直したとき（「もう一度確認」）だけ呼ぶ。拒否を覚えていない実装は何もしない。
    func recheckAvailability() async
}

extension ModelAvailabilityChecking {
    func recheckAvailability() async {}
}

protocol AddressClassifying: Sendable {
    func classify(_ request: AddressClassificationRequest) async throws -> AddressTarget
}

protocol ReplyGenerating: Sendable {
    var supportsStableReplyPrefix: Bool { get }
    func prewarm() async
    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error>
    func reset() async
}

extension ReplyGenerating {
    var supportsStableReplyPrefix: Bool { false }
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
    var outputVolume: Float { get async }
    func activate() async throws
    func deactivate() async
}
