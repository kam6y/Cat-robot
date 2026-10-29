import OSLog

struct OSReplyTraceSink: ReplyTraceSink {
    private let logger = Logger(subsystem: "com.kamby.CatRobot", category: "ConversationLatency")
    func record(_ event: ReplyTraceEvent) {
        logger.notice("reply trace=\(event.id.uuidString, privacy: .public) point=\(event.point.rawValue, privacy: .public) at=\(event.at, privacy: .public) part=\(event.part?.rawValue ?? "-", privacy: .public) source=\(event.source?.rawValue ?? "-", privacy: .public) sentence=\(event.sentenceOrdinal ?? -1) tool=\(event.tool?.rawValue ?? "-", privacy: .public) outcome=\(event.outcome?.rawValue ?? "-", privacy: .public)")
    }
}
