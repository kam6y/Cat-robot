import Accessibility
import SwiftUI

struct ConversationView: View {
    let state: ConversationViewState
    let actions: ConversationActions

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
                ZStack(alignment: .top) {
                    conversationBody

                    if let notice = state.memoryNotice {
                        memoryNoticeBanner(notice)
                            .padding(.top, 8)
                    }
                }
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

    private func memoryNoticeBanner(_ notice: String) -> some View {
        let layout = MemoryNoticePresentation.textLayout
        return Text(notice)
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(
                horizontal: layout.fixedHorizontally,
                vertical: layout.fixedVertically
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(memoryNoticeBackground, in: Capsule())
            .accessibilityLabel(MemoryNoticePresentation.accessibilityLabel)
            .accessibilityValue(notice)
            .allowsHitTesting(MemoryNoticePresentation.allowsHitTesting)
    }

    private var memoryNoticeBackground: AnyShapeStyle {
        switch MemoryNoticePresentation.backgroundStyle(
            reduceTransparency: reduceTransparency
        ) {
        case .opaque:
            AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        case .material:
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
            actions.performTypedInput(.show)
        }
    }

    private func dismissTypedInput() {
        actions.performTypedInput(.dismiss)
    }

    private func sendTypedText() {
        guard !state.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        actions.performTypedInput(.send)
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
