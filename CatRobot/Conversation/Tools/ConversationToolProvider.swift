import FoundationModels

/// 返答のモデルに渡す体の操作の tool（首・表情・要求された静止画像）。同じ返答ターンの tool として渡す。
/// 今の Hermes の返事からは呼ばれない（Hermes の API は呼び出し側の tool を実行しない）。Hermes への接続は別のタスク。
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
