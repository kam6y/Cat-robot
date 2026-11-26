import SwiftUI

/// 設定「会話」の右列。声と、居眠りまでの時間。返事を作るのは Hermes なので、モデルと effort の選択は「Hermes 接続」に置く。
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

/// 設定「Hermes 接続」の右列。接続先（https の root）と API キー、その Hermes で使うモデルと effort。
/// 保存済みのキーは表示せず、入力欄にも戻さない。
struct HermesConnectionSettingsPane: View {
    let settings: HermesConnectionSettings
    @State private var draft: HermesConnectionSettings.Draft
    private var endpointText: String { draft.endpointText }
    @State private var status: (draft: String, message: String)?
    @State private var isWorking = false

    init(settings: HermesConnectionSettings) {
        self.settings = settings
        _draft = State(initialValue: HermesConnectionSettings.Draft(endpointText: settings.endpoint?.absoluteString ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("https://hermes.example:8443", text: $draft.endpointText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("接続先")
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesEndpointField.rawValue)
            } header: { Text("接続先") } footer: {
                Text("https で始まる URL（パス・クエリなし）。iPhone 標準の証明書の確認を通る接続先だけに送ります。")
            }
            Section {
                SecureField(settings.hasSavedKey(for: endpointText) ? "保存済み（変えるときだけ入力）" : "API キー", text: $draft.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("API キー")
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesAPIKeyField.rawValue)
                Text(keyStatus)
                    .foregroundStyle(.secondary)
            } header: { Text("API キー") } footer: {
                Text("キーは接続先ごとにこの iPhone のキーチェーンに保存し、ほかの接続先へは送りません。接続先を変えたら、その接続先のキーを入力してください。")
            }
            Section {
                Button("保存", action: save)
                    .disabled(isWorking)
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesSaveButton.rawValue)
                Button("この接続先のキーを削除", role: .destructive, action: deleteKey)
                    .disabled(isWorking || !settings.hasSavedKey(for: endpointText))
                    .accessibilityIdentifier(ConversationSettingsIdentifier.hermesDeleteKeyButton.rawValue)
                if let status, status.draft == endpointText { Text(status.message) }
            } footer: {
                Text("普段使いできる常設の HTTPS 接続先はまだ用意されていません。接続先とキーを設定しないと、通常の返事は使えません（ほかのモデルが代わりに答えることはありません）。")
            }
            HermesModelSection(settings: settings)
        }
        .task { await settings.refresh() }
        // 開いたときと、接続先かキーを保存・削除したときに、Hermes の cache から候補を読む（probe し直すのは明示の再取得だけ）。
        .task(id: settings.models.connectionRevision) { await settings.refreshModels(force: false) }
    }

    private var keyStatus: String {
        guard let saved = settings.endpoint, saved == HermesConnectionSettings.endpoint(from: endpointText) else {
            return "表示中の接続先はまだ保存されていません"
        }
        return settings.hasSavedKey(for: endpointText)
            ? "この接続先のキーはこの iPhone に保存されています"
            : "この接続先のキーはまだ保存されていません"
    }

    private func save() {
        guard !isWorking else { return }
        let submitted = draft
        isWorking = true
        Task {
            defer { isWorking = false }
            guard draft.revision == submitted.revision else { return }
            do {
                try await settings.save(draft: submitted)
                guard draft.revision == submitted.revision, let saved = settings.endpoint,
                      saved == submitted.endpoint else { return }
                draft.apiKey = ""
                draft.endpointText = saved.absoluteString
                let message = settings.hasSavedKey(for: endpointText)
                    ? "保存しました。次の返事からこの接続先を使います。"
                    : "接続先を保存しました。この接続先の API キーを入力してください。"
                status = (endpointText, message)
            } catch HermesConnectionSettings.SaveError.invalidEndpoint {
                status = (submitted.endpointText, "接続先は https で始まる URL（パス・クエリなし）で入力してください。")
            } catch HermesConnectionSettings.SaveError.invalidKey {
                status = (submitted.endpointText, "API キーに使えない文字があります。空白や改行を含めずに入力してください。")
            } catch {
                status = (submitted.endpointText, "キーを保存できませんでした。設定は変えていません。")
            }
        }
    }

    private func deleteKey() {
        let draft = endpointText
        isWorking = true
        Task {
            defer { isWorking = false }
            guard HermesConnectionSettings.endpoint(from: endpointText) == HermesConnectionSettings.endpoint(from: draft) else { return }
            do {
                if try await settings.deleteKey(for: draft) {
                    status = (draft, "この接続先のキーを削除しました。")
                }
            } catch {
                status = (draft, "キーを削除できませんでした。")
            }
        }
    }
}

