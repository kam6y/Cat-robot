import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A control response starts the assistant message: line 1 is the marker, line 2 one JSON object, line 3 onward the speech.
/// Ordinary replies are never scanned for commands. Only `look` needs the device result before the answer, so a
/// look reply's speech is discarded and answered by one follow-up; neck and face ride with the first reply's speech.
struct HermesDeviceActions: Decodable, Sendable {
    static let marker = "CAROT_ACTIONS"
    let look: Bool?
    let moveHead: Movement?
    let express: Expression?

    struct Movement: Decodable, Sendable {
        let gesture: String
        let intensity: String
        let repeats: Int?
    }

    struct Expression: Decodable, Sendable {
        let expression: String
        let holdSeconds: Int?
        enum CodingKeys: String, CodingKey { case expression, holdSeconds = "hold_seconds" }
    }

    enum CodingKeys: String, CodingKey { case look, moveHead = "move_head", express }

    /// nil は普通の返事。制御が崩れているとき、動作が無いとき、look を頼まずに言葉が無いときは throw（何も動かさない）。
    static func parse(_ text: String) throws -> (actions: Self, speech: String)? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 2, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == Substring(marker) else { return nil }
        guard lines.count >= 2, lines[1].utf8.count <= 2_048,
              let actions = try? JSONDecoder().decode(Self.self, from: Data(lines[1].utf8)),
              actions.look == true || actions.moveHead != nil || actions.express != nil else {
            throw ConversationServiceError.modelGenerationFailed
        }
        let speech = lines.count == 3 ? lines[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard actions.look == true || !speech.isEmpty else { throw ConversationServiceError.modelGenerationFailed }
        return (actions, speech)
    }
}

struct HermesDeviceFeedback: Sendable {
    /// 撮影の結果。首・表情の予約結果は会話に含めない。
    var cameraMessage: String?
    var jpeg: Data?
}

extension RobotConversationToolProvider {
    func perform(_ actions: HermesDeviceActions) async throws -> HermesDeviceFeedback {
        var result = HermesDeviceFeedback()
        try Task.checkCancellation()
        if let move = actions.moveHead {
            _ = try await MoveHeadTool(motion: motion).call(arguments:
                .init(gesture: move.gesture, intensity: move.intensity, repeats: move.repeats))
        }
        if let face = actions.express {
            _ = try await ExpressTool(expressions: expressions).call(arguments:
                .init(expression: face.expression, hold_seconds: face.holdSeconds))
        }
        if actions.look == true {
            let capture = try await LookTool(look: look).call(arguments: .init(purpose: "この返答で目の前を確認する"))
            if let image = capture.image {
                // Encode the upright camera pixels in memory. No source file, EXIF or location metadata is copied.
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                    if CGImageDestinationFinalize(destination) { result.jpeg = data as Data }
                }
                result.cameraMessage = result.jpeg == nil ? "カメラの画像を送信できませんでした。" : capture.message
            } else {
                result.cameraMessage = capture.message
            }
        }
        try Task.checkCancellation()
        return result
    }
}
