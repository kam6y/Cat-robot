import Foundation
import Observation

enum RobotControlMode: Equatable, Sendable {
    case conversation, settings, calibration(UUID), inactive, background
}

enum RobotCalibrationExit { case save, restore }

@MainActor
@Observable
final class RobotSettingsModel {
    private(set) var snapshot: RobotLinkSnapshot
    private(set) var calibration: RobotCalibrationSession?
    private(set) var calibrationExitWarning: String?
    let preferences: RobotPreferences
    @ObservationIgnored private let link: any RobotLinkControlling
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private let onControlModeChanged: @MainActor @Sendable (RobotControlMode) -> Void
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var opening: Task<Void, Never>?
    private var settingsOpen = false
    private var calibrationID: UUID?
    private var applicationMode: RobotControlMode?

    init(link: any RobotLinkControlling, preferences: RobotPreferences, clock: any RobotClock,
         onControlModeChanged: @escaping @MainActor @Sendable (RobotControlMode) -> Void = { _ in }) {
        self.link = link
        self.preferences = preferences
        self.clock = clock
        self.onControlModeChanged = onControlModeChanged
        snapshot = link.snapshot
        let updates = link.updates()
        observer = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    deinit { observer?.cancel(); opening?.cancel() }

    var presentation: RobotConnectionPresentation { .init(snapshot: snapshot) }

    var connectionActionTitle: String {
        switch snapshot.state {
        case .connected: "接続を切る"
        case .connecting, .preparing, .reconnecting: "接続をキャンセル"
        default: "このロボットに接続"
        }
    }
    func performConnectionAction() {
        switch link.snapshot.state {
        case .connecting, .preparing, .reconnecting, .connected: disconnect()
        default: if let device = link.snapshot.device { select(device) }
        }
    }

    /// Only the freshly read velocity caps describe an applied strength while connected.
    var displayedStrength: RobotMotionStrength? {
        guard snapshot.state == .connected, let limits = snapshot.limits else { return preferences.strength }
        return RobotMotionStrength.allCases.first { $0.matches(limits) }
    }
    var displayedStrengthText: String {
        if let displayedStrength { return displayedStrength.displayName }
        guard let limits = snapshot.limits else { return "速度上限を確認してください" }
        return "左右\(Int(limits.yawVelocityDeci) / 10)°/秒・上下\(Int(limits.pitchVelocityDeci) / 10)°/秒"
    }
    var strengthIsPending: Bool {
        snapshot.state == .connected && snapshot.limits.map { !preferences.strength.matches($0) } == true
    }

    var effectiveControlMode: RobotControlMode {
        if let applicationMode { return applicationMode }
        if calibration != nil, let calibrationID { return .calibration(calibrationID) }
        return settingsOpen ? .settings : .conversation
    }
    /// nil means active; a late calibration completion must not override scene ownership.
    func setApplicationMode(_ mode: RobotControlMode?) {
        guard applicationMode != mode else { return }
        applicationMode = mode
        notifyControlMode()
    }
    private func notifyControlMode() { onControlModeChanged(effectiveControlMode) }

    func settingsDidOpen() {
        guard !settingsOpen else { return }
        settingsOpen = true
        notifyControlMode()
    }

    func settingsDidClose() {
        guard calibration == nil, settingsOpen else { return }
        settingsOpen = false
        notifyControlMode()
    }

    func startSearch() { guard applicationMode == nil else { return }; link.start() }
    func select(_ device: RobotDevice) { guard calibration == nil, applicationMode == nil else { return }; link.select(device) }
    func disconnect() { link.disconnectByUser() }

    func openCalibration() async {
        guard calibration == nil, applicationMode == nil, link.snapshot.state == .connected else { return }
        calibrationExitWarning = nil
        let session = RobotCalibrationSession(link: link, clock: clock)
        settingsOpen = true
        calibrationID = UUID()
        calibration = session
        // Ownership changes before any suspension or preview work.
        notifyControlMode()
        opening = Task { try? await session.begin() }
        await Task.yield()
    }

    func closeCalibration(_ decision: RobotCalibrationExit) async {
        guard let session = calibration else { return }
        if session.hasNewChanges || session.requiresEntryRestoration {
            do {
                switch decision {
                case .save: _ = try await session.save()
                case .restore:
                    if link.snapshot.state != .connected || session.phase == .failed(.disconnected) {
                        calibrationExitWarning = "接続が切れたため、今回の変更を戻せませんでした。再接続して調整値を読み直してください。"
                    } else {
                        try await session.restoreEntry()
                    }
                }
            } catch {
                calibrationExitWarning = "調整を完了できませんでした。接続とハードの状態を確認して、もう一度お試しください。"
                return
            }
        }
        session.cancel()
        opening?.cancel()
        await opening?.value
        opening = nil
        guard calibration === session else { return }
        calibration = nil
        calibrationID = nil
        notifyControlMode()
    }
}

struct RobotConnectionPresentation {
    private(set) var message: String
    let canCalibrate: Bool

