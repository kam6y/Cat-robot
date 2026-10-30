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
    let inactivity: ConversationInactivity
    private var isSleeping: Bool { inactivity.state == .sleeping }
    private var isConversationForeground: Bool {
        destination == .conversation && scenePhase == .active && isVoiceSettingsClosed
    }
    private var canRunConversation: Bool { isConversationForeground && !isSleeping }

    @ObservationIgnored private let viewModel: ConversationViewModel
    @ObservationIgnored private let onboardingSettings: OnboardingSettings?
    @ObservationIgnored private var needsInitialConversationStart: Bool
    @ObservationIgnored private let wakeLock: ConversationScreenWakeLock
    @ObservationIgnored private let link: (any RobotLinkControlling)?
    @ObservationIgnored private let motion: any RobotMotionControlling
    @ObservationIgnored private let faceTracking: FaceTrackingCoordinator?
    @ObservationIgnored private let expressions: any FaceExpressionControlling
    @ObservationIgnored private let camera: ConversationCamera?
    @ObservationIgnored private let look: any LookControlling
    @ObservationIgnored private var hasStartedConversation = false
    @ObservationIgnored private let settingsModel: RobotSettingsModel?
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
        link: (any RobotLinkControlling)? = nil,
        motion: any RobotMotionControlling = NoopRobotMotionController(),
        settingsModel: RobotSettingsModel? = nil,
        faceTracking: FaceTrackingCoordinator? = nil,
        expressions: any FaceExpressionControlling = NoopFaceExpressionController(),
        camera: ConversationCamera? = nil,
        look: any LookControlling = NoopLookController(),
        onboardingSettings: OnboardingSettings? = nil,
        idleSettings: ConversationIdleSettings? = nil,
        idleClock: any RobotClock = ConversationIdleClock(),
        beforeActionOperation: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onboardingSettings = onboardingSettings
        needsInitialConversationStart = onboardingSettings?.isCompleted == true
        destination = needsInitialConversationStart ? .conversation : .onboarding
        self.wakeLock = wakeLock
        self.link = link
        self.motion = motion
        self.settingsModel = settingsModel
        self.faceTracking = faceTracking
        self.expressions = expressions
        self.camera = camera
        self.look = look
        self.beforeActionOperation = beforeActionOperation
        inactivity = ConversationInactivity(settings: idleSettings ?? ConversationIdleSettings(), clock: idleClock)
        viewModel.onAddressedActivity = { [weak self] in self?.inactivity.recordActivity() }
        viewModel.onPhaseChange = { [weak self] phase in self?.conversationPhaseDidChange(phase) }
        viewModel.onPendingSpeechChange = { [weak self] in
            guard let self else { return }
            if self.viewModel.hasPendingSpeech { self.motion.cancelIdleFaceMotion() }
            self.updateInactivity()
        }
        inactivity.onStateChange = { [weak self] in
            guard let self, self.isSleeping else { return }
            self.enterSleeping()
        }
        motion.setIdleFaceDriven(true)
    }

    func conversationPhaseDidChange(_ phase: ConversationPhase) {
        updateFaceEnvironment(phase: phase)
        updateInactivity(phase: phase)
    }

    private func updateInactivity(phase: ConversationPhase? = nil) {
        inactivity.setMonitoring(isConversationForeground, phase: phase ?? viewModel.viewState.phase,
            hasPendingSpeech: viewModel.hasPendingSpeech)
    }

    private func enterSleeping() {
        viewModel.clearCaptionForStandby()
        invalidateActionTasksForSceneInactivity()
        pauseConversationForScene()
        updateRobotScene(scenePhase)
    }

    private func wakeFromSleeping() {
        launchAction(allowWhileSleeping: true) { [weak self] in
            guard let self else { return }
            // A tap can arrive while recognizer/audio shutdown is still suspended.
            await self.pauseTask?.value
            guard !Task.isCancelled, self.scenePhase == .active, self.isVoiceSettingsClosed,
                  self.isSleeping else { return }
            self.inactivity.wake()
            self.updateRobotScene(self.scenePhase)
            await self.viewModel.startConversation()
        }
    }

    /// The mode while the scene is active: conversation unless a settings sheet owns the robot.
    private var activeControlMode: RobotControlMode {
        isVoiceSettingsClosed ? (isSleeping ? .inactive : .conversation) : settingsModel?.effectiveControlMode ?? .settings
    }

    private func updateFaceEnvironment(phase: ConversationPhase? = nil) {
        let visible = canRunConversation
        expressions.setVisible(visible)
        look.setVisible(visible)
        let mode: RobotControlMode
        switch scenePhase {
        case .active: mode = activeControlMode
        case .inactive: mode = .inactive
        case .background: mode = .background
        }
        camera?.setEnvironment(conversationVisible: visible, sceneActive: scenePhase == .active,
            mode: mode, phase: phase ?? viewModel.viewState.phase)
        faceTracking?.setEnvironment(conversationVisible: destination == .conversation && hasStartedConversation && isVoiceSettingsClosed && !isSleeping,
            sceneActive: scenePhase == .active, mode: mode, phase: phase ?? viewModel.viewState.phase)
    }

    /// Microphone/model/audio preflight has already finished. Camera rejection never fails chat.
    private func completeConversationStartIfEligible() async {
        guard !Task.isCancelled, canRunConversation,
              viewModel.viewState.phase.permitsFaceTracking else { return }
        hasStartedConversation = true
        updateInactivity()
        guard !isSleeping else { return }
        updateFaceEnvironment()
        await faceTracking?.requestPermissionForConversation()
        updateFaceEnvironment()
        // Returning from background/settings can precede the OS permission result. The old
        // start was cancelled, so the foreground owner must launch its replacement now.
        if Task.isCancelled { resumeListeningIfNeeded() }
    }

    func beginConversation() {
        guard destination == .onboarding, isVoiceSettingsClosed else { return }
        onboardingSettings?.markCompleted()
        destination = .conversation
        inactivity.recordActivity()
        updateRobotScene(scenePhase)
        acquireWakeLockIfNeeded()
        launchStart()
    }

    /// 会話画面が前面にある間は聞き取る（要件 FR-RUN-4 の前倒し）。前面復帰、設定を閉じた後、新しい会話の後に呼ぶ。
    /// 進行中の開始（マイク許可の待ちなど）があるときは重ねない。猫のタップによる一時停止もこれらの出来事で解ける。
    private func resumeListeningIfNeeded() {
        updateInactivity()
        guard canRunConversation,
              activeStartIntentID == nil, faceTracking?.isAwaitingPermission != true else { return }
        launchStart()
    }

    private func launchStart() {
        guard !isSleeping else { return }
        startIntentCounter &+= 1
        let intentID = startIntentCounter
        activeStartIntentID = intentID
        startTaskID = intentID
        let task = Task { @MainActor [weak self, viewModel] in
            await viewModel.startConversation()
            guard let self else { return }
            if self.activeStartIntentID == intentID { await self.completeConversationStartIfEligible() }
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
        if newPhase == .active, needsInitialConversationStart {
            needsInitialConversationStart = false
            inactivity.recordActivity()
        }
        updateInactivity()
        updateRobotScene(newPhase)

        switch newPhase {
        case .active:
            if deferredPermissionPrompt {
                viewModel.releaseMicrophonePermissionCompletion()
            }
            deferredPermissionPrompt = false
            didForwardPauseSinceActive = false
            acquireWakeLockIfNeeded()
            resumeListeningIfNeeded()
        case .inactive:
            invalidateActionTasksForSceneInactivity()
            releaseWakeLockIfNeeded()
            if activeStartIntentID != nil,
               viewModel.isAwaitingMicrophonePermission {
                deferredPermissionPrompt = true
                viewModel.deferMicrophonePermissionCompletion()
                return
            }
            if faceTracking?.isAwaitingPermission == true { return }
            forwardPauseIfNeeded()
        case .background:
            invalidateActionTasksForSceneInactivity()
            deferredPermissionPrompt = false
            releaseWakeLockIfNeeded()
            forwardPauseIfNeeded()
        }
    }

    private func updateRobotScene(_ phase: ConversationAppScenePhase) {
        switch phase {
        case .active:
            settingsModel?.setApplicationMode(isSleeping && isVoiceSettingsClosed ? .inactive : nil)
            motion.setControlMode(activeControlMode)
            link?.setApplicationActive(true)
            if destination == .conversation { link?.resume() }
        case .inactive:
            settingsModel?.setApplicationMode(.inactive)
            motion.setControlMode(.inactive)
            link?.setApplicationActive(false)
        case .background:
            settingsModel?.setApplicationMode(.background)
            motion.setControlMode(.background)
            link?.setApplicationActive(false)
            link?.suspend()
        }
        updateFaceEnvironment()
    }

    func openVoiceSettings() {
        guard scenePhase == .active, isVoiceSettingsClosed else { return }
        isOpeningVoiceSettings = true
        updateInactivity()
        settingsModel?.setApplicationMode(nil)
        settingsModel?.settingsDidOpen()
        motion.setControlMode(.settings)
        updateFaceEnvironment()
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
                // 開く途中で場面が変わりシートを出さない。前面に戻っていれば、ここで聞き取りを再開する。
                self.isOpeningVoiceSettings = false
                self.settingsModel?.settingsDidClose()
                self.updateRobotScene(self.scenePhase)
                self.acquireWakeLockIfNeeded()
                self.resumeListeningIfNeeded()
                return
            }
            self.isOpeningVoiceSettings = false
            self.showsVoiceSettings = true
        }
    }

    func closeVoiceSettings() {
        guard !isOpeningVoiceSettings, settingsModel?.calibration == nil else { return }
        showsVoiceSettings = false
        updateInactivity()
        settingsModel?.settingsDidClose()
        updateRobotScene(scenePhase)
        acquireWakeLockIfNeeded()
        resumeListeningIfNeeded()
    }

    /// 設定の「すべて削除」。シートが開いたまま実行し、覚えていることと会話の要約を消す。聞き取りはシートを閉じたときに再開する。
    func deleteAllMemory() async {
        actionCounter &+= 1
        let actionID = actionCounter
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.forgetConversation()
            self.actionTasks[actionID] = nil
            // 削除中にシートを閉じていると、閉じた時点の再開は削除中のため見送られている。完了後にもう一度評価する。
            // 削除に失敗した場合は viewModel 側が開始を拒むので、ここで再開しても聞き取りは始まらない。
            self.resumeListeningIfNeeded()
        }
        actionTasks[actionID] = task
        await task.value
    }

    func makeActions(openSettings: @escaping @MainActor () -> Void) -> ConversationActions {
        ConversationActions(
            toggleListening: { [weak self] in
                guard let self else { return }
                if self.isSleeping { self.wakeFromSleeping(); return }
                self.launchAction { [weak self] in
                    guard let self else { return }
                    self.inactivity.recordActivity()
                    await self.viewModel.toggleListening()
                }
            },
            showTypedInput: { [weak self] in
                guard let self, !self.isSleeping else { return }
                self.viewModel.showTypedInput()
            },
            hideTypedInput: { [weak self] in
                self?.viewModel.hideTypedInput()
            },
            updateTypedText: { [weak self] text in
                guard let self, !self.isSleeping else { return }
                self.viewModel.updateTypedText(text)
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
                    guard !self.isSleeping else { return }
                    self.viewModel.showTypedInput()
                }
            },
            openVoiceSettings: { [weak self] in self?.openVoiceSettings() },
            startNewConversation: { [weak self] in
                self?.launchAction { [weak self] in
                    guard let self else { return }
                    self.hasStartedConversation = false
                    self.inactivity.recordActivity()
                    self.updateInactivity()
                    self.updateFaceEnvironment()
                    self.faceTracking?.resetConversation()
                    await self.viewModel.startNewConversation()
                    self.resumeListeningIfNeeded()
                }
            },
            retryMemory: { [weak self] in
                self?.launchAction(allowWhileSleeping: true) { [weak self] in
                    guard let self else { return }
                    // 削除失敗からの復旧は会話を止めて行うので、成功したら再開する。
                    // 保存の再試行は聞き取りに触れないので、猫のタップによる一時停止もそのまま残す。
                    let recoversFromForgetFailure: Bool
                    if case .forgetFailed = self.viewModel.viewState.memoryState {
                        recoversFromForgetFailure = true
                    } else {
                        recoversFromForgetFailure = false
                    }
                    await self.viewModel.retryMemoryOperation()
                    if recoversFromForgetFailure { self.resumeListeningIfNeeded() }
                }
            },
            idleFaceMotion: { [weak self] cue in
                guard let self, self.canRunConversation,
                      self.viewModel.viewState.allowsIdleFaceLife, !self.viewModel.hasPendingSpeech,
                      !self.look.isLooking, self.expressions.heldExpression == nil else { return }
                switch cue.kind {
                case .idle: self.motion.requestIdleFaceMotion(yaw: cue.yaw, pitch: cue.pitch)
                case .yawn: self.motion.requestYawnMotion(pitch: cue.pitch)
                }
            },
            cancelIdleFaceMotion: { [weak self] in self?.motion.cancelIdleFaceMotion() }
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
        pauseConversationForScene()
    }

    private func pauseConversationForScene() {
        activeStartIntentID = nil
        startTask?.cancel()
        viewModel.invalidateForSceneInactivity()

        let task = Task { @MainActor [weak self, viewModel] in
            await viewModel.sceneBecameInactive()
            self?.pauseTask = nil
        }
        pauseTask = task
    }

    private func launchAction(allowWhileSleeping: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        guard scenePhase == .active, isVoiceSettingsClosed, allowWhileSleeping || !isSleeping else { return }
        actionCounter &+= 1
        let actionID = actionCounter
        let sceneGeneration = actionSceneGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beforeActionOperation()
            guard !Task.isCancelled,
                  self.scenePhase == .active, self.isVoiceSettingsClosed,
                  allowWhileSleeping || !self.isSleeping,
                  self.actionSceneGeneration == sceneGeneration else {
                self.actionTasks[actionID] = nil
                return
            }
            await operation()
            await self.completeConversationStartIfEligible()
            self.updateFaceEnvironment()
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
        guard isConversationForeground, wakeLockToken == nil else { return }
        wakeLockToken = wakeLock.acquire()
    }

    private func releaseWakeLockIfNeeded() {
        guard let wakeLockToken else { return }
        self.wakeLockToken = nil
        wakeLock.release(wakeLockToken)
    }
}
