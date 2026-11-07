import XCTest
@testable import CatRobot

@MainActor
final class FacingAddressingTests: XCTestCase {
    func testFacingAcceptsFullTranscriptWithoutAName() {
        XCTAssertEqual(AddresseePolicy().route("  今日どう？  ", at: 0, engagement: .inactive,
            pending: nil, isFacingScreen: true), .accept("今日どう？"))
        XCTAssertEqual(AddresseePolicy().route("猫ちゃん、今日どう？", at: 0, engagement: .inactive,
            pending: nil, isFacingScreen: true), .accept("猫ちゃん、今日どう？"))
    }

    func testFacingDuringPendingAcceptsActualWordsAndStillIgnoresFiller() {
        let pending = PendingClarification(utterance: "明日の予定は？", at: 0)
        XCTAssertEqual(AddresseePolicy().route("はい", at: 2, engagement: .inactive,
            pending: pending, isFacingScreen: true), .accept("はい"))
        XCTAssertEqual(AddresseePolicy().route("ううん", at: 2, engagement: .inactive,
            pending: pending, isFacingScreen: true), .accept("ううん"))
        XCTAssertEqual(AddresseePolicy().route("今日どう？", at: 2, engagement: .inactive,
            pending: pending, isFacingScreen: true), .accept("今日どう？"))
        XCTAssertEqual(AddresseePolicy().route("えっと", at: 2, engagement: .inactive,
            pending: pending, isFacingScreen: true), .ignore)
    }

    func testFacingBypassesNegativeClassifierAndArmsThirtySecondFollowUp() async {
        let h = ConversationHarness(classification: .notAddressed)
        h.attention.isFacingScreen = true
        await h.completeTurn("今日どう？", at: 0)
        h.attention.isFacingScreen = false
        await h.completeTurn("続けて", at: 29)
        await h.completeTurn("期限後", at: 61)
        let classified = await h.classifier.calls
        let replies = await h.reply.prompts
        XCTAssertEqual(replies, ["今日どう？", "続けて"])
        XCTAssertEqual(classified, ["期限後"])
        await h.sut.shutdown()
    }

    func testContinuedFacingRenewsHardDeadlineButFollowUpAloneDoesNot() async {
        for renewedFacing in [false, true] {
            let h = ConversationHarness(classification: .notAddressed)
            h.attention.isFacingScreen = true
            await h.completeTurn("開始", at: 0)
            h.attention.isFacingScreen = false
            for time in stride(from: 29.0, through: 290.0, by: 29.0) {
                await h.completeTurn("続けて", at: time)
            }
            h.attention.isFacingScreen = renewedFacing
            await h.completeTurn("今の質問", at: 295)
            h.attention.isFacingScreen = false
            await h.completeTurn("五分後", at: 310)
            let classified = await h.classifier.calls
            XCTAssertEqual(classified, renewedFacing ? [] : ["五分後"])
            await h.sut.shutdown()
        }
    }

    func testFacingDuringPendingGeneratesFromActualWordsWithoutClassifier() async {
        for answer in ["今日どう？", "いいえ"] {
            let h = ConversationHarness(classification: .ambiguous)
            await h.completeTurn("明日の予定は？", at: 0)
            h.attention.isFacingScreen = true
            await h.completeTurn(answer, at: 3)
            let replies = await h.reply.prompts
            let classified = await h.classifier.calls
            XCTAssertEqual(replies, [answer])
            XCTAssertEqual(classified, ["明日の予定は？"])
            await h.sut.shutdown()
        }
    }

    func testCameraFacingUsesExistingHeadBoundsAndCurrentYawCorrection() async throws {
        let h = FacingCameraHarness()
        try await h.frame(yaw: -40 * .pi / 180)
        XCTAssertFalse(h.isFacing)
        XCTAssertTrue(h.camera.hasFreshFacingFace(yawCorrection: 14))
        try await h.frame(yaw: -8.5 * .pi / 180, pitch: 25 * .pi / 180, advance: 0.01)
        XCTAssertTrue(h.isFacing)
        try await h.frame(pitch: 26 * .pi / 180, advance: 0.01)
        XCTAssertFalse(h.isFacing)
        h.camera.shutdown()
    }

