import SwiftUI

/// 設定画面の操作部品の識別子。View は文字列リテラルではなくこの列挙から取る（VoiceOver 確認は Task 10）。
enum ConversationSettingsIdentifier: String, CaseIterable {
    case modelPicker, effortPicker, voicePresetPicker, dailyTurnLimitStepper, memoryFactsList, deleteAllMemoryButton
}

struct ConversationSettingsView: View {
    @Bindable var voiceSettings: SpeechVoiceSettings
    @Bindable var modelSettings: ConversationModelSettings
    let memory: LongTermMemoryViewModel
    let usage: any ConversationUsageMetering
    /// 「すべて削除」の実体。覚えていることと会話の要約を消す。確認はこの画面で済ませる。
    let onDeleteAll: @MainActor () async -> Void
    let onDone: () -> Void
    @State private var usageSummary: ConversationUsageSummary?
    @State private var showsDeleteAllConfirmation = false
    @State private var isDeletingAll = false

    init(voiceSettings: SpeechVoiceSettings, modelSettings: ConversationModelSettings,
         memory: LongTermMemoryViewModel, usage: any ConversationUsageMetering,
         onDeleteAll: @escaping @MainActor () async -> Void, onDone: @escaping () -> Void) {
        self.voiceSettings = voiceSettings; self.modelSettings = modelSettings
        self.memory = memory; self.usage = usage; self.onDeleteAll = onDeleteAll; self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("モデル", selection: $modelSettings.model) {
                        ForEach(ConversationModelChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier(ConversationSettingsIdentifier.modelPicker.rawValue)
                    Picker("考える深さ", selection: $modelSettings.effort) {
                        ForEach(ConversationEffort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier(ConversationSettingsIdentifier.effortPicker.rawValue)
                } header: { Text("AI モデル") } footer: {
                    Text("変更は「新しい会話を始める」か次回起動から使います。進行中の会話では切り替えません。")
                }
                Section {
                    Picker("声", selection: $voiceSettings.selected) {
                        ForEach(SpeechVoicePreset.allCases, id: \.self) { Text("Supertonic \($0.rawValue)").tag($0) }
                    }
                    .accessibilityIdentifier(ConversationSettingsIdentifier.voicePresetPicker.rawValue)
                } header: { Text("声") } footer: { Text("選んだ声は次の会話から使います。初期設定はF1です。") }
                Section {
                    if memory.loadFailed { Text("覚えていることを読み込めませんでした") }
                    else if memory.facts.isEmpty { Text("まだ何も覚えていません") }
                    // Form は List なので入れ子の List にせず、行を Section に直接置く。
                    ForEach(memory.facts) { fact in
                        HStack {
                            Text(fact.category.label).font(.caption).foregroundStyle(.secondary)
                            Text(fact.text)
                        }
                    }
                    .onDelete { offsets in
                        let targets = offsets.map { memory.facts[$0] }
                        Task { for fact in targets { await memory.forget(fact) } }
                    }
                    Button("すべて削除", role: .destructive) { showsDeleteAllConfirmation = true }
                        .disabled(isDeletingAll)
                        .accessibilityIdentifier(ConversationSettingsIdentifier.deleteAllMemoryButton.rawValue)
                } header: { Text("覚えていること") } footer: {
                    Text("個別に消した事実は次の返答から反映します。「すべて削除」は会話の要約も消します。")
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.memoryFactsList.rawValue)
                Section {
                    Stepper("1日の上限 \(modelSettings.dailyTurnLimit) 回", value: $modelSettings.dailyTurnLimit, in: 10...2_000, step: 10)
                        .accessibilityIdentifier(ConversationSettingsIdentifier.dailyTurnLimitStepper.rawValue)
                    if let usageSummary {
                        LabeledContent("今日", value: "\(usageSummary.turnsToday) 回・約 \(usageSummary.estimatedTokensToday.formatted()) トークン")
                        LabeledContent("今月", value: "\(usageSummary.turnsThisMonth) 回・約 \(usageSummary.estimatedTokensThisMonth.formatted()) トークン")
                        LabeledContent("今月の概算", value: String(format: "約 $%.2f", usageSummary.estimatedCostUSDThisMonth))
                    }
                } header: { Text("利用量") } footer: {
                    Text("上限に達した日は、端末内のモデルで短く答えます。利用料は作者のワークスペースに課金されます。")
                }
                Section("情報") {
                    Text("返事は Anthropic の Claude で作ります。送るのは話しかけた文字と会話の要約・覚えていることだけで、音声は送りません。")
                    Text("音声合成: Supertonic 3（MIT / OpenRAIL-M）。推論: ONNX Runtime 1.24.2。Claude 連携: ClaudeForFoundationModels 0.2.3（Apache-2.0）。")
                }
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了", action: onDone) } }
            .confirmationDialog("すべて削除", isPresented: $showsDeleteAllConfirmation, titleVisibility: .visible) {
                Button("削除する", role: .destructive) {
                    Task { @MainActor in
                        isDeletingAll = true
                        await onDeleteAll()
                        await memory.load()
                        isDeletingAll = false
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("覚えていることと、このiPhoneに保存した会話の記憶をすべて削除します。元には戻せません。")
            }
            .task {
                await memory.load()
                usageSummary = await usage.summary()
            }
        }
        .preferredColorScheme(.dark)
    }
}
