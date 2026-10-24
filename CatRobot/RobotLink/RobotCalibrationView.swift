import SwiftUI

struct RobotCalibrationView: View {
    let session: RobotCalibrationSession
    @Bindable var preferences: RobotPreferences
    let onClose: @MainActor (RobotCalibrationExit) async -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsExitConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(session.saveStateText).font(.callout)
                    let layout = typeSize.isAccessibilitySize || geometry.size.width < 650
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    layout {
                        offsets.frame(maxWidth: .infinity, alignment: .topLeading)
                        direction.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Button("中立・回転方向の変更を戻す") { Task { try? await session.restoreEntry() } }
                        .disabled(!session.canEdit || !session.hasNewChanges)
                    Button("中立・回転方向をロボットに保存") { Task { _ = try? await session.save() } }
                        .buttonStyle(.borderedProminent).disabled(!session.canEdit)
                    Divider()
                    faceTrackingAim
                }.padding(20)
            }.background(Color(.systemGroupedBackground))
        }
        .navigationTitle("中立と回転方向")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("停止", systemImage: "stop.fill") { Task { await session.stop() } }
                    .tint(.red).accessibilityLabel("首の動作を停止")
                    .disabled(session.phase == .closed)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("ロボット", systemImage: "chevron.left") {
                    if session.hasNewChanges { showsExitConfirmation = true }
                    else { Task { await onClose(.restore) } }
                }.accessibilityLabel("ロボットの設定へ戻る")
            }
        }
        .confirmationDialog("調整を終えますか？", isPresented: $showsExitConfirmation, titleVisibility: .visible) {
            Button("保存して戻る") { Task { await onClose(.save) } }.disabled(!session.canEdit)
            Button("今回の変更を戻して戻る") { Task { await onClose(.restore) } }
            Button("そのまま編集", role: .cancel) {}
        } message: { Text("中立・回転方向に未保存の変更があります。接続が切れている場合、変更を戻すことはできません。顔追尾の補正はiPhoneに自動保存されます。") }
    }

    private var faceTrackingAim: some View {
        GroupBox("顔追尾の向き") {
            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $preferences.trackingYawCorrection,
                        in: RobotPreferences.trackingYawCorrectionRange,
                        step: RobotPreferences.trackingYawCorrectionStep) {
                    Text("左右補正  \(preferences.trackingYawCorrection, specifier: "%.1f")°").monospacedDigit()
                }
                .accessibilityLabel("顔追尾の左右補正を微調整")
                .accessibilityValue(String(format: "%.1f度", preferences.trackingYawCorrection))
                .accessibilityIdentifier("faceTrackingYawCorrectionStepper")
                Slider(value: $preferences.trackingYawCorrection,
                       in: RobotPreferences.trackingYawCorrectionRange,
                       step: RobotPreferences.trackingYawCorrectionStep) { Text("顔追尾の左右補正") }
                    .accessibilityValue(String(format: "%.1f度", preferences.trackingYawCorrection))
                    .accessibilityIdentifier("faceTrackingYawCorrectionSlider")
                HStack { Text("0°"); Spacer(); Text("20°") }
                    .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Button("8.5°に戻す") { preferences.trackingYawCorrection = RobotPreferences.defaultTrackingYawCorrection }
                    .disabled(preferences.trackingYawCorrection == RobotPreferences.defaultTrackingYawCorrection)
                    .accessibilityLabel("顔追尾の補正を8.5度に戻す")
                Text("左側のカメラと画面中央のずれを補正します。値はこのiPhoneに自動保存され、会話画面に戻ると反映されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }

    private var offsets: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("中立の調整") {
                VStack(spacing: 16) {
                    offset("左右のずれ", yaw: true)
                    Divider()
                    offset("上下のずれ", yaw: false)
                }.padding(.top, 8)
            }.disabled(!session.canEdit)
            Text("調整すると首がその場で追従します。保存すると、電源を入れ直しても調整が残ります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var direction: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("回転方向") {
                VStack(spacing: 14) {
                    Toggle("左右を反転", isOn: inversion(bit: 1))
                    Divider()
                    Toggle("上下を反転", isOn: inversion(bit: 2))
                }.padding(.top, 8)
            }.disabled(!session.canEdit)
            GroupBox("動かして確認") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("左右はロボットと向かい合って見た方向です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("正面を向かせる") { Task { try? await session.center() } }.disabled(!session.canEdit)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        edgeButton("左端へ", .left)
                        edgeButton("右端へ", .right)
                        edgeButton("上端へ", .up)
                        edgeButton("下端へ", .down)
                    }
                }.buttonStyle(.bordered).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func edgeButton(_ label: String, _ edge: RobotCalibrationEdge) -> some View {
        Button(label) { Task { try? await session.moveToEdge(edge) } }
            .disabled(!session.canEdit).accessibilityLabel("首をゆっくり\(label)")
    }

    private func offset(_ title: String, yaw: Bool) -> some View {
        let binding = Binding<Double>(get: {
            Double(yaw ? session.draft?.yawOffsetDeci ?? 0 : session.draft?.pitchOffsetDeci ?? 0) / 10
        }, set: { degrees in
            guard let draft = session.draft else { return }
            let value = Int16((degrees * 10).rounded())
            session.preview(.init(yawOffsetDeci: yaw ? value : draft.yawOffsetDeci,
                                  pitchOffsetDeci: yaw ? draft.pitchOffsetDeci : value, invert: draft.invert))
        })
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title)  \(binding.wrappedValue, specifier: "%.1f")°").monospacedDigit()
            Slider(value: binding, in: -20...20, step: 0.5) { Text(title) }
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.1f度", binding.wrappedValue))
            HStack { Text("−20°"); Spacer(); Text("+20°") }.font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private func inversion(bit: UInt8) -> Binding<Bool> {
        Binding(get: { (session.draft?.invert ?? 0) & bit != 0 }, set: { enabled in
            guard let draft = session.draft else { return }
            session.preview(.init(yawOffsetDeci: draft.yawOffsetDeci, pitchOffsetDeci: draft.pitchOffsetDeci,
                                  invert: enabled ? draft.invert | bit : draft.invert & ~bit))
        })
    }
}
