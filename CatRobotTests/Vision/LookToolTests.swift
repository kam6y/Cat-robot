import CoreGraphics
import FoundationModels
import XCTest
@testable import CatRobot

@MainActor
final class LookToolTests: XCTestCase {
    func testSpeechAfterCameraCompletionKeepsIndicationThroughToolHandoff() async throws {
        let h = LookHarness(), turn = h.begin()
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let look = GatedLookHandoff(base: h.look, gate: gate)
        let task = Task {
            try await MotionTurnContext.$current.withValue(turn) {
                try await LookTool(look: look).call(arguments: .init(purpose: "確認"))
            }
        }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        try h.camera.complete()
        await gate.waitUntilEntered()
        look.speechStarted(turn)
        XCTAssertTrue(look.isLooking)
        await gate.open()
        let output = try await task.value
        XCTAssertNotNil(output.image)
        XCTAssertTrue(look.isLooking)
        look.generationFinished(turn, outcome: .success)
        XCTAssertFalse(look.isLooking)
    }

    func testCameraInvalidatedAfterCompletionCannotReturnToolImage() async throws {
        for action in ["heat", "hidden", "permission", "shutdown", "expired"] {
            let clock = ManualRobotClock(), source = FakeFaceCaptureSource()
            let camera = ConversationCamera(source: source, clock: clock)
            camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: .thinking)
            let base = LookCoordinator(camera: camera, clock: clock)
            let gate = ConversationTestGate()
            addTeardownBlock { await gate.open() }
            let look = GatedLookHandoff(base: base, gate: gate)
            look.setVisible(true)
            let turn = MotionTurnID()
            look.beginTurn(turn)
            let task = Task {
                try await MotionTurnContext.$current.withValue(turn) {
                    try await LookTool(look: look).call(arguments: .init(purpose: "確認"))
                }
            }
            await robotDrain()
            await clock.advance(by: 0.1)
            try completeSnapshot(source, clock: clock)
            await gate.waitUntilEntered() // camera and coordinator succeeded; Tool has not resumed.
            XCTAssertEqual(source.stops, 1)
            switch action {
            case "heat": camera.setThermalState(.serious)
            case "hidden": camera.setEnvironment(conversationVisible: false, sceneActive: true, mode: .settings, phase: .thinking)
            case "permission": source.authorization = .denied; camera.refreshAuthorization()
            case "shutdown": camera.shutdown()
            default: await clock.advance(by: 0.4)
            }
            await gate.open()
            let result = try await task.value
            XCTAssertNil(result.image, action)
            XCTAssertFalse(base.isLooking, action)
            base.reset()
            camera.shutdown()
        }
    }

    func testRejectedOldImageCannotClearANewerLookIndication() async throws {
        let clock = ManualRobotClock(), source = FakeFaceCaptureSource()
        let camera = ConversationCamera(source: source, clock: clock)
        camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: .thinking)
        let base = LookCoordinator(camera: camera, clock: clock)
        let gate = ConversationTestGate()
        addTeardownBlock { await gate.open() }
        let look = GatedLookHandoff(base: base, gate: gate)
        look.setVisible(true)
        let turn = MotionTurnID()
        look.beginTurn(turn)
        let old = Task {
            try await MotionTurnContext.$current.withValue(turn) {
                try await LookTool(look: look).call(arguments: .init(purpose: "古い画像"))
            }
        }
        await robotDrain()
        await clock.advance(by: 0.1)
        try completeSnapshot(source, clock: clock)
        await gate.waitUntilEntered()
        let nextTurn = MotionTurnID()
        base.beginTurn(nextTurn)
        let next = Task { try await base.capture(for: nextTurn) }
        await robotDrain()
        await clock.advance(by: 0.1)
        try completeSnapshot(source, clock: clock)
        let nextSnapshot = try await next.value
        XCTAssertTrue(base.finishCapture(nextSnapshot, for: nextTurn))
        XCTAssertTrue(base.isLooking)
        await gate.open()
        let stale = try await old.value
        XCTAssertNil(stale.image)
        XCTAssertTrue(base.isLooking)
        base.reset()
        camera.shutdown()
    }

    func testRealSDKReceivesOneImageAndContinuesTheSameReply() async throws {
        let camera = ImmediateSnapshotCamera()
        let look = LookCoordinator(camera: camera, clock: SystemRobotClock())
        look.setVisible(true)
        let turn = MotionTurnID()
        look.beginTurn(turn)
        let session = makeLookSession(look)
        let result = try await MotionTurnContext.$current.withValue(turn) {
            try await session.respond(to: "これ何？")
        }
        XCTAssertEqual(result.content, "done")
        XCTAssertEqual(camera.requests, 1)
        let images = lookToolImages(session.transcript)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.cgImage.width, 4)
        XCTAssertEqual(images.first?.orientation, .up)
        XCTAssertNil(images.first?.url)
        XCTAssertTrue(look.isLooking)
        look.generationFinished(turn, outcome: .success)
        XCTAssertFalse(look.isLooking)
    }

    func testPermissionFailureIsTextOnlyAndDoesNotFailGeneration() async throws {
        let camera = ImmediateSnapshotCamera(error: .permissionRequired)
        let look = LookCoordinator(camera: camera, clock: SystemRobotClock())
        look.setVisible(true)
        let turn = MotionTurnID()
        look.beginTurn(turn)
        let session = makeLookSession(look)
        let result = try await MotionTurnContext.$current.withValue(turn) {
            try await session.respond(to: "見て")
        }
        XCTAssertEqual(result.content, "done")
        XCTAssertTrue(lookToolImages(session.transcript).isEmpty)
        let messages = session.transcript.flatMap { entry -> [String] in
            guard case let .toolOutput(output) = entry else { return [] }
            return output.segments.compactMap { if case let .text(text) = $0 { return text.content }; return nil }
        }
        XCTAssertTrue(messages.joined().contains("カメラを許可"))
        XCTAssertFalse(look.isLooking)
    }

    func testMissingOldAndHiddenScopesCannotCapture() async throws {
        let h = LookHarness(), old = h.begin()
        let tool = LookTool(look: h.look)
        let missing = try await tool.call(arguments: .init(purpose: "確認"))
        XCTAssertNil(missing.image)
        let next = h.begin()
        let stale = try await MotionTurnContext.$current.withValue(old) {
            try await tool.call(arguments: .init(purpose: "確認"))
        }
        XCTAssertNil(stale.image)
        h.look.setVisible(false)
        let hidden = try await MotionTurnContext.$current.withValue(next) {
            try await tool.call(arguments: .init(purpose: "確認"))
        }
        XCTAssertNil(hidden.image)
        XCTAssertEqual(h.camera.requests, 0)
    }

    func testCancelledToolThrowsCancellationInsteadOfReturningImage() async throws {
        let h = LookHarness(), turn = h.begin()
        let task = Task {
            try await MotionTurnContext.$current.withValue(turn) {
                try await LookTool(look: h.look).call(arguments: .init(purpose: "確認"))
            }
        }
        await robotDrain()
        await h.clock.advance(by: 0.1)
        task.cancel()
        await robotDrain()
        try h.camera.complete()
        do { _ = try await task.value; XCTFail("Cancelled tool returned an output") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(h.look.isLooking)
    }
}

