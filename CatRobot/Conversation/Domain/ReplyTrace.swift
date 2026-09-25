import Foundation

enum ReplyTracePoint: String, Codable, Sendable {
    case captureBoundary, captureClosed, classificationStarted, classificationFinished
    case request, firstCaption, firstSentence, generationFinished, streamFinished
    case compactionStarted, compactionFinished, sessionStarted, sessionFinished
    case saveStarted, saveFinished, speechEnqueued, speechStarted, speechFinished, finished
}
enum ReplyTraceOutcome: String, Codable, Sendable {
    case success, cancelled, generationFailure, speechFailure, saveWarning, noResponse, ambiguous
}
enum ReplySpeechPart: String, Codable, Sendable { case first, remainder, full }
enum ReplySpeechStartSource: String, Codable, Sendable { case started, willSpeakFallback }
struct ReplyTraceEvent: Codable, Sendable {
    let id: UUID
    let point: ReplyTracePoint
    let at: TimeInterval
    let part: ReplySpeechPart?
    let source: ReplySpeechStartSource?
    let outcome: ReplyTraceOutcome?
    var sentenceOrdinal: Int? = nil
}
protocol ReplyTraceSink: Sendable { func record(_ event: ReplyTraceEvent) }
struct NoopReplyTraceSink: ReplyTraceSink { func record(_ event: ReplyTraceEvent) {} }

/// Records only timing and enumerated metadata, never conversation content.
final class ReplyTrace: @unchecked Sendable {
    let id: UUID
    private let sink: any ReplyTraceSink
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var terminal = false
    private var once: Set<String> = []
    private var intervals: [ReplyTracePoint: Int] = [:]
    private static let ends: [ReplyTracePoint: ReplyTracePoint] = [
        .classificationFinished: .classificationStarted, .compactionFinished: .compactionStarted,
        .sessionFinished: .sessionStarted, .saveFinished: .saveStarted
    ]

    init(id: UUID = UUID(), sink: any ReplyTraceSink, now: @escaping @Sendable () -> TimeInterval) {
        self.id = id; self.sink = sink; self.now = now
    }

    func mark(_ point: ReplyTracePoint, part: ReplySpeechPart? = nil,
              source: ReplySpeechStartSource? = nil, outcome: ReplyTraceOutcome? = nil, sentenceOrdinal: Int? = nil) {
        lock.withLock {
            if let start = Self.ends[point] {
                guard intervals[start, default: 0] > 0 else { return }
                intervals[start, default: 0] -= 1
            } else {
                guard !terminal else { return }
                if Self.ends.values.contains(point) { intervals[point, default: 0] += 1 }
            }
            switch point {
            case .firstCaption, .firstSentence, .speechStarted, .generationFinished, .streamFinished:
                guard once.insert(point.rawValue + (part?.rawValue ?? "") + (sentenceOrdinal.map(String.init) ?? "")).inserted else { return }
            default: break
            }
            if point == .finished { terminal = true }
            sink.record(ReplyTraceEvent(id: id, point: point, at: now(), part: part, source: source, outcome: outcome, sentenceOrdinal: sentenceOrdinal))
        }
    }
    func finish(_ outcome: ReplyTraceOutcome) { mark(.finished, outcome: outcome) }
}

enum ReplyTraceContext { @TaskLocal static var current: ReplyTrace? }
