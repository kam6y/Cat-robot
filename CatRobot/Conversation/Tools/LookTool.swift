import CoreGraphics
import FoundationModels

struct LookToolOutput: PromptRepresentable, Sendable {
    let message: String
    var image: CGImage? = nil

    var promptRepresentation: Prompt {
        Prompt {
            message
            if let image { Attachment(image, orientation: .up) }
        }
    }
}

struct LookTool: Tool {
    let name = "look"
    let description = "利用者に見てと頼まれたとき、または返答に目の前の視覚情報が必要なとき、前面カメラの現在の静止画像を1枚取得する。purposeには見る理由を短く記す。取得できなければ見えたと主張せず、文字の結果に従って返答を続ける。"

    @Generable
    struct Arguments {
        @Guide(description: "目の前を見る必要がある理由を短く記す")
        var purpose: String
    }

    private let look: any LookControlling
    init(look: any LookControlling) { self.look = look }

    func call(arguments: Arguments) async throws -> LookToolOutput {
        let trace = ReplyTraceContext.current
        trace?.mark(.toolStarted, tool: .look)
        var outcome = ReplyTraceOutcome.generationFailure
        defer { trace?.mark(.toolFinished, outcome: Task.isCancelled ? .cancelled : outcome, tool: .look) }
        // Capture the SDK caller's scope before crossing the main actor.
        let turn = MotionTurnContext.current
        try Task.checkCancellation()
        guard let turn else { outcome = .success; return .init(message: "この返答では画像を取得できません") }
        let result = try await capture(for: turn)
        outcome = .success
        return result
    }

    @MainActor
    private func capture(for turn: MotionTurnID) async throws -> LookToolOutput {
        do {
            let snapshot = try await look.capture(for: turn)
            let accepted = look.finishCapture(snapshot, for: turn)
            try Task.checkCancellation()
            guard accepted else { return .init(message: "この返答の画像取得は取り消されました") }
            return .init(message: "現在の前面カメラの画像を1枚取得しました。画像をもとに返答してください。", image: snapshot.image)
        } catch {
            try Task.checkCancellation()
            let message: String
            switch error as? CameraSnapshotError {
            case .permissionRequired: message = "画像を取得できません。アプリの設定からカメラを許可してください。"
            case .busy: message = "別の画像を取得中です。今回は画像を取得していません。"
            case .timedOut: message = "カメラの準備が間に合わず、画像を取得できませんでした。"
            case .cancelled: message = "この返答の画像取得は取り消されました。"
            case .unavailable, nil: message = "今はカメラの画像を取得できません。見えたと主張せず、会話を続けてください。"
            }
            return .init(message: message)
        }
    }
}
