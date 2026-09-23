import Foundation

/// Splits at most once. The emitted prefix is immutable; the remaining text may change.
struct ReplySentenceBuffer {
    private var sent: String?
    private static let endings: Set<Character> = ["。", "！", "？", "!", "?"]
    private static let pairs: [Character: Character] = ["「": "」", "『": "』", "（": "）", "(": ")", "“": "”", "\"": "\""]
    private static let closers = Set(pairs.values)

    mutating func receive(_ snapshot: String) throws -> String? {
        if sent != nil { _ = try remainder(in: snapshot); return nil }
        var stack: [Character] = []
        var candidate: String.Index?
        var ready: String.Index?
        var hasContent = false
        var escaped = false
        var isURL = false
        for index in snapshot.indices {
            let character = snapshot[index]
            let next = snapshot.index(after: index)
            let content = Self.isContent(character)
            if let boundary = ready {
                if content {
                    let prefix = String(snapshot[..<boundary])
                    sent = prefix
                    return prefix
                }
                // Only adjacent closing marks, terminators and whitespace belong
                // to the first sentence. An opening quote belongs to the next one.
                if candidate == index, character.isWhitespace || Self.endings.contains(character) || Self.closers.contains(character) {
                    ready = next
                    candidate = next
                } else { candidate = nil }
                continue
            }
            if character.isWhitespace { isURL = false }
            // A URL need not be separated from Japanese text by whitespace.
            // Conservatively protect through the next whitespace; delaying a
            // split is safer than speaking a query delimiter as a sentence end.
            if character == "h", snapshot[index...].hasPrefix("https://") || snapshot[index...].hasPrefix("http://") {
                isURL = true
            }
            if escaped {
                escaped = false
                if content { hasContent = true; candidate = nil }
                continue
            }
            if character == "\\" { escaped = true; continue }
            if stack.last == character {
                stack.removeLast()
                if candidate != nil {
                    candidate = next
                    if stack.isEmpty, hasContent { ready = next }
                }
            } else if let closing = Self.pairs[character] {
                stack.append(closing)
                candidate = nil
            } else if Self.endings.contains(character), !isURL {
                candidate = next
                if stack.isEmpty, hasContent { ready = next }
            } else if content {
                hasContent = true
                candidate = nil
            }
        }
        return nil
    }

    func remainder(in finalSnapshot: String) throws -> String {
        guard let sent else { return finalSnapshot }
        guard finalSnapshot.hasPrefix(sent) else { throw ConversationServiceError.modelGenerationFailed }
        return String(finalSnapshot.dropFirst(sent.count))
    }

    private static func isContent(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation
        }
    }
}
