import Foundation

/// Single producer/consumer, with an awaited send instead of a dropping stream.
actor SpeechSentenceChannel {
    private let capacity: Int
    private var queue: [SpeechSentence] = []
    private var closed = false
    private var failure: Error?
    private var sender: (UUID, SpeechSentence, CheckedContinuation<Void, Error>)?
    private var receiver: (UUID, CheckedContinuation<SpeechSentence?, Error>)?
    init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    func send(_ sentence: SpeechSentence) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if let failure { continuation.resume(throwing: failure) }
                else if closed { continuation.resume(throwing: ConversationServiceError.cancelled) }
                else if let waiting = receiver {
                    receiver = nil
                    waiting.1.resume(returning: sentence)
                    continuation.resume()
                } else if queue.count < capacity {
                    queue.append(sentence); continuation.resume()
                } else if sender == nil { sender = (id, sentence, continuation) }
                else { continuation.resume(throwing: ConversationServiceError.modelBusy) }
            }
        } onCancel: { Task { await self.cancelSend(id) } }
    }
    func next() async throws -> SpeechSentence? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if let failure { continuation.resume(throwing: failure) }
                else if !queue.isEmpty {
                    let first = queue.removeFirst()
                    if let waiting = sender {
                        sender = nil; queue.append(waiting.1); waiting.2.resume()
                    }
                    continuation.resume(returning: first)
                } else if closed { continuation.resume(returning: nil) }
                else if receiver == nil { receiver = (id, continuation) }
                else { continuation.resume(throwing: ConversationServiceError.modelBusy) }
            }
        } onCancel: { Task { await self.cancelReceive(id) } }
    }
    func finish(throwing error: Error? = nil) {
        guard failure == nil else { return }
        if closed, error == nil { return }
        closed = true
        failure = error
        if error != nil { queue.removeAll() }
        if let waiting = sender {
            sender = nil; waiting.2.resume(throwing: error ?? ConversationServiceError.cancelled)
        }
        if let waiting = receiver {
            receiver = nil
            if let error { waiting.1.resume(throwing: error) }
            else { waiting.1.resume(returning: nil) }
        }
    }
    private func cancelSend(_ id: UUID) {
        guard let waiting = sender, waiting.0 == id else { return }
        sender = nil; waiting.2.resume(throwing: CancellationError())
    }
    private func cancelReceive(_ id: UUID) {
        guard let waiting = receiver, waiting.0 == id else { return }
        receiver = nil; waiting.1.resume(throwing: CancellationError())
    }
}
