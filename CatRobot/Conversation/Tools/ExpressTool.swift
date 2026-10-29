import FoundationModels

struct ExpressTool: Tool {
    let name = "express"
    let description = "返答の発話開始に合わせる猫の表情を予約する。expressionはneutral, happy, curious, thinking, speaking, sleepy, surprised, sorry。hold_secondsは1〜10秒、省略は3秒。不明な表情はneutral、秒数は範囲内に丸める。結果は表示済みではなく予約を表す。"

    @Generable
    struct Arguments {
        @Guide(description: "neutral, happy, curious, thinking, speaking, sleepy, surprised, sorry のいずれか")
        var expression: String
        @Guide(description: "保持秒数。1〜10、省略時は3")
        var hold_seconds: Int?
    }

    private let expressions: any FaceExpressionControlling
    init(expressions: any FaceExpressionControlling) { self.expressions = expressions }

    func call(arguments: Arguments) async throws -> String {
        let trace = ReplyTraceContext.current
        trace?.mark(.toolStarted, tool: .express)
        defer { trace?.mark(.toolFinished, outcome: Task.isCancelled ? .cancelled : .success, tool: .express) }
        guard let turn = MotionTurnContext.current, !Task.isCancelled else {
            return "この返答の表情は変更できません"
        }
        let request = FaceExpressionRequest(expression: .normalized(arguments.expression),
                                            holdSeconds: arguments.hold_seconds ?? 3)
        let result = await MainActor.run {
            Task.isCancelled ? FaceExpressionReservationResult.invalidated : expressions.reserve(request, for: turn)
        }
        switch result {
        case .reserved: return "\(label(request.expression))表情を\(request.holdSeconds)秒予約しました"
        case .invalidated: return "この返答の表情は変更できません"
        case .unavailable: return "今は表情を変えられません"
        }
    }

    private func label(_ expression: FaceExpression) -> String {
        switch expression {
        case .neutral: "通常の"
        case .happy: "うれしい"
        case .curious: "興味を持った"
        case .thinking: "考え中の"
        case .speaking: "話している"
        case .sleepy: "眠そうな"
        case .surprised: "驚いた"
        case .sorry: "申し訳なさそうな"
        case .sleeping: "眠っている"
        }
    }
}
