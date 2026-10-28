import SwiftUI

enum ConversationListeningSemantic: Equatable {
    case resume
    case pause
    case wake

    var actionLabel: String {
        switch self {
        case .resume:
            "聞き取りを再開"
        case .pause:
            "聞き取りを一時停止"
        case .wake:
            "猫を起こす"
        }
    }

    var hint: String {
        switch self {
        case .resume:
            "マイクの聞き取りを再開します"
        case .pause:
            "マイクの聞き取りを停止します"
        case .wake:
            "タップして会話を再開します"
        }
    }
}

struct ConversationAccessibility: Equatable {
    let listeningSemantic: ConversationListeningSemantic
    let microphoneValue: String

    var listeningAction: String { listeningSemantic.actionLabel }
    var listeningHint: String { listeningSemantic.hint }

    init(phase: ConversationPhase, inactivity: ConversationInactivityState = .awake) {
        if inactivity == .sleeping {
            listeningSemantic = .wake
            microphoneValue = "停止中"
            return
        }
        switch phase {
        case .idle, .paused, .failed:
            listeningSemantic = .resume
        default:
            listeningSemantic = .pause
        }

        switch phase {
        case .idle:
            microphoneValue = "待機中"
        case .preparing:
            microphoneValue = "準備中"
        case .listening:
            microphoneValue = "聞き取り中"
        case .classifying, .clarifying, .thinking, .speaking:
            microphoneValue = "一時休止中"
        case .paused:
            microphoneValue = "一時停止中"
        case .failed:
            microphoneValue = "待機中"
        }
    }
}

enum ConversationPresentationPolicy {
    static let isStatusBarHidden = false
}

enum ConversationAnnouncementPolicy {
    static func announcement(
        from oldState: ConversationViewState,
        to newState: ConversationViewState
    ) -> String? {
        if newState.isSleeping && !oldState.isSleeping { return newState.displayedActivityStatus }
        if oldState.memoryState != newState.memoryState,
           let message = ConversationMemoryPresentation(state: newState.memoryState).message {
            return message
        }
        if let notice = newState.memoryNotice, notice != oldState.memoryNotice { return notice }
        if let error = newState.errorMessage,
           oldState.errorMessage != newState.errorMessage
            || oldState.recoveries != newState.recoveries {
            let recoveryTitles = newState.recoveries.map(\.title)
            guard !recoveryTitles.isEmpty else { return error }
            return "\(error)。利用できる操作。\(recoveryTitles.joined(separator: "、"))"
        }

        if newState.isLooking && !oldState.isLooking { return "見ています" }

        if oldState.phase == .speaking,
           newState.phase == .listening,
           !newState.caption.isEmpty {
            return "猫の返事。\(newState.caption)"
        }

        if oldState.phase != newState.phase || oldState.activityStatus != newState.activityStatus,
           !newState.activityStatus.isEmpty {
            return newState.activityStatus
        }

        // The robot status is a connection-only projection, so an angle update never reaches here.
        if oldState.robotStatus != newState.robotStatus { return newState.robotStatus?.message }

        return nil
    }
}
