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
actor HermesConversationService: ReplyGenerating, ConversationMemoryManaging, ModelAvailabilityChecking, ConversationHistoryReading {
    nonisolated let supportsStableReplyPrefix = false
    private let connection: @Sendable () async -> HermesConnection?
    private let transport: any HermesTransport
    private let records: any HermesSessionRecordStore
    private let clock: any HermesClock
    private let timing: HermesConversationTiming
    private let makeSessionID: @Sendable () -> String
    private let makeIdempotencyKey: @Sendable () -> UUID
    private var load: Task<HermesSessionRecord?, Never>?
    private var loaded = false
    private var record: HermesSessionRecord?
    private var save: Task<Void, Never>?
    private var prepared = false
    private var state: ConversationMemoryState = .unprepared
    private var turns: [ConversationMemoryTurn] = []
    private var clarification: ConversationMemoryTurn?
    /// 401 を受けた接続（接続ごと）。どの要求の 401 でも記録し、明示の確認（recheckAvailability）でその接続を外すまで、その接続では何も送らない。
    /// 接続ごとに覚えるので、キーを替えた後に前のキーへ遅れて届いた 401 が今のキーの拒否を消すことはない。
    private var rejectedConnections: [HermesConnection] = []
    private var active: HermesReplyOperation?
    private var generation: Task<Void, Never>?
    private var starting: UUID?
    private var epoch: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<ConversationMemoryState>.Continuation] = [:]

    init(connection: @escaping @Sendable () async -> HermesConnection?,
         transport: any HermesTransport,
         records: any HermesSessionRecordStore,
         clock: any HermesClock = SystemHermesClock(),
         timing: HermesConversationTiming = HermesConversationTiming(),
         makeSessionID: @escaping @Sendable () -> String = { "catrobot-" + UUID().uuidString.lowercased() },
         makeIdempotencyKey: @escaping @Sendable () -> UUID = { UUID() }) {
        self.connection = connection
        self.transport = transport
        self.records = records
        self.clock = clock
        self.timing = timing
        self.makeSessionID = makeSessionID
        self.makeIdempotencyKey = makeIdempotencyKey
    }

    func availability() async -> ModelAvailability {
        guard let current = await connection() else { return .hermesNotConfigured }
        return rejectedConnections.contains(current) ? .hermesUnauthorized : .available
    }

    /// 拒否されたキーを、利用者が確かめ直したときだけ同じ資格情報で 1 回確かめる（自動では送り直さない）。
    /// 確かな 401 と取り消された確認は拒否のまま。届かなかった確認は拒否の根拠にせず、次のターンの答えに任せる。
    /// 端末の記録・履歴・session は変えない。
    func recheckAvailability() async {
        guard let current = await connection(), rejectedConnections.contains(current) else { return }
        do { _ = try await client(current).capabilities() } catch HermesClientError.unauthorized { return } catch {}
        guard !Task.isCancelled, rejectedConnections.contains(current) else { return }
        rejectedConnections.removeAll { $0 == current }
    }
    func prewarm() async {}

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        try Task.checkCancellation()
        let requestedEpoch = epoch
        if active?.isCancelled == true, let generation { await generation.value }
        try Task.checkCancellation()
        guard requestedEpoch == epoch else { throw ConversationServiceError.cancelled }
        guard starting == nil, active == nil else { throw ConversationServiceError.modelBusy }
        let reservation = UUID()
        starting = reservation
        defer { if starting == reservation { starting = nil } }
        guard let current = await connection() else { throw ConversationServiceError.modelUnavailable(.hermesNotConfigured) }
        guard !rejectedConnections.contains(current) else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        let prompt = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4_000 else { throw ConversationServiceError.inputTooLong }
        await selectRecord(for: current)
        guard starting == reservation else { throw ConversationServiceError.cancelled }
        if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
        try Task.checkCancellation()
        guard let snapshot = record else { throw ConversationMemoryError.unavailable }
        let operation = HermesReplyOperation(client: client(current), connection: current, sessionID: snapshot.sessionID)
        active = operation
        let instructions = HermesConversationInstructions.text(clarification: clarification)
        clarification = nil
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                operation.cancel()
                Task { await self?.stop(operation) }
            }
        }
        generation = Task { await self.generate(prompt, instructions: instructions, key: self.makeIdempotencyKey(),
                                                 connection: current, operation: operation, into: continuation) }
        return stream
    }

    private func generate(_ prompt: String, instructions: String, key: UUID, connection: HermesConnection,
                          operation: HermesReplyOperation, into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        defer { if active === operation { active = nil; generation = nil } }
        do {
            let start = await clock.now()
            let priorUncertainty = record?.hasUncertainSubmission ?? false
            try await cleanUpRuns(for: operation)
            guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
            guard !rejectedConnections.contains(connection) else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
            await updateRecord(origin: operation.origin) {
                if $0.sessionID == operation.sessionID { $0.hasUncertainSubmission = true }
            }
            var accepted: HermesRunHandle?
            var hadUncertainAttempt = false
            while accepted == nil {
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                guard await withinDeadline(start) else { throw ConversationServiceError.replyTimedOut }
                do {
                    try ensureNotRefused(connection)
                    accepted = try await operation.client.createRun(input: prompt, sessionID: operation.sessionID,
                                                                    idempotencyKey: key, instructions: instructions)
                } catch {
                    if Self.isDefiniteRefusal(error) {
                        await updateRecord(origin: operation.origin) {
                            if $0.sessionID == operation.sessionID { $0.hasUncertainSubmission = priorUncertainty || hadUncertainAttempt }
                        }
                        if error as? HermesClientError == .unauthorized { noteRefusal(of: connection) }
                        throw Self.present(error)
                    }
                    hadUncertainAttempt = true
                    // Retrying an uncertain, cancelled POST could start work that was never accepted.
                    guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                    try await clock.sleep(for: timing.submitRetryDelay)
                }
            }
            guard let accepted else { throw ConversationServiceError.modelGenerationFailed }
            await updateRecord(origin: operation.origin) {
                if $0.sessionID == operation.sessionID {
                    $0.hasTurns = true
                    $0.hasUncertainSubmission = priorUncertainty
                }
                if !$0.unsettledRunIDs.contains(accepted.runID) { $0.unsettledRunIDs.append(accepted.runID) }
            }
            // Publish the id only after its durable bookkeeping, so cancellation cannot settle it before it is recorded.
            operation.accept(accepted.runID)
            guard !operation.isCancelled else { await stop(operation); throw ConversationServiceError.cancelled }
            while await withinDeadline(start) {
                // 待ちの間に取り消されたら、次の照会を出さない。
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                let result: HermesRunState
                do {
                    try ensureNotRefused(connection)
                    result = try await operation.client.run(id: accepted.runID)
                }
                catch {
                    if error as? HermesClientError == .unauthorized { try throwRefusal(of: connection) }
                    guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                    try await clock.sleep(for: timing.pollInterval)
                    continue
                }
                if result.status.isTerminal {
                    await settle(accepted.runID, origin: operation.origin)
                    guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                    guard result.status == .completed,
                          let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                        throw ConversationServiceError.modelGenerationFailed
                    }
                    let spoken = Self.speechPrefix(output)
                    guard operation.claimAdoption() else { throw ConversationServiceError.cancelled }
                    if record?.origin == operation.origin, record?.sessionID == operation.sessionID {
                        turns.append(ConversationMemoryTurn(prompt: prompt, response: spoken))
                        turns = Array(turns.suffix(100))
                    }
                    continuation.yield(spoken)
                    setState(.ready)
                    continuation.finish()
                    return
                }
                guard !operation.isCancelled else { throw ConversationServiceError.cancelled }
                if result.status.rawValue == "waiting_for_approval" {
                    await stop(operation)
                    throw ConversationServiceError.modelGenerationFailed
                }
                try await clock.sleep(for: timing.pollInterval)
            }
            await stop(operation)
            throw ConversationServiceError.replyTimedOut
        } catch {
            continuation.finish(throwing: operation.isCancelled ? ConversationServiceError.cancelled : error)
        }
    }

    private func withinDeadline(_ start: Date) async -> Bool {
        let limit = Double(timing.turnDeadline.components.seconds) + Double(timing.turnDeadline.components.attoseconds) / 1e18
        return await clock.now().timeIntervalSince(start) < limit
    }

    private func stop(_ operation: HermesReplyOperation) async {
        guard let id = operation.claimStop() else { return }
        do {
            try ensureNotRefused(operation.connection)
            if try await operation.client.stop(id: id)?.isTerminal == true { await settle(id, origin: operation.origin) }
        } catch HermesClientError.runNotFound { await settle(id, origin: operation.origin) }
        catch HermesClientError.unauthorized { noteRefusal(of: operation.connection) }
        catch { /* Unknown remains in the record; neither ACK nor a disconnect proves termination. */ }
    }

    /// 取り消されたら次の要求を出さない（次のターンはこの worker の終了を待つ）。送信中の 1 本の答えは記録に反映する。
    /// 401 を受けたら後始末をやめ、そのターンを送らずに終える（前のキーへの 401 でも、そのキーではもう送らない）。
    private func cleanUpRuns(for operation: HermesReplyOperation) async throws {
        let client = operation.client, origin = operation.origin
        for id in record?.unsettledRunIDs ?? [] {
            guard !operation.isCancelled else { return }
            do {
                try ensureNotRefused(operation.connection)
                if try await client.stop(id: id)?.isTerminal == true { await settle(id, origin: origin); continue }
            } catch HermesClientError.runNotFound { await settle(id, origin: origin); continue }
            catch HermesClientError.unauthorized { try throwRefusal(of: operation.connection) }
            catch {}
            guard !operation.isCancelled else { return }
            do {
                try ensureNotRefused(operation.connection)
                if try await client.run(id: id).status.isTerminal { await settle(id, origin: origin) }
            } catch HermesClientError.runNotFound { await settle(id, origin: origin) }
            catch HermesClientError.unauthorized { try throwRefusal(of: operation.connection) }
            catch {}
        }
    }

    /// 401 を、その要求の接続の拒否として覚える（今の接続は読み直さない。前のキーへの遅い 401 は前のキーだけを拒否にする）。
    private func noteRefusal(of refused: HermesConnection) {
        if !rejectedConnections.contains(refused) { rejectedConnections.append(refused) }
    }

    /// 認証付きの要求を出す直前に、その要求の接続がもう拒否されていないか確かめる（並行する別の要求や前の worker が記録した拒否も守る）。
    /// 拒否の中なら送らず、401 を受けたのと同じ扱いにする。明示の確認（recheckAvailability）だけはこれを通らない。
    private func ensureNotRefused(_ connection: HermesConnection) throws {
        if rejectedConnections.contains(connection) { throw HermesClientError.unauthorized }
    }

    private func throwRefusal(of refused: HermesConnection) throws -> Never {
        noteRefusal(of: refused)
        throw ConversationServiceError.modelUnavailable(.hermesUnauthorized)
    }

    private func settle(_ id: String, origin: String) async {
        await updateRecord(origin: origin) { $0.unsettledRunIDs.removeAll { $0 == id } }
    }

    func reset() async {
        active?.cancel()
        if let active { Task { await self.stop(active) } }
        active = nil
        generation = nil
        starting = nil
        epoch &+= 1
        await loadRecord()
        let current = await connection()
        let origin = current?.origin ?? record?.origin
        let unsettled = record?.origin == origin ? record?.unsettledRunIDs ?? [] : []
        if let origin { await persist(HermesSessionRecord(origin: origin, sessionID: makeSessionID(), unsettledRunIDs: unsettled)) }
        turns = []
        clarification = nil
        prepared = true
        setState(.ready)
    }

    func prepareMemory() async throws {
        guard let current = await connection() else { setState(.ready); return }
        guard !rejectedConnections.contains(current) else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        await selectRecord(for: current)
        if case .restoreFailed = state { throw ConversationMemoryError.unavailable }
        guard !prepared, let snapshot = record else { return }
        if snapshot.hasTurns || snapshot.hasUncertainSubmission {
            let generation = epoch
            do {
                guard let history = try await readHistory(current, snapshot) else { return }
                turns = Self.pairs(Self.entries(history))
            } catch is HermesClientError, is CancellationError {
                // 届かなかった読み込みは会話を止めない（宛先判定に添える直近の往復は空で続ける）。
                guard generation == epoch else { return }
                turns = []
            }
        }
        prepared = true
        setState(.ready)
    }

    func transcript() async throws -> [HermesTranscriptEntry] {
        guard let current = await connection() else { throw ConversationServiceError.modelUnavailable(.hermesNotConfigured) }
        guard !rejectedConnections.contains(current) else { throw ConversationServiceError.modelUnavailable(.hermesUnauthorized) }
        await selectRecord(for: current)
        guard let snapshot = record, snapshot.hasTurns || snapshot.hasUncertainSubmission else { return [] }
        return try await readHistory(current, snapshot).map(Self.entries) ?? []
    }

    /// 前の会話を Hermes から読む（返事の準備と設定の履歴の共通の規則）。世代が進んでいたら nil（結果を捨てる）。
    /// - 読めたら記録の session を Hermes の tip にそろえ、会話があれば受付済みとして残す（受付の分からない送信の後でも、失われたら明示できる）。
    /// - 404: 受付済みの session は失われた会話（restoreFailed）。受付の分からない送信だけなら、まだ始まっていない空の会話。
    /// - 401: この接続の拒否として記録する。
    /// それ以外の失敗は呼び出し側が決める（返事の準備は空の会話で続け、設定の履歴は失敗を出す）。
    private func readHistory(_ current: HermesConnection, _ snapshot: HermesSessionRecord) async throws -> HermesSessionHistory? {
        let generation = epoch
        do {
            try ensureNotRefused(current)
            let history = try await client(current).history(sessionID: snapshot.sessionID)
            guard generation == epoch else { return nil }
            await updateRecord(origin: current.origin) {
                $0.sessionID = history.sessionID
                if !history.messages.isEmpty { $0.hasTurns = true }
            }
            guard generation == epoch else { return nil }
            return history
        } catch HermesClientError.sessionNotFound {
            guard generation == epoch else { return nil }
            guard snapshot.hasTurns else { return HermesSessionHistory(sessionID: snapshot.sessionID, messages: []) }
            setState(.restoreFailed(.unavailable))
            throw ConversationMemoryError.unavailable
        } catch HermesClientError.unauthorized {
            try throwRefusal(of: current)
        }
    }

    func recordExternalTurn(prompt: String, response: String) async {
        if let current = await connection() { await selectRecord(for: current) }
        let turn = ConversationMemoryTurn(prompt: prompt, response: response)
        clarification = turn
        turns.append(turn)
    }
    func memoryState() -> ConversationMemoryState { state }
    func recentTurns() -> [ConversationMemoryTurn] { turns }
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
        if !loaded { record = value; loaded = true }
    }
    private func selectRecord(for current: HermesConnection) async {
        await loadRecord()
        if record?.origin != current.origin {
            if record != nil { turns = []; clarification = nil; epoch &+= 1 }
            prepared = false
            setState(.unprepared)
            await persist(HermesSessionRecord(origin: current.origin, sessionID: makeSessionID()))
        }
    }
    private func updateRecord(origin: String, _ change: (inout HermesSessionRecord) -> Void) async {
        guard var value = record, value.origin == origin else { return }
        change(&value)
        await persist(value)
    }
    private func persist(_ value: HermesSessionRecord) async {
        record = value
        let previous = save
        let store = records
        let write = Task { await previous?.value; await store.save(value) }
        save = write
        await write.value
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
    private static func entries(_ history: HermesSessionHistory) -> [HermesTranscriptEntry] {
        history.messages.compactMap { message in
            guard !message.hasToolCalls, message.displayKind != "hidden",
                  let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            switch message.role {
            case "user": return HermesTranscriptEntry(speaker: .user, text: text)
            case "assistant": return HermesTranscriptEntry(speaker: .cat, text: text)
            default: return nil
            }
        }
    }
    private static func pairs(_ entries: [HermesTranscriptEntry]) -> [ConversationMemoryTurn] {
        var prompt: String?
        var result: [ConversationMemoryTurn] = []
        for entry in entries {
            switch entry.speaker {
            case .user: prompt = entry.text
            case .cat:
                if let prompt { result.append(ConversationMemoryTurn(prompt: prompt, response: entry.text)) }
                prompt = nil
            }
        }
        return result
    }
}

/// onTermination can run off the service actor. Its cancellation, run id and one-time stop claim are lock protected.
/// Adoption has one atomic decision before touching the cache or stream (no stream callback runs under the lock).
private final class HermesReplyOperation: @unchecked Sendable {
    let client: HermesRunClient
    let connection: HermesConnection
    let sessionID: String
    private let lock = NSLock()
    private var cancelled = false
    private var runID: String?
    private var stopClaimed = false
    init(client: HermesRunClient, connection: HermesConnection, sessionID: String) {
        self.client = client; self.connection = connection; self.sessionID = sessionID
    }
    var origin: String { connection.origin }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func accept(_ id: String) { lock.withLock { runID = id } }
    func claimStop() -> String? {
        lock.withLock {
            guard !stopClaimed, let runID else { return nil }
            stopClaimed = true
            return runID
        }
    }
    func claimAdoption() -> Bool { lock.withLock { !cancelled } }
}
