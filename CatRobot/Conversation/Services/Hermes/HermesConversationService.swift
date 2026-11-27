import Foundation

struct HermesConversationTiming: Sendable {
    var pollInterval: Duration = .milliseconds(500)
    var turnDeadline: Duration = .seconds(90)
    var submitRetryDelay: Duration = .seconds(1)
}

/// 会話履歴の表示用の 1 行。
struct HermesTranscriptEntry: Equatable, Sendable {
    enum Speaker: Sendable { case user, cat }
    let speaker: Speaker
    let text: String
}

/// 通常会話の Hermes adapter。本文の正本はサーバーに置き、端末は識別子と表示用 cache だけを持つ。
actor HermesConversationService: ReplyGenerating, ConversationMemoryManaging, ModelAvailabilityChecking {
    nonisolated let supportsStableReplyPrefix = false
    private let connection: @Sendable () async -> HermesConnection?
    /// その origin で run に付けるモデルと effort（設定「返答モデル」）。nil は Hermes の既定。
    private let runOptions: @Sendable (String) async -> HermesRunOptions?
    private let transport: any HermesTransport
    private let records: any HermesSessionRecordStore
    private let clock: any HermesClock
    private let timing: HermesConversationTiming
    private let makeSessionID: @Sendable () -> String
    private let makeIdempotencyKey: @Sendable () -> UUID
    /// 返事が頼んだ首・表情・カメラを端末で実行する。nil なら動作を頼ませない（persona もそう伝える）。
    private let deviceActions: (@Sendable (HermesDeviceActions) async throws -> HermesDeviceFeedback)?
    private var load: Task<HermesSessionRecord?, Never>?
    private var loaded = false
    private var record: HermesSessionRecord?
    private var save: Task<Void, Never>?
    private var prepared = false
    // Track the restored tip through the first submission, including the durable pre-POST save.
    private var hasUnsubmittedHistory = false
    private var needsFreshHistory = false
    private var state: ConversationMemoryState = .unprepared
    /// 401 を受けた接続（接続ごと）。どの要求の 401 でも記録し、明示の確認（recheckAvailability）でその接続を外すまで、その接続では何も送らない。
    /// 接続ごとに覚えるので、キーを替えた後に前のキーへ遅れて届いた 401 が今のキーの拒否を消すことはない。
    private var rejectedConnections: [(connection: HermesConnection, revision: UUID)] = []
    private var cleanup: CleanupRequest?
    private var stoppingRuns: [UInt64: Set<String>] = [:]
    // The durable flag is the union of in-flight POSTs and submissions whose outcome was lost.
    private var pendingSubmissions: Set<ObjectIdentifier> = []
    private var unresolvedSubmission = false
    private var active: HermesReplyOperation?
    private var generation: Task<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparingHistory: UUID?
    private var historyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var starting: UUID?
    private var epoch: UInt64 = 0
    private var originEpoch: UInt64 = 0
    private var tipRevision: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<ConversationMemoryState>.Continuation] = [:]

    init(connection: @escaping @Sendable () async -> HermesConnection?,
         runOptions: @escaping @Sendable (String) async -> HermesRunOptions? = { _ in nil },
         transport: any HermesTransport,
         records: any HermesSessionRecordStore,
         clock: any HermesClock = SystemHermesClock(),
         timing: HermesConversationTiming = HermesConversationTiming(),
         makeSessionID: @escaping @Sendable () -> String = { "catrobot-" + UUID().uuidString.lowercased() },
         makeIdempotencyKey: @escaping @Sendable () -> UUID = { UUID() },
         deviceActions: (@Sendable (HermesDeviceActions) async throws -> HermesDeviceFeedback)? = nil) {
        self.deviceActions = deviceActions
        self.connection = connection
        self.runOptions = runOptions
        self.transport = transport
        self.records = records
        self.clock = clock
        self.timing = timing
        self.makeSessionID = makeSessionID
        self.makeIdempotencyKey = makeIdempotencyKey
    }

    func availability() async -> ModelAvailability {
        guard let current = await connection() else { return .hermesNotConfigured }
        return refusalRevision(for: current) != nil ? .hermesUnauthorized : .available
    }

    /// 拒否されたキーを、利用者が確かめ直したときだけ同じ資格情報で 1 回確かめる（自動では送り直さない）。
    /// 確かな 401 と取り消された確認は拒否のまま。届かなかった確認は拒否の根拠にせず、次のターンの答えに任せる。
    /// 端末の記録・履歴・session は変えない。
    func recheckAvailability() async {
        guard let current = await connection(), let revision = refusalRevision(for: current) else { return }
        do {
            _ = try await client(current).capabilities()
        } catch HermesClientError.unauthorized {
            noteRefusal(of: current)
            return
        } catch {}
        guard !Task.isCancelled, refusalRevision(for: current) == revision else { return }
        rejectedConnections.removeAll { $0.connection == current }
    }
    func prewarm() async {}

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        let requestedEpoch = epoch
        if active?.isCancelled == true {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        try Task.checkCancellation()
        guard requestedEpoch == epoch else { throw ConversationServiceError.cancelled }
        guard starting == nil, active == nil else { throw ConversationServiceError.modelBusy }
        let reservation = UUID()
        starting = reservation
        defer { if starting == reservation { starting = nil } }
        let start = await clock.now()
        guard let current = await connection() else { throw ConversationServiceError.modelUnavailable(.hermesNotConfigured) }
        guard refusalRevision(for: current) == nil else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        let prompt = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4_000 else { throw ConversationServiceError.inputTooLong }
        // ターンの初めに 1 回だけ読み、そのターンの再送では変えない（Hermes は body 全体で同じ送信かを判定する）。
        // 読むのはこの接続の origin の選択だけ（別の接続先で選んだモデルを送らない）。
        let options = await runOptions(current.origin)
        guard let selection = await selectRecord(for: current, requestedEpoch: requestedEpoch) else {
            throw ConversationServiceError.cancelled
        }
        let deadline = start.addingTimeInterval(turnLimit)
        try await waitForHistory(in: selection, deadline: deadline)
        guard starting == reservation, let selected = latestSelection(in: selection) else {
            throw ConversationServiceError.cancelled
        }
        guard refusalRevision(for: current) == nil else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        try checkPreparedHistory(for: selected)
        try Task.checkCancellation()
        let operation = HermesReplyOperation(client: client(current), connection: current, selection: selected,
                                             options: options)
        active = operation
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                operation.cancel()
                Task { await self?.scheduleStop(for: operation) }
            }
        }
        generation = Task { await self.generate(prompt, key: self.makeIdempotencyKey(), operation: operation,
                                                 startingAt: start, into: continuation) }
        return stream
    }

    private func generate(_ prompt: String, key: UUID, operation: HermesReplyOperation,
                          startingAt start: Date, into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        let deadline = start.addingTimeInterval(turnLimit)
        let timer = Task { [weak self, clock] in
            do { try await clock.sleepUntilTurnDeadline(deadline) } catch { return }
            await self?.expire(operation, into: continuation)
        }
        defer {
            timer.cancel()
            if active === operation { releaseActiveTurn() }
        }
        do {
            try await cleanUpRuns(for: operation, startingAt: start)
            let input = HermesTurnLeg(input: prompt, image: nil, key: key,
                                      instructions: deviceActions == nil ? HermesConversationInstructions.persona
                                                                         : HermesConversationInstructions.devicePersona)
            var output = try await submitAndAwait(input, for: operation, startingAt: start)
            if let control = try HermesDeviceActions.parse(output) {
                guard let deviceActions else { throw ConversationServiceError.modelGenerationFailed }
                let feedback = try await performDevice(control.actions, perform: deviceActions, for: operation, startingAt: start)
                if control.actions.look == true {
                    output = try await submitAndAwait(followUp(with: feedback), for: operation, startingAt: start)
                    guard try HermesDeviceActions.parse(output) == nil else { throw ConversationServiceError.modelGenerationFailed }
                } else {
                    output = control.speech
                }
            }
            guard await withinDeadline(start) else { throw ConversationServiceError.replyTimedOut }
            guard isCurrent(operation.selection), operation.claimAdoption() else { throw ConversationServiceError.cancelled }
            continuation.yield(Self.speechPrefix(output))
            setState(.ready)
            continuation.finish()
        } catch {
            let onTime = await withinDeadline(start)
            if !onTime || error as? ConversationServiceError == .replyTimedOut {
                expire(operation, into: continuation)
            }
            continuation.finish(throwing: operation.isCancelled ? ConversationServiceError.cancelled : error)
        }
    }

    /// 受理が不明な POST だけ同じ入力とキーで再送し、受理された run の終端を待つ。
    private func submitAndAwait(_ leg: HermesTurnLeg, for operation: HermesReplyOperation, startingAt start: Date) async throws -> String {
        let connection = operation.connection
        guard isCurrent(operation.selection), !operation.isCancelled else { throw ConversationServiceError.cancelled }
        try ensureNotRefused(connection)
        pendingSubmissions.insert(ObjectIdentifier(operation))
        await updateRecord(for: operation) { $0.hasUncertainSubmission = true }
        var hadUncertainAttempt = false
        let accepted: HermesRunHandle
        do {
            while true {
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                guard await withinDeadline(start) else { throw ConversationServiceError.replyTimedOut }
                guard isCurrent(operation.selection), !operation.isCancelled else { throw ConversationServiceError.cancelled }
                try ensureNotRefused(connection)
                if !hadUncertainAttempt {
                    try Task.checkCancellation()
                    try checkPreparedHistory(for: operation.selection)
                    hasUnsubmittedHistory = false
                    needsFreshHistory = false
                }
                do {
                    accepted = try await operation.client.createRun(input: leg.input, sessionID: operation.sessionID,
                                                                    idempotencyKey: leg.key, instructions: leg.instructions,
                                                                    options: operation.options, image: leg.image, isolation: self)
                    break
                } catch {
                    if Self.isDefiniteRefusal(error) {
                        if error as? HermesClientError == .unauthorized { noteRefusal(of: connection) }
                        throw Self.present(error)
                    }
                    hadUncertainAttempt = true
                    guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                    try await clock.sleep(for: timing.submitRetryDelay)
                }
            }
        } catch {
            await finishSubmission(for: operation, accepted: nil, uncertain: hadUncertainAttempt)
            throw error
        }
        await finishSubmission(for: operation, accepted: accepted.runID, uncertain: false)
        // Publish the id after the durable save so a late acceptance can still be stopped.
        operation.accept(accepted.runID)
        guard !operation.isCancelled else {
            scheduleStop(for: operation)
            throw ConversationServiceError.cancelled
        }
        return try await finalOutput(of: accepted.runID, for: operation, startingAt: start)
    }

    /// run の終端まで poll し、完了した出力を返す。終端を見たら、その run は stop の対象と記録から外す。
    private func finalOutput(of runID: String, for operation: HermesReplyOperation, startingAt start: Date) async throws -> String {
        let connection = operation.connection
        while await withinDeadline(start) {
            // 待ちの間に取り消されたら、次の照会を出さない。
            guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
            try ensureNotRefused(connection)
            let result: HermesRunState
            do {
                result = try await operation.client.run(id: runID)
            } catch HermesClientError.runNotFound {
                operation.markTerminal()
                await settle(runID, for: operation)
                throw ConversationServiceError.modelGenerationFailed
            } catch {
                if error as? HermesClientError == .unauthorized { try throwRefusal(of: connection) }
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                try await clock.sleep(for: timing.pollInterval)
                continue
            }
            if result.status.isTerminal {
                operation.markTerminal()
                await settle(runID, for: operation)
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                guard result.status == .completed,
                      let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                    throw ConversationServiceError.modelGenerationFailed
                }
                return output
            }
            guard await withinDeadline(start) else { throw ConversationServiceError.replyTimedOut }
            guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
            if result.status.rawValue == "waiting_for_approval" {
                await stop(operation)
                throw ConversationServiceError.modelGenerationFailed
            }
            try await clock.sleep(for: timing.pollInterval)
        }
        throw ConversationServiceError.replyTimedOut
    }

    /// 返事が頼んだ動作を、そのターンのうちに 1 回だけ実行する。古いターン・取消・期限切れなら何も動かさない。
    private func performDevice(_ actions: HermesDeviceActions,
                               perform: @escaping @Sendable (HermesDeviceActions) async throws -> HermesDeviceFeedback,
                               for operation: HermesReplyOperation, startingAt start: Date) async throws -> HermesDeviceFeedback {
        guard await withinDeadline(start) else { throw ConversationServiceError.replyTimedOut }
        guard isCurrent(operation.selection), !operation.isCancelled else { throw ConversationServiceError.cancelled }
        try Task.checkCancellation()
        do {
            return try await operation.performDevice { try await perform(actions) }
        } catch is CancellationError {
            throw ConversationServiceError.cancelled
        } catch {
            return HermesDeviceFeedback(cameraMessage: "今はカメラの画像を取得できません。")
        }
    }

    private func followUp(with feedback: HermesDeviceFeedback) -> HermesTurnLeg {
        let oversized = (feedback.jpeg?.count ?? 0) > Self.maximumImageBytes
        let message = oversized ? "画像が大きすぎるため送れませんでした。" : (feedback.cameraMessage ?? "画像を取得できませんでした。")
        let key = makeIdempotencyKey()
        return HermesTurnLeg(input: HermesDeviceResult.text(id: key, cameraMessage: message),
                             image: oversized ? nil : feedback.jpeg, key: key, instructions: HermesConversationInstructions.continuation)
    }

    /// Hermes の API server は body を 10 MB までしか受けない。base64 で 4/3 倍になる分と本文の余裕を残す。
    private static let maximumImageBytes = 6_000_000

    private func expire(_ operation: HermesReplyOperation,
                        into continuation: AsyncThrowingStream<String, Error>.Continuation) {
        guard active === operation else { return }
        let error: ConversationServiceError = operation.isCancelled ? .cancelled : .replyTimedOut
        operation.cancel()
        continuation.finish(throwing: error)
        generation?.cancel()
        releaseActiveTurn()
        scheduleStop(for: operation)
    }

    private func releaseActiveTurn() {
        active = nil
        generation = nil
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func finishSubmission(for operation: HermesReplyOperation,
                                  accepted: String?, uncertain: Bool) async {
        guard isCurrent(operation.selection) || accepted != nil else { return }
        await updateRecord(for: operation) {
            if isCurrent(operation.selection) {
                pendingSubmissions.remove(ObjectIdentifier(operation))
                unresolvedSubmission = unresolvedSubmission || uncertain
                $0.hasUncertainSubmission = unresolvedSubmission || !pendingSubmissions.isEmpty
                if accepted != nil { $0.hasTurns = true }
            }
            if let accepted, !$0.unsettledRunIDs.contains(accepted) { $0.unsettledRunIDs.append(accepted) }
        }
    }

    private var turnLimit: TimeInterval {
        Double(timing.turnDeadline.components.seconds) + Double(timing.turnDeadline.components.attoseconds) / 1e18
    }

    private func withinDeadline(_ start: Date) async -> Bool {
        await clock.now().timeIntervalSince(start) < turnLimit
    }

    private func scheduleStop(for operation: HermesReplyOperation) {
        guard let id = claimStop(for: operation) else { return }
        // A single request with its own budget survives cancellation of the reply worker.
        let request = Task { await self.sendStop(id, for: operation) }
        let budget = operation.client.maximumRequestDuration
        Task {
            let timer = Task {
                do { try await Task.sleep(for: .seconds(budget)) } catch { return }
                request.cancel()
            }
            await request.value
            timer.cancel()
        }
    }

    private func stop(_ operation: HermesReplyOperation) async {
        guard let id = claimStop(for: operation) else { return }
        await sendStop(id, for: operation)
    }

    private func claimStop(for operation: HermesReplyOperation) -> String? {
        guard let id = operation.claimStop(),
              stoppingRuns[operation.selection.originEpoch, default: []].insert(id).inserted else { return nil }
        return id
    }

    private func sendStop(_ id: String, for operation: HermesReplyOperation) async {
        let lifetime = operation.selection.originEpoch
        defer {
            stoppingRuns[lifetime]?.remove(id)
            if stoppingRuns[lifetime]?.isEmpty == true { stoppingRuns.removeValue(forKey: lifetime) }
        }
        guard originEpoch != lifetime || record?.unsettledRunIDs.contains(id) == true else { return }
        do {
            try ensureNotRefused(operation.connection)
            if try await operation.client.stop(id: id)?.isTerminal == true { await settle(id, for: operation) }
        } catch HermesClientError.runNotFound { await settle(id, for: operation) }
        catch HermesClientError.unauthorized { noteRefusal(of: operation.connection) }
        catch { /* Unknown remains in the record; neither ACK nor a disconnect proves termination. */ }
    }

    private func cleanUpRuns(for operation: HermesReplyOperation, startingAt start: Date) async throws {
        let budget = turnLimit / 4
        let deadline = start.addingTimeInterval(budget)
        let wallDeadline = ContinuousClock.now.advanced(by: .seconds(budget))
        for id in operation.selection.record.unsettledRunIDs {
            guard stoppingRuns[operation.selection.originEpoch]?.contains(id) != true,
                  record?.unsettledRunIDs.contains(id) == true else { continue }
            guard let stopped = try await cleanUpRun(id, for: operation, stop: true,
                                                     deadline: deadline, wallDeadline: wallDeadline) else { return }
            if !stopped {
                guard try await cleanUpRun(id, for: operation, stop: false,
                                           deadline: deadline, wallDeadline: wallDeadline) != nil else { return }
            }
        }
    }

    // nil ends cleanup for this turn. A timed-out request keeps the single slot until it returns.
    private func cleanUpRun(_ id: String, for operation: HermesReplyOperation, stop: Bool,
                            deadline: Date, wallDeadline: ContinuousClock.Instant) async throws -> Bool? {
        let logicalSeconds = deadline.timeIntervalSince(await clock.now())
        let remaining = wallDeadline - ContinuousClock.now
        let wallSeconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        let budget = min(logicalSeconds, wallSeconds, operation.client.maximumRequestDuration)
        guard budget > 0, cleanup == nil, !operation.isCancelled, isCurrent(operation.selection) else { return nil }
        try ensureNotRefused(operation.connection)

        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            let expiry = ContinuousClock.now.advanced(by: .seconds(budget))
            let request = Task { [weak self] in
                let result: Result<Bool, Error>
                do {
                    guard try await self?.canStartCleanup(operation) == true else {
                        await self?.finishCleanup(.success(false), id: id, operation: operation)
                        return
                    }
                    let terminal: Bool
                    if stop {
                        terminal = try await operation.client.stop(id: id, timeout: budget)?.isTerminal == true
                    } else {
                        terminal = try await operation.client.run(id: id, timeout: budget).status.isTerminal
                    }
                    result = .success(terminal)
                } catch HermesClientError.runNotFound {
                    result = .success(true)
                } catch {
                    result = .failure(error)
                }
                await self?.finishCleanup(result, id: id, operation: operation)
            }
            let timer = Task { [weak self] in
                do { try await Task.sleep(until: expiry, clock: .continuous) } catch { return }
                await self?.expireCleanup(token)
            }
            cleanup = CleanupRequest(token: token, request: request, timer: timer, waiter: continuation)
        }
    }

    private func canStartCleanup(_ operation: HermesReplyOperation) throws -> Bool {
        try Task.checkCancellation()
        guard isCurrent(operation.selection), !operation.isCancelled else { return false }
        try ensureNotRefused(operation.connection)
        return true
    }

    private struct CleanupRequest {
        let token: UUID
        let request: Task<Void, Never>
        let timer: Task<Void, Never>
        var waiter: CheckedContinuation<Bool?, Error>?
    }

    private func expireCleanup(_ token: UUID) {
        guard cleanup?.token == token else { return }
        cleanup?.request.cancel()
        cleanup?.waiter?.resume(returning: nil)
        cleanup?.waiter = nil
    }

    private func finishCleanup(_ result: Result<Bool, Error>, id: String, operation: HermesReplyOperation) async {
        let outcome: Result<Bool?, Error>
        switch result {
        case .success(let terminal):
            if terminal { await settle(id, for: operation) }
            outcome = .success(terminal)
        case .failure(let error) where error as? HermesClientError == .unauthorized:
            noteRefusal(of: operation.connection)
            outcome = .failure(ConversationServiceError.modelUnavailable(.hermesUnauthorized))
        case .failure(let error as ConversationServiceError):
            outcome = .failure(error)
        case .failure:
            outcome = .success(false)
        }
        cleanup?.timer.cancel()
        let waiter = cleanup?.waiter
        cleanup = nil
        waiter?.resume(with: outcome)
    }

    private func refusalRevision(for connection: HermesConnection) -> UUID? {
        rejectedConnections.first { $0.connection == connection }?.revision
    }

    /// An actual 401 refreshes only the refusal for the connection that sent the request.
    private func noteRefusal(of refused: HermesConnection) {
        rejectedConnections.removeAll { $0.connection == refused }
        rejectedConnections.append((refused, UUID()))
    }

    private func ensureNotRefused(_ connection: HermesConnection) throws {
        if refusalRevision(for: connection) != nil {
            throw ConversationServiceError.modelUnavailable(.hermesUnauthorized)
        }
    }

    private func throwRefusal(of refused: HermesConnection) throws -> Never {
        noteRefusal(of: refused)
        throw ConversationServiceError.modelUnavailable(.hermesUnauthorized)
    }

    private func settle(_ id: String, for operation: HermesReplyOperation) async {
        await updateRecord(for: operation) {
            $0.unsettledRunIDs.removeAll { $0 == id }
        }
    }

    func reset() async {
        active?.cancel()
        if let active { scheduleStop(for: active) }
        releaseActiveTurn()
        let reservation = UUID()
        starting = reservation
        defer { if starting == reservation { starting = nil } }
        epoch &+= 1
        hasUnsubmittedHistory = false
        needsFreshHistory = false
        releaseHistoryPreparation()
        let requestedEpoch = epoch
        await loadRecord()
        let current = await connection()
        guard requestedEpoch == epoch else { return }
        let origin = current?.origin ?? record?.origin
        let sameOrigin = record?.origin == origin
        if !sameOrigin { originEpoch &+= 1 }
        let unsettled = sameOrigin ? record?.unsettledRunIDs ?? [] : []
        prepared = true
        pendingSubmissions.removeAll()
        unresolvedSubmission = false
        if let origin {
            await enqueueSave(HermesSessionRecord(origin: origin, sessionID: makeSessionID(), unsettledRunIDs: unsettled)).value
        }
        if requestedEpoch == epoch { setState(.ready) }
    }

    func prepareMemory() async throws {
        let requestedEpoch = epoch
        guard let current = await connection() else {
            if requestedEpoch == epoch { setState(.ready) }
            return
        }
        guard refusalRevision(for: current) == nil else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        guard let selection = await selectRecord(for: current, requestedEpoch: requestedEpoch) else { return }
        try await waitForHistory(in: selection)
        guard isCurrent(selection), !Task.isCancelled else { return }
        if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
        guard !prepared else { return }

        // History rows have no identity shared with run results. Keep this client's submission
        // and adoption on one side of the snapshot.
        let preparation = UUID()
        preparingHistory = preparation
        defer { if preparingHistory == preparation { releaseHistoryPreparation() } }
        while let active, isCurrent(active.selection), isCurrent(selection), !Task.isCancelled {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        // Retry a superseded snapshot once while continuing to hold the preparation gate.
        for attempt in 0...1 {
            guard let selected = latestSelection(in: selection) else { return }
            try Task.checkCancellation()
            if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
            let snapshot = selected.record
            if snapshot.hasTurns || snapshot.hasUncertainSubmission {
                do {
                    guard let result = try await readHistory(current, selected),
                          isCurrent(selected, tipRevision: result.tipRevision) else {
                        guard isCurrent(selection) else { return }
                        if attempt == 0 { continue }
                        throw ConversationMemoryError.unavailable
                    }
                    try Task.checkCancellation()
                    if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
                    hasUnsubmittedHistory = true
                } catch is HermesClientError {
                    // An ordinary offline failure keeps the conversation usable.
                    guard isCurrent(selection) else { return }
                    try Task.checkCancellation()
                    if selected.tipRevision != tipRevision, attempt == 0 { continue }
                    if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
                    guard !needsFreshHistory else { throw ConversationMemoryError.unavailable }
                }
            }
            prepared = true
            setState(.ready)
            return
        }
    }

    func transcript() async throws -> [HermesTranscriptEntry] {
        let requestedEpoch = epoch
        guard let current = await connection() else { throw ConversationServiceError.modelUnavailable(.hermesNotConfigured) }
        guard refusalRevision(for: current) == nil else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        guard let selected = await selectRecord(for: current, requestedEpoch: requestedEpoch), isCurrent(selected),
              selected.record.hasTurns || selected.record.hasUncertainSubmission else { return [] }
        guard let result = try await readHistory(current, selected, fromTranscript: true),
              isCurrent(selected, tipRevision: result.tipRevision) else { return [] }
        return Self.decodeHistory(result.history)
    }

    /// 前の会話を Hermes から読む（返事の準備と履歴画面で共通の規則）。世代が進んでいたら nil（結果を捨てる）。
    /// - 読めたら記録の session を Hermes の tip にそろえ、会話があれば受付済みとして残す（受付の分からない送信の後でも、失われたら明示できる）。
    /// - 404: 受付済みの session は失われた会話（restoreFailed）。受付の分からない送信だけなら、まだ始まっていない空の会話。
    /// - 401: この接続の拒否として記録する。
    /// それ以外の失敗は呼び出し側が決める（返事の準備はキャッシュを保ち、履歴画面は失敗を出す）。
    private func readHistory(_ current: HermesConnection, _ selected: HermesRecordSelection,
                             fromTranscript: Bool = false) async throws -> (history: HermesSessionHistory, tipRevision: UInt64)? {
        let snapshot = selected.record
        guard isCurrent(selected, tipRevision: selected.tipRevision) else { return nil }
        do {
            try ensureNotRefused(current)
            let history = try await client(current).history(
                sessionID: snapshot.sessionID, limit: fromTranscript ? Self.transcriptRows + Self.transcriptContextRows : 100)
            guard isCurrent(selected, tipRevision: selected.tipRevision), var updated = record else { return nil }
            try Task.checkCancellation()
            if fromTranscript, updated.sessionID != history.sessionID,
               preparingHistory != nil || hasUnsubmittedHistory || needsFreshHistory {
                needsFreshHistory = true
                if prepared {
                    prepared = false
                    setState(.unprepared)
                }
            }
            updated.sessionID = history.sessionID
            if !history.messages.isEmpty { updated.hasTurns = true }
            let write = enqueueSave(updated)
            let adoptedTipRevision = tipRevision
            await write.value
            return isCurrent(selected, tipRevision: adoptedTipRevision) ? (history, adoptedTipRevision) : nil
        } catch HermesClientError.sessionNotFound {
            guard isCurrent(selected, tipRevision: selected.tipRevision) else { return nil }
            // A successful prior turn (including one that finished during a retry) makes a 404 a lost session.
            guard snapshot.hasTurns else {
                return (HermesSessionHistory(sessionID: snapshot.sessionID, messages: []), tipRevision)
            }
            setState(.restoreFailed(.unavailable))
            throw ConversationMemoryError.unavailable
        } catch HermesClientError.unauthorized {
            noteRefusal(of: current)
            guard isCurrent(selected, tipRevision: selected.tipRevision) else { return nil }
            throw ConversationServiceError.modelUnavailable(.hermesUnauthorized)
        } catch {
            guard isCurrent(selected, tipRevision: selected.tipRevision) else { return nil }
            throw error
        }
    }

    func memoryState() -> ConversationMemoryState { state }
    func forgetConversation() async throws { throw ConversationMemoryError.unsupported }
    func retryMemoryOperation() async throws { prepared = false; setState(.unprepared); try await prepareMemory() }

    func memoryUpdates() -> AsyncStream<ConversationMemoryState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConversationMemoryState>.makeStream()
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func setState(_ value: ConversationMemoryState) {
        state = value
        for continuation in subscribers.values { continuation.yield(value) }
    }

    private func client(_ current: HermesConnection) -> HermesRunClient {
        HermesRunClient(endpoint: current.endpoint, credential: current.credential, transport: transport, clock: clock)
    }
    private func loadRecord() async {
        if load == nil { load = Task { await records.load() } }
        let value = await load?.value
        if !loaded {
            record = value
            unresolvedSubmission = value?.hasUncertainSubmission ?? false
            loaded = true
        }
    }
    private func selectRecord(for current: HermesConnection, requestedEpoch: UInt64) async -> HermesRecordSelection? {
        await loadRecord()
        guard requestedEpoch == epoch, !Task.isCancelled else { return nil }
        if let record, record.origin == current.origin {
            return HermesRecordSelection(record: record, epoch: epoch, originEpoch: originEpoch, tipRevision: tipRevision)
        }
        epoch &+= 1
        originEpoch &+= 1
        hasUnsubmittedHistory = false
        needsFreshHistory = false
        releaseHistoryPreparation()
        pendingSubmissions.removeAll()
        unresolvedSubmission = false
        if record != nil, let active {
            active.cancel()
            scheduleStop(for: active)
        }
        prepared = false
        setState(.unprepared)
        let value = HermesSessionRecord(origin: current.origin, sessionID: makeSessionID())
        let write = enqueueSave(value)
        let selected = HermesRecordSelection(record: value, epoch: epoch, originEpoch: originEpoch, tipRevision: tipRevision)
        await write.value
        return selected
    }

    private func waitForHistory(in selection: HermesRecordSelection, deadline: Date? = nil) async throws {
        while preparingHistory != nil, isCurrent(selection) {
            try Task.checkCancellation()
            let id = UUID()
            let timer = deadline.map { deadline in
                Task { [weak self, clock] in
                    do { try await clock.sleepUntilTurnDeadline(deadline) } catch { return }
                    await self?.finishHistoryWait(id, throwing: ConversationServiceError.replyTimedOut)
                }
            }
            defer { timer?.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { historyWaiters[id] = $0 }
            } onCancel: {
                Task { await self.finishHistoryWait(id, throwing: CancellationError()) }
            }
        }
    }

    private func finishHistoryWait(_ id: UUID, throwing error: Error) {
        historyWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func releaseHistoryPreparation() {
        preparingHistory = nil
        let waiters = historyWaiters.values
        historyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func checkPreparedHistory(for selection: HermesRecordSelection) throws {
        if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
        guard !needsFreshHistory || (prepared && tipRevision == selection.tipRevision) else {
            throw ConversationMemoryError.unavailable
        }
    }

    private func latestSelection(in selection: HermesRecordSelection) -> HermesRecordSelection? {
        guard isCurrent(selection), let record else { return nil }
        return HermesRecordSelection(record: record, epoch: epoch, originEpoch: originEpoch, tipRevision: tipRevision)
    }

    // Conversation ownership survives compaction. History also checks the tip revision it read.
    private func isCurrent(_ selected: HermesRecordSelection, tipRevision expectedTip: UInt64? = nil) -> Bool {
        epoch == selected.epoch && record?.origin == selected.record.origin
            && (expectedTip == nil || tipRevision == expectedTip)
    }

    // Run IDs survive a reset on the same origin. An origin replacement starts a new lifetime,
    // including a later return to the same origin.
    private func updateRecord(for operation: HermesReplyOperation, _ change: (inout HermesSessionRecord) -> Void) async {
        guard originEpoch == operation.selection.originEpoch,
              var value = record, value.origin == operation.selection.record.origin else { return }
        change(&value)
        await enqueueSave(value).value
    }

    private func enqueueSave(_ value: HermesSessionRecord) -> Task<Void, Never> {
        if record?.sessionID != value.sessionID { tipRevision &+= 1 }
        record = value
        let previous = save
        let store = records
        let write = Task { await previous?.value; await store.save(value) }
        save = write
        return write
    }
    private static func isDefiniteRefusal(_ error: Error) -> Bool {
        if error as? HermesClientError == .unauthorized { return true }
        if case HermesClientError.httpStatus(let code) = error { return (400..<500).contains(code) || code == 503 }
        return false
    }
    private static func present(_ error: Error) -> ConversationServiceError {
        if error as? HermesClientError == .unauthorized { return .modelUnavailable(.hermesUnauthorized) }
        if case HermesClientError.httpStatus(let code) = error, code == 429 || code == 503 { return .modelUnreachable }
        return .modelGenerationFailed
    }
    private static func speechPrefix(_ text: String) -> String {
        guard text.count > 2_000 else { return text }
        let prefix = String(text.prefix(2_000))
        guard let end = prefix.lastIndex(where: { "。！？!?\n".contains($0) }) else { return prefix }
        return String(prefix[...end])
    }
    /// 履歴画面に出すのは最新の `transcriptRows` 行。その前の `transcriptContextRows` 行は、境界の状態を知るためだけに読む
    /// （写真の頼み・結果・答えのやり取りは、間に Hermes の tool の行が入っても、ページの境界をまたぐことがある）。
    private static let transcriptRows = 100
    private static let transcriptContextRows = 20

    /// Hermes の履歴を表示の行にする。利用者の発言と猫の最終の返事だけを、届いた文字のまま並べる。
    /// 制御の行は話していないので出さない（首・表情の返事は言葉の部分だけ、look の返事と見た結果の行は出さない）。
    private static func decodeHistory(_ history: HermesSessionHistory) -> [HermesTranscriptEntry] {
        // 読んだ範囲の先頭では、直前の行が分からない（撮影の頼みが前のページにあることもある）。
        enum PhotoExchange { case unknown, ordinary, awaitingResult, awaitingAnswer }
        var photo: PhotoExchange = .unknown
        let firstShown = max(0, history.messages.count - transcriptRows)
        var entries: [HermesTranscriptEntry] = []
        for (index, message) in history.messages.enumerated() {
            guard !message.hasToolCalls, message.displayKind != "hidden",
                  let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let entry: HermesTranscriptEntry?
            switch message.role {
            case "user":
                if (photo == .unknown || photo == .awaitingResult), HermesDeviceResult.isResult(text) {
                    photo = .awaitingAnswer
                    entry = nil
                } else {
                    photo = .ordinary
                    entry = HermesTranscriptEntry(speaker: .user, text: text)
                }
            case "assistant":
                let previous = photo
                photo = .ordinary
                do {
                    if let control = try HermesDeviceActions.parse(text) {
                        if previous == .awaitingAnswer {
                            entry = nil  // 写真の答えの位置の制御は、棄却して話していない。
                        } else if control.actions.look == true {
                            photo = .awaitingResult
                            entry = nil
                        } else if previous == .unknown {
                            entry = nil  // 直前が分からない先頭の首・表情は、写真の答えとして棄却したものかもしれない。
                        } else {
                            entry = HermesTranscriptEntry(speaker: .cat, text: control.speech)
                        }
                    } else {
                        entry = HermesTranscriptEntry(speaker: .cat, text: text)
                    }
                } catch {
                    entry = nil
                }
            default: continue
            }
            if index >= firstShown, let entry { entries.append(entry) }
        }
        return entries
    }
}

/// 1 ターンの中の 1 回の run（発話か、端末の結果を渡す続き）。届いたか分からない送信は同じ key と同じ body で送り直す。
private struct HermesTurnLeg {
    let input: String
    let image: Data?
    let key: UUID
    let instructions: String
}

private struct HermesRecordSelection: Sendable {
    let record: HermesSessionRecord
    let epoch: UInt64
    let originEpoch: UInt64
    let tipRevision: UInt64
}

/// onTermination can run off the service actor. Its cancellation, run id and one-time stop claim are lock protected.
/// Adoption has one atomic decision before touching the stream (no stream callback runs under the lock).
private final class HermesReplyOperation: @unchecked Sendable {
    let client: HermesRunClient
    let connection: HermesConnection
    let selection: HermesRecordSelection
    /// そのターンのモデルと effort（ターンの初めに固定）。
    let options: HermesRunOptions?
    private let lock = NSLock()
    private var cancelled = false
    private var runID: String?
    private var deviceTask: Task<HermesDeviceFeedback, Error>?
    private var stopClaimed = false
    init(client: HermesRunClient, connection: HermesConnection, selection: HermesRecordSelection,
         options: HermesRunOptions? = nil) {
        self.client = client
        self.connection = connection
        self.selection = selection
        self.options = options
    }
    var sessionID: String { selection.record.sessionID }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return deviceTask
        }
        task?.cancel()
    }

    /// 中断をカメラにも届ける。HTTP の送信中は、遅れて返る run ID を受け取って停止できるようにしておく。
    func performDevice(_ action: @escaping @Sendable () async throws -> HermesDeviceFeedback) async throws -> HermesDeviceFeedback {
        let task = try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            let task = Task {
                try Task.checkCancellation()
                return try await action()
            }
            deviceTask = task
            return task
        }
        defer { lock.withLock { deviceTask = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 同じターンの続きの run も受け付ける。前の run は終端済みなので、stop の権利は新しい run に移す。
    func accept(_ id: String) { lock.withLock { runID = id; stopClaimed = false } }
    func markTerminal() { lock.withLock { stopClaimed = true } }
    func claimStop() -> String? {
        lock.withLock {
            guard !stopClaimed, let runID else { return nil }
            stopClaimed = true
            return runID
        }
    }
    func claimAdoption() -> Bool { lock.withLock { !cancelled } }
}
