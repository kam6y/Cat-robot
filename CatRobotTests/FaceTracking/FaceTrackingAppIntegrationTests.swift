import XCTest
import UIKit
@testable import CatRobot

@MainActor
private final class FaceAppHarness {
    let face: FaceTrackingHarness
    let conversation: ConversationHarness
    let settings: RobotSettingsModel
    let app: ConversationAppCoordinator

    init(authorization: FaceCameraAuthorization = .authorized, enabled: Bool = true,
         microphoneGate: ConversationTestGate? = nil) {
        face = FaceTrackingHarness(authorization: authorization, enabled: enabled)
        conversation = ConversationHarness(permissionGate: microphoneGate)
        let face = face
        settings = RobotSettingsModel(link: face.link, preferences: face.preferences, clock: face.clock,
            onControlModeChanged: { mode in
                face.motion.setControlMode(mode)
                face.coordinator.setControlMode(mode)
            })
        app = ConversationAppCoordinator(viewModel: conversation.sut,
            wakeLock: ConversationScreenWakeLock(readIdleTimerDisabled: { false }, writeIdleTimerDisabled: { _ in }),
            link: face.link, motion: face.motion, settingsModel: settings, faceTracking: face.coordinator)
    }
    func begin() async {
        app.beginConversation()
        await app.waitForOperations()
        await robotDrain()
    }
    func close() async {
        app.scenePhaseDidChange(.background)
        await app.waitForOperations()
        await conversation.sut.shutdown()
    }
}

@MainActor
final class FaceTrackingAppIntegrationTests: XCTestCase {
    func testFirstCameraPermissionWaitsUntilMicrophoneAndVoicePreflightFinish() async {
        let microphoneGate = ConversationTestGate()
        let h = FaceAppHarness(authorization: .notDetermined, microphoneGate: microphoneGate)
        h.app.beginConversation()
        await microphoneGate.waitUntilEntered()
        XCTAssertEqual(h.face.source.requests, 0)
        await microphoneGate.open()
        let requested = await h.conversation.waitUntil { h.face.source.requests == 1 }
        XCTAssertTrue(requested)
        XCTAssertEqual(h.conversation.sut.viewState.phase, .listening)
        h.face.source.resolveAuthorization(.authorized)
        await h.app.waitForOperations()
        XCTAssertEqual(h.face.source.starts.count, 1)
        await h.close()
    }

    func testDeniedCameraTurnsPreferenceOffAndKeepsConversationListening() async {
        let h = FaceAppHarness(authorization: .notDetermined)
        h.app.beginConversation()
        let requested = await h.conversation.waitUntil { h.face.source.requests == 1 }
        XCTAssertTrue(requested)
        h.face.source.resolveAuthorization(.denied)
        await h.app.waitForOperations()
        XCTAssertFalse(h.face.preferences.trackingEnabled)
        XCTAssertEqual(h.conversation.sut.viewState.phase, .listening)
        XCTAssertTrue(h.face.source.starts.isEmpty)
        await h.close()
    }

