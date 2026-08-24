import Foundation

enum MemoryNoticeBackgroundStyle: Equatable, Sendable {
    case opaque
    case material
}

struct MemoryNoticeTextLayout: Equatable, Sendable {
    let fixedHorizontally: Bool
    let fixedVertically: Bool
}

struct MemoryNoticePresentation: Equatable, Sendable {
    static let accessibilityLabel = "記憶の変更"
    static let allowsHitTesting = false
    static let textLayout = MemoryNoticeTextLayout(
        fixedHorizontally: false,
        fixedVertically: true
    )

    let text: String

    init(change: ReplyMemoryChange) {
        switch change {
        case .remembered:
            text = "記憶しました"
        case .forgotten:
            text = "記憶を削除しました"
        case .updated:
            text = "記憶を更新しました"
        }
    }

    static func backgroundStyle(
        reduceTransparency: Bool
    ) -> MemoryNoticeBackgroundStyle {
        reduceTransparency ? .opaque : .material
    }
}
