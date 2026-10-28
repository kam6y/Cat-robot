import SwiftUI

/// 設定「会話」の右列。声・モデル・考える深さと、居眠りまでの時間。
struct ConversationSettingsPane: View {
    @Bindable var voiceSettings: SpeechVoiceSettings
    @Bindable var modelSettings: ConversationModelSettings
    @Bindable var idleSettings: ConversationIdleSettings

    var body: some View {
        Form {
            Section {
                Picker("声", selection: $voiceSettings.selected) {
                    ForEach(SpeechVoicePreset.allCases, id: \.self) { Text("Supertonic \($0.rawValue)").tag($0) }
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.voicePresetPicker.rawValue)
                Picker("モデル", selection: $modelSettings.model) {
                    ForEach(ConversationModelChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.modelPicker.rawValue)
                Picker("考える深さ", selection: $modelSettings.effort) {
                    ForEach(ConversationEffort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.effortPicker.rawValue)
            } footer: { Text("声とモデルは次の会話から使います。") }
            Section {
                Stepper("眠そうになるまで \(idleSettings.sleepyMinutes) 分", value: $idleSettings.sleepyMinutes, in: ConversationIdleSettings.sleepyRange)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.sleepyMinutesStepper.rawValue)
                Stepper("待機に入るまで \(idleSettings.sleepingMinutes) 分", value: $idleSettings.sleepingMinutes, in: ConversationIdleSettings.sleepingRange)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.sleepingMinutesStepper.rawValue)
            } header: { Text("居眠り") } footer: {
                Text("最後に話しかけてからの時間です。待機中はマイク・カメラ・ハードを止め、猫をタップすると起きます。")
            }
        }
    }
}

/// 設定「記憶」の右列。覚えていることの一覧と「すべて削除」。
struct MemorySettingsPane: View {
    let memory: LongTermMemoryViewModel
    let isDeletingAll: Bool
    let onDeleteAll: () -> Void
    @State private var showsDeleteAllConfirmation = false

    var body: some View {
        Form {
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
            } header: { Text("覚えていること") } footer: {
                Text("左にスワイプすると1件ずつ消せます。次の返答から反映します。")
            }
            .accessibilityIdentifier(ConversationSettingsIdentifier.memoryFactsList.rawValue)
            Section {
                Button("すべて削除", role: .destructive) { showsDeleteAllConfirmation = true }
                    .disabled(isDeletingAll)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.deleteAllMemoryButton.rawValue)
            } footer: {
                Text("覚えていることと、このiPhoneに保存した会話の要約を消します。元には戻せません。")
            }
        }
        .confirmationDialog("すべて削除", isPresented: $showsDeleteAllConfirmation, titleVisibility: .visible) {
            Button("削除する", role: .destructive, action: onDeleteAll)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("覚えていることと、このiPhoneに保存した会話の記憶をすべて削除します。元には戻せません。")
        }
    }
}

/// 設定「利用量」の右列。1日の上限と、今日・今月の回数。
struct UsageSettingsPane: View {
    @Bindable var modelSettings: ConversationModelSettings
    let summary: ConversationUsageSummary?

    var body: some View {
        Form {
            Section {
                Stepper("1日の上限 \(modelSettings.dailyTurnLimit) 回", value: $modelSettings.dailyTurnLimit, in: 10...2_000, step: 10)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.dailyTurnLimitStepper.rawValue)
            } footer: { Text("上限に達した日は、端末内のモデルで短く答えます。") }
            Section {
                LabeledContent("今日", value: summary.map { "\($0.turnsToday) 回・約 \($0.estimatedTokensToday.formatted()) トークン" } ?? "—")
                LabeledContent("今月", value: summary.map { "\($0.turnsThisMonth) 回・約 \($0.estimatedTokensThisMonth.formatted()) トークン" } ?? "—")
                LabeledContent("今月の概算", value: summary.map { String(format: "約 $%.2f", $0.estimatedCostUSDThisMonth) } ?? "—")
            } footer: { Text("利用料は作者のワークスペースに課金されます。") }
        }
    }
}

/// 設定「このアプリについて」の右列。送るもの・保存するものの説明はここだけに置く。
struct AboutSettingsPane: View {
    @State private var showsOnboarding = false

    var body: some View {
        Form {
            Section {
                Text("返事は Anthropic の Claude で作ります。送るのは話しかけた文字・会話の要約・覚えていることと、「見て」と頼んだときの静止画像1枚です。音声や連続した映像は送りません。聞き取り・読み上げ・顔追尾の映像処理はこのiPhoneの中で行い、会話の記憶もこのiPhoneだけに保存します。")
            } header: { Text("送るもの・保存するもの") }
            Section {
                Button("はじめの説明をもう一度見る") { showsOnboarding = true }
            }
            Section {
                Text("音声合成: Supertonic 3（MIT / OpenRAIL-M）。推論: ONNX Runtime 1.24.2。Claude 連携: ClaudeForFoundationModels 0.2.3（Apache-2.0）。")
                    .font(.footnote)
            } header: { Text("ライセンス") }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(onStart: { showsOnboarding = false }, isReview: true)
        }
    }
}
