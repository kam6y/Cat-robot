import Foundation
import Observation

enum ConversationAppDestination: Equatable, Sendable {
    case onboarding
    case conversation
}

enum ConversationAppScenePhase: Equatable, Sendable {
    case active
    case inactive
    case background
}

@MainActor
@Observable
final class ConversationAppCoordinator {
    private(set) var showsVoiceSettings = false
    private(set) var isOpeningVoiceSettings = false
    private var isVoiceSettingsClosed: Bool { !showsVoiceSettings && !isOpeningVoiceSettings }
    @ObservationIgnored private var voiceSettingsTask: Task<Void, Never>?
    private(set) var destination: ConversationAppDestination = .onboarding

    @ObservationIgnored private let viewModel: ConversationViewModel
    @ObservationIgnored private let wakeLock: ConversationScreenWakeLock
    @ObservationIgnored private var scenePhase: ConversationAppScenePhase = .active
    @ObservationIgnored private var wakeLockToken: ConversationScreenWakeLock.Token?
    @ObservationIgnored private var startIntentCounter: UInt64 = 0
    @ObservationIgnored private var activeStartIntentID: UInt64?
    @ObservationIgnored private var startTaskID: UInt64?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var actionCounter: UInt64 = 0
    @ObservationIgnored private var actionSceneGeneration: UInt64 = 0
    @ObservationIgnored private var actionTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var didForwardPauseSinceActive = false
    @ObservationIgnored private var deferredPermissionPrompt = false
    @ObservationIgnored private let beforeActionOperation: @MainActor @Sendable () async -> Void

    init(
        viewModel: ConversationViewModel,
        wakeLock: ConversationScreenWakeLock,
        beforeActionOperation: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.viewModel = viewModel
        self.wakeLock = wakeLock
        self.beforeActionOperation = beforeActionOperation
    }

    func beginConversation() {
        guard destination == .onboarding, isVoiceSettingsClosed else { return }
        destination = .conversation
        acquireWakeLockIfNeeded()

        startIntentCounter &+= 1
        let intentID = startIntentCounter
        activeStartIntentID = intentID
        startTaskID = intentID
        let task = Task { @MainActor [weak self, viewModel] in
            await viewModel.startConversation()
            guard let self else { return }
            if self.activeStartIntentID == intentID {
                self.activeStartIntentID = nil
            }
            if self.startTaskID == intentID {
                self.startTaskID = nil
                self.startTask = nil
            }
        }
        startTask = task
    }

    func scenePhaseDidChange(_ newPhase: ConversationAppScenePhase) {
        scenePhase = newPhase

        switch newPhase {
        case .active:
            if deferredPermissionPrompt {
                viewModel.releaseMicrophonePermissionCompletion()
            }
            deferredPermissionPrompt = false
            didForwardPauseSinceActive = false
            acquireWakeLockIfNeeded()
        case .inactive:
            invalidateActionTasksForSceneInactivity()
            releaseWakeLockIfNeeded()
            if activeStartIntentID != nil,
               viewModel.isAwaitingMicrophonePermission {
                deferredPermissionPrompt = true
                viewModel.deferMicrophonePermissionCompletion()
                return
            }
            forwardPauseIfNeeded()
        case .background:
            invalidateActionTasksForSceneInactivity()
            deferredPermissionPrompt = false
            releaseWakeLockIfNeeded()
            forwardPauseIfNeeded()
        }
    }

    func openVoiceSettings() {
        guard scenePhase == .active, isVoiceSettingsClosed else { return }
        isOpeningVoiceSettings = true
        invalidateActionTasksForSceneInactivity()
        let generation = actionSceneGeneration
        activeStartIntentID = nil
        deferredPermissionPrompt = false
        startTask?.cancel()
        viewModel.invalidateForSceneInactivity()
        releaseWakeLockIfNeeded()
        voiceSettingsTask = Task { @MainActor [weak self, viewModel] in
            await viewModel.sceneBecameInactive()
            guard let self else { return }
            self.voiceSettingsTask = nil
            guard self.scenePhase == .active, self.actionSceneGeneration == generation else {
                self.isOpeningVoiceSettings = false
                return
            }
            self.isOpeningVoiceSettings = false
            self.showsVoiceSettings = true
        }
    }

