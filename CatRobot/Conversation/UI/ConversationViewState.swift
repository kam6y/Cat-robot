import Foundation

enum CatVisualState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case clarifying
    case speaking
    case failed
}

enum MouthPose: Equatable, Sendable {
    case closed
    case small
    case medium
    case wide
}

struct SpeechMouthPoseSequence {
    private static let wordPoses: [MouthPose] = [.wide, .medium, .small]
    private var wordIndex = 0

    mutating func nextWordPose() -> MouthPose {
        defer { wordIndex += 1 }
        return Self.wordPoses[wordIndex % Self.wordPoses.count]
    }
}

enum ConversationRecoveryAction: Equatable, Sendable {
    case retry
    case openSettings
    case showTypedInput
}

struct ConversationRecovery: Equatable, Sendable {
    var title: String
    var action: ConversationRecoveryAction
}

struct ConversationViewState: Equatable, Sendable {
    var phase: ConversationPhase
    var catState: CatVisualState
    var mouthPose: MouthPose
    var microphoneStatus: String
    var activityStatus: String
    var provisionalTranscript: String
    var caption: String
    var memoryNotice: String?
    var typedText: String
    var showsTypedInput: Bool
    var errorMessage: String?
    var recoveries: [ConversationRecovery]
}

struct ConversationActions {
    var toggleListening: () -> Void
    var showTypedInput: () -> Void
    var hideTypedInput: () -> Void
    var updateTypedText: (String) -> Void
    var sendTypedText: () -> Void
    var performRecovery: (ConversationRecoveryAction) -> Void
}

enum ConversationTypedInputAction: Equatable, Sendable {
    case show
    case dismiss
    case send
}

extension ConversationActions {
    func performTypedInput(_ action: ConversationTypedInputAction) {
        switch action {
        case .show:
            showTypedInput()
        case .dismiss:
            hideTypedInput()
        case .send:
            sendTypedText()
        }
    }
}

extension ConversationPhase {
    var allowsTypedSubmission: Bool {
        switch self {
        case .idle, .listening, .clarifying, .paused, .failed:
            true
        case .preparing, .classifying, .thinking, .speaking:
            false
        }
    }
}

extension ConversationViewState {
    var allowsTypedSubmission: Bool {
        phase.allowsTypedSubmission
    }

    static let idle = Self(
        phase: .idle,
        catState: .idle,
        mouthPose: .closed,
        microphoneStatus: "マイクは待機中",
        activityStatus: "会話を始める準備ができました",
        provisionalTranscript: "",
        caption: "",
        memoryNotice: nil,
        typedText: "",
        showsTypedInput: false,
        errorMessage: nil,
        recoveries: []
    )

    static let preparing = Self(
        phase: .preparing,
        catState: .thinking,
        mouthPose: .closed,
        microphoneStatus: "会話の準備中",
        activityStatus: "準備しています",
        provisionalTranscript: "",
        caption: "",
        memoryNotice: nil,
        typedText: "",
        showsTypedInput: false,
        errorMessage: nil,
        recoveries: []
    )

    static let listening = Self(
        phase: .listening,
        catState: .listening,
        mouthPose: .closed,
        microphoneStatus: "端末上で聞き取り中",
        activityStatus: "話しかけてください",
        provisionalTranscript: "",
        caption: "",
        memoryNotice: nil,
        typedText: "",
        showsTypedInput: false,
        errorMessage: nil,
        recoveries: []
    )

    static let thinking = Self(
        phase: .thinking,
        catState: .thinking,
        mouthPose: .closed,
        microphoneStatus: "聞き取りを休止",
        activityStatus: "考えています",
        provisionalTranscript: "",
        caption: "",
        memoryNotice: nil,
        typedText: "",
        showsTypedInput: false,
        errorMessage: nil,
        recoveries: []
    )

    static let clarifying = Self(
        phase: .clarifying,
        catState: .clarifying,
        mouthPose: .small,
        microphoneStatus: "聞き返しの間は聞き取りを休止",
        activityStatus: "聞き返しています",
        provisionalTranscript: "",
        caption: "今の、ぼくに言った？",
        memoryNotice: nil,
        typedText: "",
        showsTypedInput: false,
        errorMessage: nil,
        recoveries: []
    )

    static func speaking(caption: String) -> Self {
        Self(
            phase: .speaking,
            catState: .speaking,
            mouthPose: .medium,
            microphoneStatus: "返事の間は聞き取りを休止",
            activityStatus: "話しています",
            provisionalTranscript: "",
            caption: caption,
            memoryNotice: nil,
            typedText: "",
            showsTypedInput: false,
            errorMessage: nil,
            recoveries: []
        )
    }

    static func failed(
        error: ConversationServiceError,
        message: String,
        recoveries: [ConversationRecovery]
    ) -> Self {
        Self(
            phase: .failed(error),
            catState: .failed,
            mouthPose: .closed,
            microphoneStatus: "マイクは待機中",
            activityStatus: "会話を続けられません",
            provisionalTranscript: "",
            caption: "",
            memoryNotice: nil,
            typedText: "",
            showsTypedInput: false,
            errorMessage: message,
            recoveries: recoveries
        )
    }
}
