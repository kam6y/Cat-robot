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
    let latency: any ConversationLatencyTracking
    let addresseePolicy: AddresseePolicy
    let now: @Sendable () -> TimeInterval
    let clarificationDelay: @Sendable (Duration) async -> Void
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
        addresseePolicy: AddresseePolicy = AddresseePolicy(),
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        clarificationDelay: @escaping @Sendable (Duration) async -> Void = { duration in
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
        self.latency = latency
        self.addresseePolicy = addresseePolicy
        self.now = now
        self.clarificationDelay = clarificationDelay
        self.lifecycleCheckpoint = lifecycleCheckpoint
        self.serviceTeardown = serviceTeardown
    }
}

extension ConversationDependencies {
    @MainActor
    static func live() -> Self {
        let reply = FoundationModelReplyService()
        let concreteRecognizer = AppleSpeechRecognizer()
        let recognizer: any SpeechRecognizing = concreteRecognizer
        let speaker = AppleSpeechSynthesizer()
        let audioSession = AppleAudioSessionController()
        let serviceTeardown: @Sendable () async -> Void = {
            await concreteRecognizer.shutdown()
        }

        return Self(
            microphonePermission: MicrophonePermissionService(),
            modelAvailability: FoundationModelAvailabilityService(),
            recognizer: recognizer,
            classifier: FoundationModelAddressClassifier(),
            reply: reply,
            speaker: speaker,
            audioSession: audioSession,
            latency: ConversationLatencyTracker.live(),
            serviceTeardown: serviceTeardown
        )
    }
}
