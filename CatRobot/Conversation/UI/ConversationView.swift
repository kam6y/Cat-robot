import Accessibility
import SwiftUI

struct ConversationView: View {
    let state: ConversationViewState
    let actions: ConversationActions
    var isOpeningVoiceSettings = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var accessibility: ConversationAccessibility {
        ConversationAccessibility(phase: state.phase)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 12) {
                statusHeader
                conversationBody
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .statusBarHidden(ConversationPresentationPolicy.isStatusBarHidden)
        .confirmationDialog("会話を忘れる", isPresented: Binding(
            get: { state.showsForgetConfirmation },
            set: { if !$0 { actions.cancelForget() } }
        ), titleVisibility: .visible) {
            Button("削除する", role: .destructive, action: actions.confirmForget)
            Button("キャンセル", role: .cancel, action: actions.cancelForget)
        } message: {
            Text("このiPhoneに保存した会話の記憶を削除します。元には戻せません。")
        }
        .onChange(of: state) { oldState, newState in
            guard let announcement = ConversationAnnouncementPolicy.announcement(
                from: oldState,
                to: newState
            ) else { return }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Label(state.microphoneStatus, systemImage: microphoneSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityLabel("マイクの状態")
                .accessibilityValue(accessibility.microphoneValue)

            Text(state.activityStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("AIの猫の状態")
                .accessibilityValue(accessibility.assistantStatus)

            Spacer(minLength: 0)
            Menu {
                Button("声を選ぶ", systemImage: "speaker.wave.2", action: actions.openVoiceSettings)
                    .accessibilityIdentifier("openVoiceSettings")
                if ConversationMemoryPresentation(state: state.memoryState).supportsForget {
                    Button("会話を忘れる", role: .destructive, action: actions.requestForget)
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("会話の設定")
            .accessibilityIdentifier("conversationSettings")
            .disabled(state.memoryState == .forgetting || isOpeningVoiceSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversationContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                catArtwork
                    .frame(minWidth: 300, maxWidth: .infinity)
                    .frame(height: 250)

                transcriptContent
                    .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 520 : 280,
                           maxWidth: 520,
                           alignment: .leading)
            }

            VStack(spacing: 12) {
                catArtwork
                    .frame(maxWidth: 420)
                    .frame(height: 190)

                transcriptContent
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }

    private var catArtwork: some View {
        CatFaceView(
            state: state.catState,
            mouthPose: state.mouthPose,
            reduceMotion: reduceMotion
        )
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.caption.isEmpty {
                Text(state.caption)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("猫の返事")
                    .accessibilityValue(state.caption)
            }

            if !state.provisionalTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("聞き取り中…")
                        .font(.caption.weight(.semibold))
                    Text(state.provisionalTranscript)
                        .font(.body)
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            if let message = ConversationMemoryPresentation(state: state.memoryState).message {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if ConversationMemoryPresentation(state: state.memoryState).canRetry {
                        Button(state.memoryState == .unsaved ? "保存を再試行" : "再試行", action: actions.retryMemory)
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
                .accessibilityElement(children: .contain)
            } else if let notice = state.memoryNotice {
                Text(notice).font(.subheadline)
            }

            if let errorMessage = state.errorMessage {
                errorCard(message: errorMessage)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("エラー")
                .accessibilityValue(message)

            ForEach(Array(state.recoveries.enumerated()), id: \.offset) { _, recovery in
                Button(recovery.title) {
                    actions.performRecovery(recovery.action)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityLabel(recovery.title)
                .accessibilityHint("エラーから回復する操作を実行します")
            }
        }
        .padding(14)
        .background(errorBackground, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private var errorBackground: AnyShapeStyle {
        if reduceTransparency {
            AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        } else {
            AnyShapeStyle(.regularMaterial)
        }
    }

    @ViewBuilder
    private var conversationBody: some View {
        if reduceTransparency {
            verticalBody(usesGlass: false)
        } else {
            GlassEffectContainer(spacing: 12) {
                verticalBody(usesGlass: true)
            }
        }
    }

    private func verticalBody(usesGlass: Bool) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                scrollableContent(usesGlass: usesGlass)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            fixedControls(usesGlass: usesGlass)
        }
    }

    @ViewBuilder
    private func scrollableContent(usesGlass: Bool) -> some View {
        switch ConversationVerticalLayout.preferred(
            for: dynamicTypeSize,
            showsTypedInput: state.showsTypedInput
        ) {
        case .standard:
            conversationContent
        case .scrollableContentWithFixedControls:
            VStack(spacing: 12) {
                conversationContent

                if state.showsTypedInput {
                    typedInput(usesGlass: usesGlass)
                }
            }
        }
    }

    private func typedInput(usesGlass: Bool) -> some View {
        TypedInputView(
            text: Binding(
                get: { state.typedText },
                set: { newValue in
                    actions.updateTypedText(newValue)
                }
            ),
            usesGlass: usesGlass,
            isSubmissionAllowed: state.allowsTypedSubmission,
            onSend: sendTypedText,
            onDismiss: dismissTypedInput
        )
    }

    @ViewBuilder
    private func fixedControls(usesGlass: Bool) -> some View {
        if usesGlass {
            controlButtons(usesGlass: true)
        } else {
            controlButtons(usesGlass: false)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    @ViewBuilder
    private func controlButtons(usesGlass: Bool) -> some View {
        switch ConversationLowerControlsLayout.preferred(
            for: dynamicTypeSize,
            showsTypedInput: state.showsTypedInput
        ) {
        case .horizontalFirst:
            ViewThatFits(in: .horizontal) {
                horizontalControlButtons(usesGlass: usesGlass)
                stackedControlButtons(usesGlass: usesGlass)
            }
        case .stacked:
            ViewThatFits(in: .horizontal) {
                stackedControlButtons(usesGlass: usesGlass)
            }
        case .compactHorizontal:
            compactControlButtons(usesGlass: usesGlass)
        }
    }

    private func horizontalControlButtons(usesGlass: Bool) -> some View {
        HStack(spacing: 12) {
            listeningButton(usesGlass: usesGlass)
            keyboardButton(usesGlass: usesGlass)
        }
        .frame(maxWidth: .infinity)
    }

    private func stackedControlButtons(usesGlass: Bool) -> some View {
        VStack(spacing: 8) {
            listeningButton(usesGlass: usesGlass)
            keyboardButton(usesGlass: usesGlass)
        }
        .frame(maxWidth: .infinity)
    }

    private func compactControlButtons(usesGlass: Bool) -> some View {
        HStack(spacing: 12) {
            listeningButton(usesGlass: usesGlass, usesCompactLabel: true)
            keyboardButton(usesGlass: usesGlass, usesCompactLabel: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func listeningButton(
        usesGlass: Bool,
        usesCompactLabel: Bool = false
    ) -> some View {
        ListeningControl(
            phase: state.phase,
            usesGlass: usesGlass,
            usesCompactLabel: usesCompactLabel,
            action: actions.toggleListening
        )
        .disabled(ConversationMemoryPresentation(state: state.memoryState).blocksConversation)
    }

    @ViewBuilder
    private func keyboardButton(
        usesGlass: Bool,
        usesCompactLabel: Bool = false
    ) -> some View {
        if usesGlass {
            keyboardButton(usesCompactLabel: usesCompactLabel).buttonStyle(.glass)
        } else {
            keyboardButton(usesCompactLabel: usesCompactLabel).buttonStyle(.bordered)
        }
    }

    private func keyboardButton(usesCompactLabel: Bool) -> some View {
        Button(action: toggleTypedInput) {
            Label(
                keyboardButtonTitle(usesCompactLabel: usesCompactLabel),
                systemImage: state.showsTypedInput ? "keyboard.chevron.compact.down" : "keyboard"
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(state.showsTypedInput ? "文字入力を閉じる" : "文字入力を開く")
        .accessibilityValue(state.showsTypedInput ? "開いています" : "閉じています")
    }

    private func keyboardButtonTitle(usesCompactLabel: Bool) -> String {
        if usesCompactLabel {
            return state.showsTypedInput ? "閉じる" : "文字入力"
        }
        return state.showsTypedInput ? "文字入力を閉じる" : "文字で入力"
    }

    private var microphoneSymbol: String {
        switch state.phase {
        case .listening:
            "mic.fill"
        case .paused, .failed:
            "mic.slash.fill"
        default:
            "mic.badge.xmark"
        }
    }

    private func toggleTypedInput() {
        if state.showsTypedInput {
            dismissTypedInput()
        } else {
            actions.showTypedInput()
        }
    }

    private func dismissTypedInput() {
        actions.hideTypedInput()
    }

    private func sendTypedText() {
        guard !state.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.sendTypedText()
    }
}

#if DEBUG
#Preview("Landscape conversation") {
    ConversationView(
        state: .speaking(caption: "こんにちは。今日はどんなことを話そうか？"),
        actions: .init(
            toggleListening: {},
            showTypedInput: {},
            hideTypedInput: {},
            updateTypedText: { _ in },
            sendTypedText: {},
            performRecovery: { _ in }
        )
    )
}
#endif
