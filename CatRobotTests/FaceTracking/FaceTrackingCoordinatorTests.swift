import XCTest
@testable import CatRobot

private let turnedFace = FaceRectangle(x: 0.4, y: 0.4, width: 0.2, height: 0.2, yawRadians: .pi / 2, pitchRadians: 0)
private let unknownHeadingFace = FaceRectangle(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

private func face(yawDegrees: Double) -> FaceRectangle {
    FaceRectangle(x: 0.4, y: 0.4, width: 0.2, height: 0.2, yawRadians: yawDegrees * .pi / 180, pitchRadians: 0)
}

@MainActor
final class FaceTrackingCoordinatorTests: XCTestCase {
    func testPersistedScreenAimChangesActualTrackingTarget() async throws {
        for (correction, expectedYaw) in [(0.0, 0.0), (9.5, -9.5), (14.0, -14.0), (20.0, -20.0)] {
            let h = FaceTrackingHarness(storedYawCorrection: correction)
            h.environment()
            h.frame()
            await robotDrain()
            let target = try XCTUnwrap(h.following.last)
            XCTAssertEqual(target.yaw, expectedYaw, accuracy: 0.000_001)
            XCTAssertEqual(target.pitch, 0)
        }
    }

    func testAimChangeDuringSettingsOrCalibrationWaitsForFreshConversationFrame() async throws {
        for mode in [RobotControlMode.settings, .calibration(UUID())] {
            let h = FaceTrackingHarness()
            h.environment()
            let old = try XCTUnwrap(h.source.starts.last)
            h.frame()
            await robotDrain()
            XCTAssertEqual(h.following.count, 1)
            h.environment(mode: mode)
            h.preferences.trackingYawCorrection = 14
            h.frame(generation: old.generation)
            await robotDrain()
            XCTAssertEqual(h.source.starts.count, 1)
            XCTAssertEqual(h.motion.trackingStates.last, .disabled)
            XCTAssertEqual(h.following.count, 1)
            h.environment()
            h.frame(generation: old.generation)
            await robotDrain()
            XCTAssertEqual(h.following.count, 1)
            h.frame()
            await robotDrain()
            XCTAssertEqual(h.following.count, 2)
            XCTAssertEqual(try XCTUnwrap(h.following.last).yaw, -14, accuracy: 0.000_001)
        }
    }

    func testConstructionIsInertAndUndeterminedPermissionWaitsForExplicitRequest() async {
        let h = FaceTrackingHarness(authorization: .notDetermined)
        await robotDrain()
        XCTAssertEqual(h.source.requests, 0)
        XCTAssertTrue(h.source.starts.isEmpty)
        h.environment()
        await robotDrain()
        XCTAssertEqual(h.source.requests, 0)
        XCTAssertTrue(h.source.starts.isEmpty)
        let permission = Task { await h.coordinator.requestPermissionForConversation() }
        await robotDrain()
        XCTAssertEqual(h.source.requests, 1)
        h.source.resolveAuthorization(.authorized)
        await permission.value
        XCTAssertEqual(h.source.starts.count, 1)
    }

    func testDeniedAndRestrictedPermissionPersistOffWithoutBlockingConversation() async {
        for authorization in [FaceCameraAuthorization.denied, .restricted] {
            let h = FaceTrackingHarness(authorization: authorization)
            h.environment()
            await h.coordinator.requestPermissionForConversation()
            XCTAssertFalse(h.preferences.trackingEnabled)
            XCTAssertFalse(RobotPreferences(defaults: h.defaults).trackingEnabled)
            XCTAssertEqual(h.coordinator.status, .permissionRequired)
            XCTAssertEqual(h.source.requests, 0)
            XCTAssertTrue(h.source.starts.isEmpty)
        }
    }

    func testSavedOffNeverPromptsAndEnablingFromSettingsDoesNotCapture() async {
        let h = FaceTrackingHarness(authorization: .notDetermined, enabled: false)
        h.environment()
        await h.coordinator.requestPermissionForConversation()
        XCTAssertEqual(h.source.requests, 0)
        h.environment(mode: .settings)
        let permission = Task { await h.coordinator.setEnabled(true) }
        await robotDrain()
        XCTAssertEqual(h.source.requests, 1)
        h.source.resolveAuthorization(.authorized)
        await permission.value
        XCTAssertTrue(h.preferences.trackingEnabled)
        XCTAssertTrue(h.source.starts.isEmpty)
        h.environment()
        XCTAssertEqual(h.source.starts.count, 1)
    }

    func testLatePermissionAfterLeavingOrDisablingCannotStartCapture() async {
        for disable in [false, true] {
            let h = FaceTrackingHarness(authorization: .notDetermined)
            h.environment()
            let permission = Task { await h.coordinator.requestPermissionForConversation() }
            await robotDrain()
            if disable { await h.coordinator.setEnabled(false) }
            else { h.environment(visible: false) }
            h.source.resolveAuthorization(.authorized)
            await permission.value
            XCTAssertTrue(h.source.starts.isEmpty)
            if disable { XCTAssertFalse(h.preferences.trackingEnabled) }
        }
    }

    func testConcurrentPermissionRequestsShareOneDialog() async {
        let h = FaceTrackingHarness(authorization: .notDetermined)
        h.environment()
        let first = Task { await h.coordinator.requestPermissionForConversation() }
        await robotDrain()
        let second = Task { await h.coordinator.setEnabled(true) }
        await robotDrain()
        XCTAssertEqual(h.source.requests, 1)
        h.source.resolveAuthorization(.authorized)
        await first.value
        await second.value
        XCTAssertEqual(h.source.starts.count, 1)
    }

    func testAllOngoingConversationPhasesKeepOneCaptureSession() async {
        let h = FaceTrackingHarness()
        for phase in [ConversationPhase.idle, .listening, .classifying, .thinking, .clarifying, .speaking] {
            h.environment(phase: phase)
            await robotDrain()
        }
        XCTAssertEqual(h.source.starts.count, 1)
        XCTAssertEqual(h.source.stops, 0)
        XCTAssertEqual(h.coordinator.status, .searching)
    }

    func testSettingsCalibrationInactivityAndStoppedPhasesInvalidateCapture() async {
        let environments: [(Bool, Bool, RobotControlMode, ConversationPhase)] = [
            (true, true, .settings, .listening), (true, true, .calibration(UUID()), .listening),
            (true, false, .conversation, .listening), (false, true, .conversation, .listening),
            (true, true, .conversation, .paused), (true, true, .conversation, .preparing),
            (true, true, .conversation, .failed(.speechCaptureFailed))
        ]
        for (visible, active, mode, phase) in environments {
            let h = FaceTrackingHarness()
            h.environment()
            let old = h.source.starts.last?.generation
            h.environment(visible: visible, active: active, mode: mode, phase: phase)
            XCTAssertEqual(h.source.stops, 1)
            h.frame(generation: old)
            await robotDrain()
            XCTAssertTrue(h.following.isEmpty)
            XCTAssertEqual(h.motion.trackingStates.last, .disabled)
            h.environment()
            XCTAssertEqual(h.source.starts.count, 2)
            XCTAssertNotEqual(h.source.starts.last?.generation, old)
        }
    }

    func testDisableStopsAndPersistedOffSurvivesRecreation() async {
        let h = FaceTrackingHarness()
        h.environment()
        await h.coordinator.setEnabled(false)
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.source.stops, 1)
        XCTAssertEqual(h.coordinator.status, .off)
        XCTAssertTrue(h.following.isEmpty)
        XCTAssertFalse(RobotPreferences(defaults: h.defaults).trackingEnabled)
    }

    func testDisconnectRejectsOldFrames() async {
        let h = FaceTrackingHarness()
        h.environment()
        let old = h.source.starts.last?.generation
        h.link.disconnect()
        await robotDrain()
        XCTAssertEqual(h.source.stops, 1)
        XCTAssertEqual(h.coordinator.status, .waitingForRobot)
        h.link.reconnect()
        await robotDrain()
        h.frame(generation: old)
        await robotDrain()
        XCTAssertTrue(h.following.isEmpty)
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        XCTAssertEqual(h.source.starts.count, 2)
    }

    func testInterpolatesCapturePoseAndKeepsOnlyLatestPendingFrame() async throws {
        let h = FaceTrackingHarness()
        h.environment()
        await robotDrain()
        await h.clock.advance(by: 0.1)
        h.frame(faces: [.init(x: 0.7, y: 0.4, width: 0.1, height: 0.2, yawRadians: 0, pitchRadians: 0)])
        await robotDrain()
        await h.clock.advance(by: 0.05)
        h.frame()
        await robotDrain()
        XCTAssertTrue(h.following.isEmpty)
        await h.clock.advance(by: 0.05)
        h.link.emitStatus(robotStatus(yaw: 200))
        await robotDrain()
        let target = try XCTUnwrap(h.following.last)
        XCTAssertEqual(h.following.count, 1)
        // Capture-time pose is 15 degrees; the default left-camera correction subtracts 8.5.
        XCTAssertEqual(target.yaw, 6.5, accuracy: 0.000_001)
        XCTAssertEqual(target.validUntil, 0.55, accuracy: 0.000_001)
        XCTAssertEqual(h.coordinator.status, .tracking)
    }

    func testStaleImageAndOutOfOrderFramesCannotReplaceFreshTarget() async {
        let h = FaceTrackingHarness()
        h.environment()
        await h.advanceFresh(by: 0.6)
        h.frame(capturedAt: 0.1)
        await robotDrain()
        XCTAssertTrue(h.following.isEmpty)
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        h.frame(capturedAt: 0.5)
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
    }

    func testFreshThreeFPSFrameWaitingForPoseDoesNotBrieflyDeclareFaceLoss() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        await h.clock.advance(by: 0.2)
        h.link.emitStatus(robotStatus())
        await robotDrain()
        await h.clock.advance(by: 0.183_333)
        h.frame(capturedAt: 0.333_333)
        await robotDrain()
        XCTAssertEqual(h.following.count, 1) // This image still needs the next 5Hz STATUS.
        await h.clock.advance(by: 0.016_667)
        h.link.emitStatus(robotStatus())
        await robotDrain()
        XCTAssertEqual(h.following.count, 2)
        XCTAssertFalse(h.motion.trackingStates.contains(.holding))
    }

    func testPendingFaceStillEntersHoldWhenItsOwnImageExpires() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        await h.clock.advance(by: 0.2)
        h.link.emitStatus(robotStatus())
        await robotDrain()
        await h.clock.advance(by: 0.183_333)
        h.frame(capturedAt: 0.333_333)
        await robotDrain()
        await h.clock.advance(by: 0.35)
        XCTAssertEqual(h.following.count, 1)
        XCTAssertEqual(h.motion.trackingStates.last, .holding)
    }

    func testMissingPoseExpiresInsteadOfUsingCompletionPose() async {
        let h = FaceTrackingHarness()
        h.environment()
        await robotDrain()
        await h.clock.advance(by: 0.1)
        h.frame()
        await robotDrain()
        await h.clock.advance(by: 0.5)
        h.link.emitStatus(robotStatus(yaw: 300))
        await robotDrain()
        XCTAssertTrue(h.following.isEmpty)
    }

    func testLossHoldsUntilExactlyTenSecondsAndEmptyFramesDoNotRenewIt() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        await h.advanceFresh(by: 0.2)
        h.frame(faces: [])
        await robotDrain()
        XCTAssertEqual(h.motion.trackingStates.last, .holding)
        await h.advanceFresh(by: 9.79)
        h.frame(faces: [])
        await robotDrain()
        XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
        await h.advanceFresh(by: 0.01)
        XCTAssertEqual(h.motion.trackingStates.filter { $0 == .returnToCenter }.count, 1)
        await h.advanceFresh(by: 3)
        h.frame(faces: [])
        await robotDrain()
        XCTAssertEqual(h.motion.trackingStates.filter { $0 == .returnToCenter }.count, 1)
    }

    func testTurnedOrUnknownHeadingFacesNeverStartFollowing() async {
        for face in [turnedFace, unknownHeadingFace] {
            let h = FaceTrackingHarness()
            h.environment()
            h.frame(faces: [face])
            await robotDrain()
            XCTAssertTrue(h.following.isEmpty)
            XCTAssertFalse(h.motion.trackingStates.contains(.holding))
            XCTAssertEqual(h.coordinator.status, .searching)
        }
    }

    func testTurnedFrameDiscardsPendingFacingFrameAndIsNotReportedAsTracking() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        await h.clock.advance(by: 0.1)
        h.frame(faces: [.init(x: 0.6, y: 0.4, width: 0.2, height: 0.2, yawRadians: 0, pitchRadians: 0)])
        await robotDrain()
        XCTAssertEqual(h.coordinator.status, .tracking) // The fresh facing image still waits for STATUS.
        await h.clock.advance(by: 0.05)
        h.frame(faces: [turnedFace])
        await robotDrain()
        XCTAssertEqual(h.motion.trackingStates.last, .holding)
        XCTAssertEqual(h.coordinator.status, .searching)
        await h.clock.advance(by: 0.05)
        h.link.emitStatus(robotStatus())
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
    }

    func testTurnedAndUnknownHeadingFramesDoNotRenewLossAndFacingFaceResumes() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        await h.advanceFresh(by: 0.2)
        h.frame(faces: [turnedFace])
        await robotDrain()
        XCTAssertEqual(h.motion.trackingStates.last, .holding)
        await h.advanceFresh(by: 9.79)
        h.frame(faces: [unknownHeadingFace])
        await robotDrain()
        XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
        await h.advanceFresh(by: 0.01)
        XCTAssertEqual(h.motion.trackingStates.filter { $0 == .returnToCenter }.count, 1)
        XCTAssertEqual(h.following.count, 1)
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 2)
        XCTAssertEqual(h.coordinator.status, .tracking)
    }

    func testStoredScreenAimCorrectionCentersTheFacingWindowForReceiveAndProjection() async throws {
        let h = FaceTrackingHarness(storedYawCorrection: 10)
        h.environment()
        h.frame(faces: [face(yawDegrees: -39)])
        await robotDrain()
        let target = try XCTUnwrap(h.following.last)
        XCTAssertEqual(target.yaw, -10, accuracy: 0.000_001)
        XCTAssertEqual(h.coordinator.status, .tracking)
    }

    func testFaceOutsideCorrectedWindowDiscardsPendingFrameAndDoesNotRenewLoss() async {
        let h = FaceTrackingHarness(storedYawCorrection: 10)
        h.environment()
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.following.count, 1)
        await h.clock.advance(by: 0.1)
        h.frame()
        await robotDrain()
        XCTAssertEqual(h.coordinator.status, .tracking) // The fresh facing image still waits for STATUS.
        await h.clock.advance(by: 0.05)
        h.frame(faces: [face(yawDegrees: 25)])
        await robotDrain()
        XCTAssertEqual(h.motion.trackingStates.last, .holding)
        XCTAssertEqual(h.coordinator.status, .searching)
        await h.advanceFresh(by: 9.84)
        h.frame(faces: [face(yawDegrees: 25)])
        await robotDrain()
        XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
        await h.advanceFresh(by: 0.01)
        XCTAssertEqual(h.motion.trackingStates.filter { $0 == .returnToCenter }.count, 1)
        XCTAssertEqual(h.following.count, 1)
    }

    func testCorrectionChangedInSettingsRecentersTheWindowForTheNextCapture() async throws {
        let h = FaceTrackingHarness(storedYawCorrection: 0)
        h.environment()
        h.frame(faces: [face(yawDegrees: -35)])
        await robotDrain()
        XCTAssertTrue(h.following.isEmpty)
        h.environment(mode: .settings)
        h.preferences.trackingYawCorrection = 14
        h.environment()
        h.frame(faces: [face(yawDegrees: -40)])
        await robotDrain()
        let target = try XCTUnwrap(h.following.last)
        XCTAssertEqual(target.yaw, -14, accuracy: 0.000_001)
    }

    func testNewFaceCancelsLossDeadlineAndNewConversationDiscardsIt() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.frame()
        await robotDrain()
        await h.advanceFresh(by: 9.9)
        h.frame()
        await robotDrain()
        await h.advanceFresh(by: 0.2)
        XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
        h.coordinator.resetConversation()
        await h.advanceFresh(by: 10)
        XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
        XCTAssertEqual(h.source.starts.count, 2)
    }

    func testSeriousAndCriticalStopUntilCoolForTenContinuousSeconds() async {
        for heat in [ProcessInfo.ThermalState.serious, .critical] {
            let h = FaceTrackingHarness()
            h.environment()
            h.frame()
            await robotDrain()
            h.coordinator.setThermalState(heat)
            XCTAssertEqual(h.source.stops, 1)
            XCTAssertEqual(h.coordinator.status, .pausedForHeat)
            XCTAssertEqual(h.motion.automaticSuspensions.last, true)
            await h.advanceFresh(by: 12)
            XCTAssertFalse(h.motion.trackingStates.contains(.returnToCenter))
            h.coordinator.setThermalState(.fair)
            await h.advanceFresh(by: 9.99)
            XCTAssertEqual(h.source.starts.count, 1)
            await h.advanceFresh(by: 0.01)
            XCTAssertEqual(h.source.starts.count, 2)
            XCTAssertEqual(h.motion.automaticSuspensions.last, false)
        }
    }

    func testReheatResetsCoolingAndForegroundEligibilityStillApplies() async {
        let h = FaceTrackingHarness()
        h.environment()
        h.coordinator.setThermalState(.serious)
        h.coordinator.setThermalState(.fair)
        await h.advanceFresh(by: 9)
        h.coordinator.setThermalState(.critical)
        h.coordinator.setThermalState(.nominal)
        await h.advanceFresh(by: 1)
        XCTAssertEqual(h.source.starts.count, 1)
        h.environment(active: false)
        await h.advanceFresh(by: 9)
        XCTAssertEqual(h.source.starts.count, 1)
        h.environment()
        XCTAssertEqual(h.source.starts.count, 2)
    }

    func testCaptureFailureDoesNotRetryUntilDeliberateEligibilityTransition() async throws {
        for interruption in [false, true] {
            let h = FaceTrackingHarness()
            h.environment()
            let generation = try XCTUnwrap(h.source.starts.last?.generation)
            h.source.emit(interruption ? .interrupted(generation: generation) : .unavailable(generation: generation))
            await robotDrain()
            XCTAssertEqual(h.coordinator.status, .unavailable)
            XCTAssertEqual(h.source.stops, 1)
            await h.advanceFresh(by: 2)
            XCTAssertEqual(h.source.starts.count, 1)
            h.environment(mode: .settings)
            h.environment()
            XCTAssertEqual(h.source.starts.count, 2)
            h.source.emit(.unavailable(generation: generation))
            await robotDrain()
            XCTAssertEqual(h.coordinator.status, .searching)
        }
    }
}
