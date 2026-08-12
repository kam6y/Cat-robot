import SwiftUI

struct ConversationView: View {
    let state: ConversationViewState
    let actions: ConversationActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isTypedInputPresented: Bool

    init(state: ConversationViewState, actions: ConversationActions) {
        self.state = state
        self.actions = actions
        _isTypedInputPresented = State(initialValue: state.showsTypedInput)
    }

    private var accessibility: ConversationAccessibility {
        ConversationAccessibility(phase: state.phase)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            VStack(spacing: 12) {
                statusHeader

                ScrollView {
                    conversationContent
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)

                lowerControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .onChange(of: state.showsTypedInput) { _, isPresented in
            isTypedInputPresented = isPresented
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
    private var lowerControls: some View {
        if reduceTransparency {
            controlContents(usesGlass: false)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else {
            GlassEffectContainer(spacing: 12) {
                controlContents(usesGlass: true)
            }
        }
    }

    private func controlContents(usesGlass: Bool) -> some View {
        VStack(spacing: 10) {
            if isTypedInputPresented {
                TypedInputView(
                    text: Binding(
                        get: { state.typedText },
                        set: { newValue in
                            actions.updateTypedText(newValue)
                        }
                    ),
                    usesGlass: usesGlass,
                    onSend: sendTypedText,
                    onDismiss: dismissTypedInput
                )
            }

            HStack(spacing: 12) {
                ListeningControl(
                    phase: state.phase,
                    usesGlass: usesGlass,
                    action: actions.toggleListening
                )

                keyboardButton(usesGlass: usesGlass)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func keyboardButton(usesGlass: Bool) -> some View {
        if usesGlass {
            keyboardButton.buttonStyle(.glass)
        } else {
            keyboardButton.buttonStyle(.bordered)
        }
    }

    private var keyboardButton: some View {
        Button(action: toggleTypedInput) {
            Label(
                isTypedInputPresented ? "文字入力を閉じる" : "文字で入力",
                systemImage: isTypedInputPresented ? "keyboard.chevron.compact.down" : "keyboard"
            )
            .lineLimit(1)
            .frame(minHeight: 44)
        }
        .accessibilityLabel(isTypedInputPresented ? "文字入力を閉じる" : "文字入力を開く")
        .accessibilityValue(isTypedInputPresented ? "開いています" : "閉じています")
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
        if isTypedInputPresented {
            dismissTypedInput()
        } else {
            actions.showTypedInput()
            isTypedInputPresented = true
        }
    }

    private func dismissTypedInput() {
        isTypedInputPresented = false
    }

    private func sendTypedText() {
        guard !state.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.sendTypedText()
        isTypedInputPresented = false
    }
}

#if DEBUG
#Preview("Landscape conversation") {
    ConversationView(
        state: .speaking(caption: "こんにちは。今日はどんなことを話そうか？"),
        actions: .init(
            toggleListening: {},
            showTypedInput: {},
            updateTypedText: { _ in },
            sendTypedText: {},
            performRecovery: { _ in }
        )
    )
}
#endif
