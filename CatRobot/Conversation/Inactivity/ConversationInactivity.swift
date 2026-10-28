import Foundation
import Observation

/// ContinuousClock includes device sleep, unlike the motion controller's uptime clock.
@MainActor
final class ConversationIdleClock: RobotClock {
    private let origin = ContinuousClock.now
    var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
    }
}

enum ConversationInactivityState: Equatable, Sendable {
    case awake, sleepy, sleeping
}

/// Owns inactivity deadlines, independent of audio tasks and SwiftUI update timing.
@MainActor @Observable
final class ConversationInactivity {
    private(set) var state: ConversationInactivityState = .awake
    let settings: ConversationIdleSettings
    @ObservationIgnored var onStateChange: @MainActor () -> Void = {}
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private var lastActivity: TimeInterval?
    @ObservationIgnored private var monitoring = false
    @ObservationIgnored private var phase: ConversationPhase = .idle
    @ObservationIgnored private var hasPendingSpeech = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(settings: ConversationIdleSettings, clock: any RobotClock) {
        self.settings = settings
        self.clock = clock
    }

    deinit { timer?.cancel() }

    func setMonitoring(_ enabled: Bool, phase: ConversationPhase, hasPendingSpeech: Bool = false) {
        monitoring = enabled
        self.phase = phase
        self.hasPendingSpeech = hasPendingSpeech
        if enabled, lastActivity == nil { lastActivity = clock.now }
        evaluate()
    }

    func recordActivity() {
        guard state != .sleeping else { return }
        lastActivity = clock.now
        setState(.awake)
        evaluate()
    }

    /// Called only for an explicit face tap; lifecycle and settings never clear sleeping.
    func wake() {
        lastActivity = clock.now
        setState(.awake)
        evaluate()
    }

    private func setState(_ value: ConversationInactivityState) {
        guard state != value else { return }
        state = value
        onStateChange()
    }

    private func evaluate() {
        generation &+= 1
        timer?.cancel()
        timer = nil
        guard state != .sleeping, monitoring, let lastActivity else { return }
        switch phase {
        case .idle, .listening, .paused, .failed: break
        case .preparing, .classifying, .thinking, .speaking, .clarifying:
            setState(.awake)
            return
        }
        let now = clock.now
        let sleepyAt = lastActivity + Double(settings.sleepyMinutes) * 60
        let sleepingAt = lastActivity + Double(settings.sleepingMinutes) * 60
        if phase == .listening, hasPendingSpeech {
            // Preserve the deadline while the segmenter finishes the current utterance.
            // Its existing 20-second maximum also releases unfinalized recognition.
            setState(now >= sleepyAt ? .sleepy : .awake)
            return
        }
        if now >= sleepingAt {
            setState(.sleeping)
            return
        }
        let isSleepy = now >= sleepyAt
        setState(isSleepy ? .sleepy : .awake)
        let deadline = isSleepy ? sleepingAt : sleepyAt
        let token = generation
        timer = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.evaluate()
        }
    }
}
