import Foundation

struct MotionTurnID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum MotionTurnContext {
    @TaskLocal static var current: MotionTurnID? = nil
}
