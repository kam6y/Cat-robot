import SwiftUI

enum ConversationListeningSemantic: Equatable {
    case resume
    case pause

    var actionLabel: String {
        switch self {
        case .resume:
            "聞き取りを再開"
        case .pause:
            "聞き取りを一時停止"
        }
    }

    var symbol: String {
        switch self {
        case .resume:
            "mic.fill"
        case .pause:
            "pause.fill"
        }
    }

    var hint: String {
        switch self {
        case .resume:
            "マイクの聞き取りを再開します"
        case .pause:
            "マイクの聞き取りを停止します"
        }
    }
}

struct ConversationAccessibility: Equatable {
    let listeningSemantic: ConversationListeningSemantic
    let microphoneValue: String
    let assistantStatus: String

    var listeningAction: String { listeningSemantic.actionLabel }
    var listeningSymbol: String { listeningSemantic.symbol }
    var listeningHint: String { listeningSemantic.hint }

    init(phase: ConversationPhase) {
        switch phase {
        case .idle, .paused, .failed:
            listeningSemantic = .resume
        default:
            listeningSemantic = .pause
        }

        switch phase {
        case .idle:
            microphoneValue = "待機中"
            assistantStatus = "待機しています"
        case .preparing:
            microphoneValue = "準備中"
            assistantStatus = "準備しています"
        case .listening:
            microphoneValue = "聞き取り中"
            assistantStatus = "話しかけてください"
        case .classifying:
            microphoneValue = "一時休止中"
            assistantStatus = "呼びかけを確認しています"
        case .clarifying:
            microphoneValue = "再開中"
            assistantStatus = "聞き返しています"
        case .thinking:
            microphoneValue = "一時休止中"
            assistantStatus = "考えています"
        case .speaking:
            microphoneValue = "一時休止中"
            assistantStatus = "話しています"
        case .paused:
            microphoneValue = "一時停止中"
            assistantStatus = "一時停止しています"
        case .failed:
            microphoneValue = "待機中"
            assistantStatus = "エラーが発生しました"
        }
    }
}

enum ConversationLowerControlsLayout: Equatable {
    case horizontalFirst
    case stacked

    static func preferred(for dynamicTypeSize: DynamicTypeSize) -> Self {
        dynamicTypeSize.isAccessibilitySize ? .stacked : .horizontalFirst
    }
}

enum ConversationAnnouncementPolicy {
    static func announcement(
        from oldState: ConversationViewState,
        to newState: ConversationViewState
    ) -> String? {
        if let error = newState.errorMessage,
           oldState.errorMessage != newState.errorMessage
            || oldState.recoveries != newState.recoveries {
            let recoveryTitles = newState.recoveries.map(\.title)
            guard !recoveryTitles.isEmpty else { return error }
            return "\(error)。利用できる操作。\(recoveryTitles.joined(separator: "、"))"
        }

        if oldState.phase == .speaking,
           newState.phase != .speaking,
           !newState.caption.isEmpty {
            return "猫の返事。\(newState.caption)"
        }

        if oldState.phase != newState.phase
            || oldState.activityStatus != newState.activityStatus {
            return newState.activityStatus.isEmpty ? nil : newState.activityStatus
        }

        return nil
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
            Label(labels.listeningAction, systemImage: labels.listeningSymbol)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(labels.listeningAction)
        .accessibilityValue(labels.microphoneValue)
        .accessibilityHint(labels.listeningHint)
    }
}
