import Foundation

struct SpeechSentence: Sendable, Equatable { let ordinal: Int; let original: String }
struct SentenceSpeechEvent: Sendable { let ordinal: Int; let event: SpeechEvent }
protocol SentenceSpeechSpeaking: SpeechSpeaking {
    func speakSentences(from channel: SpeechSentenceChannel, prefetch: Bool)
        async throws -> AsyncThrowingStream<SentenceSpeechEvent, Error>
}
