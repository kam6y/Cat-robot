import SwiftUI

/// 設定「会話」の右列。声・モデル・エフォートと、居眠りまでの時間。
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
                Picker("エフォート", selection: $modelSettings.effort) {
                    ForEach(ConversationEffort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.effortPicker.rawValue)
            } footer: { Text("声・モデル・エフォートは次の会話から使います。") }
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

/// 設定「このアプリについて」の右列。送るもの・保存するものの説明はここだけに置く。
struct AboutSettingsPane: View {
    @State private var showsOnboarding = false

    var body: some View {
        Form {
            Section {
                Text("返事は Anthropic の Claude で作ります。送るのは話しかけた文字・会話の要約・覚えていることと、「見て」と頼んだときの静止画像1枚です。猫に話しかけたかの判定にも Claude を使うため、聞き取った発話と直近の会話も送ります。音声や連続した映像は送りません。聞き取り・読み上げ・顔追尾の映像処理はこのiPhoneの中で行い、会話の記憶もこのiPhoneだけに保存します。")
            } header: { Text("送るもの・保存するもの") }
            Section {
                Button("はじめの説明をもう一度見る") { showsOnboarding = true }
            }
            Section {
                Text("音声の終了判定: Smart Turn v3.2（BSD-2-Clause）、Silero VAD（MIT）。音声合成: Supertonic 3（MIT / OpenRAIL-M）。推論: ONNX Runtime 1.24.2。Claude 連携: ClaudeForFoundationModels 0.2.3（Apache-2.0）。")
                    .font(.footnote)
            } header: { Text("ライセンス") }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(onStart: { showsOnboarding = false }, isReview: true)
        }
    }
}
