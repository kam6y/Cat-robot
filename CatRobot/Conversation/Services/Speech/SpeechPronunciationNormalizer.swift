import Foundation

/// Changes only curated spoken words. The caller retains the original caption/memory.
struct SpeechPronunciationNormalizer: Sendable {
    func normalize(_ original: String) -> String {
        let text = original as NSString
        let full = NSRange(location: 0, length: text.length)
        let protectedPattern = #"(?i)https?://[^\s<>「」]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let protectedExpression = try! NSRegularExpression(pattern: protectedPattern)
        var protected = protectedExpression.matches(in: original, range: full).map(\.range)
        var cursor = 0
        while cursor < text.length {
            let opening = text.range(of: "`", range: NSRange(location: cursor, length: text.length - cursor))
            guard opening.location != NSNotFound else { break }
            var end = opening.location
            while end < text.length, text.character(at: end) == 96 { end += 1 }
            let delimiter = text.substring(with: NSRange(location: opening.location, length: end - opening.location))
            let closing = text.range(of: delimiter, range: NSRange(location: end, length: text.length - end))
            let last = closing.location == NSNotFound ? text.length : NSMaxRange(closing)
            protected.append(NSRange(location: opening.location, length: last - opening.location))
            cursor = last
        }
        let words = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_])(iphone|bluetooth)(?![A-Za-z0-9_])"#)
        let result = NSMutableString(string: original)
        for match in words.matches(in: original, range: full).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let replacement = text.substring(with: match.range).lowercased() == "iphone" ? "アイフォーン" : "ブルートゥース"
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }
}
