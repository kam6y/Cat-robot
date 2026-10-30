import SwiftUI
import XCTest
@testable import CatRobot

@MainActor
final class CatFaceLifeTests: XCTestCase {
    func testPlannerLeavesQuietIntervalsAndNeverMovesMouthOutsideYawn() {
        var planner = CatFaceLifePlanner()
        let random = ScriptedRobotRandom()
        var kinds = Set<String>()
        var lastGesture = -100
        var lastDirection: CGFloat?
        for index in 0..<100 {
            let sequence = planner.next(expression: .neutral, using: random)!
            XCTAssertTrue((2.5...7).contains(sequence.delay))
            kinds.insert(sequence.kind.rawValue)
            for frame in sequence.frames {
                XCTAssertEqual(frame.appearance.yawn, 0)
                XCTAssertEqual(frame.appearance.mouthWidth, CatFaceAppearance.neutral.mouthWidth)
                if let cue = frame.neckCue {
                    XCTAssertLessThanOrEqual(abs(cue.yaw), 3)
                    XCTAssertLessThanOrEqual(abs(cue.pitch), 2)
                }
            }
            if sequence.kind == .glance || sequence.kind == .whisker {
                XCTAssertGreaterThanOrEqual(index - lastGesture, 4, "Do not fill every interval with a gesture")
                lastGesture = index
            }
            if sequence.kind == .glance {
                let direction = sequence.frames[0].appearance.leftEye.pupilCenter.x - CatFaceAppearance.neutral.leftEye.pupilCenter.x
                if let lastDirection { XCTAssertLessThan(direction * lastDirection, 0) }
                lastDirection = direction
                let neckIndex = sequence.frames.firstIndex { $0.neckCue != nil }!
                let lead = sequence.frames[..<neckIndex].reduce(0) { $0 + $1.duration + $1.hold }
                XCTAssertGreaterThanOrEqual(lead, 0.3)
            }
            XCTAssertEqual(sequence.frames.last?.appearance, .neutral)
        }
        XCTAssertTrue(kinds.contains("glance"))
        XCTAssertTrue(kinds.contains("whisker"))
        XCTAssertTrue(kinds.contains("slowBlink"))
    }

    func testBothSleepyEyelidsUseSlowDurationsWithOnlyThirtyMillisecondsStagger() async {
        let h = LifeHarness()
        await h.start(expression: .sleepy)
        await h.clock.advance(by: 5)
        XCTAssertEqual(h.frames.last?.duration, 0.18)
        await h.clock.advance(by: 0.03)
        XCTAssertEqual(h.frames.last?.appearance.rightEye.blink, 1, "Right eyelid must start after 30 ms")
        XCTAssertEqual(h.frames.last?.duration, 0.18, "The second eye must not snap in 30 ms")
        await h.clock.advance(by: 0.21)
        XCTAssertEqual(h.frames.last?.duration, 0.35)
        await h.clock.advance(by: 0.03)
        XCTAssertEqual(h.frames.last?.appearance.rightEye.blink, 0)
        XCTAssertEqual(h.frames.last?.duration, 0.35, "Both eyelids open slowly")
        await h.stop()
    }

    func testGlanceNeckOnsetIncludesEyeTravelAndStaysInsideEightTenths() {
        var planner = CatFaceLifePlanner()
        let random = UpperBoundWithCueRandom()
        var glance: CatFaceLifeSequence?
        for _ in 0..<8 {
            let sequence = planner.next(expression: .neutral, using: random)!
            if sequence.kind == .glance { glance = sequence; break }
        }
        let sequence = glance!
        let cueIndex = sequence.frames.firstIndex { $0.neckCue != nil }!
        let lead = sequence.frames[..<cueIndex].reduce(0) { $0 + $1.duration + $1.hold }
        XCTAssertLessThanOrEqual(lead, 0.8)
        XCTAssertGreaterThanOrEqual(lead, 0.3)
    }

