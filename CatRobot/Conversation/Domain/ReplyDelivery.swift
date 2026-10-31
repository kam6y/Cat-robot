import Foundation

/// Identity follows a routed reply through generation, playback, and memory.
enum ReplyDeliveryContext {
    @TaskLocal static var current: UUID?
}

struct ReplyInterruption: Equatable, Sendable {
    let id: UUID
    let prompt: String
    let completedText: String
    let interruptedSentence: Bool

    var memoryResponse: String {
        let marker = interruptedSentence
            ? "[利用者の発話で返答を中断。上記は再生完了した文のみ。次の文は途中で止まり、その先は伝えていない。]"
            : "[利用者の発話で返答を中断。上記以外はまだ読み上げていない。]"
        return completedText.isEmpty ? marker : completedText + "\n" + marker
    }
}

/// Only a contiguous prefix of completed sentences can count as delivered.
struct ReplyDeliveryProgress {
    private var sentences: [Int: String] = [:]
    private var started: Set<Int> = []
    private var finished: Set<Int> = []

    mutating func enqueue(_ sentence: SpeechSentence) { sentences[sentence.ordinal] = sentence.original }
    mutating func start(_ ordinal: Int) { started.insert(ordinal) }
    mutating func finish(_ ordinal: Int) { finished.insert(ordinal) }

    func interruption(id: UUID, prompt: String) -> ReplyInterruption {
        var ordinal = 0
        var text = ""
        while finished.contains(ordinal), let sentence = sentences[ordinal] {
            text += sentence
            ordinal += 1
        }
        return ReplyInterruption(id: id, prompt: prompt, completedText: text,
            interruptedSentence: !started.subtracting(finished).isEmpty)
    }
}
