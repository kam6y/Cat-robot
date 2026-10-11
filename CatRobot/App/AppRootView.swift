import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let voiceSettings: SpeechVoiceSettings
    private let modelSettings: ConversationModelSettings
    private let usage: any ConversationUsageMetering
    @State private var viewModel: ConversationViewModel
    @State private var coordinator: ConversationAppCoordinator
    /// シートを開くたびに作り直すと一覧が空に戻るので、ルートで 1 つ持つ。
    @State private var memoryViewModel: LongTermMemoryViewModel

    init(
        dependencies: ConversationDependencies,
        voiceSettings: SpeechVoiceSettings? = nil,
        wakeLock: ConversationScreenWakeLock = .live(),
        modelSettings: ConversationModelSettings? = nil,
        memory: LongTermMemoryManager? = nil,
        usage: (any ConversationUsageMetering)? = nil
    ) {
        self.voiceSettings = voiceSettings ?? SpeechVoiceSettings()
        self.modelSettings = modelSettings ?? ConversationModelSettings()
        self.usage = usage ?? UserDefaultsUsageMeter()
        _memoryViewModel = State(initialValue: LongTermMemoryViewModel(
            memory: memory ?? LongTermMemoryManager(store: InMemoryLongTermMemoryStore())))
        let viewModel = ConversationViewModel(dependencies: dependencies)
        _viewModel = State(initialValue: viewModel)
        _coordinator = State(
            initialValue: ConversationAppCoordinator(
                viewModel: viewModel,
                wakeLock: wakeLock
            )
        )
    }

    var body: some View {
        Group {
            switch coordinator.destination {
            case .onboarding:
                OnboardingView(onStart: coordinator.beginConversation)
            case .conversation:
                ConversationView(
                    state: viewModel.viewState,
                    actions: coordinator.makeActions(openSettings: openSettings),
                    isOpeningVoiceSettings: coordinator.isOpeningVoiceSettings
                )
            }
        }
        .sheet(isPresented: Binding(get: { coordinator.showsVoiceSettings },
                                    set: { if !$0 { coordinator.closeVoiceSettings() } })) {
            ConversationSettingsView(voiceSettings: voiceSettings, modelSettings: modelSettings,
                                     memory: memoryViewModel, usage: usage, onDone: coordinator.closeVoiceSettings)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            coordinator.scenePhaseDidChange(Self.appScenePhase(newPhase))
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private static func appScenePhase(_ phase: ScenePhase) -> ConversationAppScenePhase {
        switch phase {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .inactive
        }
    }
}
