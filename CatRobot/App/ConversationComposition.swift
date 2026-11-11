import Foundation

/// 本番の依存関係を 1 か所で組み立てる。通常の返事・会話の記憶・履歴は 1 つの Hermes の会話が受け持ち、
/// 声の宛先判定だけを Claude Haiku に残す（返事をほかのモデルで代わりに作ることはしない）。
/// 構築時はネットワーク、マイク・音声の稼働、モデル生成・availability 照会、Keychain と会話の記録の読み書きを行わない。
@MainActor
struct ConversationComposition {
    let dependencies: ConversationDependencies
    let voiceSettings: SpeechVoiceSettings
    let connectionSettings: HermesConnectionSettings
    /// 設定の「会話の履歴」が読む会話（返事・記憶と同じ Hermes の session）。
    let history: any ConversationTranscriptReading
    let robotLink: any RobotLinkControlling
    let faceTracking: FaceTrackingCoordinator
    let camera: ConversationCamera
    let robotSettings: RobotSettingsModel

    static func live(voiceSettings: SpeechVoiceSettings = SpeechVoiceSettings(),
                     connectionSettings: HermesConnectionSettings = HermesConnectionSettings(),
                     hermesTransport: any HermesTransport = HermesURLSessionTransport(),
                     sessionRecords: any HermesSessionRecordStore = UserDefaultsHermesSessionRecordStore(),
                     auth: ClaudeAuthConfiguration = .live(),
                     robotTransport: (any RobotTransport)? = nil,
                     robotClock: (any RobotClock)? = nil,
                     robotPreferences: RobotPreferences? = nil,
                     faceCaptureSource: (any FaceCaptureSource)? = nil) -> Self {
        let clock = robotClock ?? SystemRobotClock()
        let preferences = robotPreferences ?? RobotPreferences()
        let robotLink = RobotLink(transport: robotTransport ?? CoreBluetoothRobotTransport(),
                                  clock: clock, preferences: preferences)
        let motion = MotionCoordinator(link: robotLink, clock: clock, preferences: preferences)
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
        // 接続先とキーはターンごとに設定から読む（保存した次のターンから効く）。
        let hermes = HermesConversationService(connection: { await connectionSettings.connection() },
                                               transport: hermesTransport, records: sessionRecords)
        let reply = makeReplyGenerator(base: hermes, motion: replyTurnObserver)
        // 声の宛先判定は補助の経路として Claude Haiku のまま。直近の会話は返事と同じ Hermes の会話から読む。
        let classifier = makeAddressClassifier(claudeClient: ClaudeAddressModelClient(auth: auth), history: hermes)

        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let smartTurn = SmartTurnService(root: resources.appendingPathComponent("SmartTurn"))
        let concreteRecognizer = AppleSpeechRecognizer(audioTurnService: smartTurn)
        let engine = SupertonicEngine(root: resources.appendingPathComponent("Supertonic"),
                                      manifest: resources.appendingPathComponent("supertonic-manifest.json"))
        let speaker = SupertonicSentenceSpeaker(engine: engine, voice: { voiceSettings.selected })
        let dependencies = ConversationDependencies(
            microphonePermission: MicrophonePermissionService(),
            modelAvailability: hermes,
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
            memory: hermes,
            isFacingScreen: { camera.hasFreshFacingFace(yawCorrection: preferences.trackingYawCorrection) },
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
        return Self(dependencies: dependencies, voiceSettings: voiceSettings, connectionSettings: connectionSettings, history: hermes,
                    robotLink: robotLink, faceTracking: faceTracking, camera: camera, robotSettings: robotSettings)
    }

    /// 返答の組み立て。首の予約（MotionReplyGenerator）→ 返事を作る service の順。
    static func makeReplyGenerator(base: any ReplyGenerating,
                                   motion: any ReplyTurnObserving) -> MotionReplyGenerator {
        MotionReplyGenerator(base: base, motion: motion)
    }

    /// 宛先判定の組み立て。直近の会話を添える decorator → Claude の分類器。liveと試験で同じ経路を使う。
    static func makeAddressClassifier(claudeClient: any AddressModelClient,
                                      history: any ConversationHistoryReading) -> ContextualAddressClassifier {
        ContextualAddressClassifier(base: ClaudeAddressClassifier(client: claudeClient), history: history)
    }
}
