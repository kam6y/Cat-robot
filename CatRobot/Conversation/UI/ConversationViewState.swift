import Foundation

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

enum RobotConnectionStatus: Equatable, Sendable {
    case connected, disconnected, reconnecting
    var message: String {
        switch self { case .connected: "ハードと接続中"; case .disconnected: "ハードと未接続"; case .reconnecting: "ハードを再接続中" }
    }
}

enum ConversationStatusChip: String, CaseIterable, Sendable {
    case listening, paused, looking, sleeping, robotReconnecting, trackingPausedForHeat

    var title: String {
        switch self {
        case .listening: "聞き取り中"
        case .paused: "一時停止中・猫をタップで再開"
        case .looking: "見ています"
        case .sleeping: ConversationViewState.standbyStatus
        case .robotReconnecting: RobotConnectionStatus.reconnecting.message
        case .trackingPausedForHeat: "熱のため顔追尾を一時停止"
        }
    }

    var systemImage: String {
        switch self {
        case .listening: "mic.fill"
        case .paused: "mic.slash.fill"
        case .looking: "camera.fill"
        case .sleeping: "moon.fill"
        case .robotReconnecting: "arrow.triangle.2.circlepath"
        case .trackingPausedForHeat: "thermometer.high"
        }
    }

    var isWarning: Bool { self == .robotReconnecting || self == .trackingPausedForHeat }
    var accessibilityIdentifier: String { "statusChip.\(rawValue)" }
}

struct ConversationViewState: Equatable, Sendable {
    static let standbyStatus = "待機中・タップで起こす"
    var robotStatus: RobotConnectionStatus? = nil
    var memoryState: ConversationMemoryState = .unsupported
    var memoryNotice: String? = nil
    var heldExpression: FaceExpression? = nil
    var isLooking = false
    var inactivity: ConversationInactivityState = .awake
    var isAwaitingTapToResume = false
    var isRobotReconnecting = false
    var isFaceTrackingPausedForHeat = false
    var isSleeping: Bool { inactivity == .sleeping }
    var showsTapToResume: Bool {
        phase == .paused && isAwaitingTapToResume && !isSleeping
            && !ConversationMemoryPresentation(state: memoryState).blocksConversation
    }
    var faceOpacity: Double { showsTapToResume ? 0.5 : 1 }
    var statusChips: [ConversationStatusChip] {
        var chips: [ConversationStatusChip] = []
        if isSleeping {
            chips.append(.sleeping)
        } else {
            if phase == .listening && !ConversationMemoryPresentation(state: memoryState).blocksConversation {
                chips.append(.listening)
            }
            if showsTapToResume { chips.append(.paused) }
            if isLooking { chips.append(.looking) }
        }
        if isRobotReconnecting { chips.append(.robotReconnecting) }
        if isFaceTrackingPausedForHeat { chips.append(.trackingPausedForHeat) }
        return chips
    }
    var displaysTypedInput: Bool { showsTypedInput && !isSleeping }
    var faceExpression: FaceExpression {
        if isSleeping { return .sleeping }
        if inactivity == .sleepy, phase == .listening || phase == .idle || phase == .paused { return .sleepy }
        return isLooking ? .curious : heldExpression ?? .automatic(for: phase)
    }
    /// 完了・停止した返答を VoiceOver の「その他のコンテンツ」で読めるようにする。
    /// 配信中の断片を再通知せず、待機中は前の会話を露出しない。
    var accessibleReply: String? {
        guard !isSleeping, !caption.isEmpty else { return nil }
        switch phase {
        case .idle, .listening, .paused, .failed: return caption
        case .preparing, .classifying, .thinking, .speaking, .clarifying: return nil
        }
    }
    var displayedActivityStatus: String { isSleeping ? Self.standbyStatus : activityStatus }
    var phase: ConversationPhase
    var mouthPose: MouthPose
    var microphoneStatus: String
    var activityStatus: String
    var provisionalTranscript: String = ""
    var caption: String = ""
    var typedText: String = ""
    var showsTypedInput: Bool = false
    var errorMessage: String? = nil
    var recoveries: [ConversationRecovery] = []
}

struct ConversationActions {
    var toggleListening: () -> Void
    var showTypedInput: () -> Void
    var hideTypedInput: () -> Void
    var updateTypedText: (String) -> Void
    var sendTypedText: () -> Void
    var performRecovery: (ConversationRecoveryAction) -> Void
    var openVoiceSettings: () -> Void = {}
    var startNewConversation: () -> Void = {}
    var retryMemory: () -> Void = {}
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
        !isSleeping && phase.allowsTypedSubmission && !ConversationMemoryPresentation(state: memoryState).blocksConversation
    }

    static let idle = Self(
        phase: .idle,
        mouthPose: .closed,
        microphoneStatus: "マイクは待機中",
        activityStatus: "会話を始める準備ができました"
    )

    static let preparing = Self(
        phase: .preparing,
        mouthPose: .closed,
        microphoneStatus: "会話の準備中",
        activityStatus: "準備しています"
    )

    static let listening = Self(
        phase: .listening,
        mouthPose: .closed,
        microphoneStatus: "端末上で聞き取り中",
        activityStatus: "話しかけてください"
    )

    static let thinking = Self(
        phase: .thinking,
        mouthPose: .closed,
        microphoneStatus: "聞き取りを休止",
        activityStatus: "考えています"
    )

    static let clarifying = Self(
        phase: .clarifying,
        mouthPose: .small,
        microphoneStatus: "聞き返しの間は聞き取りを休止",
        activityStatus: "聞き返しています",
        caption: "今の、ぼくに言った？"
    )

    static func speaking(caption: String) -> Self {
        Self(
            phase: .speaking,
            mouthPose: .medium,
            microphoneStatus: "返事の間は聞き取りを休止",
            activityStatus: "話しています",
            caption: caption
        )
    }

    static func failed(
        error: ConversationServiceError,
        message: String,
        recoveries: [ConversationRecovery]
    ) -> Self {
        var state = Self.idle
        state.presentFailure(error: error, message: message, recoveries: recoveries)
        return state
    }

    mutating func presentFailure(
        error: ConversationServiceError,
        message: String,
        recoveries: [ConversationRecovery]
    ) {
        phase = .failed(error)
        mouthPose = .closed
        microphoneStatus = "マイクは待機中"
        activityStatus = "会話を続けられません"
        provisionalTranscript = ""
        errorMessage = message
        self.recoveries = recoveries
    }
}