    func testMultipleFacesBypassClassifierWhenAnyEligibleFaceLooksTowardScreen() async throws {
        let offCenterFacing = FaceRectangle(x: 0.1, y: 0.35, width: 0.12, height: 0.18,
            yawRadians: -8.5 * .pi / 180, pitchRadians: 0)
        let largerCentralTurned = FaceRectangle(x: 0.25, y: 0.25, width: 0.5, height: 0.5,
            yawRadians: 1, pitchRadians: 0)
        let malformed = FaceRectangle(x: -0.1, y: 0.4, width: 0.2, height: 0.2,
            yawRadians: 0, pitchRadians: 0)
        let cases: [[FaceRectangle]] = [
            [FacingCameraHarness.face(), FacingCameraHarness.face(yaw: 1)],
            [FacingCameraHarness.face(yaw: 1), FacingCameraHarness.face()],
            [FacingCameraHarness.face(), offCenterFacing],
            [largerCentralTurned, offCenterFacing],
            [FacingCameraHarness.face(yaw: 22 * .pi / 180), offCenterFacing],
            [malformed, offCenterFacing]
        ]
        for faces in cases {
            let camera = FacingCameraHarness()
            let conversation = ConversationHarness(classification: .notAddressed,
                isFacingScreen: { camera.isFacing })
            try await camera.emit(faces: faces)
            await conversation.completeTurn("今日どう？ この質問に答えてね。", at: 0)
            let classified = await conversation.classifier.calls
            let replies = await conversation.reply.prompts
            XCTAssertEqual(classified, [])
            XCTAssertEqual(replies, ["今日どう？ この質問に答えてね。"])
            await conversation.sut.shutdown()
            camera.camera.shutdown()
        }
    }

    func testFacingExpiresAtFourHundredMilliseconds() async throws {
        for faces in [[FacingCameraHarness.face()], [FacingCameraHarness.face(), FacingCameraHarness.face()]] {
            let h = FacingCameraHarness()
            try await h.emit(faces: faces)
            await h.clock.advance(by: 0.399)
            XCTAssertTrue(h.isFacing)
            await h.clock.advance(by: 0.001)
            XCTAssertFalse(h.isFacing)
            h.camera.shutdown()
        }
    }

    func testLatestEmptyOrTurnedFaceRevokesFacingAndOlderFrameCannotRestoreIt() async throws {
        for faces in [[], [FacingCameraHarness.face(yaw: 1)],
                      [FacingCameraHarness.face(yaw: 1), FacingCameraHarness.face(yaw: -1)]] {
            let h = FacingCameraHarness()
            try await h.frame()
            XCTAssertTrue(h.isFacing)
            await h.clock.advance(by: 0.1)
            try await h.emit(faces: faces)
            XCTAssertFalse(h.isFacing)
            try await h.emit(faces: [FacingCameraHarness.face()], capturedAt: 0)
            XCTAssertFalse(h.isFacing)
            h.camera.shutdown()
        }
    }

