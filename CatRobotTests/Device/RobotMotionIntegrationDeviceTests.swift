import Foundation
import UIKit
import XCTest
@testable import CatRobot

/// Attended hardware validation only. Normal test runs never create a BLE central.
@MainActor
final class RobotMotionIntegrationDeviceTests: XCTestCase {
    private var records: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var traces: [MotionTraceEvent] = []
    private var lastSampleAt: TimeInterval?
    private var directory: URL!
    private var metadata: [String: Any] = [:]
    private var connectionID: UUID?
    private var baselineStatus: RobotStatus?

    private struct ValidationFailure: Error, CustomStringConvertible {
        let description: String
    }

    func testSelectedStage() async throws {
#if targetEnvironment(simulator) || !DEBUG
        throw XCTSkip("Attended iPhone hardware test required")
#else
        let env = ProcessInfo.processInfo.environment
        guard env["ROBOT_MOTION_DEVICE_TESTS"] == "1", env["ROBOT_ATTENDED"] == "1",
              let runID = env["ROBOT_RUN_ID"], UUID(uuidString: runID) != nil,
              let rawStage = env["ROBOT_STAGE"], let intensity = RobotIntensity(rawValue: rawStage),
              let expectedName = env["ROBOT_DEVICE_NAME"], !expectedName.isEmpty else {
            throw XCTSkip("Use scripts/run_robot_motion_device_test.sh --attended")
        }
        // XCTest can enter the test method before the host finishes becoming active.
        // Wait before constructing/starting any hardware controller; later foreground loss aborts.
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 15
        while UIApplication.shared.applicationState != .active {
            guard ProcessInfo.processInfo.systemUptime < activationDeadline else {
                throw ValidationFailure(description: "Unlock the iPhone and keep the test host foreground")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = RobotPreferences()
        guard let device = saved.selectedDevice, device.name == expectedName else {
            throw ValidationFailure(description: "The saved robot does not match the explicitly selected test robot")
        }
        let suiteName = "RobotMotionValidation.\(runID)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RobotPreferences(defaults: defaults)
        preferences.selectedDevice = device
        preferences.strength = saved.strength
        preferences.idleEnabled = true
        let clock = SystemRobotClock()
        let link = RobotLink(transport: CoreBluetoothRobotTransport(), clock: clock, preferences: preferences)
        let motion = MotionCoordinator(link: link, clock: clock, preferences: preferences,
                                       random: SystemRobotRandomSource(), trace: { [weak self] in self?.traces.append($0) })
        motion.setConversationPhase(.thinking) // Suppress autonomous idle/tracking between fixtures.
        // This test owns a different link from the app UI. Cancel pending writes at the
        // lifecycle event, including while send/read is suspended under BLE backpressure.
        let inactiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                motion.stopAll(reason: .background)
                link.setApplicationActive(false)
                link.suspend()
            }
        }
        defer { NotificationCenter.default.removeObserver(inactiveObserver) }
        let oldWakeLock = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldWakeLock; link.suspend() }
        executionTimeAllowance = 240
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RobotMotionValidation/\(runID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadata = ["schemaVersion": 1, "runID": runID, "intensity": rawStage, "robotName": device.name,
                    "strength": saved.strength.rawValue, "OS": UIDevice.current.systemVersion,
                    "sourceRevision": Bundle.main.object(forInfoDictionaryKey: "CatRobotSourceRevision") as? String ?? "unknown",
                    "thermalBefore": String(describing: ProcessInfo.processInfo.thermalState),
                    "trigger": "synthetic speechStarted through production MotionCoordinator and BLE",
                    "angleEvidence": "firmware STATUS target angles; not external physical angle measurements"]
        try save(outcome: "running")
        do {
            link.resume()
            try await wait(link, seconds: 35) { link.snapshot.motionAvailable && link.snapshot.limits.map(saved.strength.matches) == true }
            connectionID = link.snapshot.connectionID
            baselineStatus = link.snapshot.status
            let calibrationBefore = try RobotProtocol.decodeCalibration(await link.read(.calibration))
            guard calibrationBefore.saved, let initial = baselineStatus,
                  initial.flags.intersection([.brownout, .calibrationDirty, .saveError]).isEmpty else {
                throw ValidationFailure(description: "Calibration or firmware precondition failed")
            }
            metadata["calibrationBefore"] = calibrationJSON(calibrationBefore)
            try await moveToRest(.center(speed: 10), yaw: 0, pitch: 0, link: link, clock: clock)
            for gesture in RobotGesture.allCases {
                if gesture == .lookAtUser || gesture == .center {
                    // Both center variants must actually move. No face target is injected in this matrix.
                    try await moveToRest(.move(yawDeci: -100, pitchDeci: -50, speed: 10), yaw: -100, pitch: -50, link: link, clock: clock)
                }
                try await trial(gesture, intensity: intensity, motion: motion, link: link)
                try await wait(link, seconds: 4) { clock.now - (self.traces.last?.at ?? clock.now) >= 2.5 }
            }
            let calibrationAfter = try RobotProtocol.decodeCalibration(await link.read(.calibration))
            metadata["calibrationAfter"] = calibrationJSON(calibrationAfter)
            guard calibrationBefore == calibrationAfter else { throw ValidationFailure(description: "Calibration changed") }
            motion.stopAll(reason: .userStop)
            try await wait(link, seconds: 4) { link.snapshot.status?.flags.contains(.torque) == false }
            try save(outcome: "success")
        } catch {
            motion.stopAll(reason: .userStop)
            try? await Task.sleep(for: .milliseconds(200))
            link.suspend() // Firmware disconnect failsafe also runs if STOP cannot be delivered.
            metadata["error"] = String(describing: error)
            try? save(outcome: "failed")
            throw error
        }
#endif
    }

