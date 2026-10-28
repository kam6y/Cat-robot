import SwiftUI
import UIKit

/// 設定画面の操作部品の識別子。View は文字列リテラルではなくこの列挙から取る（VoiceOver 確認は Task 10）。
enum ConversationSettingsIdentifier: String, CaseIterable {
    case sleepyMinutesStepper, sleepingMinutesStepper
    case cameraPermissionButton
    case modelPicker, effortPicker, voicePresetPicker, dailyTurnLimitStepper, memoryFactsList, deleteAllMemoryButton
}

/// 設定の左列に並べるカテゴリ。開いたときは「会話」を選ぶ。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case conversation, memory, cameraAndTracking, robot, usage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "会話"
        case .memory: "記憶"
        case .cameraAndTracking: "カメラと顔追尾"
        case .robot: "ロボット"
        case .usage: "利用量"
        case .about: "このアプリについて"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "bubble.left"
        case .memory: "book.closed"
        case .cameraAndTracking: "camera"
        case .robot: "antenna.radiowaves.left.and.right"
        case .usage: "chart.bar"
        case .about: "info.circle"
        }
    }

    var accessibilityIdentifier: String { "settingsCategory.\(rawValue)" }
}

/// 左にカテゴリ、右に中身の2列。アクセシビリティ用の大きい文字では2列が収まらないので、一覧から詳細へ進む。
struct ConversationSettingsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var voiceSettings: SpeechVoiceSettings
    @Bindable var modelSettings: ConversationModelSettings
    @Bindable var idleSettings: ConversationIdleSettings
    let memory: LongTermMemoryViewModel
    let usage: any ConversationUsageMetering
    let faceTracking: FaceTrackingCoordinator?
    let camera: ConversationCamera?
    let robotSettings: RobotSettingsModel?
    /// 「すべて削除」の実体。覚えていることと会話の要約を消す。確認は「記憶」の中で済ませる。
    let onDeleteAll: @MainActor () async -> Void
    let onDone: () -> Void
    @State private var selection: SettingsCategory
    @State private var usageSummary: ConversationUsageSummary?
    @State private var isDeletingAll = false

    init(voiceSettings: SpeechVoiceSettings, modelSettings: ConversationModelSettings,
         memory: LongTermMemoryViewModel, usage: any ConversationUsageMetering,
         idleSettings: ConversationIdleSettings, robotSettings: RobotSettingsModel? = nil, faceTracking: FaceTrackingCoordinator? = nil,
         camera: ConversationCamera? = nil, initialCategory: SettingsCategory = .conversation,
         onDeleteAll: @escaping @MainActor () async -> Void, onDone: @escaping () -> Void) {
        self.idleSettings = idleSettings
        self.faceTracking = faceTracking
        self.camera = camera
        self.robotSettings = robotSettings
        self.voiceSettings = voiceSettings; self.modelSettings = modelSettings
        self.memory = memory; self.usage = usage; self.onDeleteAll = onDeleteAll; self.onDone = onDone
        _selection = State(initialValue: initialCategory)
    }

    /// 首やカメラを持たない構成（テストなど）では、その欄を出さない。
    private var categories: [SettingsCategory] {
        SettingsCategory.allCases.filter { category in
            switch category {
            case .robot: robotSettings != nil
            case .cameraAndTracking: camera != nil || faceTracking != nil
            default: true
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if typeSize.isAccessibilitySize { categoryList } else { twoColumns }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("設定")
            // 上部の左に「設定」、右に「完了」を自前で置く。進んだ先（校正・大きい文字の詳細）ではバーを出す。
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsCategory.self) { category in
                pane(for: category)
                    .navigationTitle(category.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                camera?.refreshAuthorization()
            }
            .task {
                camera?.refreshAuthorization()
                await memory.load()
                usageSummary = await usage.summary()
            }
        }
        .interactiveDismissDisabled(robotSettings?.calibration != nil)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("設定")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("完了", action: onDone)
                .buttonStyle(.glass)
                .fontWeight(.semibold)
                .disabled(robotSettings?.calibration != nil)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var twoColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            // 最大の標準文字でカテゴリ名が折り返して縦に入らないときだけ、左列もスクロールさせる。
            ViewThatFits(in: .vertical) {
                sidebar
                ScrollView { sidebar }
            }
            .frame(width: 220)
            pane(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(categories) { category in
                categoryButton(category)
            }
        }
        .padding(.top, 6)
    }

    private func categoryButton(_ category: SettingsCategory) -> some View {
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
        List(categories) { category in
            NavigationLink(value: category) {
                Label(category.title, systemImage: category.systemImage)
            }
            .accessibilityIdentifier(category.accessibilityIdentifier)
        }
    }

    @ViewBuilder
    private func pane(for category: SettingsCategory) -> some View {
        switch category {
        case .conversation:
            ConversationSettingsPane(voiceSettings: voiceSettings, modelSettings: modelSettings, idleSettings: idleSettings)
        case .memory:
            MemorySettingsPane(memory: memory, isDeletingAll: isDeletingAll, onDeleteAll: deleteAll)
        case .cameraAndTracking:
            CameraTrackingSettingsPane(camera: camera, faceTracking: faceTracking, preferences: robotSettings?.preferences)
        case .robot:
            if let robotSettings { RobotConnectionView(model: robotSettings) }
        case .usage:
            UsageSettingsPane(modelSettings: modelSettings, summary: usageSummary)
        case .about:
            AboutSettingsPane()
        }
    }

    private func deleteAll() {
        Task { @MainActor in
            isDeletingAll = true
            await onDeleteAll()
            await memory.load()
            isDeletingAll = false
        }
    }
}
