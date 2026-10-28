import Foundation
import Observation

enum RobotCalibrationPhase: Equatable, Sendable {
    case inactive, waitingForRest, editing, saving, restoring
    case failed(RobotLinkFailure)
    case closed
}

// Directions as seen by a person facing the robot. Protocol yaw remains robot-relative.
enum RobotCalibrationEdge: Sendable { case left, right, up, down }

@MainActor
@Observable
final class RobotCalibrationSession {
    private(set) var entry: RobotCalibration?
    private(set) var draft: RobotCalibrationValues?
    // Draft equality does not confirm the robot restored an earlier preview.
    // Clear only after read-back confirms a save or restoration.
    private(set) var requiresEntryRestoration = false
    private(set) var phase: RobotCalibrationPhase = .inactive
    private var currentSnapshot: RobotLinkSnapshot
    @ObservationIgnored private let link: any RobotLinkControlling
    @ObservationIgnored private let clock: any RobotClock
    @ObservationIgnored private var epoch: UUID?
    @ObservationIgnored private var connectionInvalidated = false
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var tokens: Set<UUID> = []
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewToken: UUID?
    @ObservationIgnored private var lastPreviewSentAt: TimeInterval = -.infinity
    @ObservationIgnored private var direction = UUID()
    @ObservationIgnored private var directionToken: UUID?
    @ObservationIgnored private var lastRequest: UInt8?
    @ObservationIgnored private var ioTasks: [UUID: Task<Data, Error>] = [:]
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]

    private struct Waiter {
        let operation: UUID
        let predicate: (RobotLinkSnapshot) -> Bool
        let continuation: CheckedContinuation<RobotLinkSnapshot, Error>
        var timeout: Task<Void, Never>?
    }

    init(link: any RobotLinkControlling, clock: any RobotClock) {
        self.link = link
        self.clock = clock
        currentSnapshot = link.snapshot
    }

    deinit {
        observer?.cancel()
        previewTask?.cancel()
    }

    var hasNewChanges: Bool { draft != nil && draft != entry?.values }

    var canEdit: Bool {
        let editable: Bool
        switch phase {
        case .editing, .failed: editable = true
        default: editable = false
        }
        return editable && draft != nil && !connectionInvalidated
            && currentSnapshot.connectionID == epoch && currentSnapshot.state == .connected
            && currentSnapshot.motionAvailable && currentSnapshot.status?.flags.contains(.gesture) == false
    }

    func begin() async throws {
        guard phase != .closed, let epoch = link.snapshot.connectionID, link.snapshot.state == .connected else {
            phase = .failed(.notReady)
            throw RobotLinkFailure.notReady
        }
        self.epoch = epoch
        connectionInvalidated = false
        currentSnapshot = link.snapshot
        startObserving()
        let op = newOperation()
        phase = .waitingForRest
        do {
            _ = try await waitFor(operation: op, predicate: Self.isAtRest)
            let calibration = try RobotProtocol.decodeCalibration(try await read(.calibration, operation: op))
            _ = try RobotProtocol.decodeLimits(try await read(.limits, operation: op))
            try ensure(op)
            entry = calibration
            draft = calibration.values
            requiresEntryRestoration = false
            phase = .editing
        } catch {
            record(error, operation: op)
            throw failure(error)
        }
    }

    func preview(_ values: RobotCalibrationValues) {
        guard canEdit else { return }
        guard (-200...200).contains(values.yawOffsetDeci), (-200...200).contains(values.pitchOffsetDeci),
              values.invert <= 3 else {
            phase = .failed(.invalidData)
            return
        }
        if values != entry?.values { requiresEntryRestoration = true }
        draft = values
        phase = .editing
        let previous = invalidatePreview()
        let token = issueToken()
        previewToken = token
        let op = operation
        previewTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.clock.sleep(until: max(self.clock.now, self.lastPreviewSentAt + 0.1))
                try self.ensure(op)
                guard !Task.isCancelled, self.previewToken == token, self.canEdit else { return }
                try await self.link.send(.setCalibration(values), priority: .calibration,
                                         token: token, expiresAt: self.clock.now + 0.3)
                // Even cancellation immediately after a successful write must rate-limit the next driver.
                self.lastPreviewSentAt = self.clock.now
            } catch { }
        }
    }

    func save() async throws -> RobotCalibration {
        guard canEdit, let intended = draft else { throw RobotLinkFailure.notReady }
        let previous = invalidatePreview()
        let op = newOperation()
        phase = .saving
        await previous?.value
        let token = issueToken()
        do {
            for _ in 0..<2 {
                try ensure(op)
                let confirmed = try await persist(intended, operation: op, token: token)
                try ensure(op)
                if confirmed.saved, confirmed.values == intended {
                    entry = confirmed
                    draft = intended
                    requiresEntryRestoration = false
                    phase = .editing
                    return confirmed
                }
            }
            throw RobotLinkFailure.valueMismatch
        } catch {
            record(error, operation: op)
            throw failure(error)
        }
    }

    func restoreEntry() async throws {
        guard canEdit, let entry else { throw RobotLinkFailure.notReady }
        let previous = invalidatePreview()
        let op = newOperation()
        phase = .restoring
        await previous?.value
        let token = issueToken()
        do {
            try ensure(op)
            try await link.send(.setCalibration(entry.values), priority: .calibration,
                                token: token, expiresAt: clock.now + 0.3)
            let actual = try RobotProtocol.decodeCalibration(try await read(.calibration, operation: op))
            try ensure(op)
            guard actual.values == entry.values else { throw RobotLinkFailure.valueMismatch }
            self.entry = actual
            draft = actual.values
            requiresEntryRestoration = false
            phase = .editing
        } catch {
            record(error, operation: op)
            throw failure(error)
        }
    }

    func moveToEdge(_ edge: RobotCalibrationEdge) async throws {
        guard canEdit else { throw RobotLinkFailure.notReady }
        let op = operation
        let (direction, token) = beginDirection()
        let limits = try RobotProtocol.decodeLimits(try await read(.limits, operation: op))
        try ensure(op)
        guard self.direction == direction, canEdit, let status = link.snapshot.status else {
            throw RobotLinkFailure.cancelled
        }
        var yaw = status.yawDeci, pitch = status.pitchDeci
        switch edge {
        case .left: yaw = -min(limits.yawAngleDeci, 600)
        case .right: yaw = min(limits.yawAngleDeci, 600)
        case .up: pitch = min(limits.pitchAngleDeci, 300)
        case .down: pitch = -min(limits.pitchAngleDeci, 300)
        }
        try await link.send(.move(yawDeci: yaw, pitchDeci: pitch, speed: 10), priority: .calibration,
                            token: token, expiresAt: clock.now + 0.3)
    }

    func center() async throws {
        guard canEdit else { throw RobotLinkFailure.notReady }
        let (_, token) = beginDirection()
        try await link.send(.center(speed: 10), priority: .calibration, token: token, expiresAt: clock.now + 0.3)
    }

    func stop() async {
        guard phase != .closed else { return }
        let abortingSave = phase == .saving || phase == .restoring
        if abortingSave {
            _ = newOperation(cancelReads: false)
            phase = .failed(.cancelled)
        } else {
            _ = invalidatePreview()
            if let directionToken { invalidateToken(directionToken) }
            direction = UUID()
        }
        let token = issueToken()
        try? await link.send(.stop, priority: .manualStop, token: token, expiresAt: clock.now + 0.3)
        if abortingSave { for task in ioTasks.values { task.cancel() } }
    }

    func cancel() {
        _ = invalidatePreview()
        _ = newOperation()
        phase = .closed
        observer?.cancel()
        observer = nil
    }

    private func persist(_ values: RobotCalibrationValues, operation op: UUID, token: UUID) async throws -> RobotCalibration {
        try ensure(op)
        try await link.send(.setCalibration(values), priority: .calibration, token: token, expiresAt: clock.now + 0.3)
        try ensure(op)
        let req = nextRequest()
        for attempt in 0..<3 {
            try await link.send(.saveCalibration(req: req), priority: .calibration,
                                token: token, expiresAt: clock.now + 0.3)
            let sentAt = clock.now
            let ack: RobotLinkSnapshot
            do {
                ack = try await waitFor(operation: op, until: clock.now + 1) {
                    $0.status?.saveSeq == req && ($0.statusReceivedAt ?? -.infinity) >= sentAt
                }
            } catch RobotLinkFailure.timedOut where attempt < 2 { continue }
            guard ack.status?.flags.contains(.saveError) == false else { throw RobotLinkFailure.saveFailed }
            return try RobotProtocol.decodeCalibration(try await read(.calibration, operation: op))
        }
        throw RobotLinkFailure.timedOut
    }

    private func nextRequest() -> UInt8 {
        var req = (link.snapshot.status?.saveSeq ?? 0) % 255 + 1
        if req == lastRequest { req = req % 255 + 1 }
        lastRequest = req
        return req
    }

    private func beginDirection() -> (UUID, UUID) {
        if let directionToken { invalidateToken(directionToken) }
        direction = UUID()
        let token = issueToken()
        directionToken = token
        return (direction, token)
    }

    private func issueToken() -> UUID {
        let token = UUID()
        tokens.insert(token)
        return token
    }

    private func invalidateToken(_ token: UUID) {
        guard tokens.remove(token) != nil else { return }
        link.invalidate(token)
    }

    @discardableResult
    private func newOperation(cancelReads: Bool = true) -> UUID {
        operation = UUID()
        direction = UUID()
        for token in tokens { link.invalidate(token) }
        tokens.removeAll()
        for id in Array(waiters.keys) { finishWaiter(id, result: .failure(RobotLinkFailure.cancelled)) }
        if cancelReads { for task in ioTasks.values { task.cancel() } }
        return operation
    }

    private func invalidatePreview() -> Task<Void, Never>? {
        let previous = previewTask
        previous?.cancel()
        previewTask = nil
        if let previewToken { invalidateToken(previewToken) }
        previewToken = nil
        return previous
    }

    private func read(_ characteristic: RobotCharacteristic, operation op: UUID) async throws -> Data {
        try ensure(op)
        let id = UUID()
        let link = link
        let task = Task { try await link.read(characteristic) }
        ioTasks[id] = task
        defer { ioTasks.removeValue(forKey: id) }
        let data = try await task.value
        try ensure(op)
        return data
    }

    private func startObserving() {
        guard observer == nil else { return }
        let updates = link.updates()
        observer = Task { [weak self] in
            for await snapshot in updates {
                guard let self else { return }
                self.receive(snapshot)
            }
        }
    }

    private func receive(_ snapshot: RobotLinkSnapshot) {
        currentSnapshot = snapshot
        guard phase != .closed, !connectionInvalidated else { return }
        if epoch != nil, snapshot.connectionID != epoch || snapshot.state != .connected {
            connectionInvalidated = true
            operation = UUID()
            _ = invalidatePreview()
            for token in tokens { link.invalidate(token) }
            for task in ioTasks.values { task.cancel() }
            for id in Array(waiters.keys) { finishWaiter(id, result: .failure(RobotLinkFailure.disconnected)) }
            phase = .failed(.disconnected)
            return
        }
        if snapshot.status?.flags.contains(.gesture) == true {
            _ = invalidatePreview()
            if let directionToken { invalidateToken(directionToken) }
            direction = UUID()
        }
        for (id, waiter) in waiters where waiter.operation == operation && waiter.predicate(snapshot) {
            finishWaiter(id, result: .success(snapshot))
        }
    }

    private func waitFor(operation op: UUID, until deadline: TimeInterval? = nil,
                         predicate: @escaping (RobotLinkSnapshot) -> Bool) async throws -> RobotLinkSnapshot {
        try ensure(op)
        if predicate(link.snapshot) { return link.snapshot }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(operation: op, predicate: predicate, continuation: continuation)
                if let deadline {
                    let clock = clock
                    waiters[id]?.timeout = Task { [weak self] in
                        do {
                            try await clock.sleep(until: deadline)
                            guard !Task.isCancelled else { return }
                            self?.finishWaiter(id, result: .failure(RobotLinkFailure.timedOut))
                        } catch { }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(id, result: .failure(RobotLinkFailure.cancelled))
            }
        }
    }

    private func finishWaiter(_ id: UUID, result: Result<RobotLinkSnapshot, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(with: result)
    }

    private func ensure(_ op: UUID) throws {
        guard !Task.isCancelled, operation == op, phase != .closed else { throw RobotLinkFailure.cancelled }
        guard !connectionInvalidated, epoch != nil, link.snapshot.connectionID == epoch,
              link.snapshot.state == .connected else { throw RobotLinkFailure.disconnected }
    }

    private static func isAtRest(_ snapshot: RobotLinkSnapshot) -> Bool {
        snapshot.motionAvailable && snapshot.status?.isAtRest == true
    }

    private func failure(_ error: Error) -> RobotLinkFailure {
        if let error = error as? RobotLinkFailure { return error }
        if error is CancellationError { return .cancelled }
        return .invalidData
    }

    private func record(_ error: Error, operation op: UUID) {
        if operation == op, phase != .closed { phase = .failed(failure(error)) }
    }
}