    func testSleepyBlinkIsSlowerAndOtherExpressionsDoNotGetDecorations() {
        var planner = CatFaceLifePlanner()
        let sequence = planner.next(expression: .sleepy, using: ScriptedRobotRandom())!
        XCTAssertTrue((5...9).contains(sequence.delay))
        XCTAssertGreaterThanOrEqual(sequence.frames.first!.duration, 0.18)
        XCTAssertEqual(sequence.frames.last?.appearance, .sleepy)
        XCTAssertNil(planner.next(expression: .speaking, using: ScriptedRobotRandom()))
        XCTAssertNil(planner.next(expression: .sleeping, using: ScriptedRobotRandom()))
    }

    func testYawnHasClosedEyesLargeMouthAndReturnsToSleepyInFourPointFiveSeconds() {
        let sequence = CatFaceLifePlanner.yawn()
        XCTAssertEqual(sequence.frames.reduce(0) { $0 + $1.duration + $1.hold }, 4.5, accuracy: 0.001)
        XCTAssertTrue(sequence.frames.contains { $0.appearance == .yawning })
        XCTAssertEqual(sequence.frames.last?.appearance, .sleepy)
        XCTAssertEqual(CatFaceAppearance.yawning.yawn, 1)
    }

    func testYawnWhiskersNeverCrossVisibleEyesThroughoutActualKeyframeTweens() {
        var previous = CatFaceAppearance.neutral
        for (index, frame) in CatFaceLifePlanner.yawn().frames.enumerated() {
            assertNoEyeWhiskerIntersection(from: previous, to: frame.appearance, label: "frame \(index)")
            previous = frame.appearance
        }
    }

    func testInterruptedYawnDoesNotCrossVisibleEyesOnTheWayToAnyExpression() {
        for expression in FaceExpression.allCases {
            assertNoEyeWhiskerIntersection(from: .yawning, to: .preset(expression), label: "interrupt → \(expression)")
        }
    }

