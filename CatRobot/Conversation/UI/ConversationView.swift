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
            // 「新しい会話を始めました」などの短い通知は「…」の左に出す（利用者の要望）。
            if let notice = state.memoryNotice {
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("memoryNotice")
            }
            Menu {
                Button("文字で話しかける", systemImage: "keyboard", action: actions.showTypedInput)
                    .accessibilityIdentifier("showTypedInput")
                Button("設定", systemImage: "gearshape", action: actions.openVoiceSettings)
                    .accessibilityIdentifier("openVoiceSettings")
                Button("新しい会話を始める", systemImage: "arrow.counterclockwise", action: actions.startNewConversation)
                    .accessibilityIdentifier("startNewConversation")
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

    /// 猫そのものが一時停止 / 再開のボタン。画面が前面にある間は聞き取っているので、止めたいときだけ触る。
    private var catArtwork: some View {
        Button(action: actions.toggleListening) {
            CatFaceView(
                state: state.catState,
                mouthPose: state.mouthPose,
                reduceMotion: reduceMotion
            )
        }
        .buttonStyle(.plain)
        .disabled(ConversationMemoryPresentation(state: state.memoryState).blocksConversation)
        .accessibilityLabel(accessibility.listeningAction)
        .accessibilityValue(accessibility.microphoneValue)
        .accessibilityHint(accessibility.listeningHint)
        .accessibilityIdentifier("catListeningToggle")
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

    /// 本文はスクロールし、文字入力欄は開いている間だけ下に固定する。送信しても閉じない。
    private func verticalBody(usesGlass: Bool) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                conversationContent
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            if state.showsTypedInput {
                typedInput(usesGlass: usesGlass)
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
            onDismiss: actions.hideTypedInput
        )
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
