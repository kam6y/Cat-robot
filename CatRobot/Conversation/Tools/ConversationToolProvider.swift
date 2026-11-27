import FoundationModels

/// 会話で使う首・表情・前面カメラの操作をまとめる。
protocol ConversationToolProvider: Sendable {
    func tools() -> [any Tool]
}

struct RobotConversationToolProvider: ConversationToolProvider {
    let motion: any RobotMotionControlling
    let expressions: any FaceExpressionControlling
    let look: any LookControlling

    init(motion: any RobotMotionControlling, expressions: any FaceExpressionControlling = NoopFaceExpressionController(),
         look: any LookControlling = NoopLookController()) {
        self.motion = motion
        self.expressions = expressions
        self.look = look
    }

    func tools() -> [any Tool] {
        [MoveHeadTool(motion: motion), ExpressTool(expressions: expressions), LookTool(look: look)]
    }
}