    private func trial(_ gesture: RobotGesture, intensity: RobotIntensity, motion: MotionCoordinator, link: RobotLink) async throws {
        let turn = MotionTurnID()
        let sampleStart = samples.count
        print("ROBOT_TRIAL_BEGIN \(intensity.rawValue) \(gesture.rawValue)")
        motion.beginTurn(turn)
        guard motion.reserve(.init(gesture: gesture, intensity: intensity, repeats: 1), for: turn) == .reserved(cycles: 1) else {
            throw ValidationFailure(description: "Reservation failed: \(gesture.rawValue)")
        }
        motion.speechStarted(turn)
        motion.generationFinished(turn, outcome: .success)
        motion.speechFinished(turn)
        try await wait(link, seconds: 20) { self.traces.contains { $0.turn == turn && ($0.point == .completed || $0.point == .discarded) } }
        let events = traces.filter { $0.turn == turn }
        let observed = Array(samples.dropFirst(sampleStart))
        let completed = events.contains { $0.point == .completed && $0.result == .success }
        let moved = events.contains { $0.point == .startObserved }
        let centered = link.snapshot.status.map { $0.yawDeci == 0 && $0.pitchDeci == 0 } == true
        records.append(["gesture": gesture.rawValue, "intensity": intensity.rawValue,
                        "outcome": completed && moved && centered ? "success" : "failed",
                        "events": events.map(traceJSON), "samples": observed])
        try save(outcome: "running")
        guard completed && moved && centered else { throw ValidationFailure(description: "Motion failed: \(gesture.rawValue)") }
        print("ROBOT_TRIAL_END \(intensity.rawValue) \(gesture.rawValue) success")
    }

    private func moveToRest(_ command: RobotCommand, yaw: Int16, pitch: Int16, link: RobotLink, clock: SystemRobotClock) async throws {
        let sentAt = clock.now
        try await link.send(command, priority: .motion, token: UUID(), expiresAt: clock.now + 1)
        try await wait(link, seconds: 15) {
            guard let status = link.snapshot.status, (link.snapshot.statusReceivedAt ?? 0) > sentAt else { return false }
            return status.yawDeci == yaw && status.pitchDeci == pitch && status.flags.intersection([.moving, .gesture, .returning]).isEmpty
        }
    }

    private func wait(_ link: RobotLink, seconds: Double, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            guard UIApplication.shared.applicationState == .active else { throw ValidationFailure(description: "Test app left foreground") }
            let snapshot = link.snapshot
            if let connectionID {
                guard snapshot.connectionID == connectionID, snapshot.motionAvailable,
                      snapshot.statusReceivedAt.map({ ProcessInfo.processInfo.systemUptime - $0 < 1 }) == true else {
                    throw ValidationFailure(description: "Connection lost or STATUS became stale")
                }
            }
            if let status = snapshot.status {
                guard abs(Int(status.yawDeci)) <= 450, abs(Int(status.pitchDeci)) <= 200,
                      status.flags.intersection([.brownout, .saturated, .calibrationDirty, .saveError]).isEmpty,
                      baselineStatus.map({ $0.rejectedCount == status.rejectedCount && $0.saveSeq == status.saveSeq }) ?? true else {
                    throw ValidationFailure(description: "Firmware bounds, error flags, rejection or save counter changed")
                }
                if lastSampleAt != snapshot.statusReceivedAt {
                    lastSampleAt = snapshot.statusReceivedAt
                    samples.append(["at": snapshot.statusReceivedAt ?? 0, "yawDeci": status.yawDeci, "pitchDeci": status.pitchDeci,
                                    "flags": status.flags.rawValue, "state": status.state.rawValue,
                                    "rejectedCount": status.rejectedCount, "saveSeq": status.saveSeq])
                }
            }
            if condition() { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ValidationFailure(description: "Timed out after \(seconds)s") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func traceJSON(_ event: MotionTraceEvent) -> [String: Any] {
        ["turn": event.turn?.rawValue.uuidString ?? "", "cycle": event.cycle?.uuidString ?? "", "point": event.point.rawValue,
         "at": event.at, "result": event.result?.rawValue ?? "", "speechToSend": event.speechToSend ?? -1,
         "previousCycleWait": event.previousCycleWait ?? -1]
    }

    private func calibrationJSON(_ calibration: RobotCalibration) -> [String: Any] {
        ["yawOffsetDeci": calibration.values.yawOffsetDeci, "pitchOffsetDeci": calibration.values.pitchOffsetDeci,
         "invert": calibration.values.invert, "saved": calibration.saved]
    }

    private func save(outcome: String) throws {
        var payload = metadata
        payload["outcome"] = outcome
        payload["thermalAfter"] = String(describing: ProcessInfo.processInfo.thermalState)
        payload["records"] = records
        payload["allSamples"] = samples
        payload["allEvents"] = traces.map(traceJSON)
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}
