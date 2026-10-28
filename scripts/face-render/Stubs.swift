// macOS レンダーハーネス用に、製品の enum だけを写したもの。ケース名と順序は製品と同じに保つ。
// - MouthPose: CatRobot/Conversation/UI/ConversationViewState.swift
// - FaceExpression: CatRobot/Conversation/Face/FaceExpression.swift（ケースのみ。automatic(for:) は会話状態に依存するので写さない）

enum MouthPose: Equatable, Sendable {
    case closed
    case small
    case medium
    case wide
}

enum FaceExpression: String, CaseIterable, Sendable {
    case neutral, happy, curious, thinking, listening, speaking, sleepy, surprised, sorry, sleeping
}
