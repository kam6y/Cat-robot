import XCTest
@testable import CatRobot

@MainActor
final class MotionControllerSpy: RobotMotionControlling {
    var reservationResult: MotionReservationResult = .reserved(cycles: 1)
    var begins: [MotionTurnID] = []
    var reservations: [(request: RobotMotionRequest, turn: MotionTurnID)] = []
    var speechStarts: [MotionTurnID] = []
    var speechEnds: [MotionTurnID] = []
    var generations: [(turn: MotionTurnID, succeeded: Bool)] = []
    var cancellations: [(turn: MotionTurnID, reason: MotionCancellationReason)] = []
    var onGeneration: (() -> Void)?
    var controlModes: [RobotControlMode] = []
    var phases: [ConversationPhase] = []
    var confirmations = 0
    var trackingStates: [RobotTrackingState] = []
    var automaticSuspensions: [Bool] = []
    func beginTurn(_ id: MotionTurnID) { begins.append(id) }
    func reserve(_ request: RobotMotionRequest, for id: MotionTurnID) -> MotionReservationResult {
        reservations.append((request, id)); return reservationResult
    }
    func speechStarted(_ id: MotionTurnID) { speechStarts.append(id) }
    func speechFinished(_ id: MotionTurnID) { speechEnds.append(id) }
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
        switch outcome { case .success: generations.append((id, true)); case .failed: generations.append((id, false)) }
        onGeneration?()
    }
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) { cancellations.append((id, reason)) }
    func setControlMode(_ mode: RobotControlMode) { controlModes.append(mode) }
    func setConversationPhase(_ phase: ConversationPhase) { phases.append(phase) }
    func utteranceConfirmed() { confirmations += 1 }
    func stopAll(reason: MotionCancellationReason) {}
    func setTrackingState(_ state: RobotTrackingState) { trackingStates.append(state) }
    func setAutomaticMotionSuspended(_ suspended: Bool) { automaticSuspensions.append(suspended) }
}

@MainActor
final class MoveHeadToolTests: XCTestCase {
    func testAllSevenGesturesAndThreeIntensitiesParseOnceAndReserveImmediately() async throws {
        let spy = MotionControllerSpy()
        let tool = MoveHeadTool(motion: spy)
        let turn = MotionTurnID()
        XCTAssertEqual(tool.name, "move_head")
        for gesture in RobotGesture.allCases {
            for intensity in RobotIntensity.allCases {
                let result = try await MotionTurnContext.$current.withValue(turn) {
                    try await tool.call(arguments: .init(gesture: gesture.rawValue.uppercased(), intensity: intensity.rawValue, repeats: nil))
                }
                XCTAssertTrue(result.contains("1回予約しました"))
                XCTAssertEqual(spy.reservations.last?.request, .init(gesture: gesture, intensity: intensity, repeats: 1))
                XCTAssertEqual(spy.reservations.last?.turn, turn)
            }
        }
        XCTAssertEqual(spy.reservations.count, 21)
        XCTAssertTrue(spy.speechStarts.isEmpty)
    }

    func testInvalidValuesAndRepeatBoundsNeverReachMotion() async throws {
        let spy = MotionControllerSpy()
        let tool = MoveHeadTool(motion: spy)
        let turn = MotionTurnID()
        for arguments in [MoveHeadTool.Arguments(gesture: "unknown", intensity: "small", repeats: 1),
                          .init(gesture: "nod", intensity: "unknown", repeats: 1),
                          .init(gesture: "nod", intensity: "small", repeats: 0),
                          .init(gesture: "nod", intensity: "small", repeats: 4)] {
            let result = try await MotionTurnContext.$current.withValue(turn) { try await tool.call(arguments: arguments) }
            XCTAssertFalse(result.contains("予約しました"))
        }
        XCTAssertTrue(spy.reservations.isEmpty)
    }

    func testMissingScopeCannotReusePreviousTurn() async throws {
        let spy = MotionControllerSpy()
        let tool = MoveHeadTool(motion: spy)
        _ = try await MotionTurnContext.$current.withValue(MotionTurnID()) {
            try await tool.call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
        }
        let result = try await tool.call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
        XCTAssertFalse(result.contains("予約しました"))
        XCTAssertEqual(spy.reservations.count, 1)
    }

    func testToolReturnsAReservationWithoutWaitingForSpeech() async throws {
        let h = MotionHarness()
        let turn = MotionTurnID()
        h.motion.beginTurn(turn)
        let result = try await MotionTurnContext.$current.withValue(turn) {
            try await MoveHeadTool(motion: h.motion).call(arguments: .init(gesture: "nod", intensity: "large", repeats: 1))
        }
        XCTAssertEqual(result, "頷く動作を1回予約しました")
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testCancelledOldToolCannotReserveForNextTurn() async throws {
        let h = MotionHarness()
        let tool = MoveHeadTool(motion: h.motion)
        let old = MotionTurnID(), next = MotionTurnID()
        h.motion.beginTurn(old)
        let gate = ConversationTestGate()
        let lateCall = Task {
            try await MotionTurnContext.$current.withValue(old) {
                await gate.wait()
                return try await tool.call(arguments: .init(gesture: "nod", intensity: "large", repeats: 1))
            }
        }
        await gate.waitUntilEntered()
        h.motion.beginTurn(next)
        await gate.open()
        let result = try await lateCall.value
        XCTAssertEqual(result, "この返答の動作予約は取り消されました")
        h.motion.speechStarted(next)
        await h.drain()
        XCTAssertTrue(h.sentCommands.isEmpty)
    }

    func testReservationFailuresHaveShortDistinctResultsAndProviderKeepsRemember() async throws {
        let spy = MotionControllerSpy()
        let provider = RobotConversationToolProvider(motion: spy)
        let tools = provider.tools(memory: RememberToolTests.Writer())
        XCTAssertEqual(tools.map(\.name), ["remember", "move_head", "express", "look"])
        let tool = try XCTUnwrap(tools.first { $0.name == "move_head" } as? MoveHeadTool)
        for (outcome, expected) in [(MotionReservationResult.unavailable, "今は首を動かせません"),
                                    (.budgetExceeded, "この返答の動作枠を超えるため追加しません"),
                                    (.invalidated, "この返答の動作予約は取り消されました")] {
            spy.reservationResult = outcome
            let result = try await MotionTurnContext.$current.withValue(MotionTurnID()) {
                try await tool.call(arguments: .init(gesture: "nod", intensity: "small", repeats: 1))
            }
            XCTAssertEqual(result, expected)
        }
    }
}
