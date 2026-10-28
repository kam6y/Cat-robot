import Foundation

enum ConversationLifecycleCheckpoint: Sendable {
    case waitingForFailureCleanup
    case preflightWillStart
    case preflightWillFinish
    case joiningExistingPreflight
}

struct ConversationDependencies: Sendable {
    let microphonePermission: any MicrophoneAuthorizing
    let modelAvailability: any ModelAvailabilityChecking
    let recognizer: any SpeechRecognizing
    let classifier: any AddressClassifying
    let reply: any ReplyGenerating
    let speaker: any SpeechSpeaking
    let audioSession: any AudioSessionControlling
    let memory: any ConversationMemoryManaging
    let replyPlaybackMode: ReplyPlaybackMode
    let motion: any RobotMotionControlling
    let faceExpressions: any FaceExpressionControlling
    let look: any LookControlling
    let replyTurnObserver: any ReplyTurnObserving
    let replyTraceSink: any ReplyTraceSink
    let latency: any ConversationLatencyTracking
    let addresseePolicy: AddresseePolicy
    let now: @Sendable () -> TimeInterval
    let clarificationDelay: @Sendable (Duration) async -> Void
    /// 「新しい会話を始めました」などの通知を消すまでの待ち。テストでは差し替える。
    let noticeDelay: @Sendable (Duration) async -> Void
    let lifecycleCheckpoint: @Sendable (ConversationLifecycleCheckpoint) async -> Void
    let serviceTeardown: @Sendable () async -> Void

    init(
        microphonePermission: any MicrophoneAuthorizing,
        modelAvailability: any ModelAvailabilityChecking,
        recognizer: any SpeechRecognizing,
        classifier: any AddressClassifying,
        reply: any ReplyGenerating,
        speaker: any SpeechSpeaking,
        audioSession: any AudioSessionControlling,
        latency: any ConversationLatencyTracking,
        replyTraceSink: any ReplyTraceSink = NoopReplyTraceSink(),
        replyPlaybackMode: ReplyPlaybackMode = .completeResponse,
        motion: any RobotMotionControlling = NoopRobotMotionController(),
        faceExpressions: any FaceExpressionControlling = NoopFaceExpressionController(),
        look: any LookControlling = NoopLookController(),
        replyTurnObserver: (any ReplyTurnObserving)? = nil,
        memory: any ConversationMemoryManaging = UnsupportedConversationMemoryManager(),
        addresseePolicy: AddresseePolicy = AddresseePolicy(),
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        clarificationDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        noticeDelay: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        lifecycleCheckpoint: @escaping @Sendable (ConversationLifecycleCheckpoint) async -> Void = { _ in },
        serviceTeardown: @escaping @Sendable () async -> Void = {}
    ) {
        self.microphonePermission = microphonePermission
        self.modelAvailability = modelAvailability
        self.recognizer = recognizer
        self.classifier = classifier
        self.reply = reply
        self.speaker = speaker
        self.audioSession = audioSession
        self.memory = memory
        self.latency = latency
        self.replyTraceSink = replyTraceSink
        self.replyPlaybackMode = replyPlaybackMode
        self.motion = motion
        self.faceExpressions = faceExpressions
        self.look = look
        self.replyTurnObserver = replyTurnObserver ?? motion
        self.addresseePolicy = addresseePolicy
        self.now = now
        self.clarificationDelay = clarificationDelay
        self.noticeDelay = noticeDelay
        self.lifecycleCheckpoint = lifecycleCheckpoint
        self.serviceTeardown = serviceTeardown
    }
}
