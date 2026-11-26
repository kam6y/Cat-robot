import SwiftUI
import UIKit

/// 設定画面の操作部品の識別子。View は文字列リテラルではなくこの列挙から取る（VoiceOver 確認は Task 10）。
enum ConversationSettingsIdentifier: String, CaseIterable {
    case sleepyMinutesStepper, sleepingMinutesStepper
    case cameraPermissionButton
    case faceTrackingEnabled, faceTrackingStatus, faceTrackingYawCorrectionStepper
    case voicePresetPicker
    case wakePhraseField, wakePhraseRecordButton, wakePhraseSaveButton
    case hermesEndpointField, hermesAPIKeyField, hermesSaveButton, hermesDeleteKeyButton
    case hermesModelPicker, hermesEffortPicker, hermesModelRefresh, replyModelOpenConnection
    case historyReloadButton
    case settingsDoneButton
}

/// 設定の左列に並べるカテゴリ（使う目的ごとの名前）。開いたときは先頭の「声と待機時間」を選ぶ。
/// 会話の履歴は設定ではなく、会話メニューから開く独立した画面に置く。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case conversation, replyModel, hermesConnection, cameraAndTracking, robot, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "声と待機時間"
        case .replyModel: "返答モデル"
        case .hermesConnection: "Hermes 接続"
        case .cameraAndTracking: "カメラと顔追尾"
        case .robot: "ロボット"
        case .about: "このアプリについて"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "bubble.left"
        case .replyModel: "sparkles"
        case .hermesConnection: "network"
        case .cameraAndTracking: "camera"
        case .robot: "antenna.radiowaves.left.and.right"
        case .about: "info.circle"
        }
    }

    var accessibilityIdentifier: String { "settingsCategory.\(rawValue)" }
}

/// 左にカテゴリ、右に中身の2列。アクセシビリティ用の大きい文字では2列が収まらないので、一覧から詳細へ進む。
struct ConversationSettingsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var voiceSettings: SpeechVoiceSettings
    let connectionSettings: HermesConnectionSettings?
    @Bindable var idleSettings: ConversationIdleSettings
    let faceTracking: FaceTrackingCoordinator?
    let camera: ConversationCamera?
    let robotSettings: RobotSettingsModel?
    let wakePhraseRecorder: WakePhraseRecorder?
    let onDone: () -> Void
    @State private var selection: SettingsCategory
    /// 大きい文字のときの一覧から詳細への stack。校正の画面（isPresented / item の destination）も同じ stack に積まれる。
    @State private var path = NavigationPath()
    @State private var pendingDetail: SettingsCategory?

    init(voiceSettings: SpeechVoiceSettings, connectionSettings: HermesConnectionSettings? = nil,
         idleSettings: ConversationIdleSettings, robotSettings: RobotSettingsModel? = nil, faceTracking: FaceTrackingCoordinator? = nil,
         camera: ConversationCamera? = nil, wakePhraseRecorder: WakePhraseRecorder? = nil, initialCategory: SettingsCategory? = nil,
         onDone: @escaping () -> Void) {
        self.idleSettings = idleSettings
        self.wakePhraseRecorder = wakePhraseRecorder
        self.faceTracking = faceTracking
        self.camera = camera
        self.robotSettings = robotSettings
        self.voiceSettings = voiceSettings; self.connectionSettings = connectionSettings
        self.onDone = onDone
        _selection = State(initialValue: initialCategory ?? .conversation)
        _pendingDetail = State(initialValue: initialCategory)
    }

    /// 首やカメラを持たない構成（テストなど）では、その欄を出さない。
    private var categories: [SettingsCategory] {
        SettingsCategory.allCases.filter { category in
            switch category {
            case .replyModel, .hermesConnection: connectionSettings != nil
            case .robot: robotSettings != nil
            case .cameraAndTracking: camera != nil || faceTracking != nil
            default: true
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                if typeSize.isAccessibilitySize { categoryList } else { twoColumns }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("設定")
            // 上部の左に「設定」、右に「完了」を自前で置く。進んだ先（校正・大きい文字の詳細）ではバーを出す。
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsCategory.self) { category in
                // 大きい文字では一覧から進む。返答モデルから接続へは、同じ stack に接続の画面を積む（戻るとモデルに戻る）。
                pane(for: category, openConnection: nil)
                    .navigationTitle(category.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                camera?.refreshAuthorization()
            }
            .task {
                camera?.refreshAuthorization()
            }
            .onAppear(perform: openInitialDetailIfNeeded)
        }
        .interactiveDismissDisabled(robotSettings?.calibration != nil)
        .preferredColorScheme(.dark)
    }

    /// 大きい文字で特定の設定を指定したときは、その詳細から開く。戻れば一覧へ移る。
    private func openInitialDetailIfNeeded() {
        guard let category = pendingDetail else { return }
        pendingDetail = nil
        guard typeSize.isAccessibilitySize, categories.contains(category) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { path.append(category) }
    }

    private var header: some View {
        HStack {
            Text("設定")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // 閉じる操作は押しやすく。見た目・当たり判定・VoiceOver の枠がそろうよう、大きさは label の内側で取る。
            Button(action: onDone) {
                Text("完了")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 36)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier(ConversationSettingsIdentifier.settingsDoneButton.rawValue)
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
            // 2 列では、返答モデルの「Hermes 接続を設定」で右列を接続に切り替える。
            pane(for: selection, openConnection: { selection = .hermesConnection })
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

    /// openConnection は 2 列のときの切り替え。nil なら（大きい文字の一覧から進んだ先）接続の画面へ進む link にする。
    @ViewBuilder
    private func pane(for category: SettingsCategory, openConnection: (() -> Void)?) -> some View {
        switch category {
        case .conversation:
            ConversationSettingsPane(voiceSettings: voiceSettings, idleSettings: idleSettings, wakePhraseRecorder: wakePhraseRecorder)
        case .replyModel:
            if let connectionSettings { ReplyModelSettingsPane(settings: connectionSettings, openConnection: openConnection) }
        case .hermesConnection:
            if let connectionSettings { HermesConnectionSettingsPane(settings: connectionSettings) }
        case .cameraAndTracking:
            CameraTrackingSettingsPane(camera: camera, faceTracking: faceTracking, preferences: robotSettings?.preferences)
        case .robot:
            if let robotSettings { RobotConnectionView(model: robotSettings) }
        case .about:
            AboutSettingsPane()
        }
    }
}
