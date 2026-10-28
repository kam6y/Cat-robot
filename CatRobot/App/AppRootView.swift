import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let voiceSettings: SpeechVoiceSettings
    private let modelSettings: ConversationModelSettings
    private let usage: any ConversationUsageMetering
    private let faceTracking: FaceTrackingCoordinator?
    private let faceExpressions: any FaceExpressionControlling
    private let camera: ConversationCamera?
    private let look: any LookControlling
    private let robotSettings: RobotSettingsModel?
    private let robotLink: (any RobotLinkControlling)?
    @State private var robotStatus: RobotConnectionStatus?
    @State private var reconnectIndicator: RobotReconnectIndicator
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
        usage: (any ConversationUsageMetering)? = nil,
        robotSettings: RobotSettingsModel? = nil,
        robotLink: (any RobotLinkControlling)? = nil,
        faceTracking: FaceTrackingCoordinator? = nil,
        camera: ConversationCamera? = nil,
        onboardingSettings: OnboardingSettings? = nil
    ) {
        self.faceTracking = faceTracking
        self.camera = camera
        self.look = dependencies.look
        self.faceExpressions = dependencies.faceExpressions
        self.robotSettings = robotSettings
        self.robotLink = robotLink
        _robotStatus = State(initialValue: robotLink.map { RobotConnectionStatus(snapshot: $0.snapshot) })
        var reconnectIndicator = RobotReconnectIndicator()
        if let robotLink { reconnectIndicator.update(robotLink.snapshot) }
        _reconnectIndicator = State(initialValue: reconnectIndicator)
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
                wakeLock: wakeLock, link: robotLink, motion: dependencies.motion, settingsModel: robotSettings,
                faceTracking: faceTracking, expressions: dependencies.faceExpressions, camera: camera, look: dependencies.look,
                onboardingSettings: onboardingSettings
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
                    state: conversationState,
                    actions: coordinator.makeActions(openSettings: openSettings),
                    isOpeningVoiceSettings: coordinator.isOpeningVoiceSettings
                )
            }
        }
        .sheet(isPresented: Binding(get: { coordinator.showsVoiceSettings },
                                    set: { if !$0 { coordinator.closeVoiceSettings() } })) {
            ConversationSettingsView(voiceSettings: voiceSettings, modelSettings: modelSettings,
                                     memory: memoryViewModel, usage: usage, idleSettings: coordinator.inactivity.settings, robotSettings: robotSettings, faceTracking: faceTracking, camera: camera,
                                     onDeleteAll: { await coordinator.deleteAllMemory() },
                                     onDone: coordinator.closeVoiceSettings)

        }
        .task {
            guard let robotLink else { return }
            for await snapshot in robotLink.updates() {
                guard !Task.isCancelled else { return }
                let status = RobotConnectionStatus(snapshot: snapshot)
                if robotStatus != status { robotStatus = status }
                var updatedIndicator = reconnectIndicator
                updatedIndicator.update(snapshot)
                if reconnectIndicator != updatedIndicator { reconnectIndicator = updatedIndicator }
            }
        }
        .onAppear { updateThermalState() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            updateThermalState()
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            coordinator.scenePhaseDidChange(Self.appScenePhase(newPhase))
        }
    }

    private var conversationState: ConversationViewState {
        var state = viewModel.viewState
        state.robotStatus = robotStatus
        state.isRobotReconnecting = reconnectIndicator.isVisible
        state.isFaceTrackingPausedForHeat = faceTracking?.status == .pausedForHeat
        state.heldExpression = faceExpressions.heldExpression
        state.isLooking = look.isLooking
        state.inactivity = coordinator.inactivity.state
        return state
    }

    private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        faceTracking?.setThermalState(state)
        camera?.setThermalState(state)
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
