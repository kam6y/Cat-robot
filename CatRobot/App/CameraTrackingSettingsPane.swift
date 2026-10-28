import SwiftUI
import UIKit

/// 設定「カメラと顔追尾」の右列。カメラの許可と、顔追尾のオンオフ・状態・左右補正をまとめる。
struct CameraTrackingSettingsPane: View {
    let camera: ConversationCamera?
    let faceTracking: FaceTrackingCoordinator?
    let preferences: RobotPreferences?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let camera {
                Section {
                    LabeledContent("カメラ", value: Self.authorizationLabel(camera.authorization))
                    if camera.authorization == .notDetermined {
                        Button(camera.permissionInProgress ? "確認中…" : "カメラを許可") {
                            Task { await camera.requestAuthorization() }
                        }
                        .disabled(camera.permissionInProgress)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(ConversationSettingsIdentifier.cameraPermissionButton.rawValue)
                    } else if camera.authorization != .authorized {
                        openSystemSettingsButton
                            .accessibilityIdentifier(ConversationSettingsIdentifier.cameraPermissionButton.rawValue)
                    }
                } footer: {
                    Text("「見て」と頼んだときに、前面カメラの静止画像を1枚Claudeへ送ります。画像は保存しません。")
                }
            }
            if let faceTracking {
                Section {
                    Toggle("顔に合わせてハードを向ける", isOn: Binding(get: { faceTracking.isEnabled }, set: { enabled in
                        Task { await faceTracking.setEnabled(enabled) }
                    }))
                    .accessibilityIdentifier("faceTrackingEnabled")
                    LabeledContent("状態", value: faceTracking.status.text)
                        .accessibilityIdentifier("faceTrackingStatus")
                    // 通常はカメラの欄に同じボタンがある。カメラを持たない構成のときだけここに出す。
                    if camera == nil, faceTracking.needsSystemSettings { openSystemSettingsButton }
                    if let preferences { TrackingAimRows(preferences: preferences) }
                } header: { Text("顔追尾（ハードの接続が必要）") } footer: {
                    Text("映像はこのiPhone内だけで処理し、保存・送信しません。補正は左側のカメラと画面中央のずれを直します（iPhoneに自動保存）。")
                }
            }
        }
    }

    private var openSystemSettingsButton: some View {
        Button("iPhoneの設定を開く") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .frame(minHeight: 44)
    }

    private static func authorizationLabel(_ authorization: FaceCameraAuthorization) -> String {
        switch authorization {
        case .notDetermined: "未確認"
        case .authorized: "許可済み"
        case .denied: "許可されていません"
        case .restricted: "制限されています"
        }
    }
}

/// 左右補正のステッパーと「8.5°に戻す」。狭い右列に収めるためスライダーは置かない。
private struct TrackingAimRows: View {
    @Bindable var preferences: RobotPreferences
    /// The default aim ("8.5") as shown by the reset button and its accessibility label.
    private static let defaultAimText = String(format: "%.1f", RobotPreferences.defaultTrackingYawCorrection)

    var body: some View {
        Stepper(value: $preferences.trackingYawCorrection,
                in: RobotPreferences.trackingYawCorrectionRange,
                step: RobotPreferences.trackingYawCorrectionStep) {
            Text("左右補正  \(preferences.trackingYawCorrection, specifier: "%.1f")°").monospacedDigit()
        }
        .accessibilityLabel("顔追尾の左右補正を微調整")
        .accessibilityValue(String(format: "%.1f度", preferences.trackingYawCorrection))
        .accessibilityIdentifier("faceTrackingYawCorrectionStepper")
        Button("\(Self.defaultAimText)°に戻す") { preferences.trackingYawCorrection = RobotPreferences.defaultTrackingYawCorrection }
            .disabled(preferences.trackingYawCorrection == RobotPreferences.defaultTrackingYawCorrection)
            .accessibilityLabel("顔追尾の補正を\(Self.defaultAimText)度に戻す")
    }
}
