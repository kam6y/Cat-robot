struct ConversationMemoryPresentation {
    let state: ConversationMemoryState
    var message: String? {
        switch state {
        case .unsaved:
            "会話を保存できませんでした。アプリを閉じると、最新の会話を忘れることがあります"
        case .restoreFailed:
            "保存した会話を読み込めませんでした。再試行するか、記憶を消して新しく始められます"
        case .forgetFailed:
            "会話の記憶を削除できませんでした。保存した記憶が残っている可能性があります。削除を再試行してください"
        case .forgetting: "会話の記憶を削除しています"
        case .loading: "前回の会話を準備しています"
        default: nil
        }
    }
    var blocksConversation: Bool {
        switch state {
        case .restoreFailed, .forgetFailed, .forgetting: true
        default: false
        }
    }
    var canRetry: Bool {
        switch state {
        case .unsaved, .restoreFailed, .forgetFailed: true
        default: false
        }
    }
    var supportsForget: Bool { state != .unsupported }
}
