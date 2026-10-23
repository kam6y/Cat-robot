import SwiftUI

struct RobotConnectionView: View {
    @Bindable var model: RobotSettingsModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsDevices = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.presentation.message).font(.headline)
                    if let warning = model.calibrationExitWarning { Text(warning).foregroundStyle(.orange) }
                    let layout = typeSize.isAccessibilitySize || geometry.size.width < 650
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    layout {
                        connectionAndMotion.frame(maxWidth: .infinity, alignment: .topLeading)
                        information.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }.padding(20)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("ロボット")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
        .navigationDestination(isPresented: Binding(get: { model.calibration != nil }, set: { _ in })) {
            if let session = model.calibration {
                RobotCalibrationView(session: session, onClose: model.closeCalibration)
            }
        }
    }

    private var connectionAndMotion: some View {
        @Bindable var preferences = model.preferences
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox("接続先") {
                VStack(alignment: .leading, spacing: 14) {
                    if let device = model.snapshot.device {
                        Text(device.name).font(.headline)
                        if model.snapshot.state == .connected {
                            Button("接続を切る", action: model.disconnect)
                        } else {
                            Button("このロボットに接続") { model.select(device) }
                        }
                    } else { Text("接続先が未選択です") }
                    Divider()
                    Button("検索・接続先を変更") { model.startSearch(); showsDevices = true }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            GroupBox("首の動き") {
                VStack(spacing: 14) {
                    Text("動きの強さ").frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        ForEach(RobotMotionStrength.allCases, id: \.self) { strength in
                            Button(strength.displayName) { preferences.strength = strength }
                        }
                    } label: {
                        Label(model.displayedStrengthText, systemImage: "chevron.up.chevron.down")
                    }.accessibilityLabel("動きの強さ").accessibilityValue(model.displayedStrengthText)
                    if model.strengthIsPending {
                        Text("選んだ強さはまだ反映されていません。首の停止を待ち、接続を確認してください。必要ならつなぎ直してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("待機中も少し動く", isOn: $preferences.idleEnabled)
                }.padding(.top, 8)
            }
            Text("首がつながっていない間も、会話は続けられます。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("調整と情報") {
                VStack(alignment: .leading, spacing: 14) {
                    Button("中立と回転方向を調整") { Task { await model.openCalibration() } }
                        .disabled(!model.presentation.canCalibrate)
                    Divider()
                    LabeledContent("ファームウェア", value: firmwareVersion)
                    LabeledContent("首の状態", value: firmwareState)
                    LabeledContent("指令角", value: angles)
                }.padding(.top, 8)
            }
            Text("角度はロボットへ送っている指令値です。調整中は会話と自動の首の動きを一時停止します。")
                .font(.footnote).foregroundStyle(.secondary)
        }
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
