import Foundation

/// 日次上限を返答の直前と prewarm で確かめる decorator。上限の日は base を呼ばないので、
/// Claude のセッション生成・通信・記憶の更新・利用量の加算は起きない。上限は呼び出しごとに今の設定から読む。
struct DailyLimitedReplyGenerator: ReplyGenerating {
    private let base: any ReplyGenerating
    private let usage: any ConversationUsageMetering
    private let configuration: @Sendable () async -> ConversationModelConfiguration

    init(base: any ReplyGenerating, usage: any ConversationUsageMetering,
         configuration: @escaping @Sendable () async -> ConversationModelConfiguration) {
        self.base = base
        self.usage = usage
        self.configuration = configuration
    }

    var supportsStableReplyPrefix: Bool { base.supportsStableReplyPrefix }

    func prewarm() async {
        guard await !isLimitReached() else { return }
        await base.prewarm()
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        if await isLimitReached() { throw ConversationServiceError.dailyLimitReached }
        return try await base.streamReply(to: utterance)
    }

    func reset() async { await base.reset() }

    private func isLimitReached() async -> Bool {
        let limit = await configuration().dailyTurnLimit
        return await usage.isDailyLimitReached(limit: limit)
    }
}