    func testNoEligibleFaceUnknownOrMalformedHeadPoseFallBack() async throws {
        let invalid: [[FaceRectangle]] = [
            [FacingCameraHarness.face(yaw: 1), FacingCameraHarness.face(yaw: -1)],
            [FacingCameraHarness.face(yaw: .nan), FacingCameraHarness.face(yaw: 1)],
            [.init(x: -0.1, y: 0.4, width: 0.2, height: 0.2, yawRadians: 0, pitchRadians: 0),
             FacingCameraHarness.face(yaw: 1)],
            [.init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)],
            [FacingCameraHarness.face(yaw: .nan)],
            [FacingCameraHarness.face(pitch: .infinity)],
            [.init(x: -0.1, y: 0.4, width: 0.2, height: 0.2, yawRadians: 0, pitchRadians: 0)]
        ]
        for faces in invalid {
            let h = FacingCameraHarness()
            try await h.frame()
            XCTAssertTrue(h.isFacing)
            await h.clock.advance(by: 0.01)
            try await h.emit(faces: faces)
            XCTAssertFalse(h.isFacing)
            h.camera.shutdown()
        }
    }

    func testMalformedFutureAndStaleTimestampsCannotGrantFacing() async throws {
        for (captured, completed) in [(Double.nan, 1.0), (1, Double.infinity), (1.1, 1.1),
                                      (-0.1, 1), (0.5, 1), (1, 0.9)] {
            let h = FacingCameraHarness()
            await h.clock.advance(by: 1)
            try await h.emit(faces: [FacingCameraHarness.face()], capturedAt: captured, completedAt: completed)
            XCTAssertFalse(h.isFacing)
            h.camera.shutdown()
        }
    }

    func testLeavingListeningRequiresFreshObservationEvenWhenTrackingKeepsCameraRunning() async throws {
        let h = FacingCameraHarness()
        try await h.frame()
        XCTAssertTrue(h.isFacing)
        h.environment(.thinking)
        XCTAssertFalse(h.isFacing)
        await h.clock.advance(by: 0.1)
        h.environment(.listening)
        XCTAssertFalse(h.isFacing)
        try await h.emit(faces: [FacingCameraHarness.face()], capturedAt: 0.05)
        XCTAssertFalse(h.isFacing)
        try await h.frame(advance: 0.01)
        XCTAssertTrue(h.isFacing)
        XCTAssertEqual(h.source.starts.count, 1)
        h.camera.shutdown()
    }

    func testLifecycleLossAndOldGenerationNeverReviveFacing() async throws {
        for mode in [RobotControlMode.background, .inactive, .settings] {
            let h = FacingCameraHarness()
            try await h.frame()
            XCTAssertTrue(h.isFacing)
            let old = try XCTUnwrap(h.source.starts.last?.generation)
            h.camera.setEnvironment(conversationVisible: true, sceneActive: mode == .settings,
                mode: mode, phase: .listening)
            XCTAssertFalse(h.isFacing)
            h.environment(.listening)
            try await h.emit(faces: [FacingCameraHarness.face()], generation: old)
            XCTAssertFalse(h.isFacing)
            try await h.frame(advance: 0.01)
            XCTAssertTrue(h.isFacing)
            h.camera.shutdown()
            XCTAssertFalse(h.isFacing)
        }
    }

    func testHeatPermissionLossAndCaptureInterruptionRevokeFacing() async throws {
        for kind in ["heat", "permission", "interrupted", "unavailable"] {
            let h = FacingCameraHarness()
            try await h.frame()
            XCTAssertTrue(h.isFacing)
            switch kind {
            case "heat": h.camera.setThermalState(.serious)
            case "permission": h.source.authorization = .denied
            default:
                let generation = try XCTUnwrap(h.source.starts.last?.generation)
                h.source.emit(kind == "interrupted" ? .interrupted(generation: generation) : .unavailable(generation: generation))
                await robotDrain()
            }
            XCTAssertFalse(h.isFacing)
            h.camera.refreshAuthorization()
            XCTAssertFalse(h.isFacing)
            h.camera.shutdown()
        }
    }

    func testAttentionSharesPhysicalCaptureAndKeepsTrackingEventConsumer() async throws {
        let h = FacingCameraHarness()
        let client = UUID()
        h.camera.start(generation: client)
        let events = h.camera.events()
        let next = Task { var iterator = events.makeAsyncIterator(); return await iterator.next() }
        try await h.frame()
        guard case let .observation(observation) = await next.value else { return XCTFail("No tracking event") }
        XCTAssertEqual(observation.generation, client)
        XCTAssertTrue(h.isFacing)
        h.camera.stop()
        XCTAssertEqual(h.source.stops, 0, "Attention still owns the same camera")
        XCTAssertEqual(h.source.starts.count, 1)
        let snapshot = Task { try await h.camera.captureSnapshot() }
        await robotDrain()
        h.environment(.thinking)
        XCTAssertEqual(h.source.stops, 0, "Pending look still owns the same camera")
        let request = try XCTUnwrap(h.source.snapshotRequests.last)
        request.completion(.success(.init(generation: request.generation, capturedAt: h.clock.now,
            image: try makeCameraTestImage())))
        _ = try await snapshot.value
        XCTAssertEqual(h.source.stops, 1)
        h.camera.shutdown()
    }

    func testAppRequestsCameraAfterVoicePreparationWithTrackingAbsentAndHandlesInactivePrompt() async {
        let source = FakeFaceCaptureSource(authorization: .notDetermined)
        let camera = ConversationCamera(source: source, clock: ManualRobotClock())
        let gate = ConversationTestGate()
        let voice = ConversationHarness(permissionGate: gate)
        let app = ConversationAppCoordinator(viewModel: voice.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }), camera: camera)
        app.beginConversation()
        await gate.waitUntilEntered()
        XCTAssertEqual(source.requests, 0)
        await gate.open()
        let requested = await voice.waitUntil(timeout: .milliseconds(200)) { source.requests == 1 }
        XCTAssertTrue(requested)
        app.scenePhaseDidChange(.inactive)
        XCTAssertEqual(voice.sut.viewState.phase, .listening)
        app.scenePhaseDidChange(.active)
        source.resolveAuthorization(.authorized)
        await app.waitForOperations()
        XCTAssertEqual(source.requests, 1)
        XCTAssertEqual(source.starts.count, 1)
        let preparations = await voice.modelAvailability.checkCount
        XCTAssertEqual(preparations, 1)
        app.scenePhaseDidChange(.background)
        await app.waitForOperations()
        camera.shutdown()
        await voice.sut.shutdown()
    }

    func testLiveCompositionWiresFacingWithoutRobotOrTracking() async throws {
        for faces in [[FacingCameraHarness.face()],
                      [FacingCameraHarness.face(yaw: 1), FacingCameraHarness.face()],
                      [FacingCameraHarness.face(), FacingCameraHarness.face()]] {
            try await assertLiveCompositionWiresFacing(faces: faces)
        }
    }

    private func assertLiveCompositionWiresFacing(faces: [FaceRectangle]) async throws {
        let defaults = UserDefaults(suiteName: "FacingComposition.\(UUID().uuidString)")!
        let preferences = RobotPreferences(defaults: defaults)
        preferences.trackingEnabled = false
        let source = FakeFaceCaptureSource()
        let clock = ManualRobotClock()
        let composition = ConversationComposition.live(auth: .missing, robotTransport: FakeRobotTransport(),
            robotClock: clock, robotPreferences: preferences, faceCaptureSource: source)
        composition.camera.setEnvironment(conversationVisible: true, sceneActive: true,
            mode: .conversation, phase: .listening)
        let generation = try XCTUnwrap(source.starts.last?.generation)
        source.emit(.observation(.init(generation: generation, capturedAt: 0, completedAt: 0,
            horizontalFieldOfView: 90, aspectRatio: 4.0 / 3, faces: faces)))
        await robotDrain()
        XCTAssertTrue(composition.dependencies.isFacingScreen())
        XCTAssertFalse(preferences.trackingEnabled)
        await composition.dependencies.serviceTeardown()
        XCTAssertFalse(composition.dependencies.isFacingScreen())
    }
}

