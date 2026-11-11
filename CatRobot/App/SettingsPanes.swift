import SwiftUI

/// 設定「会話」の右列。声と、居眠りまでの時間。返事を作るのは Hermes なので、モデルの選択はここに置かない。
struct ConversationSettingsPane: View {
    @Bindable var voiceSettings: SpeechVoiceSettings
    @Bindable var idleSettings: ConversationIdleSettings

    var body: some View {
        Form {
            Section {
                Picker("声", selection: $voiceSettings.selected) {
                    ForEach(SpeechVoicePreset.allCases, id: \.self) { Text("Supertonic \($0.rawValue)").tag($0) }
                }
                .accessibilityIdentifier(ConversationSettingsIdentifier.voicePresetPicker.rawValue)
            } footer: { Text("声は次の返事から使います。") }
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

/// 設定「Hermes 接続」の右列。接続先（https の root）と API キー。保存済みのキーは表示せず、入力欄にも戻さない。
struct HermesConnectionSettingsPane: View {
    let settings: HermesConnectionSettings
    @State private var endpointText: String
    @State private var apiKey = ""
    @State private var status: String?
    @State private var isWorking = false

    init(settings: HermesConnectionSettings) {
        self.settings = settings
        _endpointText = State(initialValue: settings.endpoint?.absoluteString ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("https://hermes.example:8443", text: $endpointText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("接続先")
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesEndpointField.rawValue)
            } header: { Text("接続先") } footer: {
                Text("https で始まる URL（パス・クエリなし）。iPhone 標準の証明書の確認を通る接続先だけに送ります。")
            }
            Section {
                SecureField(settings.hasSavedKey ? "保存済み（変えるときだけ入力）" : "API キー", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("API キー")
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesAPIKeyField.rawValue)
                Text(settings.hasSavedKey ? "この接続先のキーはこの iPhone に保存されています" : "この接続先のキーはまだ保存されていません")
                    .foregroundStyle(.secondary)
            } header: { Text("API キー") } footer: {
                Text("キーは接続先ごとにこの iPhone のキーチェーンに保存し、ほかの接続先へは送りません。接続先を変えたら、その接続先のキーを入力してください。")
            }
            Section {
                Button("保存", action: save)
                    .disabled(isWorking)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesSaveButton.rawValue)
                Button("この接続先のキーを削除", role: .destructive, action: deleteKey)
                    .disabled(isWorking || !settings.hasSavedKey)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesDeleteKeyButton.rawValue)
                if let status { Text(status) }
            } footer: {
                Text("普段使いできる常設の HTTPS 接続先はまだ用意されていません。接続先とキーを設定しないと、通常の返事は使えません（ほかのモデルが代わりに答えることはありません）。")
            }
        }
        .task { await settings.refresh() }
    }

    private func save() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await settings.save(endpointText: endpointText, apiKey: apiKey)
                apiKey = ""
                endpointText = settings.endpoint?.absoluteString ?? endpointText
                status = settings.hasSavedKey ? "保存しました。次の返事からこの接続先を使います。" : "接続先を保存しました。この接続先の API キーを入力してください。"
            } catch HermesConnectionSettings.SaveError.invalidEndpoint {
                status = "接続先は https で始まる URL（パス・クエリなし）で入力してください。"
            } catch HermesConnectionSettings.SaveError.invalidKey {
                status = "API キーに使えない文字があります。空白や改行を含めずに入力してください。"
            } catch {
                status = "キーを保存できませんでした。設定は変えていません。"
            }
        }
    }

    private func deleteKey() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await settings.deleteKey()
                status = "この接続先のキーを削除しました。"
            } catch {
                status = "キーを削除できませんでした。"
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
                Text("返事は設定した Hermes の接続先で作り、会話の続きと履歴は Hermes に保存されます。この iPhone には会話の本文を保存しません。Hermes に送るのは話しかけた文字です。声で話しかけたときは、猫に話しかけたかの判定のため、聞き取った発話と直近の会話を Anthropic の Claude にも送ります。音声・映像・画像は送りません。聞き取り・読み上げ・顔追尾の映像処理はこのiPhoneの中で行います。")
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