@MainActor
final class ImmediateSnapshotCamera: CameraSnapshotProviding {
    private(set) var requests = 0
    var error: CameraSnapshotError?
    init(error: CameraSnapshotError? = nil) { self.error = error }
    func isSnapshotValid(_ snapshot: CameraSnapshot) -> Bool { true }
    func captureSnapshot() async throws -> CameraSnapshot {
        requests += 1
        if let error { throw error }
        return .init(generation: UUID(), capturedAt: 0, image: try makeCameraTestImage())
    }
}

@MainActor
func makeLookSession(_ look: any LookControlling) -> LanguageModelSession {
    LanguageModelSession(model: ToolProbeLanguageModel(toolName: "look", argumentsJSON: "{\"purpose\":\"目の前を確認\"}"),
                         tools: [LookTool(look: look)])
}

func lookToolImages(_ transcript: Transcript) -> [Transcript.ImageAttachment] {
    transcript.flatMap { entry -> [Transcript.ImageAttachment] in
        guard case let .toolOutput(output) = entry else { return [] }
        return output.segments.compactMap { segment in
            if case let .attachment(attachment) = segment, case let .image(image) = attachment.content { return image }
            return nil
        }
    }
}

@MainActor
private final class GatedLookHandoff: LookControlling {
    let base: LookCoordinator
    let gate: ConversationTestGate
    init(base: LookCoordinator, gate: ConversationTestGate) { self.base = base; self.gate = gate }
    var isLooking: Bool { base.isLooking }
    func capture(for id: MotionTurnID) async throws -> CameraSnapshot {
        let snapshot = try await base.capture(for: id)
        await gate.wait()
        return snapshot
    }
    func finishCapture(_ snapshot: CameraSnapshot, for id: MotionTurnID) -> Bool { base.finishCapture(snapshot, for: id) }
    func setVisible(_ visible: Bool) { base.setVisible(visible) }
    func reset() { base.reset() }
    func beginTurn(_ id: MotionTurnID) { base.beginTurn(id) }
    func speechStarted(_ id: MotionTurnID) { base.speechStarted(id) }
    func speechFinished(_ id: MotionTurnID) { base.speechFinished(id) }
    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) { base.generationFinished(id, outcome: outcome) }
    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) { base.cancelTurn(id, reason: reason) }
}

@MainActor
private func completeSnapshot(_ source: FakeFaceCaptureSource, clock: ManualRobotClock) throws {
    let request = try XCTUnwrap(source.snapshotRequests.last)
    _ = try XCTUnwrap(source.starts.last)
    request.completion(.success(.init(generation: request.generation, capturedAt: clock.now,
        image: try makeCameraTestImage())))
}