    init(snapshot: RobotLinkSnapshot) {
        canCalibrate = snapshot.state == .connected
            && snapshot.status?.state != .returning && snapshot.status?.state != .relaxWait
        switch snapshot.state {
        case .unselected: message = "ロボットを選んでください"
        case .searching: message = "近くのロボットを検索中"
        case .connecting: message = "ハードと接続しています"
        case .preparing: message = "接続を準備しています。初回はペアリングを許可してください"
        case .connected:
            message = snapshot.motionAvailable ? "ハードと接続中" : "ハードの動作・安全復帰の終了を待っています"
        case .reconnecting(let failure): message = Self.failureText(failure)
        case .unavailable(.unauthorized): message = "Bluetoothの利用が許可されていません。iPhoneの設定で許可してください"
        case .unavailable(.poweredOff): message = "Bluetoothがオフです。iPhoneの設定でオンにしてください"
        case .unavailable: message = "Bluetoothを利用できません"
        case .suspended: message = "ハードとの接続を中断しています"
        case .unsupported: message = "対応していないファームウェアです"
        }
        if snapshot.state == .unselected, let failure = snapshot.failure {
            message = Self.failureText(failure)
        }
    }

    static func failureText(_ failure: RobotLinkFailure) -> String {
        switch failure {
        case .authenticationFailed: "ペアリングを確認してください。ロボットを再起動し、60秒以内に接続してください"
        case .timedOut: "接続を確認できませんでした。ロボットの電源と距離を確認してください"
        case .protocolMismatch: "対応していないファームウェアです"
        default: "ハードを再接続中です。ハードが使えない間も会話は続けられます"
        }
    }
}

extension RobotMotionStrength {
    var displayName: String {
        switch self { case .calm: "控えめ"; case .standard: "標準"; case .active: "活発" }
    }
}

extension RobotCalibrationSession {
    var saveStateText: String {
        switch phase {
        case .inactive, .waitingForRest: return "動作の終了と調整値の読み込みを待っています"
        case .saving: return "ロボットへの保存を確認しています…"
        case .restoring: return "画面を開いたときの調整に戻しています…"
        case .failed(.disconnected): return "接続が切れました。変更は戻せていません。再接続後、調整を開き直してください"
        case .failed(.saveFailed), .failed(.valueMismatch): return "ロボットへの保存に失敗しました。変更は未保存です。もう一度保存してください"
        case .failed: return "調整に失敗しました。変更は未保存です。接続を確認して再試行してください"
        case .closed: return "調整を終了しました"
        case .editing:
            return !hasNewChanges && !requiresEntryRestoration && entry?.saved == true ? "ロボットに保存済み" : "未保存の変更があります"
        }
    }
}

/// Reconnection spans the retry delay and its subsequent connect/prepare attempt.
/// A different selected device starts a fresh presentation, even before it connects.
struct RobotReconnectIndicator: Equatable {
    private(set) var isVisible = false
    private var deviceID: UUID?
    private var hasConnected = false

    mutating func update(_ snapshot: RobotLinkSnapshot) {
        if deviceID != snapshot.device?.id {
            deviceID = snapshot.device?.id
            isVisible = false
            hasConnected = false
        }
        switch snapshot.state {
        case .connected:
            hasConnected = true
            isVisible = false
        case .reconnecting: isVisible = hasConnected
        case .connecting, .preparing: break
        case .unselected:
            hasConnected = false
            isVisible = false
        default: isVisible = false
        }
    }
}

extension RobotConnectionStatus {
    /// A small value projection prevents angle notifications from becoming conversation or accessibility updates.
    init(snapshot: RobotLinkSnapshot) {
        switch snapshot.state {
        case .connected: self = .connected
        case .connecting, .preparing, .reconnecting: self = .reconnecting
        default: self = .disconnected
        }
    }
}