/// 「Hermes 接続」のモデルと effort。候補は保存済みの接続先の Hermes から読み、選択は接続先ごとに保存する。
/// 再取得のボタンは、読み込み中・失敗・未設定のときも出す（押せないときは disabled）。
private struct HermesModelSection: View {
    let settings: HermesConnectionSettings
    private var models: HermesModelSettings { settings.models }
    /// 保存済みの接続先に、その origin のキーがある（候補を読める）。
    private var canLoad: Bool { models.origin != nil && settings.hasSavedKey }

    var body: some View {
        Section {
            Picker("モデル", selection: Binding(get: { models.current.model }, set: { models.select(model: $0) })) {
                Text(defaultModelLabel).tag(HermesModelID?.none)
                if let saved = models.current.model, models.catalog?.model(for: saved) == nil {
                    Text("\(saved.model)（保存済み）").tag(Optional(saved))
                }
                ForEach(models.catalog?.providers ?? []) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Text(model.id).tag(Optional(HermesModelID(provider: provider.slug, model: model.id)))
                        }
                    }
                }
            }
            .disabled(!canLoad)
            .accessibilityIdentifier(ConversationSettingsIdentifier.hermesModelPicker.rawValue)
            let efforts = models.effortChoices
            if !efforts.isEmpty {
                Picker("推論の深さ（effort）", selection: Binding(get: { models.current.effort }, set: { models.select(effort: $0) })) {
                    Text("Hermes の既定").tag(HermesReasoningEffort?.none)
                    ForEach(efforts, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .disabled(!canLoad)
                .accessibilityIdentifier(ConversationSettingsIdentifier.hermesEffortPicker.rawValue)
            }
            Button("モデルの候補を再取得") { Task { await settings.refreshModels(force: true) } }
                .disabled(!canLoad || models.isLoading)
                .accessibilityIdentifier(ConversationSettingsIdentifier.hermesModelRefresh.rawValue)
            if let status { Text(status).foregroundStyle(.secondary) }
            if let notice = models.notice { Text(notice).foregroundStyle(.secondary) }
        } header: { Text("モデル") } footer: {
            Text("選んだモデルと effort は次の返事から、この接続先にだけ使います。Hermes 側で /model を指定した会話では、そのモデルが優先されます。")
        }
    }

    private var defaultModelLabel: String {
        guard let catalog = models.catalog, let model = catalog.defaultModel else { return "Hermes の既定" }
        let provider = catalog.defaultProvider.map { "\($0) / " } ?? ""
        return "Hermes の既定（\(provider)\(model)）"
    }

    private var status: String? {
        guard models.origin != nil else { return "接続先とキーを保存すると、この Hermes で使えるモデルを読み込めます。" }
        guard settings.hasSavedKey else { return "この接続先の API キーを保存すると、使えるモデルを読み込めます。" }
        switch models.phase {
        case .idle: return nil
        case .loading: return "モデルの候補を読み込んでいます…"
        case .failed(let message): return message
        case .loaded:
            guard let catalog = models.catalog else { return nil }
            if catalog.providers.isEmpty { return "選べるモデルが見つかりませんでした。" }
            if catalog.source == .routes {
                return "この Hermes はモデルの一覧に対応していないため、model_routes の別名だけを表示しています。"
            }
            return nil
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
