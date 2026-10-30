import Accessibility
import SwiftUI

/// 会話中は顔と左上の聞き取り状態を見せ、必要に応じて他のチップと下部のお知らせを出す。
/// 返事の字幕や状態の文字は描かない（値は保存と VoiceOver の読み上げのために状態に残っている）。
struct ConversationView: View {
    /// 顔の枠は、会話画面（safe area を含む全画面）の幅・高さそれぞれの80%。
    static let faceScale: CGFloat = 0.80
    private static let contentInset: CGFloat = 16
    private static let menuSize: CGFloat = 44
    private static let menuTrailingInset: CGFloat = 12
    private static var chipMenuClearance: CGFloat { menuTrailingInset + menuSize + 8 }

    let state: ConversationViewState
    let actions: ConversationActions
    var isOpeningVoiceSettings = false
    var isFaceLifeVisible = true
    @State private var faceLife = CatFaceLifeRunner()
    @State private var lifeAppearance: CatFaceAppearance?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    private var accessibility: ConversationAccessibility {
        ConversationAccessibility(phase: state.phase, inactivity: state.inactivity)
    }

    private var lifeContext: CatFaceLifeContext {
        .init(expression: state.faceExpression,
              enabled: state.allowsIdleFaceLife && isFaceLifeVisible && !isOpeningVoiceSettings
                  && scenePhase == .active && !reduceMotion,
              activityGeneration: state.activityGeneration)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            conversationBody
        }
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .statusBarHidden(ConversationPresentationPolicy.isStatusBarHidden)
        .task(id: lifeContext) {
            let context = lifeContext
            actions.cancelIdleFaceMotion()
            await faceLife.run(context: context, onFrame: { frame in
                withAnimation(frame.duration > 0 ? .easeInOut(duration: frame.duration) : nil) {
                    lifeAppearance = frame.appearance
                }
            }, onNeck: { cue in actions.idleFaceMotion(cue) })
        }
        .onDisappear {
            faceLife.suspend()
            actions.cancelIdleFaceMotion()
        }
        .onChange(of: state) { oldState, newState in
            guard let announcement = ConversationAnnouncementPolicy.announcement(from: oldState, to: newState) else { return }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    /// 大きい文字・エラー・記憶カードでは、内容を縦に並べてスクロールさせる。
    private var prioritizesContent: Bool {
        dynamicTypeSize.isAccessibilitySize || state.errorMessage != nil
            || ConversationMemoryPresentation(state: state.memoryState).message != nil
    }

    @ViewBuilder
    private var conversationBody: some View {
        if reduceTransparency {
            layout(usesGlass: false)
        } else {
            GlassEffectContainer(spacing: 12) {
                layout(usesGlass: true)
            }
        }
    }

    @ViewBuilder
    private func layout(usesGlass: Bool) -> some View {
        if prioritizesContent || state.displaysTypedInput {
            contentLayout(usesGlass: usesGlass)
        } else {
            faceLayout
        }
    }

    /// 通常: 全画面の80%の枠に顔を描き、safe area の水平中央・画面の垂直中央に置く。
    /// 顔サイズ調整ツールの FaceSizePreview も同じ配置式を使うため、式を変えるときは両方を更新する。
    /// safe area の中で測り、全画面の寸法は大きさに safe area を足して求める（safe area を無視すると insets が 0 になる）。
    private var faceLayout: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            catArtwork
                .frame(width: (proxy.size.width + insets.leading + insets.trailing) * Self.faceScale,
                       height: (proxy.size.height + insets.top + insets.bottom) * Self.faceScale)
                .position(x: proxy.size.width / 2, y: (proxy.size.height + insets.bottom - insets.top) / 2)
        }
        .overlay(alignment: .topLeading) { overlaidChips }
        .overlay(alignment: .topTrailing) { topTrailingMenu }
        .overlay(alignment: .bottom) {
            if let notice = state.memoryNotice {
                noticeView(notice).padding(.horizontal, Self.contentInset).padding(.bottom, 7)
            }
        }
    }

    /// 入力欄は同じ位置のビューとして保ち、カードや利用可能な高さに応じて上側だけを切り替える。
    /// 非同期のエラー・記憶警告でも選択範囲を失わず、入力欄の自動フォーカスをやり直さない。
    private func contentLayout(usesGlass: Bool) -> some View {
        VStack(spacing: prioritizesContent ? 8 : 12) {
            if prioritizesContent {
                contentFirstUpperContent
            } else {
                ViewThatFits(in: .vertical) {
                    typedUpperContent(scrolls: false)
                    ScrollView {
                        typedUpperContent(scrolls: true)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            if state.displaysTypedInput {
                typedInput(usesGlass: usesGlass)
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.top, prioritizesContent ? 8 : 0)
        .padding(.bottom, 8)
        .overlay(alignment: .topTrailing) {
            if !prioritizesContent {
                topTrailingMenu
            }
        }
    }

    private func typedUpperContent(scrolls: Bool) -> some View {
        VStack(spacing: 12) {
            if !state.statusChips.isEmpty {
                ConversationStatusChipsView(chips: state.statusChips)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, Self.chipMenuClearance - Self.contentInset)
                    .padding(.top, 10)
            }
            if scrolls {
                catArtwork.frame(height: 120)
            } else {
                catArtwork
                    .frame(maxWidth: .infinity, minHeight: 44, idealHeight: 44, maxHeight: .infinity)
                    .padding(.top, state.statusChips.isEmpty ? 18 : 0)
            }
            if let notice = state.memoryNotice { noticeView(notice) }
        }
        .frame(maxWidth: .infinity)
    }

    /// 大きい文字・エラー・記憶カード: チップと「…」、お知らせ、顔、カードを上側でスクロールさせる。
    private var contentFirstUpperContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ConversationStatusChipsView(chips: state.statusChips)
                    Spacer(minLength: 0)
                    menuButton
                }
                if let notice = state.memoryNotice { noticeView(notice) }
                catArtwork.frame(height: 120)
                cards
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// 左上（safe area + 16pt、上10pt）。「…」ボタンに重ならない幅で、入りきらなければ縦に積む。
    private var overlaidChips: some View {
        ConversationStatusChipsView(chips: state.statusChips)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.contentInset)
            .padding(.trailing, Self.chipMenuClearance)
            .padding(.top, 10)
    }

    private var topTrailingMenu: some View {
        menuButton.padding(.trailing, Self.menuTrailingInset).padding(.top, 4)
    }

    private var menuButton: some View {
        Menu {
            Button("文字で話しかける", systemImage: "keyboard", action: actions.showTypedInput)
                .accessibilityIdentifier("showTypedInput")
                .disabled(state.isSleeping)
            Button("設定", systemImage: "gearshape", action: actions.openVoiceSettings)
                .accessibilityIdentifier("openVoiceSettings")
            Button("新しい会話を始める", systemImage: "arrow.counterclockwise", action: actions.startNewConversation)
                .accessibilityIdentifier("startNewConversation")
                .disabled(state.isSleeping)
        } label: {
            Image(systemName: "ellipsis.circle").frame(minWidth: Self.menuSize, minHeight: Self.menuSize)
        }
        .accessibilityLabel("会話の設定")
        .accessibilityIdentifier("conversationSettings")
        .disabled(state.memoryState == .forgetting || isOpeningVoiceSettings)
    }

    /// 猫そのものが一時停止 / 再開のボタン。画面が前面にある間は聞き取っているので、止めたいときだけ触る。
    private var catArtwork: some View {
        Button(action: actions.toggleListening) {
            CatFaceView(
                expression: state.faceExpression,
                mouthPose: state.mouthPose,
                reduceMotion: reduceMotion,
                appearanceOverride: lifeContext.permitsLife ? lifeAppearance : nil
            )
        }
        .buttonStyle(.plain)
        .disabled(ConversationMemoryPresentation(state: state.memoryState).blocksConversation)
        .accessibilityLabel(accessibility.listeningAction)
        .accessibilityValue(accessibility.microphoneValue)
        .accessibilityHint(accessibility.listeningHint)
        .accessibilityIdentifier("catListeningToggle")
        .accessibilityCustomContent(AccessibilityCustomContentKey("猫の返事"), state.accessibleReply.map { Text($0) })
    }

    private func noticeView(_ notice: String) -> some View {
        Text(notice)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.contentInset)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .accessibilityIdentifier("memoryNotice")
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
