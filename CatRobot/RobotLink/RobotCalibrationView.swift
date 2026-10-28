import SwiftUI

/// 校正の左列に並べる項目。開いたときは「中立の調整」を選ぶ。
enum RobotCalibrationCategory: String, CaseIterable, Identifiable {
    case offsets, direction, movement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .offsets: "中立の調整"
        case .direction: "回転方向"
        case .movement: "動作確認"
        }
    }

    var systemImage: String {
        switch self {
        case .offsets: "scope"
        case .direction: "arrow.left.arrow.right"
        case .movement: "play.circle"
        }
    }

    var accessibilityIdentifier: String { "calibrationCategory.\(rawValue)" }
}

/// 設定と同じく左に項目、右に中身の2列。アクセシビリティ用の大きい文字では一覧から詳細へ進む。
/// 中立と回転方向はまとめて保存するので、保存状態と保存・戻すは項目に共通の1か所に置く。
struct RobotCalibrationView: View {
    let session: RobotCalibrationSession
    let onClose: @MainActor (RobotCalibrationExit) async -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsExitConfirmation = false
    @State private var selection: RobotCalibrationCategory = .offsets
    /// 大きい文字で開いている詳細。
    @State private var detail: RobotCalibrationCategory?

    var body: some View {
        // Group だと下の修飾子が分岐ごとに付き直り、文字サイズの切り替えでバー・確認・詳細・onChange が作り直される。
        // 1つの容器に付けて、切り替えの間も同じものを保つ。
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize { categoryList } else { twoColumns }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .calibrationNavigationBar("中立と回転方向")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { stopButton }
            ToolbarItem(placement: .topBarLeading) {
                Button("ロボット", systemImage: "chevron.left") {
                    if session.hasNewChanges { showsExitConfirmation = true }
                    else { Task { await onClose(.restore) } }
                }.accessibilityLabel("ロボットの設定へ戻る")
            }
        }
        .navigationDestination(item: $detail) { category in
            Form {
                sections(for: category)
                saveSection
            }
            .calibrationNavigationBar(category.title)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { stopButton }
                // システムの戻るは長押しで設定まで一度に戻れて、未保存の確認を通らない。詳細からは項目の一覧へだけ戻す。
                ToolbarItem(placement: .topBarLeading) {
                    Button("調整項目", systemImage: "chevron.left") { detail = nil }
                        .accessibilityLabel("調整項目へ戻る")
                }
            }
        }
        .onChange(of: typeSize.isAccessibilitySize) { _, isAccessibilitySize in
            // 標準の文字へ戻したら、開いていた詳細を閉じて2列に戻す（選択は詳細を開いたときに合わせてある）。
            if !isAccessibilitySize { detail = nil }
        }
        .confirmationDialog("調整を終えますか？", isPresented: $showsExitConfirmation, titleVisibility: .visible) {
            Button("保存して戻る") { Task { await onClose(.save) } }.disabled(!session.canEdit)
            Button("今回の変更を戻して戻る") { Task { await onClose(.restore) } }
            Button("そのまま編集", role: .cancel) {}
        } message: { Text("中立・回転方向に未保存の変更があります。接続が切れている場合、変更を戻すことはできません。") }
    }

    private var twoColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            // 最大の標準文字で項目名が折り返して縦に入らないときだけ、左列もスクロールさせる。
            ViewThatFits(in: .vertical) {
                sidebar
                ScrollView { sidebar }
            }
            .frame(width: 220)
            // 保存の領域は右列の下に固定し、項目を切り替えてもスクロールしても見えているようにする。
            VStack(spacing: 0) {
                Form { sections(for: selection) }
                Divider()
                saveBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(RobotCalibrationCategory.allCases) { category in
                categoryButton(category)
            }
        }
        .padding(.top, 6)
    }

    /// 設定の左列と同じ寸法の行。
    private func categoryButton(_ category: RobotCalibrationCategory) -> some View {
        let isSelected = selection == category
        return Button { selection = category } label: {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(category.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(isSelected ? Color(.systemGray5) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(category.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var categoryList: some View {
        List {
            Section {
                ForEach(RobotCalibrationCategory.allCases) { category in
                    Button { selection = category; detail = category } label: {
                        HStack {
                            Label(category.title, systemImage: category.systemImage)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier(category.accessibilityIdentifier)
                }
            }
            saveSection
        }
    }

    /// 2列の右列の下に固定する保存の領域。標準より大きい文字では状態文とボタンを2段にする。
    private var saveBar: some View {
        let layout = typeSize > .large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(session.saveStateText)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                restoreButton.buttonStyle(.bordered)
                saveButton.buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// 大きい文字の一覧と詳細の末尾に置く保存の欄。
    private var saveSection: some View {
        Section {
            Text(session.saveStateText)
            restoreButton
            saveButton
        }
    }

    private var restoreButton: some View {
        Button("変更を戻す") { Task { try? await session.restoreEntry() } }
            .disabled(!session.canEdit || (!session.hasNewChanges && !session.requiresEntryRestoration))
            .accessibilityLabel("中立・回転方向の変更を戻す")
    }

    private var saveButton: some View {
        Button("ロボットに保存") { Task { _ = try? await session.save() } }
            .disabled(!session.canEdit)
            .accessibilityLabel("中立・回転方向をロボットに保存")
    }

    private var stopButton: some View {
        Button("停止", systemImage: "stop.fill") { Task { await session.stop() } }
            .tint(.red).accessibilityLabel("ハードの動作を停止")
            .disabled(session.phase == .closed)
    }

    @ViewBuilder
    private func sections(for category: RobotCalibrationCategory) -> some View {
        switch category {
        case .offsets:
            Section {
                offset("左右のずれ", yaw: true)
                offset("上下のずれ", yaw: false)
            } footer: {
                Text("調整するとハードがその場で追従します。保存すると、電源を入れ直しても調整が残ります。")
            }
            .disabled(!session.canEdit)
        case .direction:
            Section {
                Toggle("左右を反転", isOn: inversion(bit: 1))
                Toggle("上下を反転", isOn: inversion(bit: 2))
            } footer: { Text("左右はロボットと向かい合って見た方向です。") }
            .disabled(!session.canEdit)
        case .movement:
            Section {
                Button("正面を向かせる") { Task { try? await session.center() } }
                edgeButton("左端へ", .left)
                edgeButton("右端へ", .right)
                edgeButton("上端へ", .up)
                edgeButton("下端へ", .down)
            } footer: { Text("左右はロボットと向かい合って見た方向です。") }
            .disabled(!session.canEdit)
        }
    }

    private func edgeButton(_ label: String, _ edge: RobotCalibrationEdge) -> some View {
        Button(label) { Task { try? await session.moveToEdge(edge) } }
            .accessibilityLabel("ハードをゆっくり\(label)")
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
            // ラベル付きの初期化子だと、Form の中で明示のラベルと重ねて2回読み上げる。
            Slider(value: binding, in: -20...20, step: 0.5)
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

private extension View {
    /// 校正の画面はバーに停止と戻るを置く。戻るはアプリのボタンだけにし、システムの戻るは出さない。
    func calibrationNavigationBar(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarBackButtonHidden()
    }
}
