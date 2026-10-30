import Foundation
import OSLog

enum MotionTracePoint: String, Sendable {
    case reserved, speechStarted, eligible, sent, startObserved, completed, discarded
}
enum MotionTraceResult: String, Sendable {
    case success, reserved, unavailable, invalidArguments, invalidated, budgetExceeded, noStart, completionTimedOut, sendFailed
}
struct MotionTraceEvent: Sendable {
    let turn: MotionTurnID?
    let cycle: UUID?
    let point: MotionTracePoint
    let at: TimeInterval
    let result: MotionTraceResult?
    let speechToSend: TimeInterval?
    let previousCycleWait: TimeInterval?
}

struct OSMotionTraceSink {
    private let logger = Logger(subsystem: "com.kamby.CatRobot", category: "RobotMotion")
    func record(_ event: MotionTraceEvent) {
        logger.info("motion turn=\(event.turn?.rawValue.uuidString ?? "-", privacy: .public) cycle=\(event.cycle?.uuidString ?? "-", privacy: .public) point=\(event.point.rawValue, privacy: .public) at=\(event.at) result=\(event.result?.rawValue ?? "-", privacy: .public) speechToSend=\(event.speechToSend ?? -1) previousCycleWait=\(event.previousCycleWait ?? -1)")
    }
}

@MainActor
final class MotionCoordinator: RobotMotionControlling {
    private struct PlannedCycle {
        let id = UUID()
        let request: RobotMotionRequest
        let ordinal: Int
        var predicted: TimeInterval
    }
    private struct Turn {
        let id: MotionTurnID
        var valid = true
        var speechAt: TimeInterval?
        var speechDone = false
        var generationDone = false
        var accepted = 0
        var completedSeconds: TimeInterval = 0
        var pending: [PlannedCycle] = []
        var waitingSince: TimeInterval?
        var cycleWait: TimeInterval = 0
    }
    private struct RunningCycle {
        let plan: PlannedCycle
        let turn: MotionTurnID
        let token: UUID
        let command: RobotCommand
        let admittedStatusVersion: UInt64
        let requiresStart: Bool
        let speechAt: TimeInterval
        let previousWait: TimeInterval
        var writtenAt: TimeInterval?
        var startedAt: TimeInterval?
    }
    private enum AutoKind { case idle, yawn, acknowledgement, tracking, settling }
    private struct StrengthAttempt: Equatable { let connection: UUID; let strength: RobotMotionStrength }

    private let link: any RobotLinkControlling
    private let clock: any RobotClock
    private let preferences: RobotPreferences
    private let random: any RobotRandomSource
    private let trace: @MainActor @Sendable (MotionTraceEvent) -> Void
    private var snapshot: RobotLinkSnapshot
    private var statusVersion: UInt64 = 0
    private var mode: RobotControlMode = .conversation
    private var phase: ConversationPhase = .paused
    private var turn: Turn?
    private var active: RunningCycle?
    private var nextTiltLeft = true
    private var observer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var resynchronizationID: UUID?
    private var resynchronizationTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var autoToken: UUID?
    private var autoKind: AutoKind?
    private var nextIdleAt: TimeInterval?
    private var idleFaceDriven = false
    private var trackingState: RobotTrackingState = .disabled
    private var automaticOwnerConnection: UUID?
    private var automaticOwnerToken: UUID?
    private var yawnOwnerToken: UUID?
    private var lastTrackingCommand: RobotCommand?
    private var lastTrackingWriteAt = -TimeInterval.infinity
    private var lastTrackingAttemptAt = -TimeInterval.infinity
    private var trackingReturnIssued = false
    private var automaticMotionSuspended = false
    private var strengthTask: Task<Void, Never>?
    private var strengthToken: UUID?
    private var strengthReading = false
    private var strengthWasCancelled = false
    private var failedStrength: StrengthAttempt?
    private var stopTask: Task<Void, Never>?
    private var stopToken: UUID?
    // A timer generation and a write ticket are independently invalidated by every new operation.
    private var restGeneration = UUID()
    private var restSince: TimeInterval?
    private var powerOffIssued = false
    private var powerOffTask: Task<Void, Never>?
    private var powerOffTicket: UUID?

