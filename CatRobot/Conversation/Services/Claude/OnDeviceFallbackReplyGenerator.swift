import Foundation
import OSLog

/// Claude の返答前の失敗や日次上限で端末内モデルへ切り替え、完了した往復を記憶へ引き継ぐ。
actor OnDeviceFallbackReplyGenerator: ReplyGenerating, ModelAvailabilityChecking {
    nonisolated let supportsStableReplyPrefix = true
    static let claudeFailureNotice = "今はいつものように話せないから、簡単に答えるね。"
    static let dailyLimitNotice = "今日はたくさん話したから、簡単にしか話せないよ。"
    static let consecutiveFailureNotice = "何度もうまく話せないみたい。少し待ってから、また話しかけてね。"
    static let consecutiveFailureThreshold = 3
    private static let logger = Logger(subsystem: "com.kamby.CatRobot", category: "ConversationFallback")

    /// ログへ渡せる値を限定する。本文・通知文・元エラーは診断情報に含めない。
    private enum FallbackCause: String {
        case modelUnreachable, modelGenerationFailed, dailyLimitReached
        var reason: String { self == .dailyLimitReached ? "dailyLimit" : "claudeFailure" }
    }

    private let motion: any ReplyTurnObserving
    private let primary: ClaudeConversationService
    private let secondary: any ReplyGenerating
    private let secondaryAvailability: any ModelAvailabilityChecking
    private let usage: any ConversationUsageMetering
    private let configuration: @Sendable () async -> ConversationModelConfiguration
    /// 代替対象の失敗だけを数え、Claude の返答が正常に完了したときだけ 0 に戻す。
    private var consecutiveClaudeFailures = 0

    init(primary: ClaudeConversationService, secondary: any ReplyGenerating, secondaryAvailability: any ModelAvailabilityChecking,
         usage: any ConversationUsageMetering, configuration: @escaping @Sendable () async -> ConversationModelConfiguration,
         motion: any ReplyTurnObserving = NoopRobotMotionController()) {
        self.motion = motion
        self.primary = primary
        self.secondary = secondary
        self.secondaryAvailability = secondaryAvailability
        self.usage = usage
        self.configuration = configuration
    }

    func availability() async -> ModelAvailability {
        let claude = await primary.availability()
        switch claude {
        case .available:
            return .available
        case .claudeUnreachable:
            // 通信障害時は端末内モデルを使えるが、既知の認証エラーは隠さない。
            return await secondaryAvailability.availability() == .available ? .available : claude
        default:
            return claude
        }
    }

    func prewarm() async { await primary.prewarm() }

    func reset() async {
        await primary.reset()
        await secondary.reset()
    }

    func interruptReply(_ interruption: ReplyInterruption) async {
        await primary.interruptReply(interruption)
        await secondary.interruptReply(interruption)
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        let limit = await configuration().dailyTurnLimit
        if await usage.isDailyLimitReached(limit: limit) {
            let failureCount = consecutiveClaudeFailures
            let available = await secondaryAvailability.availability()
            try Task.checkCancellation()
            guard available == .available else { throw ConversationServiceError.dailyLimitReached }
            return try await onDevice(utterance, notice: Self.dailyLimitNotice, cause: .dailyLimitReached, failureCount: failureCount)
        }
        let source = try await primary.streamReply(to: utterance)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let worker = Task { await self.relay(source, utterance: utterance, into: continuation) }
        continuation.onTermination = { termination in
            if case .cancelled = termination { worker.cancel() }
        }
        return stream
    }

    private func relay(_ source: AsyncThrowingStream<String, Error>, utterance: String,
                       into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        var yieldedVisibleText = false
        do {
            for try await snapshot in source {
                try Task.checkCancellation()
                if !yieldedVisibleText, !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    yieldedVisibleText = true
                }
                continuation.yield(snapshot)
            }
            try Task.checkCancellation()
            consecutiveClaudeFailures = 0
            continuation.finish()
        } catch {
            let failure = Task.isCancelled ? ConversationServiceError.cancelled : ClaudeErrorMapper.map(error)
            if failure.allowsOnDeviceFallback { consecutiveClaudeFailures += 1 }
            // この失敗の通知文と回数を await 前に固定し、後続ターンの増減の影響を受けないようにする。
            let failureCount = consecutiveClaudeFailures
            let notice = failureCount >= Self.consecutiveFailureThreshold
                ? Self.consecutiveFailureNotice : Self.claudeFailureNotice
            guard failure.allowsOnDeviceFallback, !yieldedVisibleText, !Task.isCancelled,
                  await secondaryAvailability.availability() == .available else {
                if failure == .refusal {
                    Self.logger.notice("event=refusalReceived kind=refusal reason=claudeFailure consecutiveFailures=\(failureCount, privacy: .public)")
                }
                continuation.finish(throwing: failure)
                return
            }
            // allowsOnDeviceFallback が許すのはこの 2 種類だけ。
            let cause: FallbackCause = failure == .modelUnreachable ? .modelUnreachable : .modelGenerationFailed
            do {
                let fallback = try await onDevice(utterance, notice: notice, cause: cause, failureCount: failureCount)
                for try await snapshot in fallback {
                    try Task.checkCancellation()
                    continuation.yield(snapshot)
                }
                try Task.checkCancellation()
                continuation.finish()
            } catch {
                if let memoryFailure = error as? ConversationMemoryError {
                    continuation.finish(throwing: memoryFailure)
                } else {
                    continuation.finish(throwing: ClaudeErrorMapper.map(error))
                }
            }
        }
    }

    /// 端末内モデルの累積スナップショットに注意書きを前置し、本文のある完了した往復だけを保存する。
    private func onDevice(_ utterance: String, notice: String, cause: FallbackCause,
                          failureCount: Int) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        if let turn = MotionTurnContext.current { await motion.cancelTurn(turn, reason: .fallback) }
        try Task.checkCancellation()
        // 日次上限の経路でも記憶を準備する。Claude のセッション生成やネットワーク送信は行わない。
        try await primary.beginExternalReply(prompt: utterance)
        try Task.checkCancellation()
        Self.logger.notice("event=fallbackStarted kind=\(cause.rawValue, privacy: .public) reason=\(cause.reason, privacy: .public) consecutiveFailures=\(failureCount, privacy: .public)")
        let streamsStablePrefix = secondary.supportsStableReplyPrefix
        let source = try await secondary.streamReply(to: utterance)
        try Task.checkCancellation()
        let primary = self.primary
        return AsyncThrowingStream { continuation in
            let task = Task {
                var finalBody = ""
                do {
                    try Task.checkCancellation()
                    // 安定した通知文は先に出し、改訂されうる本文は確定まで外へ出さない。
                    if !streamsStablePrefix { continuation.yield(notice) }
                    for try await snapshot in source {
                        try Task.checkCancellation()
                        finalBody = snapshot
                        if streamsStablePrefix { continuation.yield(notice + snapshot) }
                    }
                    try Task.checkCancellation()
                    guard !finalBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConversationServiceError.modelGenerationFailed
                    }
                    if !streamsStablePrefix { continuation.yield(notice + finalBody) }
                    await primary.recordExternalTurn(prompt: utterance, response: notice + finalBody)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ClaudeErrorMapper.map(error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }
}
