import FoundationModels
import XCTest
@testable import CatRobot

@MainActor
final class MotionTurnContextTests: XCTestCase {
    func testSessionToolReceivesEachCallingTurn() async throws {
        let (session, probe) = makeToolProbeSession()
        let a = MotionTurnID(), b = MotionTurnID()
        _ = try await MotionTurnContext.$current.withValue(a) {
            try await session.respond(to: "first")
        }
        _ = try await MotionTurnContext.$current.withValue(b) {
            try await session.respond(to: "second")
        }
        let recorded = await probe.recordedTurns()
        XCTAssertEqual(recorded, [a, b])
    }

    func testMissingScopeDoesNotReusePreviousTurn() async throws {
        let (session, probe) = makeToolProbeSession()
        let turn = MotionTurnID()
        _ = try await MotionTurnContext.$current.withValue(turn) {
            try await session.respond(to: "scoped")
        }
        _ = try await session.respond(to: "unscoped")
        let recorded = await probe.recordedTurns()
        XCTAssertEqual(recorded, [turn, nil])
    }

    func testCancelledLateToolKeepsCapturedTurnWhenNewScopeRuns() async throws {
        let (session, probe) = makeToolProbeSession()
        let old = MotionTurnID(), next = MotionTurnID()
        await probe.holdNextCall()
        let response = Task {
            try await MotionTurnContext.$current.withValue(old) {
                try await session.respond(to: "cancel while tool is suspended")
            }
        }
        try await probe.waitUntilHeld()
        response.cancel()
        await MotionTurnContext.$current.withValue(next) {
            await probe.releaseHeldCall()
            _ = await response.result
        }
        let recorded = await probe.recordedTurns()
        XCTAssertEqual(recorded, [old])
        XCTAssertFalse(recorded.contains(next))
    }
}
