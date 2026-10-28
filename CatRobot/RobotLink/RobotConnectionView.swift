import SwiftUI

/// 設定「ロボット」の右列。接続先・ハードの動き・「中立と回転方向」への入口をまとめる。
struct RobotConnectionView: View {
    @Bindable var model: RobotSettingsModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDevices = false

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            if let warning = model.calibrationExitWarning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
            Section {
                connection
                Button("接続先を変更") { model.startSearch(); showsDevices = true }
            } footer: { Text("ハードがつながっていない間も、会話は続けられます。") }
            Section {
                // 表示はハードに反映済みの強さ（未反映なら注記で知らせる）なので、選択値を表示する Picker ではなく Menu の行にする。
                Menu {
                    ForEach(RobotMotionStrength.allCases, id: \.self) { strength in
                        Button(strength.displayName) { preferences.strength = strength }
                    }
                } label: {
                    HStack {
                        Text("動きの強さ").foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(model.displayedStrengthText).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .accessibilityLabel("動きの強さ")
                .accessibilityValue(model.displayedStrengthText)
                Toggle("待機中も少し動く", isOn: $preferences.idleEnabled)
            } footer: {
                if model.strengthIsPending {
                    Text("選んだ強さはまだ反映されていません。ハードの停止を待ち、接続を確認してください。必要ならつなぎ直してください。")
                }
            }
            Section {
                Button("中立と回転方向を調整") { Task { await model.openCalibration() } }
                    .disabled(!model.presentation.canCalibrate)
            } footer: {
                Text("ファームウェア \(firmwareVersion)　ハードの状態 \(firmwareState)\n指令角 \(angles)").monospacedDigit()
            }
        }
        .sheet(isPresented: $showsDevices) {
            NavigationStack {
                List {
                    if model.snapshot.state == .searching { ProgressView("ロボットを検索中") }
                    ForEach(model.snapshot.discoveredDevices, id: \.id) { device in
                        Button { model.select(device); showsDevices = false } label: {
                            HStack { Text(device.name); Spacer(); if let rssi = device.rssi { Text("\(rssi) dBm").foregroundStyle(.secondary) } }
                        }.accessibilityLabel("\(device.name)に接続")
                    }
                    if model.snapshot.discoveredDevices.isEmpty {
                        Text("ロボットの電源を入れ、近くで検索してください。初回のペアリングは起動後60秒以内に行います。")
                    }
                    Button("もう一度検索", action: model.startSearch)
                }
                .navigationTitle("接続先を選ぶ")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showsDevices = false } } }
            }.preferredColorScheme(.dark)
        }
        // 設定の2列ではなく、設定シート全体に重ねて進む。
        .navigationDestination(isPresented: Binding(get: { model.calibration != nil }, set: { _ in })) {
            if let session = model.calibration {
                RobotCalibrationView(session: session, onClose: model.closeCalibration)
                    .toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private var connection: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot.device?.name ?? "接続先が未選択です").font(.headline)
                if showsConnectionMessage {
                    Text(model.presentation.message)
                        .font(.subheadline)
                        .foregroundStyle(model.snapshot.state == .connected ? Color.green : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.snapshot.device != nil {
                // 行全体ではなくボタンだけで反応させる（名前に触れて接続を切らない）。
                Button(model.connectionActionTitle, action: model.performConnectionAction)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// 未選択で失敗もないときは「接続先が未選択です」だけで足りる。
    private var showsConnectionMessage: Bool {
        model.snapshot.device != nil || model.snapshot.state != .unselected || model.snapshot.failure != nil
    }

    private var firmwareVersion: String {
        guard let info = model.snapshot.info else { return "—" }
        return "\(info.major).\(info.minor).\(info.patch)"
    }
    private var angles: String {
        guard let status = model.snapshot.status else { return "—" }
        return String(format: "左右 %.1f° / 上下 %.1f°", Double(status.yawDeci) / 10, Double(status.pitchDeci) / 10)
    }
    private var firmwareState: String {
        guard let status = model.snapshot.status else { return "—" }
        switch status.state {
        case .boot, .bootCenter: return "起動中"
        case .returning, .relaxWait: return "安全復帰中"
        case .idle, .active:
            if status.flags.contains(.moving) { return "動作中" }
            return status.flags.contains(.torque) ? "待機中・位置を保持" : "待機中・PWM停止"
        }
    }
}
