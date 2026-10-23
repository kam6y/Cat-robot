import Foundation

@MainActor
protocol RobotClock: AnyObject {
    var now: TimeInterval { get }
    func sleep(until deadline: TimeInterval) async throws
}

@MainActor
final class SystemRobotClock: RobotClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}
