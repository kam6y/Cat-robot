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

    static func live(voiceSettings: SpeechVoiceSettings = SpeechVoiceSettings(),
                     modelSettings: ConversationModelSettings = ConversationModelSettings(),
                     auth: ClaudeAuthConfiguration = .live()) -> Self {
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
                                               tools: RememberToolProvider(),
                                               configuration: configuration, usage: usage)
        let onDeviceAvailability = FoundationModelAvailabilityService()
        let reply = OnDeviceFallbackReplyGenerator(primary: claude, secondary: FoundationModelReplyService(),
                                                   secondaryAvailability: onDeviceAvailability, usage: usage,
                                                   configuration: configuration)
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
            modelAvailability: reply,
            recognizer: concreteRecognizer,
            classifier: classifier,
            reply: reply,
            speaker: speaker,
            audioSession: AppleAudioSessionController(),
            latency: ConversationLatencyTracker.live(),
            replyTraceSink: OSReplyTraceSink(),
            replyPlaybackMode: .sentencePrefetch,
            memory: claude,
            serviceTeardown: { await concreteRecognizer.shutdown() }
        )
        return Self(dependencies: dependencies, voiceSettings: voiceSettings, modelSettings: modelSettings,
                    longTermMemory: longTermMemory, usage: usage)
    }
}