    func closeVoiceSettings() {
        showsVoiceSettings = false
        acquireWakeLockIfNeeded()
    }

    func makeActions(openSettings: @escaping @MainActor () -> Void) -> ConversationActions {
        ConversationActions(
            toggleListening: { [weak self] in
                self?.launchAction { [weak self] in
                    await self?.viewModel.toggleListening()
                }
            },
            showTypedInput: { [weak self] in
                self?.viewModel.showTypedInput()
            },
            hideTypedInput: { [weak self] in
                self?.viewModel.hideTypedInput()
            },
            updateTypedText: { [weak self] text in
                self?.viewModel.updateTypedText(text)
            },
            sendTypedText: { [weak self] in
                guard let self else { return }
                let submitted = self.viewModel.viewState.typedText
                self.launchAction { [weak self] in
                    await self?.viewModel.submitTypedText(submitted)
                }
            },
            performRecovery: { [weak self] action in
                guard let self else { return }
                switch action {
                case .retry:
                    self.launchAction { [weak self] in
                        await self?.viewModel.retryRecovery()
                    }
                case .openSettings:
                    openSettings()
                case .showTypedInput:
                    self.viewModel.showTypedInput()
                }
            },
            openVoiceSettings: { [weak self] in self?.openVoiceSettings() },
            requestForget: { [weak self] in self?.viewModel.requestForgetConversation() },
            cancelForget: { [weak self] in self?.viewModel.cancelForgetConversation() },
            confirmForget: { [weak self] in
                // Capture the user's decision before SwiftUI dismisses the dialog.
                guard let self, self.viewModel.viewState.showsForgetConfirmation else { return }
                self.launchAction { [weak self] in
                    await self?.viewModel.confirmForgetConversation(confirmationAccepted: true)
                }
            },
            retryMemory: { [weak self] in
                self?.launchAction { [weak self] in await self?.viewModel.retryMemoryOperation() }
            }
        )
    }

    func waitForOperations() async {
        while true {
            let tasks = [startTask, pauseTask, voiceSettingsTask].compactMap { $0 }
                + Array(actionTasks.values)
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    private func forwardPauseIfNeeded() {
        guard destination == .conversation, !didForwardPauseSinceActive else { return }
        didForwardPauseSinceActive = true
        deferredPermissionPrompt = false
        activeStartIntentID = nil
        startTask?.cancel()
        viewModel.invalidateForSceneInactivity()

        let task = Task { @MainActor [weak self, viewModel] in
            await viewModel.sceneBecameInactive()
            self?.pauseTask = nil
        }
        pauseTask = task
    }

    private func launchAction(_ operation: @escaping @MainActor () async -> Void) {
        guard scenePhase == .active, isVoiceSettingsClosed else { return }
        actionCounter &+= 1
        let actionID = actionCounter
        let sceneGeneration = actionSceneGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beforeActionOperation()
            guard !Task.isCancelled,
                  self.scenePhase == .active, self.isVoiceSettingsClosed,
                  self.actionSceneGeneration == sceneGeneration else {
                self.actionTasks[actionID] = nil
                return
            }
            await operation()
            self.actionTasks[actionID] = nil
        }
        actionTasks[actionID] = task
    }

    private func invalidateActionTasksForSceneInactivity() {
        actionSceneGeneration &+= 1
        for task in actionTasks.values {
            task.cancel()
        }
    }

    private func acquireWakeLockIfNeeded() {
        guard destination == .conversation,
              scenePhase == .active, isVoiceSettingsClosed,
              wakeLockToken == nil else { return }
        wakeLockToken = wakeLock.acquire()
    }

    private func releaseWakeLockIfNeeded() {
        guard let wakeLockToken else { return }
        self.wakeLockToken = nil
        wakeLock.release(wakeLockToken)
    }
}
