import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private let voiceSettings: SpeechVoiceSettings
    private let connectionSettings: HermesConnectionSettings?
    private let history: (any ConversationTranscriptReading)?
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

    init(composition: ConversationComposition, onboardingSettings: OnboardingSettings? = nil) {
        self.init(dependencies: composition.dependencies, voiceSettings: composition.voiceSettings,
                  connectionSettings: composition.connectionSettings, history: composition.history,
                  robotSettings: composition.robotSettings, robotLink: composition.robotLink,
                  faceTracking: composition.faceTracking, camera: composition.camera, onboardingSettings: onboardingSettings)
    }

    init(
        dependencies: ConversationDependencies,
        voiceSettings: SpeechVoiceSettings? = nil,
        wakeLock: ConversationScreenWakeLock = .live(),
        connectionSettings: HermesConnectionSettings? = nil,
        history: (any ConversationTranscriptReading)? = nil,
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
        self.connectionSettings = connectionSettings
        self.history = history
        let viewModel = ConversationViewModel(dependencies: dependencies)
        _viewModel = State(initialValue: viewModel)
        _coordinator = State(
            initialValue: ConversationAppCoordinator(
                viewModel: viewModel,
                wakeLock: wakeLock, link: robotLink, motion: dependencies.motion, settingsModel: robotSettings,
                faceTracking: faceTracking, expressions: dependencies.faceExpressions, camera: camera, look: dependencies.look,
                // 会話と同じ認識器と音声の session を使う。coordinator が会話と重ならない間だけ使えるようにする。
                wakePhraseRecorder: WakePhraseRecorder(recognizer: dependencies.recognizer, audioSession: dependencies.audioSession,
                                                       permission: dependencies.microphonePermission),
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
                    isOpeningVoiceSettings: coordinator.isOpeningVoiceSettings,
                    isFaceLifeVisible: !coordinator.showsVoiceSettings
                )
            }
        }
        // 横向きでも「キャンセル」が見える alert を使う。確定・取消は各ボタンで一度だけ処理する。
        .alert("新しい会話を始めますか？",
               isPresented: Binding(get: { coordinator.confirmsNewConversation }, set: { _ in })) {
            Button("新しい会話を始める", action: coordinator.confirmNewConversation)
                .accessibilityIdentifier("confirmNewConversation")
            Button("キャンセル", role: .cancel, action: coordinator.cancelNewConversation)
        } message: {
            Text("切り替えた後、アプリの履歴には新しい会話だけが表示されます。これまでの会話は Hermes に残ります。")
        }
        .sheet(isPresented: Binding(get: { coordinator.showsVoiceSettings },
                                    set: { if !$0 { coordinator.closeVoiceSettings() } })) {
            switch coordinator.sheet {
            case .settings(let category):
                ConversationSettingsView(voiceSettings: voiceSettings, connectionSettings: connectionSettings,
                                         idleSettings: coordinator.inactivity.settings, robotSettings: robotSettings, faceTracking: faceTracking, camera: camera,
                                         wakePhraseRecorder: coordinator.wakePhraseRecorder, initialCategory: category,
                                         onDone: coordinator.closeVoiceSettings)
            case .history:
                ConversationHistorySheet(history: history, onDone: coordinator.closeVoiceSettings)
            }
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
        state.activityGeneration = coordinator.inactivity.activityGeneration
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

/// 会話メニューの「会話の履歴」。設定とは別の全幅の画面で、「完了」で会話に戻る。
struct ConversationHistorySheet: View {
    let history: (any ConversationTranscriptReading)?
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let history {
                    ConversationHistoryPane(reader: history)
                } else {
                    ContentUnavailableView("履歴を表示できません", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("会話の履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", action: onDone)
                        .accessibilityIdentifier("historyDoneButton")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