@MainActor
private final class FacingCameraHarness {
    let clock = ManualRobotClock()
    let source = FakeFaceCaptureSource()
    let camera: ConversationCamera
    var isFacing: Bool { camera.hasFreshFacingFace(yawCorrection: 8.5) }

    init() {
        camera = ConversationCamera(source: source, clock: clock)
        environment(.listening)
        camera.start(generation: UUID())
    }

    static func face(yaw: Double = 0, pitch: Double = 0) -> FaceRectangle {
        .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2, yawRadians: yaw, pitchRadians: pitch)
    }

    func environment(_ phase: ConversationPhase) {
        camera.setEnvironment(conversationVisible: true, sceneActive: true, mode: .conversation, phase: phase)
    }

    func frame(yaw: Double = 0, pitch: Double = 0, advance: TimeInterval = 0) async throws {
        await clock.advance(by: advance)
        try await emit(faces: [Self.face(yaw: yaw, pitch: pitch)])
    }

    func emit(faces: [FaceRectangle], capturedAt: TimeInterval? = nil,
              completedAt: TimeInterval? = nil, generation: UUID? = nil) async throws {
        let owner = try XCTUnwrap(generation ?? source.starts.last?.generation)
        source.emit(.observation(.init(generation: owner, capturedAt: capturedAt ?? clock.now,
            completedAt: completedAt ?? clock.now, horizontalFieldOfView: 90, aspectRatio: 4.0 / 3, faces: faces)))
        await robotDrain()
    }
}
