import FoundationModels

struct MoveHeadTool: Tool {
    let name = "move_head"
    let description = "返答の発話開始に合わせる首の動作を予約する。gestureはnod, shake, tilt, look_up, look_down, look_at_user, center。intensityはsmall, medium, large。repeatsは1〜3、省略は1。look_at_userは追尾対象がなければ正面。結果は実行済みではなく予約を表す。"

    @Generable
    struct Arguments {
        @Guide(description: "nod, shake, tilt, look_up, look_down, look_at_user, center のいずれか") var gesture: String
        @Guide(description: "small, medium, large のいずれか") var intensity: String
        @Guide(description: "1〜3。省略時は1") var repeats: Int?
    }

    private let motion: any RobotMotionControlling
    init(motion: any RobotMotionControlling) { self.motion = motion }

    func call(arguments: Arguments) async throws -> String {
        return await ReplyTraceContext.withTool(.moveHead) {
            guard let turn = MotionTurnContext.current else { return "この返答では首の動作を予約できません" }
            guard !Task.isCancelled else { return "この返答の動作予約は取り消されました" }
            guard let gesture = RobotGesture(rawValue: arguments.gesture.lowercased()),
                  let intensity = RobotIntensity(rawValue: arguments.intensity.lowercased()),
                  (1...3).contains(arguments.repeats ?? 1) else {
                return "動作・強さ・回数を確認してください（回数は1〜3です）"
            }
            let request = RobotMotionRequest(gesture: gesture, intensity: intensity, repeats: arguments.repeats ?? 1)
            let result = await MainActor.run {
                Task.isCancelled ? MotionReservationResult.invalidated : motion.reserve(request, for: turn)
            }
            switch result {
            case .reserved(let count): return "\(label(gesture))を\(count)回予約しました"
            case .unavailable: return "今は首を動かせません"
            case .budgetExceeded: return "この返答の動作枠を超えるため追加しません"
            case .invalidated: return "この返答の動作予約は取り消されました"
            case .invalidArguments: return "動作・強さ・回数を確認してください（回数は1〜3です）"
            }
        }
    }

    private func label(_ gesture: RobotGesture) -> String {
        switch gesture {
        case .nod: "頷く動作"
        case .shake: "首を振る動作"
        case .tilt: "首をかしげる動作"
        case .lookUp: "上を向く動作"
        case .lookDown: "下を向く動作"
        case .lookAtUser, .center: "正面を向く動作"
        }
    }
}
