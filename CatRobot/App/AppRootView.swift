import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let voiceSettings: SpeechVoiceSettings
    @State private var viewModel: ConversationViewModel
    @State private var coordinator: ConversationAppCoordinator

    init(
        dependencies: ConversationDependencies,
        voiceSettings: SpeechVoiceSettings? = nil,
        wakeLock: ConversationScreenWakeLock = .live()
    ) {
        self.voiceSettings = voiceSettings ?? SpeechVoiceSettings()
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
            VoiceSettingsView(settings: voiceSettings, onDone: coordinator.closeVoiceSettings)
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
