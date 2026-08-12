import SwiftUI

struct ConversationAccessibility: Equatable {
    let listeningAction: String
    let microphoneValue: String
    let assistantStatus: String

    init(phase: ConversationPhase) {
        switch phase {
        case .idle:
            listeningAction = "聞き取りを再開"
            microphoneValue = "待機中"
            assistantStatus = "待機しています"
        case .preparing:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "準備中"
            assistantStatus = "準備しています"
        case .listening:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "聞き取り中"
            assistantStatus = "話しかけてください"
        case .classifying:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "一時休止中"
            assistantStatus = "呼びかけを確認しています"
        case .clarifying:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "再開中"
            assistantStatus = "聞き返しています"
        case .thinking:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "一時休止中"
            assistantStatus = "考えています"
        case .speaking:
            listeningAction = "聞き取りを一時停止"
            microphoneValue = "一時休止中"
            assistantStatus = "話しています"
        case .paused:
            listeningAction = "聞き取りを再開"
            microphoneValue = "一時停止中"
            assistantStatus = "一時停止しています"
        case .failed:
            listeningAction = "聞き取りを再開"
            microphoneValue = "待機中"
            assistantStatus = "エラーが発生しました"
        }
    }
}

struct ListeningControl: View {
    let phase: ConversationPhase
    let usesGlass: Bool
    let action: () -> Void

    private var labels: ConversationAccessibility {
        ConversationAccessibility(phase: phase)
    }

    var body: some View {
        if usesGlass {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(labels.listeningAction, systemImage: phase == .paused ? "mic.fill" : "pause.fill")
                .lineLimit(1)
                .frame(minHeight: 44)
        }
        .accessibilityLabel(labels.listeningAction)
        .accessibilityValue(labels.microphoneValue)
        .accessibilityHint(phase == .paused ? "マイクの聞き取りを再開します" : "マイクの聞き取りを停止します")
    }
}
