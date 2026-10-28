import Foundation
@testable import CatRobot

/// Supplies sentence transport for controllable single-utterance test speakers.
/// Product integration tests therefore exercise SentenceReplyPlayback; PCM synthesis
/// and bounded prefetch remain covered with the real SupertonicSentenceSpeaker.
protocol TestSentenceSpeaker: SentenceSpeechSpeaking {}

extension TestSentenceSpeaker {
    func speakSentences(from channel: SpeechSentenceChannel, prefetch: Bool)
        async throws -> AsyncThrowingStream<SentenceSpeechEvent, Error> {
        let pair = AsyncThrowingStream<SentenceSpeechEvent, Error>.makeStream()
        let task = Task {
            do {
                while let sentence = try await channel.next() {
                    let events = try await speak(sentence.original)
                    var finished = false
                    for try await event in events {
                        try Task.checkCancellation()
                        if event == .cancelled { throw ConversationServiceError.speechSynthesisFailed }
                        if event == .finished { finished = true }
                        pair.continuation.yield(.init(ordinal: sentence.ordinal, event: event))
                    }
                    try Task.checkCancellation()
                    guard finished else { throw ConversationServiceError.speechSynthesisFailed }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}
