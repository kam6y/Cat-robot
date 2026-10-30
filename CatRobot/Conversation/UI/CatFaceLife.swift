import Foundation

struct CatIdleNeckCue: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case idle, yawn }
    let yaw: Double
    let pitch: Double
    var kind: Kind = .idle
}

extension FaceExpression {
    /// 待機の仕草（まばたき・視線・ひげ・あくび）を重ねてよい表情。
    var permitsIdleLife: Bool { self == .neutral || self == .sleepy }
}

struct CatFaceLifeContext: Equatable, Sendable {
    let expression: FaceExpression
    var enabled: Bool
    let activityGeneration: UInt64

    var permitsLife: Bool { enabled && expression.permitsIdleLife }
}

struct CatFaceLifeFrame: Equatable, Sendable {
    var appearance: CatFaceAppearance
    var duration: TimeInterval
    var hold: TimeInterval = 0
    var neckCue: CatIdleNeckCue? = nil
    /// A stagger can start the next keyframe before this interpolation finishes.
    var nextAfter: TimeInterval? = nil
    var waitDuration: TimeInterval { nextAfter ?? duration + hold }
}

struct CatFaceLifeSequence: Sendable {
    enum Kind: String, Sendable { case blink, doubleBlink, slowBlink, glance, whisker, yawn }
    let kind: Kind
    let delay: TimeInterval
    var frames: [CatFaceLifeFrame]
}

/// Sparse keyframes, not a continuous display timer. Randomness only chooses bounded
/// spacing and small variations; presets and speech mouth poses stay untouched.
@MainActor
struct CatFaceLifePlanner {
    /// Neutral sequences left before the next gesture / slow blink.
    private var gestureIn = 4
    private var slowBlinkIn = 12
    private var nextIsGlance = true
    private var direction: Double = 1

    mutating func next(expression: FaceExpression, using random: any RobotRandomSource) -> CatFaceLifeSequence? {
        guard expression.permitsIdleLife else { return nil }
        let base = CatFaceAppearance.preset(expression)
        let sleepy = expression == .sleepy
        let delay = random.next(in: sleepy ? 5...9 : 2.5...7)
        if sleepy {
            return .init(kind: .blink, delay: delay, frames: Self.blink(base, close: 0.18, open: 0.35))
        }
        gestureIn -= 1
        slowBlinkIn -= 1
        if gestureIn <= 0 {
            gestureIn = Int(random.next(in: 4...7))
            defer { nextIsGlance.toggle() }
            if nextIsGlance {
                defer { direction *= -1 }
                var glance = base
                let offset = CGFloat(direction * random.next(in: 0.04...0.07))
                glance.leftEye.pupilCenter.x += offset
                glance.rightEye.pupilCenter.x -= offset
                let vertical = CGFloat(random.next(in: -0.03...0.03))
                glance.leftEye.pupilCenter.y += vertical
                glance.rightEye.pupilCenter.y += vertical
                let lead = random.next(in: 0.3...0.8)
                let hold = random.next(in: 0.8...2)
                let cue = random.next(in: 0...1) < 0.4
                    ? CatIdleNeckCue(yaw: direction * random.next(in: 1...3), pitch: 0) : nil
                var frames: [CatFaceLifeFrame] = [
                    .init(appearance: glance, duration: 0.22, hold: lead - 0.22),
                    .init(appearance: glance, duration: 0, hold: hold, neckCue: cue),
                    .init(appearance: base, duration: 0.45, hold: 0.15)
                ]
                frames += Self.blink(base)
                return .init(kind: .glance, delay: delay, frames: frames)
            }
            var twitch = base
            if random.next(in: 0...1) < 0.5 { twitch.leftWhiskers.lift += 2 }
            else { twitch.rightWhiskers.lift += 2 }
            var frames: [CatFaceLifeFrame] = [
                .init(appearance: twitch, duration: 0.15),
                .init(appearance: base, duration: 0.35)
            ]
            if random.next(in: 0...1) < 0.2 { frames += frames }
            return .init(kind: .whisker, delay: delay, frames: frames)
        }
        if slowBlinkIn <= 0 {
            slowBlinkIn = Int(random.next(in: 12...20))
            return .init(kind: .slowBlink, delay: delay,
                         frames: Self.blink(base, close: 0.35, open: 0.5, depth: 0.65, hold: 0.2))
        }
        var frames = Self.blink(base)
        let isDouble = random.next(in: 0...1) < 0.15
        if isDouble {
            frames[frames.count - 1].hold = 0.25
            frames += Self.blink(base, depth: 0.85)
        }
        return .init(kind: isDouble ? .doubleBlink : .blink, delay: delay, frames: frames)
    }