    func testInactiveCameraDialogAndLateGrantDoNotRestartVoicePreflight() async {
        let h = FaceAppHarness(authorization: .notDetermined)
        h.app.beginConversation()
        let requested = await h.conversation.waitUntil { h.face.source.requests == 1 }
        XCTAssertTrue(requested)
        h.app.scenePhaseDidChange(.inactive)
        h.face.source.resolveAuthorization(.authorized)
        await h.app.waitForOperations()
        XCTAssertTrue(h.face.source.starts.isEmpty)
        XCTAssertEqual(h.conversation.sut.viewState.phase, .listening)
        h.app.scenePhaseDidChange(.active)
        await h.app.waitForOperations()
        let microphoneRequests = await h.conversation.microphone.requestCount
        let preflights = await h.conversation.modelAvailability.checkCount
        let starts = await h.conversation.recognizer.startCount
        XCTAssertEqual(microphoneRequests, 1)
        XCTAssertEqual(preflights, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(h.face.source.starts.count, 1)
        await h.close()
    }

    func testForegroundBeforeLateCameraGrantResumesTheCancelledStart() async {
        let h = FaceAppHarness(authorization: .notDetermined)
        h.app.beginConversation()
        let requested = await h.conversation.waitUntil { h.face.source.requests == 1 }
        XCTAssertTrue(requested)
        h.app.scenePhaseDidChange(.background)
        let paused = await h.conversation.waitUntil { h.conversation.sut.viewState.phase == .paused }
        XCTAssertTrue(paused)
        h.face.link.reconnect()
        h.app.scenePhaseDidChange(.active)
        h.face.source.resolveAuthorization(.authorized)
        await h.app.waitForOperations()
        XCTAssertEqual(h.conversation.sut.viewState.phase, .listening)
        XCTAssertEqual(h.face.source.requests, 1)
        XCTAssertEqual(h.face.source.starts.count, 1)
        await h.close()
    }

    func testSettingsDuringPendingPermissionPreventCaptureUntilReturn() async {
        let h = FaceAppHarness(authorization: .notDetermined)
        h.app.beginConversation()
        let requested = await h.conversation.waitUntil { h.face.source.requests == 1 }
        XCTAssertTrue(requested)
        h.app.openVoiceSettings()
        h.face.source.resolveAuthorization(.authorized)
        await h.app.waitForOperations()
        XCTAssertTrue(h.app.showsVoiceSettings)
        XCTAssertTrue(h.face.source.starts.isEmpty)
        h.app.closeVoiceSettings()
        await h.app.waitForOperations()
        XCTAssertEqual(h.face.source.starts.count, 1)
        await h.close()
    }

    func testSettingsAndForegroundResumeRequireNewObservation() async throws {
        let h = FaceAppHarness()
        await h.begin()
        let old = try XCTUnwrap(h.face.source.starts.last)
        h.face.frame()
        await robotDrain()
        XCTAssertEqual(h.face.following.count, 1)
        h.app.openVoiceSettings()
        XCTAssertEqual(h.face.source.stops, 1, "Stop capture synchronously before awaiting audio teardown")
        h.settings.preferences.trackingYawCorrection = 14
        await h.app.waitForOperations()
        h.app.closeVoiceSettings()
        await h.app.waitForOperations()
        XCTAssertEqual(h.face.source.starts.count, 2)
        h.face.frame(generation: old.generation)
        await robotDrain()
        XCTAssertEqual(h.face.following.count, 1)
        h.app.scenePhaseDidChange(.background)
        XCTAssertEqual(h.face.source.stops, 2)
        await h.app.waitForOperations()
        h.face.link.reconnect()
        h.app.scenePhaseDidChange(.active)
        await h.app.waitForOperations()
        XCTAssertEqual(h.face.source.starts.count, 3)
        XCTAssertEqual(h.face.following.count, 1)
        h.face.frame()
        await robotDrain()
        XCTAssertEqual(h.face.following.count, 2)
        XCTAssertEqual(try XCTUnwrap(h.face.following.last).yaw, -14, accuracy: 0.000_001)
        await h.close()
    }

    func testNewConversationResetsLossTimerAndCaptureGeneration() async throws {
        let h = FaceAppHarness()
        await h.begin()
        let generation = try XCTUnwrap(h.face.source.starts.last?.generation)
        h.face.frame()
        await robotDrain()
        await h.face.advanceFresh(by: 9)
        h.app.makeActions(openSettings: {}).startNewConversation()
        await h.app.waitForOperations()
        XCTAssertNotEqual(h.face.source.starts.last?.generation, generation)
        await h.face.advanceFresh(by: 1.2)
        XCTAssertFalse(h.face.motion.trackingStates.contains(.returnToCenter))
        await h.close()
    }

    func testPausedFailedAndPreparingPhasesStopCapture() async {
        let h = FaceAppHarness()
        await h.begin()
        XCTAssertEqual(h.face.source.starts.count, 1)
        for phase in [ConversationPhase.paused, .preparing, .failed(.microphoneDenied)] {
            let stops = h.face.source.stops
            h.app.conversationPhaseDidChange(phase)
            XCTAssertEqual(h.face.source.stops, stops + 1)
            h.app.conversationPhaseDidChange(.listening)
        }
        await h.close()
    }

    func testSavedOffSurvivesRootConstructionAndConversationStart() async {
        let h = FaceAppHarness(enabled: false)
        _ = AppRootView(dependencies: h.conversation.dependencies, faceTracking: h.face.coordinator)
        let restored = RobotPreferences(defaults: h.face.defaults)
        XCTAssertFalse(restored.trackingEnabled)
        await h.begin()
        XCTAssertTrue(h.face.source.starts.isEmpty)
        XCTAssertEqual(h.face.source.requests, 0)
        await h.close()
    }
}