    init(link: any RobotLinkControlling, clock: any RobotClock, preferences: RobotPreferences,
         random: any RobotRandomSource,
         trace: @escaping @MainActor @Sendable (MotionTraceEvent) -> Void = { OSMotionTraceSink().record($0) }) {
        self.link = link
        self.clock = clock
        self.preferences = preferences
        self.random = random
        self.trace = trace
        snapshot = link.snapshot
        let updates = link.updates()
        observer = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                self?.refreshLinkState()
            }
        }
        updateTimer()
        service()
    }

    deinit {
        observer?.cancel(); timer?.cancel(); sending?.cancel(); autoTask?.cancel()
        strengthTask?.cancel(); stopTask?.cancel(); powerOffTask?.cancel(); resynchronizationTask?.cancel()
    }

    func beginTurn(_ id: MotionTurnID) {
        refreshLinkState()
        guard turn?.id != id else { return }
        if active?.writtenAt == nil { discardActive() }
        turn = Turn(id: id)
    }

    func reserve(_ request: RobotMotionRequest, for id: MotionTurnID) -> MotionReservationResult {
        refreshLinkState()
        guard turn?.id == id else { return rejected(.invalidated, for: id) }
        if case .background = mode { return rejected(.invalidated, for: id) }
        guard mode == .conversation else { return rejected(.unavailable, for: id) }
        guard turn?.valid == true else { return rejected(.invalidated, for: id) }
        guard ready, let limits = snapshot.limits, let status = snapshot.status else { return rejected(.unavailable, for: id) }
        guard (1...3).contains(request.repeats) else { return rejected(.invalidArguments, for: id) }
        let repeats = request.gesture == .center || request.gesture == .lookAtUser ? 1 : request.repeats
        var expectedStatus = status
        if let pending = turn?.pending.last { expectedStatus = restAfter(command(for: pending.request), current: status) }
        else if let active { expectedStatus = restAfter(active.command, current: status) }
        var count = 0
        for _ in 0..<repeats {
            let predicted = estimate(request, limits: limits, current: expectedStatus)
            let inFlight = active?.turn == id ? max(active!.plan.predicted, clock.now - (active!.writtenAt ?? clock.now)) : 0
            let reserved = turn!.pending.reduce(0) { $0 + $1.predicted }
            let total = turn!.completedSeconds + inFlight + reserved + predicted
            guard turn!.accepted == 0 || total <= 4 + 0.000_001 else { break }
            turn!.accepted += 1
            turn!.pending.append(.init(request: request, ordinal: turn!.accepted, predicted: predicted))
            count += 1
            expectedStatus = restAfter(command(for: request, current: expectedStatus), current: expectedStatus)
        }
        guard count > 0 else {
            record(.reserved, turn: id, result: .budgetExceeded)
            return .budgetExceeded
        }
        if turn?.speechAt != nil, active != nil, turn?.waitingSince == nil { turn?.waitingSince = clock.now }
        record(.reserved, turn: id, result: .reserved)
        cancelAuto()
        service()
        return .reserved(cycles: count)
    }

    func speechStarted(_ id: MotionTurnID) {
        refreshLinkState()
        guard turn?.id == id, turn?.valid == true, turn?.speechAt == nil else { return }
        turn?.speechAt = clock.now
        if active != nil { turn?.waitingSince = clock.now }
        record(.speechStarted, turn: id)
        cancelAuto()
        resetPowerOff()
        service()
    }

    func speechFinished(_ id: MotionTurnID) {
        refreshLinkState()
        guard turn?.id == id else { return }
        turn?.speechDone = true
        closeFinishedTurn()
    }

    func generationFinished(_ id: MotionTurnID, outcome: MotionGenerationOutcome) {
        refreshLinkState()
        guard turn?.id == id, turn?.valid == true else { return }
        switch outcome {
        case .success: turn?.generationDone = true; closeFinishedTurn()
        case .failed: cancelTurn(id, reason: .fallback)
        }
    }

    func cancelTurn(_ id: MotionTurnID, reason: MotionCancellationReason) {
        refreshLinkState()
        // Cancellation from a retired playback worker cannot interrupt a newer turn or its handoff cycle.
        guard turn?.id == id else { return }
        invalidateTurn()
        let hadAutonomousMotion = autoTask != nil || ownsTracking
        cancelAuto()
        resetPowerOff()
        if case .playbackCancelled = reason, preservesStartedCycle {
            if active?.writtenAt == nil { discardActive() }
            return
        }
        let wasRunning = active?.turn == id
        if wasRunning { discardActive() }
        switch reason {
        case .background, .linkLost: break
        default: if wasRunning || hadAutonomousMotion { sendStop() }
        }
    }

    func setControlMode(_ mode: RobotControlMode) {
        refreshLinkState()
        guard self.mode != mode else { return }
        self.mode = mode
        cancelAuto()
        nextIdleAt = nil
        resetPowerOff()
        switch mode {
        case .background: stopAll(reason: .background)
        case .settings, .calibration, .inactive:
            trackingState = .disabled
            settleOwnedAutomaticMotion()
            invalidateTurn()
            if active?.writtenAt == nil { discardActive() }
            if mode != .settings, !strengthReading, let strengthToken {
                strengthWasCancelled = true
                link.invalidate(strengthToken)
            }
        case .conversation: break
        }
        service()
    }

    func setConversationPhase(_ phase: ConversationPhase) {
        refreshLinkState()
        self.phase = phase
        if !isWaiting { cancelDecorativeMotion() }
        if !permitsTrackingPhase, autoKind == .tracking { cancelAuto(); settleOwnedAutomaticMotion() }
        service()
    }

    /// The app's face planner owns quiet intervals; tracking remains autonomous.
    func setIdleFaceDriven(_ enabled: Bool) {
        guard idleFaceDriven != enabled else { return }
        cancelDecorativeMotion()
        idleFaceDriven = enabled
        nextIdleAt = nil
        service()
    }

    /// Admit a cue only now. Rejected cues are not saved for later.
    func requestIdleFaceMotion(yaw: Double, pitch: Double) {
        guard yaw.isFinite, pitch.isFinite else { return }
        refreshLinkState()
        guard idleFaceDriven, mode == .conversation, isWaiting, atRest,
              preferences.idleEnabled, !automaticMotionSuspended,
              active == nil, autoTask == nil, strengthTask == nil, stopTask == nil,
              turn?.pending.isEmpty != false else { return }
        if preferences.trackingEnabled {
            switch trackingState {
            case .following, .holding, .returnToCenter: return
            case .disabled, .searching: break
            }
        }
        clearAutomaticOwnership()
        startColumn(kind: .idle, duration: 3, yaw: max(-3, min(3, yaw)), pitch: max(-2, min(2, pitch)))
    }

    func requestYawnMotion(pitch: Double) {
        guard pitch.isFinite else { return }
        refreshLinkState()
        guard idleFaceDriven, mode == .conversation, isWaiting, atRest || ownsTracking || ownsIdle,
              preferences.idleEnabled, !automaticMotionSuspended,
              active == nil, strengthTask == nil, stopTask == nil,
              turn?.pending.isEmpty != false,
              autoTask == nil || autoKind == .tracking || autoKind == .settling || autoKind == .idle,
              let status = snapshot.status else { return }
        let yaw = Double(status.yawDeci) / 10
        let currentPitch = Double(status.pitchDeci) / 10
        guard abs(yaw) <= 45, abs(currentPitch) <= 10 else { return }
        // Keep the previous written owner until the yawn writes, so an early cancellation can settle it.
        cancelAuto()
        if trackingState == .returnToCenter { trackingReturnIssued = false }
        startColumn(kind: .yawn, duration: 3, yaw: yaw, pitch: max(-10, min(10, pitch)))
        yawnOwnerToken = autoToken
    }

    func cancelIdleFaceMotion() {
        guard idleFaceDriven else { return }
        // A tracking write may already be replacing the last idle ownership ticket.
        // The face must never cancel that higher-priority task while it waits to send.
        guard autoKind == .idle || autoKind == .yawn || (autoTask == nil && (ownsIdle || ownsYawn)) else { return }
        cancelAuto()
        settleOwnedAutomaticMotion(includingIdle: true)
    }

    /// Stop a running face-driven column: a yawn settles the pose it owns, an ordinary idle column just stops.
    private func cancelDecorativeMotion() {
        switch autoKind {
        case .yawn: cancelIdleFaceMotion()
        case .idle: cancelAuto()
        default: break
        }
    }

    func utteranceConfirmed() {
        refreshLinkState()
        guard mode == .conversation, atRest || ownsTracking, active == nil, strengthTask == nil,
              stopTask == nil, !automaticMotionSuspended, turn?.pending.isEmpty != false else { return }
        // A brief detection gap must not turn an acknowledgement into a trip to neutral.
        if preferences.trackingEnabled, let status = snapshot.status {
            let pose = FacePose(yaw: Double(status.yawDeci) / 10, pitch: Double(status.pitchDeci) / 10)
            guard abs(pose.yaw) <= 45, abs(pose.pitch) <= 10, min(5, pose.pitch + 10) >= 1 else { return }
            cancelAuto()
            startColumn(kind: .acknowledgement, duration: 0.6, yaw: 0, pitch: 0, facePose: pose)
        } else {
            guard atRest else { return }
            cancelAuto()
            clearAutomaticOwnership()
            startColumn(kind: .acknowledgement, duration: 0.6, yaw: 0, pitch: 0)
        }
    }

    func stopAll(reason: MotionCancellationReason) {
        let hadMotion = active != nil || autoTask != nil || ownsTracking
        invalidateTurn()
        discardActive()
        cancelAuto()
        resetPowerOff()
        nextIdleAt = nil
        trackingState = .disabled
        clearAutomaticOwnership()
        trackingReturnIssued = false
        lastTrackingWriteAt = -.infinity
        lastTrackingAttemptAt = -.infinity
        switch reason {
        case .background, .linkLost:
            resynchronizationID = nil
            resynchronizationTask?.cancel(); resynchronizationTask = nil
            if case .background = reason { mode = .background }
            if let token = strengthToken { link.invalidate(token) }
            strengthTask?.cancel(); strengthTask = nil; strengthToken = nil; strengthReading = false
            if let token = stopToken { link.invalidate(token) }
            stopTask?.cancel(); stopTask = nil; stopToken = nil
        case .userStop, .newConversation: sendStop()
        default: if hadMotion { sendStop() }
        }
    }

    func setTrackingState(_ state: RobotTrackingState) {
        refreshLinkState()
        if case let .following(target) = state {
            guard target.yaw.isFinite, target.pitch.isFinite, target.validUntil.isFinite,
                  target.validUntil > clock.now else {
                setTrackingState(.holding)
                return
            }
        }
        let enteringHold = state == .holding && trackingState != .holding
        if state != .returnToCenter { trackingReturnIssued = false }
        trackingState = state
        // Keep the newest camera state, but let the yawn finish before tracking sends again.
        if autoKind == .yawn { return }
        let interruptsIdle: Bool
        switch state {
        case .following, .holding, .returnToCenter: interruptsIdle = true
        case .disabled, .searching: interruptsIdle = false
        }
        if autoKind == .tracking || (autoKind == .idle && interruptsIdle) { cancelAuto() }
        if state == .disabled || (enteringHold && autoKind != .acknowledgement) {
            settleOwnedAutomaticMotion(includingIdle: enteringHold)
        }
        service()
    }

    func setAutomaticMotionSuspended(_ suspended: Bool) {
        refreshLinkState()
        guard automaticMotionSuspended != suspended else { return }
        automaticMotionSuspended = suspended
        if suspended { cancelAuto(); settleOwnedAutomaticMotion() }
        service()
    }

    private var ownsTracking: Bool { ownsAutomaticMotion && snapshot.automaticWrite?.priority == .tracking }
    private var ownsIdle: Bool { ownsAutomaticMotion && snapshot.automaticWrite?.priority == .idleMotion }
    private var ownsYawn: Bool { ownsAutomaticMotion && automaticOwnerToken == yawnOwnerToken }
    private var ownsAutomaticMotion: Bool {
        ready && automaticOwnerConnection != nil && automaticOwnerConnection == snapshot.connectionID
            && automaticOwnerToken != nil && automaticOwnerToken == snapshot.automaticWrite?.token
            && snapshot.status?.isFreeOfOwnedMotion == true
    }

    private func clearAutomaticOwnership() {
        automaticOwnerConnection = nil
        automaticOwnerToken = nil
        yawnOwnerToken = nil
        lastTrackingCommand = nil
    }

    private func settleOwnedAutomaticMotion(includingIdle: Bool = false) {
        guard ownsTracking || (includingIdle && ownsIdle), active == nil, let status = snapshot.status else {
            clearAutomaticOwnership()
            return
        }
        cancelAuto()
        startTrackingCommand(.move(yawDeci: status.yawDeci, pitchDeci: status.pitchDeci, speed: 10),
                             validUntil: clock.now + 0.3, settling: true)
    }

    private var ready: Bool { resynchronizationID == nil && snapshot.isMotionReady(at: clock.now) }
    private var atRest: Bool { ready && snapshot.status?.isAtRest == true }
    private var isWaiting: Bool { phase == .idle || phase == .listening }
    private var permitsTrackingPhase: Bool { phase.permitsFaceTracking }
    private var preservesStartedCycle: Bool {
        switch mode { case .settings, .calibration, .inactive: true; default: false }
    }
    private var freshTracking: RobotTrackingTarget? {
        guard case let .following(target) = trackingState, target.validUntil > clock.now else { return nil }
        return target
    }

    private func refreshLinkState() {
        let current = link.snapshot
        if current != snapshot { receive(current) }
    }

    private func rejected(_ result: MotionReservationResult, for id: MotionTurnID) -> MotionReservationResult {
        let traceResult: MotionTraceResult
        switch result {
        case .unavailable: traceResult = .unavailable
        case .invalidArguments: traceResult = .invalidArguments
        default: traceResult = .invalidated
        }
        record(.reserved, turn: id, result: traceResult)
        return result
    }

    private func updateTimer() {
        guard snapshot.state == .connected else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Task { [weak self, clock] in
            do {
                while !Task.isCancelled {
                    try await clock.sleep(until: clock.now + 0.05)
                    self?.tick()
                }
            } catch { }
        }
    }

    private func receive(_ next: RobotLinkSnapshot) {
        let connectionChanged = snapshot.connectionID != next.connectionID
        let newStatus = snapshot.status != next.status || snapshot.statusReceivedAt != next.statusReceivedAt
        snapshot = next
        updateTimer()
        if let write = next.automaticWrite, write.token == autoToken, autoKind != .settling {
            automaticOwnerConnection = next.connectionID
            automaticOwnerToken = write.token
            if write.priority == .tracking {
                lastTrackingCommand = write.command
                lastTrackingWriteAt = write.at
            }
        }
        if newStatus { statusVersion &+= 1 }
        if connectionChanged { failedStrength = nil }
        if connectionChanged || next.state != .connected || !next.motionAvailable {
            stopAll(reason: .linkLost)
        }
        if newStatus { processActiveStatus() }
        service()
    }

    private func tick() {
        refreshLinkState()
        if let active, let written = active.writtenAt {
            if active.startedAt == nil, clock.now - written >= 1 - 0.000_001 {
                record(.discarded, turn: active.turn, cycle: active.plan.id, result: .noStart)
                if turn?.id == active.turn { invalidateTurn() }
                discardActive()
            } else if active.startedAt != nil,
                      clock.now - written >= min(active.plan.predicted + 2, 20) - 0.000_001 {
                resynchronizeAfterTimeout(active)
            }
        }
        service()
    }

    private func resynchronizeAfterTimeout(_ cycle: RunningCycle) {
        record(.discarded, turn: cycle.turn, cycle: cycle.plan.id, result: .completionTimedOut)
        invalidateTurn()
        discardActive()
        cancelAuto()
        resetPowerOff()
        let id = UUID(), connection = snapshot.connectionID, link = link
        resynchronizationID = id
        resynchronizationTask = Task { [weak self] in
            var synchronizedRest = false
            do {
                try Task.checkCancellation()
                guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }
                let status = try RobotProtocol.decodeStatus(try await link.read(.status))
                synchronizedRest = status.isOperational && status.isAtRest
            } catch { }
            guard let self, self.resynchronizationID == id else { return }
            self.refreshLinkState()
            guard self.resynchronizationID == id else { return }
            self.resynchronizationID = nil
            self.resynchronizationTask = nil
            if !synchronizedRest, link.snapshot.connectionID == connection {
                // A failed read or a still-busy robot recovers through disconnect, without STOP.
                link.suspend()
                link.resume()
                self.refreshLinkState()
            }
            self.service()
        }
    }

    private func service() {
        // A read continuation may resume before the snapshot observer. Use the authoritative value first.
        let current = link.snapshot
        if current != snapshot { receive(current); return }
        if !preferences.idleEnabled { cancelDecorativeMotion() }
        if active == nil, autoTask == nil, stopTask == nil, atRest, strengthTask == nil,
           mode == .conversation || mode == .settings { applyStrengthIfNeeded() }
        if active == nil, autoTask == nil, stopTask == nil, strengthTask == nil,
           mode == .conversation, atRest || ownsTracking, turn?.valid == true, turn?.speechAt != nil,
           var next = turn?.pending.first, let limits = snapshot.limits, let status = snapshot.status {
            let prediction = estimate(next.request, limits: limits, current: status)
            if next.ordinal > 1, turn!.completedSeconds + prediction > 4 + 0.000_001 {
                record(.discarded, turn: turn?.id, cycle: next.id, result: .budgetExceeded)
                turn?.pending.removeAll()
                closeFinishedTurn()
            } else {
                turn?.pending.removeFirst()
                next.predicted = prediction
                startCycle(next)
            }
        }
        serviceAutonomous()
        servicePowerOff()
    }

    private func startCycle(_ plan: PlannedCycle) {
        guard let turn else { return }
        resetPowerOff()
        cancelAuto()
        let command = command(for: plan.request)
        clearAutomaticOwnership()
        let token = UUID()
        let status = snapshot.status!
        let requiresStart: Bool
        switch command {
        case .gesture, .gestureAt: requiresStart = true
        case .center: requiresStart = abs(Int(status.yawDeci)) > 1 || abs(Int(status.pitchDeci)) > 1
        case let .move(yaw, pitch, _): requiresStart = abs(Int(yaw) - Int(status.yawDeci)) > 1 || abs(Int(pitch) - Int(status.pitchDeci)) > 1
        default: requiresStart = false
        }
        active = .init(plan: plan, turn: turn.id, token: token, command: command, admittedStatusVersion: statusVersion,
                       requiresStart: requiresStart, speechAt: turn.speechAt!, previousWait: turn.cycleWait)
        if !turn.pending.isEmpty { self.turn?.waitingSince = clock.now }
        record(.eligible, turn: turn.id, cycle: plan.id, previousWait: turn.cycleWait)
        let link = link, connection = snapshot.connectionID
        let expiresAt = min(clock.now + 0.3, plan.request.gesture == .lookAtUser ? freshTracking?.validUntil ?? .infinity : .infinity)
        sending = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }
                try await link.send(command, priority: .toolMotion, token: token, expiresAt: expiresAt)
                self?.cycleWritten(plan.id)
            } catch { self?.cycleFailed(plan.id) }
        }
    }

    private func cycleWritten(_ id: UUID) {
        guard active?.plan.id == id else { return }
        active?.writtenAt = clock.now
        sending = nil
        let active = active!
        if active.plan.request.gesture == .tilt { nextTiltLeft.toggle() }
        record(.sent, turn: active.turn, cycle: id, speechToSend: clock.now - active.speechAt,
               previousWait: active.previousWait)
        processActiveStatus()
    }

    private func processActiveStatus() {
        guard var current = active, current.writtenAt != nil, statusVersion > current.admittedStatusVersion,
              ready, let status = snapshot.status else { return }
        if !status.flags.intersection([.gesture, .moving]).isEmpty {
            if current.startedAt == nil {
                current.startedAt = clock.now
                active = current
                record(.startObserved, turn: current.turn, cycle: current.plan.id)
            }
        } else if atRest, current.startedAt != nil || !current.requiresStart {
            if current.startedAt == nil { record(.startObserved, turn: current.turn, cycle: current.plan.id) }
            finishCycle(current)
        }
    }

    private func finishCycle(_ current: RunningCycle) {
        record(.completed, turn: current.turn, cycle: current.plan.id, result: .success)
        if turn?.id == current.turn { turn?.completedSeconds += max(0, clock.now - current.writtenAt!) }
        if let since = turn?.waitingSince { turn?.cycleWait += max(0, clock.now - since); turn?.waitingSince = nil }
        active = nil
        sending = nil
        closeFinishedTurn()
    }

    private func cycleFailed(_ id: UUID) {
        guard let active, active.plan.id == id else { return }
        record(.discarded, turn: active.turn, cycle: id, result: .sendFailed)
        if turn?.id == active.turn { invalidateTurn() }
        discardActive()
        service()
    }

    /// The turn accepts no further cycles. waitingSince only feeds the next cycle's wait
    /// accounting, and an invalid turn never starts one, so clearing it is unobservable.
    private func invalidateTurn() {
        turn?.valid = false
        turn?.pending.removeAll()
        turn?.waitingSince = nil
    }

    private func discardActive() {
        if let active { link.invalidate(active.token) }
        sending?.cancel()
        sending = nil
        active = nil
    }

    private func closeFinishedTurn() {
        if let turn, turn.generationDone, turn.speechDone, turn.pending.isEmpty, active?.turn != turn.id { self.turn = nil }
    }

    private var usesAnchoredGestures: Bool {
        preferences.trackingEnabled && snapshot.info?.supportsAnchoredGestures == true
    }

    private func command(for request: RobotMotionRequest, current: RobotStatus? = nil) -> RobotCommand {
        let id: UInt8
        switch request.gesture {
        case .nod: id = 1
        case .shake: id = 2
        case .tilt: id = nextTiltLeft ? 3 : 4
        case .lookUp: id = 5
        case .lookDown: id = 6
        case .center: return .center(speed: 100)
        case .lookAtUser:
            guard let target = freshTracking else { return .center(speed: 100) }
            return .move(yawDeci: deci(target.yaw, cap: 45), pitchDeci: deci(target.pitch, cap: 20), speed: 100)
        }
        if usesAnchoredGestures, let pose = current ?? snapshot.status {
            return .gestureAt(id: id, ampDeci: request.amplitudeDeci, repeats: 1, speed: 100,
                              yawDeci: pose.yawDeci, pitchDeci: pose.pitchDeci)
        }
        return .gesture(id: id, ampDeci: request.amplitudeDeci, repeats: 1, speed: 100)
    }

    private func estimate(_ request: RobotMotionRequest, limits: RobotLimits, current: RobotStatus) -> TimeInterval {
        guard request.gesture == .lookAtUser, let target = freshTracking else {
            return GestureTiming.estimate(request: request, limits: limits, current: current,
                                          anchor: usesAnchoredGestures ? FacePose(yaw: Double(current.yawDeci) / 10, pitch: Double(current.pitchDeci) / 10) : nil)
        }
        let delta = current.with(yawDeci: Int16(clamping: Int(current.yawDeci) - Int(deci(target.yaw, cap: 45))),
                                 pitchDeci: Int16(clamping: Int(current.pitchDeci) - Int(deci(target.pitch, cap: 20))))
        return GestureTiming.estimate(request: request, limits: limits, current: delta)
    }

    private func restAfter(_ command: RobotCommand, current: RobotStatus) -> RobotStatus {
        switch command {
        case let .move(y, p, _), let .gestureAt(_, _, _, _, y, p): current.with(yawDeci: y, pitchDeci: p)
        default: current.with(yawDeci: 0, pitchDeci: 0)
        }
    }

    private func applyStrengthIfNeeded() {
        guard let connection = snapshot.connectionID, let actual = snapshot.limits else { return }
        let desired = preferences.strength
        let attempt = StrengthAttempt(connection: connection, strength: desired)
        guard !desired.matches(actual), failedStrength != attempt else { return }
        resetPowerOff()
        let token = UUID()
        strengthToken = token
        strengthReading = false
        strengthWasCancelled = false
        let link = link, clock = clock
        strengthTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }
                try await link.send(.setLimits(desired.velocityLimits), priority: .calibration,
                                    token: token, expiresAt: clock.now + 0.3)
                guard let self, self.strengthToken == token, self.snapshot.connectionID == connection else { return }
                self.strengthReading = true
                let confirmed = try RobotProtocol.decodeLimits(try await link.read(.limits))
                guard self.strengthToken == token, self.snapshot.connectionID == connection else { return }
                if !desired.matches(confirmed) { self.failedStrength = attempt }
                self.finishStrength(token)
            } catch {
                guard let self, self.strengthToken == token else { return }
                if !self.strengthWasCancelled { self.failedStrength = attempt }
                self.finishStrength(token)
            }
        }
    }

    private func finishStrength(_ token: UUID) {
        guard strengthToken == token else { return }
        strengthTask = nil
        strengthToken = nil
        strengthReading = false
        strengthWasCancelled = false
        service()
    }

    private func serviceAutonomous() {
        let permitted = mode == .conversation && permitsTrackingPhase && !automaticMotionSuspended
            && active == nil && strengthTask == nil && stopTask == nil && turn?.pending.isEmpty != false
        guard permitted, autoTask == nil else { nextIdleAt = nil; return }
        if preferences.trackingEnabled {
            switch trackingState {
            case .following:
                nextIdleAt = nil
                if let target = freshTracking, atRest || ownsTracking || ownsIdle {
                    if let command = stabilizedTrackingCommand(for: target), trackingCadenceReady {
                        startTrackingCommand(command, validUntil: target.validUntil)
                    }
                }
                return
            case .holding: nextIdleAt = nil; return
            case .returnToCenter:
                if !trackingReturnIssued {
                    nextIdleAt = nil
                    if atRest || ownsTracking || ownsIdle, trackingCadenceReady {
                        startTrackingCommand(.move(yawDeci: 0, pitchDeci: 0, speed: 10), validUntil: clock.now + 0.3)
                    }
                    return
                }
            case .disabled, .searching: break
            }
        }
        guard !idleFaceDriven, isWaiting, atRest, preferences.idleEnabled else { nextIdleAt = nil; return }
        if nextIdleAt == nil { nextIdleAt = clock.now + random.next(in: 4...10) }
        if clock.now + 0.000_001 >= nextIdleAt! {
            nextIdleAt = nil
            clearAutomaticOwnership()
            let yaw = random.next(in: -3...3), pitch = random.next(in: -2...2)
            startColumn(kind: .idle, duration: random.next(in: 3...4), yaw: yaw, pitch: pitch)
        }
    }

    private func stabilizedTrackingCommand(for target: RobotTrackingTarget) -> RobotCommand? {
        var yaw = deci(target.yaw, cap: 45), pitch = deci(target.pitch, cap: 10)
        if ownsTracking, case let .move(previousYaw, previousPitch, speed)? = lastTrackingCommand, speed == 20 {
            // Compare against the last actual write so slow movement accumulates, while
            // detection noise cannot repeatedly restart the same physical motion.
            if abs(Int(yaw) - Int(previousYaw)) < 20 { yaw = previousYaw }
            if abs(Int(pitch) - Int(previousPitch)) < 20 { pitch = previousPitch }
            if yaw == previousYaw, pitch == previousPitch { return nil }
        }
        return .move(yawDeci: yaw, pitchDeci: pitch, speed: 20)
    }

    private var trackingCadenceReady: Bool {
        clock.now - lastTrackingWriteAt >= 0.2 - 0.000_001
            && clock.now - lastTrackingAttemptAt >= 0.2 - 0.000_001
    }

    private func startColumn(kind: AutoKind, duration: TimeInterval, yaw: Double, pitch: Double, facePose: FacePose? = nil) {
        resetPowerOff()
        let token = UUID()
        autoToken = token
        autoKind = kind
        let start = clock.now
        let currentYaw = Double(snapshot.status?.yawDeci ?? 0) / 10
        let currentPitch = Double(snapshot.status?.pitchDeci ?? 0) / 10
        // Face-driven columns: ordinary idle motion stays within ±3° yaw / ±2° pitch, speed 10.
        // The yawn alone keeps the actual yaw and may dip to −10° pitch.
        let decorative = kind == .idle || kind == .yawn
        let pitchLimit: Double = kind == .yawn ? 10 : 2
        let fromYaw = kind == .yawn ? currentYaw : max(-3, min(3, currentYaw))
        let fromPitch = max(-pitchLimit, min(pitchLimit, currentPitch))
        // A small acknowledgement can start at a manual endpoint. Recenter gently.
        let needsSlowApproach = abs(currentYaw) > 3 || abs(currentPitch) > 2
        let speed: UInt8 = facePose != nil ? 20 : (decorative || needsSlowApproach ? 10 : 100)
        // A yawn temporarily owns the tracking lane so it can replace an in-flight tracking MOVE.
        let priority: RobotCommandPriority = switch kind {
        case .yawn: .tracking
        case .idle: .idleMotion
        default: facePose == nil ? .motion : .tracking
        }
        let link = link, clock = clock, connection = snapshot.connectionID
        autoTask = Task { [weak self] in
            do {
                var next = start
                while true {
                    try await clock.sleep(until: next)
                    guard let self, self.autoToken == token, self.mode == .conversation,
                          link.snapshot.connectionID == connection, self.ready else { break }
                    let elapsed = clock.now - start
                    let u = elapsed + 0.000_001 >= duration ? 1 : max(0, elapsed / duration)
                    let y: Double, p: Double
                    if kind == .acknowledgement {
                        let amplitude = facePose.map { min(5, $0.pitch + 10) } ?? 5
                        y = facePose?.yaw ?? 0
                        let dip = u <= 0.5 ? amplitude * Self.smooth(u * 2) : amplitude * (1 - Self.smooth((u - 0.5) * 2))
                        p = (facePose?.pitch ?? 0) - dip
                    } else {
                        y = fromYaw + (yaw - fromYaw) * Self.smooth(u)
                        p = fromPitch + (pitch - fromPitch) * Self.smooth(u)
                    }
                    let command = RobotCommand.move(yawDeci: self.deci(y, cap: kind == .idle ? 3 : 45),
                                                    pitchDeci: self.deci(p, cap: decorative ? pitchLimit : 20),
                                                    speed: speed)
                    try await link.send(command, priority: priority, token: token, expiresAt: clock.now + 0.3)
                    if decorative || facePose != nil, self.autoToken == token {
                        self.automaticOwnerConnection = connection
                        self.automaticOwnerToken = token
                        if facePose != nil {
                            self.lastTrackingCommand = command
                            self.lastTrackingWriteAt = clock.now
                        }
                    }
                    if u >= 1 { break }
                    // Missed deadlines skip samples rather than emitting an old burst.
                    next = clock.now + 0.05
                }
            } catch { }
            self?.finishAuto(token)
        }
    }

    private func startTrackingCommand(_ command: RobotCommand, validUntil: TimeInterval, settling: Bool = false) {
        resetPowerOff()
        let token = UUID()
        autoToken = token
        autoKind = settling ? .settling : .tracking
        lastTrackingAttemptAt = clock.now
        let link = link, clock = clock, connection = snapshot.connectionID
        let returning = trackingState == .returnToCenter
        let settlingOwner = settling ? automaticOwnerToken : nil
        autoTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }
                if settling, let settlingOwner {
                    try await link.settleAutomaticMotion(replacing: settlingOwner, token: token,
                                                         expiresAt: min(validUntil, clock.now + 0.3))
                } else if !settling {
                    try await link.send(command, priority: .tracking, token: token, expiresAt: min(validUntil, clock.now + 0.3))
                } else { throw RobotLinkFailure.notReady }
                if let self, self.autoToken == token, self.snapshot.connectionID == connection {
                    self.lastTrackingWriteAt = clock.now
                    if settling { self.clearAutomaticOwnership() }
                    else {
                        self.automaticOwnerConnection = connection
                        self.automaticOwnerToken = token
                        self.lastTrackingCommand = command
                        if returning { self.trackingReturnIssued = true }
                    }
                }
            } catch { }
            self?.finishAuto(token)
        }
    }

    private func finishAuto(_ token: UUID) {
        guard autoToken == token else { return }
        autoTask = nil; autoToken = nil; autoKind = nil
        service()
    }

    private func cancelAuto() {
        if let token = autoToken { link.invalidate(token) }
        autoTask?.cancel()
        autoTask = nil; autoToken = nil; autoKind = nil
        nextIdleAt = nil
    }

    private func servicePowerOff() {
        let permitted: Bool
        switch mode { case .conversation, .settings: permitted = true; default: permitted = false }
        // Reattaching PWM can visibly jump. Keep it continuous while idle motion is enabled,
        // including a trip through settings before returning to the conversation.
        guard permitted, preferences.allowsIdlePowerOff, atRest, snapshot.status?.isActiveAtRest == true,
              active == nil, autoTask == nil, strengthTask == nil, stopTask == nil else {
            if restSince != nil || powerOffTicket != nil { resetPowerOff() }
            return
        }
        if restSince == nil { restSince = clock.now }
        guard !powerOffIssued, clock.now - restSince! >= 2 - 0.000_001 else { return }
        powerOffIssued = true
        let generation = restGeneration, ticket = UUID(), connection = snapshot.connectionID
        powerOffTicket = ticket
        let link = link, clock = clock
        powerOffTask = Task { [weak self] in
            guard let self, self.preferences.allowsIdlePowerOff, self.restGeneration == generation,
                  self.snapshot.connectionID == connection, link.snapshot.connectionID == connection,
                  self.atRest, self.snapshot.status?.isActiveAtRest == true else { return }
            do {
                try await link.send(.torque(false), priority: .idlePowerOff, token: ticket, expiresAt: clock.now + 0.3)
            } catch {
                if self.restGeneration == generation {
                    self.restSince = clock.now
                    self.powerOffIssued = false
                }
            }
            if self.powerOffTicket == ticket { self.powerOffTask = nil; self.powerOffTicket = nil }
        }
    }

    private func resetPowerOff() {
        restGeneration = UUID()
        if let ticket = powerOffTicket { link.invalidate(ticket) }
        powerOffTask?.cancel()
        powerOffTask = nil; powerOffTicket = nil
        restSince = nil
        powerOffIssued = false
    }

    private func sendStop() {
        clearAutomaticOwnership()
        guard snapshot.state == .connected, stopTask == nil else { return }
        let token = UUID()
        stopToken = token
        let link = link, clock = clock, connection = snapshot.connectionID
        stopTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard link.snapshot.connectionID == connection else { throw RobotLinkFailure.disconnected }
                try await link.send(.stop, priority: .manualStop, token: token, expiresAt: clock.now + 0.3)
            } catch { }
            guard let self, self.stopToken == token else { return }
            self.stopTask = nil; self.stopToken = nil
            self.service()
        }
    }

    private static func smooth(_ u: Double) -> Double { u * u * u * (u * (6 * u - 15) + 10) }
    private func deci(_ value: Double, cap: Double) -> Int16 { Int16((max(-cap, min(cap, value)) * 10).rounded()) }

    private func record(_ point: MotionTracePoint, turn: MotionTurnID? = nil, cycle: UUID? = nil,
                        result: MotionTraceResult? = nil, speechToSend: TimeInterval? = nil,
                        previousWait: TimeInterval? = nil) {
        trace(.init(turn: turn, cycle: cycle, point: point, at: clock.now, result: result,
                    speechToSend: speechToSend, previousCycleWait: previousWait))
    }
}