    static func yawn() -> CatFaceLifeSequence {
        var anticipation = CatFaceAppearance.neutral
        anticipation.updateEyes { eye in
            eye.lid = 0.3
            eye.pupilCenter.y += 0.06
        }
        var shut = anticipation
        shut.updateEyes { eye in
            eye.lid = 1
            eye.closed = 1
        }
        // The peak with the mouth released: the sleepy face with both eyes still shut.
        var release = CatFaceAppearance.yawning
        release.yawn = 0
        return .init(kind: .yawn, delay: 0, frames: [
            .init(appearance: anticipation, duration: 1.2, hold: 0.4),
            // Close before the cheeks rise; keep closed until they settle again.
            .init(appearance: shut, duration: 0.2),
            .init(appearance: .yawning, duration: 0.5, hold: 0.9,
                  neckCue: .init(yaw: 0, pitch: -10, kind: .yawn)),
            .init(appearance: release, duration: 0.7),
            .init(appearance: .sleepy, duration: 0.25, hold: 0.35)
        ])
    }

    private static func blink(_ base: CatFaceAppearance, close: TimeInterval = 0.1,
                              open: TimeInterval = 0.12, depth: CGFloat = 1,
                              hold: TimeInterval = 0.03) -> [CatFaceLifeFrame] {
        var first = base, both = base, opening = base
        first.leftEye.blink = depth
        both.leftEye.blink = depth
        both.rightEye.blink = depth
        opening.rightEye.blink = depth
        return [
            .init(appearance: first, duration: close, nextAfter: 0.03),
            .init(appearance: both, duration: close, hold: hold),
            .init(appearance: opening, duration: open, nextAfter: 0.03),
            .init(appearance: base, duration: open)
        ]
    }
}

/// One sequence per visible context. Generation checks protect new poses and
/// neck cues from old cancelled tasks even when a clock ignores cancellation.
@MainActor
final class CatFaceLifeRunner {
    private let clock: any RobotClock
    private let random: any RobotRandomSource
    private var planner = CatFaceLifePlanner()
    private var previous: CatFaceLifeContext?
    private var yawnedActivity: UInt64?
    private var token = UUID()

    init(clock: any RobotClock = SystemRobotClock(), random: any RobotRandomSource = SystemRobotRandomSource()) {
        self.clock = clock
        self.random = random
    }

    func suspend() {
        token = UUID()
        previous?.enabled = false
    }

    func run(context: CatFaceLifeContext,
             onFrame: @escaping @MainActor (CatFaceLifeFrame) -> Void,
             onNeck: @escaping @MainActor (CatIdleNeckCue) -> Void) async {
        let old = previous
        previous = context
        let generation = UUID()
        token = generation
        let base = CatFaceAppearance.preset(context.expression)
        guard context.permitsLife else {
            onFrame(.init(appearance: base, duration: 0))
            return
        }
        // One yawn per activity episode, only on a visible neutral → sleepy transition.
        let shouldYawn = context.expression == .sleepy
            && old?.permitsLife == true && old?.expression == .neutral
            && old?.activityGeneration == context.activityGeneration
            && yawnedActivity != context.activityGeneration
        defer {
            if token == generation { onFrame(.init(appearance: base, duration: 0.25)) }
        }
        do {
            if shouldYawn {
                yawnedActivity = context.activityGeneration
                try await play(CatFaceLifePlanner.yawn(), token: generation, onFrame: onFrame, onNeck: onNeck)
            } else {
                onFrame(.init(appearance: base, duration: 0.25))
            }
            while token == generation, !Task.isCancelled {
                guard let sequence = planner.next(expression: context.expression, using: random) else { return }
                try await play(sequence, token: generation, onFrame: onFrame, onNeck: onNeck)
            }
        } catch { /* Cancellation restores the current preset, never a queued gesture. */ }
    }

    private func play(_ sequence: CatFaceLifeSequence, token generation: UUID,
                      onFrame: @MainActor (CatFaceLifeFrame) -> Void,
                      onNeck: @MainActor (CatIdleNeckCue) -> Void) async throws {
        try await clock.sleep(until: clock.now + sequence.delay)
        for frame in sequence.frames {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            onFrame(frame)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if let cue = frame.neckCue { onNeck(cue) }
            try await clock.sleep(until: clock.now + frame.waitDuration)
        }
    }
}
