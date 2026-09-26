import Foundation

/// Retains the exact emitted prefix, while permitting revisions to unsent text.
struct ReplySentenceStreamBuffer {
    private var emitted = ""
    private var ordinal = 0
    private var completed = false
    mutating func receive(_ snapshot: String, final: Bool = false) throws -> [SpeechSentence] {
        guard snapshot.hasPrefix(emitted) else { throw ConversationServiceError.modelGenerationFailed }
        if completed { return [] }
        var pending = String(snapshot.dropFirst(emitted.count))
        guard pending.count <= 2000 else { throw ConversationServiceError.inputTooLong }
        var output: [SpeechSentence] = []
        while true {
            var parser = ReplySentenceBuffer()
            guard let first = try parser.receive(pending) else { break }
            output.append(SpeechSentence(ordinal: ordinal, original: first))
            ordinal += 1; emitted += first
            pending = String(pending.dropFirst(first.count))
        }
        if final {
            if pending.contains(where: ReplySentenceBuffer.isContent) {
                output.append(SpeechSentence(ordinal: ordinal, original: pending))
                ordinal += 1
            }
            emitted += pending
            completed = true
        }
        return output
    }
}
