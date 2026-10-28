import FoundationModels

/// セッションに渡すツールの集合。セッションを作るたびに呼ばれ、memory はそのセッションの世代に固定された書き込み口。
/// 首、表情、要求された静止画像は、同じ返答ターンのツールとして渡す。
protocol ConversationToolProvider: Sendable {
    func tools(memory: any LongTermMemoryWriting) -> [any Tool]
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

    func tools(memory: any LongTermMemoryWriting) -> [any Tool] {
        [RememberTool(memory: memory), MoveHeadTool(motion: motion), ExpressTool(expressions: expressions), LookTool(look: look)]
    }
}