    private func assertNoEyeWhiskerIntersection(from start: CatFaceAppearance, to end: CatFaceAppearance,
                                               label: String, file: StaticString = #filePath, line: UInt = #line) {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        for step in 0...100 {
            let fraction = Double(step) / 100
            let appearance = start.interpolated(toward: end, fraction: fraction)
            for side in CatFaceSide.allCases {
                let eye = CatFaceGeometry.eye(side: side, appearance: appearance)
                let iris = eye.outline.path(in: rect).cgPath.subtracting(eye.lid.path(in: rect).cgPath)
                if appearance.eye(side).lid < 0.8 {
                    XCTAssertFalse(iris.isEmpty, "\(label): an open eye must leave a visible region", file: file, line: line)
                }
                for lineScale in [CGFloat(1), 1.35] {
                    for whisker in CatFaceGeometry.whiskers(side: side, appearance: appearance, lineScale: lineScale) {
                        XCTAssertTrue(iris.intersection(whisker.path(in: rect).cgPath).isEmpty,
                                      "\(label) at \(fraction), \(side), x\(lineScale): whisker crosses exposed eye", file: file, line: line)
                    }
                }
            }
        }
    }

    func testInitialSleepyAndDisabledContextsNeverYawnOrScheduleWhenDisabled() async {
        let h = LifeHarness()
        await h.start(expression: .sleepy, enabled: true)
        await h.clock.advance(by: 9)
        XCTAssertFalse(h.frames.contains { $0.appearance.yawn > 0 })
        await h.start(expression: .sleepy, enabled: false)
        XCTAssertEqual(h.clock.pendingSleepCount, 0)
        await h.start(expression: .sleepy, enabled: true)
        XCTAssertFalse(h.frames.contains { $0.appearance.yawn > 0 })
        await h.stop()
    }

    func testVisibleSleepyTransitionYawnsOnlyOncePerActivityEpisode() async {
        let h = LifeHarness()
        await h.start(expression: .neutral)
        await h.start(expression: .sleepy)
        await h.clock.advance(by: 1.6)
        await h.clock.advance(by: 0.2)
        XCTAssertEqual(h.frames.last?.appearance.yawn, 1)
        await h.clock.advance(by: 1.4)
        await h.clock.advance(by: 1.3)
        XCTAssertEqual(h.frames.last?.appearance, .sleepy)
        let count = h.frames.filter { $0.appearance.yawn == 1 }.count
        await h.start(expression: .neutral)
        await h.start(expression: .sleepy)
        await h.clock.advance(by: 1.8)
        XCTAssertEqual(h.frames.filter { $0.appearance.yawn == 1 }.count, count)
        await h.start(expression: .neutral, generation: 2)
        await h.start(expression: .sleepy, generation: 2)
        await h.clock.advance(by: 1.6)
        await h.clock.advance(by: 0.2)
        XCTAssertEqual(h.frames.filter { $0.appearance.yawn == 1 }.count, count + 1)
        await h.stop()
    }

    func testDisappearanceAndReturnDoNotReplayAnUnseenSleepyTransition() async {
        let h = LifeHarness()
        await h.start(expression: .neutral)
        h.runner.suspend()
        await h.start(expression: .sleepy)
        await h.clock.advance(by: 2)
        XCTAssertFalse(h.frames.contains { $0.appearance.yawn > 0 })
        XCTAssertTrue(h.cues.isEmpty)
        await h.stop()
    }

    func testCancelledClockContinuationCannotRestoreOldPoseOrSendCue() async {
        let clock = NonCooperativeLifeClock()
        let runner = CatFaceLifeRunner(clock: clock, random: ScriptedRobotRandom())
        var frames: [CatFaceLifeFrame] = []
        var cues: [CatIdleNeckCue] = []
        let awake = Task { await runner.run(context: .init(expression: .neutral, enabled: true, activityGeneration: 1),
            onFrame: { frames.append($0) }, onNeck: { cues.append($0) }) }
        await robotDrain()
        awake.cancel()
        let sleepy = Task { await runner.run(context: .init(expression: .sleepy, enabled: true, activityGeneration: 1),
            onFrame: { frames.append($0) }, onNeck: { cues.append($0) }) }
        await robotDrain()
        sleepy.cancel()
        await runner.run(context: .init(expression: .speaking, enabled: false, activityGeneration: 1),
            onFrame: { frames.append($0) }, onNeck: { cues.append($0) })
        let count = frames.count
        await clock.advance(by: 30)
        await awake.value
        await sleepy.value
        XCTAssertEqual(frames.count, count)
        XCTAssertEqual(frames.last?.appearance, .speaking)
        XCTAssertTrue(cues.isEmpty)
    }

    func testInterruptionDropsLateNeckCueAndRestoresCurrentExpression() async {
        let h = LifeHarness()
        await h.start(expression: .neutral)
        await h.start(expression: .sleepy)
        await h.clock.advance(by: 1)
        await h.start(expression: .thinking, enabled: false)
        let count = h.frames.count
        await h.clock.advance(by: 20)
        XCTAssertEqual(h.frames.count, count)
        XCTAssertEqual(h.frames.last?.appearance, .thinking)
        XCTAssertTrue(h.cues.isEmpty)
        XCTAssertEqual(h.clock.pendingSleepCount, 0)
        await h.stop()
    }
}

@MainActor
private final class LifeHarness {
    let clock = ManualRobotClock()
    lazy var runner = CatFaceLifeRunner(clock: clock, random: ScriptedRobotRandom())
    var frames: [CatFaceLifeFrame] = []
    var cues: [CatIdleNeckCue] = []
    var task: Task<Void, Never>?

    func start(expression: FaceExpression, enabled: Bool = true, generation: UInt64 = 1) async {
        task?.cancel()
        let context = CatFaceLifeContext(expression: expression, enabled: enabled, activityGeneration: generation)
        task = Task {
            await runner.run(context: context, onFrame: { self.frames.append($0) }, onNeck: { self.cues.append($0) })
        }
        await robotDrain()
    }
    func stop() async {
        task?.cancel()
        await task?.value
        await robotDrain()
    }
}


@MainActor
private final class UpperBoundWithCueRandom: RobotRandomSource {
    func next(in range: ClosedRange<Double>) -> Double {
        range == 0...1 ? 0 : range.upperBound
    }
}


@MainActor
private final class NonCooperativeLifeClock: RobotClock {
    var now: TimeInterval = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func sleep(until deadline: TimeInterval) async throws {
        guard deadline > now else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func advance(by interval: TimeInterval) async {
        now += interval
        let due = continuations
        continuations.removeAll()
        for continuation in due { continuation.resume() }
        await robotDrain()
    }
}
