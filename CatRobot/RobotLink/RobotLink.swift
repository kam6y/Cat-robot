import Foundation
import OSLog

@MainActor
final class RobotLink: RobotLinkControlling {
    private enum Preparation { case none, gatt, info, encryptedStatus, notify, calibration, limits, ready }
    private struct QueuedCommand {
        let id: UUID
        let command: RobotCommand
        let data: Data
        let priority: RobotCommandPriority
        let token: UUID
        let expiresAt: TimeInterval
        let continuation: CheckedContinuation<Void, Error>?
        var replacingAutomaticToken: UUID? = nil
    }
    private struct PendingRead {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }
    private struct Recovery {
        let startedAt: TimeInterval
        let seq: UInt8
        var written = false
        var readCompleted = false
        var echoSeen = false
    }

    private let transport: any RobotTransport
    private let clock: any RobotClock
    private let preferences: RobotPreferences
    private let logger = Logger(subsystem: "com.kamby.CatRobot", category: "RobotLink")
    private(set) var snapshot = RobotLinkSnapshot()
    private var published = RobotLinkSnapshot()
    private var observers: [UUID: AsyncStream<RobotLinkSnapshot>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var started = false
    private var wantsConnection = false
    private var wantsDiscovery = false
    private var userDisconnected = false
    private var suspended = false
    private var unsupported = false
    private var bluetooth: RobotBluetoothState = .unknown
    private var attempt: UUID?
    private var generation = 0
    private var connectCalled = false
    private var closing = false
    private var closeDeadline: TimeInterval?
    private var retryAt: TimeInterval?
    private var lastFailure: RobotLinkFailure = .disconnected
    private var preparation: Preparation = .none
    private var preparationDeadline: TimeInterval?
    private var pairingRemaining: TimeInterval?
    private var permissionRemaining: TimeInterval?
    private var permissionTimedOut = false
    private var lastClockAt: TimeInterval = 0
    private var applicationActive = true
    private var authenticatedDeviceIDs: Set<UUID> = []
    private var initialRestObserved = false
    private var automaticMotionBlockedUntilRest = false
    private var nextPingAt: TimeInterval?
    private var pingSeq: UInt8 = 0
    private var recovery: Recovery?
    private var commands: [QueuedCommand] = []
    private var invalidTokens: Set<UUID> = []
    private var reads: [RobotCharacteristic: [PendingRead]] = [:]
    private var readDeadlines: [RobotCharacteristic: TimeInterval] = [:]

    init(transport: any RobotTransport, clock: any RobotClock, preferences: RobotPreferences) {
        self.transport = transport
        self.clock = clock
        self.preferences = preferences
        snapshot.device = preferences.selectedDevice
        published = snapshot
    }

    deinit {
        eventTask?.cancel()
        monitorTask?.cancel()
    }

    func updates() -> AsyncStream<RobotLinkSnapshot> {
        let id = UUID()
        let stream = AsyncStream<RobotLinkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream.stream
    }

    func start() {
        permissionTimedOut = false
        snapshot.failure = nil
        suspended = false
        wantsDiscovery = true
        // Explicit search keeps an existing connection; saved-device reconnection belongs to resume().
        wantsConnection = attempt != nil && wantsConnection
        startTransport()
        if bluetooth == .unknown { permissionRemaining = 30; lastClockAt = clock.now }
        if bluetooth == .poweredOn { beginRequestedWork() }
    }

    func select(_ device: RobotDevice) {
        let unchanged = preferences.selectedDevice?.id == device.id
        preferences.selectedDevice = device
        snapshot.device = device
        userDisconnected = false
        suspended = false
        unsupported = false
        permissionTimedOut = false
        snapshot.failure = nil
        wantsDiscovery = false
        wantsConnection = true
        startTransport()
        if unchanged, preparation == .ready, !closing { return }
        if attempt != nil {
            if !closing { terminate(.cancelled) }
            retryAt = clock.now
        } else if bluetooth == .poweredOn {
            beginAttempt(direct: true)
        }
        publish()
    }

    func resume() {
        guard !userDisconnected, !unsupported, !permissionTimedOut, preferences.selectedDevice != nil else { return }
        suspended = false
        wantsConnection = true
        startTransport()
        if bluetooth == .poweredOn { beginRequestedWork() }
    }

    func suspend() {
        suspended = true
        wantsConnection = false
        wantsDiscovery = false
        permissionRemaining = nil
        transport.stopScan()
        if attempt != nil, !closing { terminate(.cancelled) }
        snapshot.state = .suspended
        snapshot.motionAvailable = false
        publish()
    }

    func disconnectByUser() {
        userDisconnected = true
        suspend()
    }

    func setApplicationActive(_ active: Bool) {
        accountPairingTime()
        let wasActive = applicationActive
        applicationActive = active
        if !active {
            // Retain only written ownership so an owner-bound settlement can finish this transition.
            automaticMotionBlockedUntilRest = true
            removeCommands(where: { $0.priority != .heartbeat && $0.priority != .manualStop
                && $0.priority != .automaticSettlement }, error: .notReady)
        } else if !wasActive {
            // A foreground session must obtain fresh observations; never replay an inactive settlement.
            snapshot.automaticWrite = nil
            automaticMotionBlockedUntilRest = true
            removeCommands(where: { $0.priority == .automaticSettlement }, error: .notReady)
        }
    }

    func invalidate(_ token: UUID) {
        invalidTokens.insert(token)
        removeCommands(where: { $0.token == token }, error: .cancelled)
    }

    func send(_ command: RobotCommand, priority: RobotCommandPriority,
              token: UUID, expiresAt: TimeInterval) async throws {
        try await enqueue(command, priority: priority, token: token, expiresAt: expiresAt)
    }

    func settleAutomaticMotion(replacing owner: UUID, token: UUID, expiresAt: TimeInterval) async throws {
        guard let status = snapshot.status else { throw RobotLinkFailure.notReady }
        try await enqueue(.move(yawDeci: status.yawDeci, pitchDeci: status.pitchDeci, speed: 10),
                          priority: .automaticSettlement, token: token, expiresAt: expiresAt,
                          replacingAutomaticToken: owner)
    }

    private func enqueue(_ command: RobotCommand, priority: RobotCommandPriority, token: UUID,
                         expiresAt: TimeInterval, replacingAutomaticToken: UUID? = nil) async throws {
        guard !Task.isCancelled, !invalidTokens.contains(token) else { throw RobotLinkFailure.cancelled }
        guard expiresAt > clock.now else { throw RobotLinkFailure.expired }
        guard canSend(command, priority: priority, replacingAutomaticToken: replacingAutomaticToken) else { throw RobotLinkFailure.notReady }
        let data = try RobotProtocol.encode(command)
        let id = UUID()
        let deadline = priority.isMotionLane ? min(expiresAt, clock.now + 0.3) : expiresAt
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                replaceQueued(command)
                commands.append(QueuedCommand(id: id, command: command, data: data, priority: priority,
                                               token: token, expiresAt: deadline, continuation: continuation,
                                               replacingAutomaticToken: replacingAutomaticToken))
                drainCommands()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeCommands(where: { $0.id == id }, error: .cancelled)
            }
        }
    }

    func read(_ characteristic: RobotCharacteristic) async throws -> Data {
        guard !Task.isCancelled else { throw RobotLinkFailure.cancelled }
        guard preparation == .ready, !closing, let attempt, characteristic != .command else {
            throw RobotLinkFailure.notReady
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reads[characteristic, default: []].append(.init(id: id, continuation: continuation))
                if reads[characteristic]?.count == 1 {
                    readDeadlines[characteristic] = clock.now + 3
                    transport.read(characteristic, attempt: attempt)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRead(id, characteristic: characteristic) }
        }
    }

    private func startTransport() {
        if !started {
            started = true
            let events = transport.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.receive(event)
                }
            }
            transport.start()
            if bluetooth == .unknown { permissionRemaining = 30 }
        }
        if monitorTask == nil {
            lastClockAt = clock.now
            let clock = clock
            monitorTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await clock.sleep(until: clock.now + 0.1)
                        guard let self else { return }
                        self.tick()
                    }
                } catch { }
            }
        }
    }

    private func beginRequestedWork() {
        guard !suspended else { return }
        if attempt != nil {
            if wantsDiscovery { transport.scan() }
            return
        }
        if wantsConnection, !userDisconnected, !unsupported, preferences.selectedDevice != nil {
            guard retryAt == nil || clock.now + 0.000_001 >= retryAt! else { return }
            beginAttempt(direct: false)
        } else if wantsDiscovery, snapshot.state != .searching {
            snapshot.state = .searching
            transport.scan()
            publish()
        }
    }

    private func beginAttempt(direct: Bool) {
        guard attempt == nil, bluetooth == .poweredOn, wantsConnection,
              !suspended, !userDisconnected, !unsupported, let device = preferences.selectedDevice else { return }
        let newAttempt = UUID()
        attempt = newAttempt
        generation += 1
        closing = false
        closeDeadline = nil
        retryAt = nil
        connectCalled = direct
        preparation = .gatt
        preparationDeadline = clock.now + 5
        pairingRemaining = nil
        initialRestObserved = false
        snapshot.automaticWrite = nil
        automaticMotionBlockedUntilRest = false
        recovery = nil
        nextPingAt = nil
        snapshot = RobotLinkSnapshot(state: .connecting, device: device,
                                     discoveredDevices: snapshot.discoveredDevices)
        snapshot.connectionID = newAttempt
        transport.stopScan()
        if direct { transport.connect(device.id, attempt: newAttempt) }
        else { transport.retrieve(device.id) }
        publish()
    }

    private func receive(_ event: RobotTransportEvent) {
        switch event {
        case let .bluetooth(state):
            bluetooth = state
            if state != .unknown, state != .resetting { permissionRemaining = nil }
            if state == .poweredOn {
                beginRequestedWork()
            } else {
                if attempt != nil, !closing { terminate(.bluetoothUnavailable(state)) }
                snapshot.state = suspended ? .suspended : .unavailable(state)
                snapshot.motionAvailable = false
            }
        case let .discovered(device):
            if let index = snapshot.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                snapshot.discoveredDevices[index] = device
            } else { snapshot.discoveredDevices.append(device) }
            if let attempt, !closing, !connectCalled, wantsConnection,
               preferences.selectedDevice?.id == device.id {
                connectCalled = true
                transport.stopScan()
                transport.connect(device.id, attempt: attempt)
            }
        case let .disconnected(eventAttempt, reason):
            guard eventAttempt == attempt else { return }
            if !closing {
                lastFailure = reason
                retryAt = clock.now + 2
                endOperations(reason)
            }
            finishClosing()
        case let .failed(eventAttempt, reason):
            guard eventAttempt == attempt, !closing else { return }
            terminate(reason)
        case let .gattReady(eventAttempt):
            guard eventAttempt == attempt, !closing, preparation == .gatt, connectCalled else { return }
            preparation = .info
            snapshot.state = .preparing
            transport.read(.info, attempt: eventAttempt)
        case let .notifyReady(eventAttempt):
            guard eventAttempt == attempt, !closing, preparation == .notify else { return }
            preparation = .calibration
            transport.read(.calibration, attempt: eventAttempt)
        case let .value(eventAttempt, characteristic, data):
            guard eventAttempt == attempt, !closing else { return }
            do { try receive(data, characteristic: characteristic, attempt: eventAttempt) }
            catch RobotProtocolError.unsupportedProtocol {
                unsupported = true
                wantsConnection = false
                terminate(.protocolMismatch)
            } catch { terminate(.invalidData) }
        case let .readyToWrite(eventAttempt):
            guard eventAttempt == attempt, !closing else { return }
            drainCommands()
        }
        publish()
    }

    private func receive(_ data: Data, characteristic: RobotCharacteristic, attempt: UUID) throws {
        switch characteristic {
        case .info:
            guard preparation == .info || preparation == .ready else { return }
            snapshot.info = try RobotProtocol.decodeInfo(data)
            if preparation == .info {
                preparation = .encryptedStatus
                if snapshot.device.map({ authenticatedDeviceIDs.contains($0.id) }) != true {
                    pairingRemaining = 30
                    lastClockAt = clock.now
                    preparationDeadline = nil
                }
                transport.read(.status, attempt: attempt)
            }
        case .status:
            guard preparation != .none, preparation != .gatt, preparation != .info else { return }
            let status = try RobotProtocol.decodeStatus(data)
            snapshot.status = status
            snapshot.statusReceivedAt = clock.now
            observeRest(status)
            if recovery?.written == true, recovery?.seq == status.pingSeq { recovery?.echoSeen = true }
            if preparation == .encryptedStatus {
                if let device = snapshot.device { authenticatedDeviceIDs.insert(device.id) }
                pairingRemaining = nil
                preparationDeadline = clock.now + 5
                preparation = .notify
                transport.setStatusNotify(true, attempt: attempt)
            }
        case .calibration:
            guard preparation == .calibration || preparation == .ready else { return }
            snapshot.calibration = try RobotProtocol.decodeCalibration(data)
            if preparation == .calibration {
                preparation = .limits
                transport.read(.limits, attempt: attempt)
            }
        case .limits:
            guard preparation == .limits || preparation == .ready else { return }
            snapshot.limits = try RobotProtocol.decodeLimits(data)
            if preparation == .limits {
                preparation = .ready
                preparationDeadline = nil
                snapshot.state = .connected
                nextPingAt = clock.now + 1
            }
        case .command: return
        }
        completeRead(characteristic, data: data, attempt: attempt)
        if recovery?.readCompleted == true, recovery?.echoSeen == true { recovery = nil }
        publish()
        drainCommands()
    }

    private func observeRest(_ status: RobotStatus) {
        let operational = status.isOperational
        if !operational || status.flags.contains(.returning) { initialRestObserved = false }
        if operational, status.isAtRest {
            initialRestObserved = true
            automaticMotionBlockedUntilRest = false
        }
    }

    private func accountPairingTime() {
        let elapsed = max(0, clock.now - lastClockAt)
        lastClockAt = clock.now
        if applicationActive, let remaining = pairingRemaining { pairingRemaining = remaining - elapsed }
        if applicationActive, let remaining = permissionRemaining { permissionRemaining = remaining - elapsed }
    }

    private func tick() {
        accountPairingTime()
        if let remaining = permissionRemaining, remaining <= 0 {
            permissionRemaining = nil
            permissionTimedOut = true
            wantsConnection = false
            wantsDiscovery = false
            snapshot.failure = .timedOut
            snapshot.state = .unavailable(bluetooth)
            transport.stopScan()
            publish()
        }
        if closing {
            if let deadline = closeDeadline, clock.now + 0.000_001 >= deadline {
                bluetooth = .unknown
                transport.invalidate()
                finishClosing()
            }
            return
        }
        if attempt == nil {
            if bluetooth == .poweredOn { beginRequestedWork() }
            return
        }
        if let remaining = pairingRemaining, remaining <= 0 {
            terminate(.timedOut)
            return
        }
        if let deadline = preparationDeadline, clock.now + 0.000_001 >= deadline {
            terminate(.timedOut)
            return
        }
        if readDeadlines.values.contains(where: { clock.now + 0.000_001 >= $0 }) {
            terminate(.timedOut)
            return
        }
        guard preparation == .ready else { return }
        if let recovery, clock.now - recovery.startedAt >= 2 - 0.000_001 {
            terminate(.timedOut)
            return
        }
        if recovery == nil, let received = snapshot.statusReceivedAt,
           clock.now - received >= RobotLinkSnapshot.statusFreshness - 0.000_001 {
            startRecovery()
        }
        if let nextPingAt, clock.now + 0.000_001 >= nextPingAt {
            enqueuePing(seq: recovery?.seq ?? nextSequence())
            self.nextPingAt = clock.now + 1
        }
        publish()
        drainCommands()
    }

    private func startRecovery() {
        let seq = nextSequence()
        recovery = Recovery(startedAt: clock.now, seq: seq)
        snapshot.automaticWrite = nil
        automaticMotionBlockedUntilRest = true
        removeCommands(where: { $0.priority.isMotionLane }, error: .notReady)
        enqueuePing(seq: seq)
        nextPingAt = clock.now + 1
        let expectedAttempt = attempt
        Task { [weak self] in
            guard let self, self.attempt == expectedAttempt, !self.closing else { return }
            _ = try? await self.read(.status)
        }
    }

    private func nextSequence() -> UInt8 {
        pingSeq &+= 1
        return pingSeq
    }

    private func enqueuePing(seq: UInt8) {
        let command = RobotCommand.ping(seq: seq)
        guard let data = try? RobotProtocol.encode(command) else { return }
        replaceQueued(command)
        commands.append(.init(id: UUID(), command: command, data: data, priority: .heartbeat,
                              token: UUID(), expiresAt: clock.now + 1, continuation: nil))
    }

    /// An encrypted STATUS read has succeeded on this attempt: every preparation step after it.
    private var encryptedStatusReceived: Bool {
        switch preparation {
        case .notify, .calibration, .limits, .ready: true
        case .none, .gatt, .info, .encryptedStatus: false
        }
    }

    private func canSend(_ command: RobotCommand, priority: RobotCommandPriority,
                         replacingAutomaticToken: UUID? = nil) -> Bool {
        guard attempt != nil, !closing, encryptedStatusReceived else { return false }
        if case .stop = command, priority == .manualStop { return true }
        if case .ping = command, priority == .heartbeat { return preparation == .ready }
        if priority == .automaticSettlement {
            guard replacingAutomaticToken != nil,
                  snapshot.automaticWrite?.token == replacingAutomaticToken,
                  case .move = command,
                  snapshot.status?.isFreeOfOwnedMotion == true else { return false }
            guard !commands.contains(where: { queued in
                guard queued.priority != .automaticSettlement else { return false }
                return queued.command.isMotionCommand
            }) else { return false }
            return motionIsAvailable
        }
        guard applicationActive else { return false }
        let atRest = snapshot.status?.isAtRest == true
        let mayReplaceAutomatic = snapshot.automaticWrite != nil && snapshot.status?.isFreeOfOwnedMotion == true
        if priority == .toolMotion {
            guard mayReplaceAutomatic || (atRest && !automaticMotionBlockedUntilRest) else { return false }
            guard !commands.contains(where: { queued in
                guard queued.priority == .calibration || queued.priority == .manualStop else { return false }
                return queued.command.isMotionCommand
            }) else { return false }
        }
        if priority == .tracking || priority == .idleMotion {
            guard case .move = command else { return false }
            let mayReplaceOwned = mayReplaceAutomatic
                && (priority == .tracking || snapshot.automaticWrite?.priority == .idleMotion)
            guard mayReplaceOwned || (atRest && !automaticMotionBlockedUntilRest) else { return false }
            // Never replace a manual/tool command still waiting for BLE capacity.
            guard !commands.contains(where: { queued in
                guard queued.priority != priority else { return false }
                return queued.command.isMotionCommand
            }) else { return false }
        }
        switch command {
        case .setCalibration:
            guard snapshot.status?.flags.contains(.gesture) == false else { return false }
        case .setLimits:
            guard snapshot.status?.isAtRest == true else { return false }
        case .move, .center:
            guard snapshot.status?.flags.contains(.gesture) == false else { return false }
            if case .center = command, priority == .motion, !atRest && !mayReplaceAutomatic { return false }
        case .gesture, .gestureAt:
            if case .gestureAt = command, snapshot.info?.supportsAnchoredGestures != true { return false }
            guard atRest || ((priority == .motion || priority == .toolMotion) && mayReplaceAutomatic) else { return false }
        case .torque(false) where priority == .idlePowerOff:
            // A preference change can precede the coordinator's next tick while BLE is blocked.
            guard preferences.allowsIdlePowerOff, snapshot.status?.isActiveAtRest == true else { return false }
        default: break
        }
        return motionIsAvailable
    }

    private var motionIsAvailable: Bool {
        guard preparation == .ready, !closing, initialRestObserved, recovery == nil,
              let status = snapshot.status, let received = snapshot.statusReceivedAt,
              clock.now - received < RobotLinkSnapshot.statusFreshness - 0.000_001 else { return false }
        return status.isOperational && !status.flags.contains(.returning)
    }

    private func commandGroup(_ command: RobotCommand) -> Int {
        switch command {
        case .move: 1
        case .setCalibration: 2
        case .ping: 3
        case .stop: 4
        case .gesture, .gestureAt, .center: 5
        case .saveCalibration: 6
        case .setLimits: 7
        case .torque: 8
        }
    }

    private func replaceQueued(_ command: RobotCommand) {
        let group = commandGroup(command)
        removeCommands(where: { self.commandGroup($0.command) == group }, error: .cancelled)
    }

    private func removeCommands(where predicate: (QueuedCommand) -> Bool, error: RobotLinkFailure) {
        let removed = commands.filter(predicate)
        commands.removeAll(where: predicate)
        for command in removed { command.continuation?.resume(throwing: error) }
    }

    private func drainCommands() {
        removeCommands(where: { $0.expiresAt <= self.clock.now + 0.000_001 }, error: .expired)
        guard let attempt, !closing else { return }
        while transport.canSendWriteWithoutResponse, !commands.isEmpty {
            let index = commands.indices.min { commands[$0].priority < commands[$1].priority }!
            let command = commands.remove(at: index)
            guard !invalidTokens.contains(command.token) else {
                command.continuation?.resume(throwing: RobotLinkFailure.cancelled)
                continue
            }
            guard canSend(command.command, priority: command.priority,
                          replacingAutomaticToken: command.replacingAutomaticToken) else {
                command.continuation?.resume(throwing: RobotLinkFailure.notReady)
                continue
            }
            transport.writeCommand(command.data, attempt: attempt)
            switch command.command {
            case .move, .center, .gesture, .gestureAt, .stop, .torque, .setCalibration:
                snapshot.automaticWrite = command.priority == .tracking || command.priority == .idleMotion
                    ? .init(token: command.token, command: command.command, at: clock.now, priority: command.priority) : nil
                automaticMotionBlockedUntilRest = snapshot.automaticWrite == nil
                publish()
            default: break
            }
            if case let .ping(seq) = command.command, recovery?.seq == seq { recovery?.written = true }
            command.continuation?.resume()
        }
    }

    private func completeRead(_ characteristic: RobotCharacteristic, data: Data, attempt: UUID) {
        guard var pending = reads[characteristic], !pending.isEmpty else { return }
        let completed = pending.removeFirst()
        reads[characteristic] = pending
        readDeadlines[characteristic] = nil
        if characteristic == .status, recovery != nil { recovery?.readCompleted = true }
        completed.continuation.resume(returning: data)
        if !pending.isEmpty {
            readDeadlines[characteristic] = clock.now + 3
            transport.read(characteristic, attempt: attempt)
        }
    }

    private func cancelRead(_ id: UUID, characteristic: RobotCharacteristic) {
        guard var pending = reads[characteristic], let index = pending.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 {
            // Without request IDs on GATT reads, advancing after a cancelled read could consume its late value.
            terminate(.cancelled)
        } else {
            let cancelled = pending.remove(at: index)
            reads[characteristic] = pending
            cancelled.continuation.resume(throwing: RobotLinkFailure.cancelled)
        }
    }

    private func endOperations(_ reason: RobotLinkFailure) {
        if reason == .authenticationFailed, let device = snapshot.device {
            authenticatedDeviceIDs.remove(device.id)
        }
        removeCommands(where: { _ in true }, error: reason)
        let pending = reads.values.flatMap { $0 }
        reads.removeAll()
        readDeadlines.removeAll()
        for read in pending { read.continuation.resume(throwing: reason) }
        preparation = .none
        preparationDeadline = nil
        pairingRemaining = nil
        initialRestObserved = false
        snapshot.automaticWrite = nil
        automaticMotionBlockedUntilRest = false
        recovery = nil
        nextPingAt = nil
        snapshot.motionAvailable = false
        snapshot.connectionID = nil
    }

    private func terminate(_ reason: RobotLinkFailure) {
        guard let attempt, !closing else { return }
        lastFailure = reason
        snapshot.failure = reason
        endOperations(reason)
        closing = true
        closeDeadline = clock.now + 5
        retryAt = clock.now + 2
        snapshot.state = disconnectedState
        transport.disconnect(attempt: attempt)
        publish()
    }

    private var disconnectedState: RobotLinkState {
        if unsupported { return .unsupported }
        if suspended || userDisconnected { return .suspended }
        if bluetooth != .poweredOn { return .unavailable(bluetooth) }
        return .reconnecting(lastFailure)
    }

    private func finishClosing() {
        attempt = nil
        connectCalled = false
        closing = false
        closeDeadline = nil
        snapshot.state = disconnectedState
        snapshot.motionAvailable = false
        beginRequestedWork()
    }

    private func publish() {
        snapshot.motionAvailable = motionIsAvailable
        guard snapshot != published else { return }
        if snapshot.state != published.state {
            logger.info("generation=\(self.generation) state=\(String(describing: self.snapshot.state), privacy: .public) time=\(self.clock.now)")
        }
        published = snapshot
        for continuation in observers.values { continuation.yield(snapshot) }
    }
}

private extension RobotCommand {
    var isMotionCommand: Bool {
        switch self {
        case .move, .center, .gesture, .gestureAt, .stop: true
        default: false
        }
    }
}
