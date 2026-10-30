import XCTest
@testable import CatRobot

@MainActor
final class ConversationInactivityTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func settings() -> ConversationIdleSettings {
        ConversationIdleSettings(defaults: isolatedDefaults())
    }

    func testActivityGenerationChangesOnlyForAcceptedActivityAndExplicitWake() async {
        let clock = ManualRobotClock()
        let idle = ConversationInactivity(settings: settings(), clock: clock)
        idle.setMonitoring(true, phase: .listening)
        let initial = idle.activityGeneration
        idle.setMonitoring(false, phase: .paused)
        idle.setMonitoring(true, phase: .listening)
        await clock.advance(by: 300)
        XCTAssertEqual(idle.activityGeneration, initial)
        idle.recordActivity()
        XCTAssertEqual(idle.activityGeneration, initial + 1)
        await clock.advance(by: 600)
        idle.recordActivity()
        XCTAssertEqual(idle.activityGeneration, initial + 1, "Ambient activity cannot wake a sleeping cat")
        idle.wake()
        XCTAssertEqual(idle.activityGeneration, initial + 2)
    }

    func testDefaultBoundariesAndSleepIsStickyUntilTapWake() async {
        let clock = ManualRobotClock()
        let idle = ConversationInactivity(settings: settings(), clock: clock)
        idle.setMonitoring(true, phase: .listening)
        await clock.advance(by: 299)
        XCTAssertEqual(idle.state, .awake)
        await clock.advance(by: 1)
        XCTAssertEqual(idle.state, .sleepy)
        await clock.advance(by: 299)
        XCTAssertEqual(idle.state, .sleepy)
        await clock.advance(by: 1)
        XCTAssertEqual(idle.state, .sleeping)
        idle.recordActivity()
        idle.setMonitoring(false, phase: .paused)
        idle.setMonitoring(true, phase: .listening)
        idle.setMonitoring(true, phase: .paused)
        XCTAssertEqual(idle.state, .sleeping)
        idle.wake()
        XCTAssertEqual(idle.state, .awake)
        await clock.advance(by: 300)
        XCTAssertEqual(idle.state, .sleepy)
        idle.setMonitoring(false, phase: .paused)
    }

    func testAcceptedActivityRestartsBothDeadlines() async {
        let clock = ManualRobotClock()
        let idle = ConversationInactivity(settings: settings(), clock: clock)
        idle.setMonitoring(true, phase: .listening)
        await clock.advance(by: 350)
        idle.recordActivity()
        XCTAssertEqual(idle.state, .awake)
        await clock.advance(by: 299)
        XCTAssertEqual(idle.state, .awake)
        await clock.advance(by: 301)
        XCTAssertEqual(idle.state, .sleeping)
    }

    func testBusyTurnDefersStandbyWithoutResettingElapsedTime() async {
        for phase in [ConversationPhase.preparing, .classifying, .thinking, .speaking, .clarifying] {
            let clock = ManualRobotClock()
            let idle = ConversationInactivity(settings: settings(), clock: clock)
            idle.setMonitoring(true, phase: .listening)
            await clock.advance(by: 590)
            idle.setMonitoring(true, phase: phase)
            await clock.advance(by: 50)
            XCTAssertEqual(idle.state, .awake)
            idle.setMonitoring(true, phase: .listening)
            XCTAssertEqual(idle.state, .sleeping)
        }
    }

    func testHiddenTimeIsPreservedAndEvaluatedBeforeResume() async {
        let clock = ManualRobotClock()
        let idle = ConversationInactivity(settings: settings(), clock: clock)
        idle.setMonitoring(true, phase: .listening)
        await clock.advance(by: 100)
        idle.setMonitoring(false, phase: .paused)
        await clock.advance(by: 500)
        XCTAssertNotEqual(idle.state, .sleeping)
        idle.setMonitoring(true, phase: .paused)
        XCTAssertEqual(idle.state, .sleeping)
    }

    func testThresholdChangesReevaluateElapsedTime() async {
        let clock = ManualRobotClock(), settings = settings()
        let idle = ConversationInactivity(settings: settings, clock: clock)
        idle.setMonitoring(true, phase: .listening)
        await clock.advance(by: 180)
        settings.sleepyMinutes = 1
        settings.sleepingMinutes = 2
        idle.setMonitoring(true, phase: .paused)
        XCTAssertEqual(idle.state, .sleeping)
        settings.sleepingMinutes = 20
        idle.setMonitoring(true, phase: .paused)
        XCTAssertEqual(idle.state, .sleeping)
    }

    func testSettingsPersistAndKeepSleepingLaterThanSleepy() {
        let defaults = isolatedDefaults()
        let first = ConversationIdleSettings(defaults: defaults)
        first.sleepyMinutes = 12
        XCTAssertEqual(first.sleepingMinutes, 13)
        first.sleepingMinutes = 4
        XCTAssertEqual(first.sleepyMinutes, 3)
        let restored = ConversationIdleSettings(defaults: defaults)
        XCTAssertEqual(restored.sleepyMinutes, 3)
        XCTAssertEqual(restored.sleepingMinutes, 4)
        restored.sleepyMinutes = -100
        restored.sleepingMinutes = Int.max
        XCTAssertEqual(restored.sleepyMinutes, 1)
        XCTAssertEqual(restored.sleepingMinutes, 1440)
    }
}
