import Foundation

/// 本番の依存関係を 1 か所で組み立てる。
/// 構築時はネットワーク、マイク・音声の稼働、モデル生成・availability 照会、記憶データの読み書きを行わない。
/// 既存の保存先ヘルパーが Application Support ルートだけを作る場合がある（冪等・データなし）。
/// 会話ディレクトリや current.json / facts.json は保存時まで作らない。
@MainActor
struct ConversationComposition {
    let dependencies: ConversationDependencies
    let voiceSettings: SpeechVoiceSettings
    let modelSettings: ConversationModelSettings
    let longTermMemory: LongTermMemoryManager
    let usage: any ConversationUsageMetering
    let robotLink: any RobotLinkControlling
    let faceTracking: FaceTrackingCoordinator
    let camera: ConversationCamera
    let robotSettings: RobotSettingsModel

    static func live(voiceSettings: SpeechVoiceSettings = SpeechVoiceSettings(),
                     modelSettings: ConversationModelSettings = ConversationModelSettings(),
                     auth: ClaudeAuthConfiguration = .live(),
                     robotTransport: (any RobotTransport)? = nil,
                     robotClock: (any RobotClock)? = nil,
                     robotPreferences: RobotPreferences? = nil,
                     faceCaptureSource: (any FaceCaptureSource)? = nil) -> Self {
        let clock = robotClock ?? SystemRobotClock()
        let preferences = robotPreferences ?? RobotPreferences()
        let robotLink = RobotLink(transport: robotTransport ?? CoreBluetoothRobotTransport(),
                                  clock: clock, preferences: preferences)
        let motion = MotionCoordinator(link: robotLink, clock: clock, preferences: preferences,
                                       random: SystemRobotRandomSource())
        let expressions = FaceExpressionCoordinator(clock: clock)
        let camera = ConversationCamera(source: faceCaptureSource ?? AppleFaceCaptureSource(clock: clock), clock: clock)
        let look = LookCoordinator(camera: camera, clock: clock)
        let replyTurnObserver = ReplyTurnMulticaster([motion, expressions, look])
        let faceTracking = FaceTrackingCoordinator(source: camera,
            link: robotLink, clock: clock, preferences: preferences, motion: motion)
        let robotSettings = RobotSettingsModel(link: robotLink, preferences: preferences, clock: clock,
                                               onControlModeChanged: {
                                                   motion.setControlMode($0)
                                                   faceTracking.setControlMode($0)
                                               })
        let memoryStore: any ConversationMemoryStore
        let longTermStore: any LongTermMemoryStore
        if let directory = try? FileConversationMemoryStore.defaultDirectory() {
            memoryStore = FileConversationMemoryStore(directory: directory, compatibilityID: ClaudeMemoryCompatibility.current)
            longTermStore = FileLongTermMemoryStore(directory: directory)
        } else {
            memoryStore = UnavailableConversationMemoryStore()
            longTermStore = InMemoryLongTermMemoryStore()
        }
        let factory = ClaudeSessionFactory(auth: auth)
        let longTermMemory = LongTermMemoryManager(store: longTermStore, consolidate: { try await factory.consolidateFacts($0) })
        let usage = UserDefaultsUsageMeter()
        let configuration: @Sendable () async -> ConversationModelConfiguration = { await MainActor.run { modelSettings.configuration } }
        let claude = ClaudeConversationService(factory: factory, memoryStore: memoryStore, longTermMemory: longTermMemory,
                                               tools: RobotConversationToolProvider(motion: motion, expressions: expressions, look: look),
                                               configuration: configuration, usage: usage)
        let onDeviceAvailability = FoundationModelAvailabilityService()
        let fallback = OnDeviceFallbackReplyGenerator(primary: claude, secondary: FoundationModelReplyService(),
                                                      secondaryAvailability: onDeviceAvailability, usage: usage,
                                                      configuration: configuration, motion: replyTurnObserver)
        let reply = MotionReplyGenerator(base: fallback, motion: replyTurnObserver)
        let classifier = RoutedAddressClassifier(onDevice: FoundationModelAddressClassifier(),
                                                 onDeviceAvailability: onDeviceAvailability,
                                                 claude: FoundationModelAddressClassifier(client: ClaudeAddressModelClient(auth: auth)))

        let concreteRecognizer = AppleSpeechRecognizer()
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let engine = SupertonicEngine(root: resources.appendingPathComponent("Supertonic"),
                                      manifest: resources.appendingPathComponent("supertonic-manifest.json"))
        let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { voiceSettings.selected })
        let dependencies = ConversationDependencies(
            microphonePermission: MicrophonePermissionService(),
            modelAvailability: fallback,
            recognizer: concreteRecognizer,
            classifier: classifier,
            reply: reply,
            speaker: speaker,
            audioSession: AppleAudioSessionController(),
            latency: ConversationLatencyTracker.live(),
            replyTraceSink: OSReplyTraceSink(),
            motion: motion,
            faceExpressions: expressions,
            look: look,
            replyTurnObserver: replyTurnObserver,
            memory: claude,
            serviceTeardown: {
                await MainActor.run {
                    expressions.setVisible(false)
                    look.setVisible(false)
                    camera.shutdown()
                    faceTracking.setEnvironment(conversationVisible: false, sceneActive: false, mode: .background, phase: .paused)
                    motion.setControlMode(.background)
                    robotLink.suspend()
                }
                await concreteRecognizer.shutdown()
            }
        )
        return Self(dependencies: dependencies, voiceSettings: voiceSettings, modelSettings: modelSettings,
                    longTermMemory: longTermMemory, usage: usage, robotLink: robotLink, faceTracking: faceTracking, camera: camera, robotSettings: robotSettings)
    }
}
