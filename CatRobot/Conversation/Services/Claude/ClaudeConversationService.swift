import Foundation
import FoundationModels

struct ConversationBudget: Equatable, Sendable {
    /// 現行モデルの枠（1M トークン）に対して小さいが、5 分で切れるキャッシュを書き直す費用で上限を決めている。
    var compactionTriggerCharacters = 12_000
    var retainedCharacters = 4_000
    var summaryCharacterLimit = 1_200
    var maximumPromptCharacters = 4_000
    static let `default` = ConversationBudget()
}

struct ShortTermMemory: Equatable, Sendable {
    var summary = ""
    var turns: [ConversationMemoryTurn] = []
    var characters: Int { turns.reduce(0) { $0 + $1.prompt.count + $1.response.count } }
    /// 直近から数えて minimumCharacters 以上になる位置（往復単位で切り上げ）。
    func retentionStart(minimumCharacters: Int) -> Int {
        var index = turns.count, retained = 0
        while index > 0, retained < minimumCharacters {
            index -= 1
            retained += turns[index].prompt.count + turns[index].response.count
        }
        return index
    }
}

/// Claude の返答、短期記憶（要約＋直近の往復）、その永続化を 1 つのアクターで持つ。
/// セッションは「無効化されるまで使い続ける」。無効化は 圧縮・失敗・取消・reset・forget・外部往復 のときだけ。
/// モデル設定の変更は次のセッション生成時に反映する（進行中のセッションでは切り替えない）。
actor ClaudeConversationService: ReplyGenerating, ConversationMemoryManaging, ModelAvailabilityChecking {
    nonisolated let supportsStableReplyPrefix = true

    private let factory: any ConversationSessionFactory
    private let memoryStore: any ConversationMemoryStore
    private let longTermMemory: LongTermMemoryManager
    private let toolProvider: any ConversationToolProvider
    private let configuration: @Sendable () async -> ConversationModelConfiguration
    private let usage: any ConversationUsageMetering
    private let compatibilityID: String
    private let budget: ConversationBudget

    /// 生きているセッションを作ったときのモデル。利用量の集計はこれで行う（設定変更は次のセッションから）。
    private struct CachedSession: Sendable {
        let client: any ConversationSessionClient
        let model: ConversationModelChoice
    }

    private var memory = ShortTermMemory()
    private var session: CachedSession?
    /// セッションを無効化するたびに進む世代。生成途中に無効化が入った古いセッションは登録しない。
    private var sessionEpoch: UInt64 = 0
    /// 生きているセッションを作ったときの長期メモの削除世代。設定で事実を消したら次の返答の前に作り直す。
    private var sessionFactsRevision: UInt64 = 0
    private var generation: Task<Void, Never>?
    private var isGenerating: Bool { generation != nil }

    private var persistenceState: ConversationMemoryState = .unprepared
    private var subscribers: [UUID: AsyncStream<ConversationMemoryState>.Continuation] = [:]
    private var prepared = false
    private var revision: UInt64 = 0
    private var operationEpoch: UInt64 = 0
    private var preparation: Task<Void, Error>?
    private var saveRetry: Task<Void, Error>?
    private var forgetting: Task<Void, Error>?

    init(factory: any ConversationSessionFactory,
         memoryStore: any ConversationMemoryStore,
         longTermMemory: LongTermMemoryManager,
         tools: any ConversationToolProvider,
         configuration: @escaping @Sendable () async -> ConversationModelConfiguration,
         usage: any ConversationUsageMetering,
         compatibilityID: String = ClaudeMemoryCompatibility.current,
         budget: ConversationBudget = .default) {
        self.factory = factory
        self.memoryStore = memoryStore
        self.longTermMemory = longTermMemory
        self.toolProvider = tools
        self.configuration = configuration
        self.usage = usage
        self.compatibilityID = compatibilityID
        self.budget = budget
    }

    // MARK: ModelAvailabilityChecking

    func availability() async -> ModelAvailability {
        do {
            try await factory.authenticateIfNeeded()
            return .available
        } catch {
            return ClaudeErrorMapper.availability(error)
        }
    }

    // MARK: ReplyGenerating

    func prewarm() async {
        guard (try? await prepareMemory()) != nil, forgetting == nil else { return }
        // 返答生成中は新しいセッションを作らない。generate は圧縮後の記憶をローカルに持ち self.memory はまだ圧縮前なので、
        // ここで作ると圧縮前のセッションが先に登録され、返答がそれに揃ってしまう。
        guard !isGenerating else { return }
        guard let session = await currentSession() else { return }   // 生成中に無効化されたセッションは温めない
        await session.client.prewarm()
    }

    func streamReply(to utterance: String) async throws -> AsyncThrowingStream<String, Error> {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        let epoch = operationEpoch
        try await prepareMemory()
        await awaitCancelledGeneration()
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        guard operationEpoch == epoch else { throw ConversationServiceError.cancelled }
        try Task.checkCancellation()
        guard !isGenerating, saveRetry == nil else { throw ConversationServiceError.modelBusy }
        if case .forgetFailed = persistenceState { throw ConversationMemoryError.unavailable }
        let prompt = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.count <= budget.maximumPromptCharacters else { throw ConversationServiceError.inputTooLong }

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let worker = Task { await self.generate(prompt, epoch: epoch, into: continuation) }
        generation = worker
        continuation.onTermination = { termination in
            if case .cancelled = termination { worker.cancel() }
        }
        return stream
    }

    /// 短期記憶だけを捨てる。長期メモは残す（「新しい会話を始める」と文脈超過の復旧）。
    func reset() async {
        guard forgetting == nil else { return }
        if case .forgetFailed = persistenceState { return }   // 削除失敗中は再試行で削除が成功するまで何も書かない
        let epoch = operationEpoch
        await generation?.value
        // 待機中に forget が始まった場合は、削除の後に空の記憶を書き戻さない。
        guard forgetting == nil, operationEpoch == epoch else { return }
        memory = ShortTermMemory()
        invalidateSession()
        revision &+= 1
        if prepared { try? await saveMemory(epoch: epoch) }
    }

    /// 端末内モデルで答えた往復を記憶に加える。Claude の生きたセッションには無い内容なので、次回は作り直す。
    func recordExternalTurn(prompt: String, response: String) async {
        guard prepared, forgetting == nil else { return }
        let epoch = operationEpoch
        await awaitCancelledGeneration()
        // 待機中に呼び出しが取り消された場合、forget が始まった（または終わった）場合は、往復を書き戻さない。
        guard !Task.isCancelled, prepared, forgetting == nil, operationEpoch == epoch, !isGenerating else { return }
        if case .forgetFailed = persistenceState { return }
        memory.turns.append(ConversationMemoryTurn(prompt: prompt, response: response))
        revision &+= 1
        invalidateSession()
        try? await saveMemory(epoch: epoch)
    }

    /// 取り消し済みのターンが後始末（generation = nil）を終えるまで待つ。
    /// 利用側は購読の終了しか待たないので、取り消し直後の次のターンがここで後始末を追い越さないようにする。
    /// 進行中（取り消されていない）のターンは待たず、呼び出し側の modelBusy 判定に任せる。
    private func awaitCancelledGeneration() async {
        if isGenerating, let generation, generation.isCancelled { await generation.value }
    }

    private func generate(_ prompt: String, epoch: UInt64, into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        var failure: ConversationServiceError?
        // 設定で消した事実を生きているセッションが知り続けないよう、削除があれば作り直す（要約と直近の往復は残る）。
        if await longTermMemory.factsRevision != sessionFactsRevision { invalidateSession() }
        var candidate = memory
        var response = ""
        do {
            if candidate.characters >= budget.compactionTriggerCharacters {
                candidate = try await compact(candidate)
                invalidateSession()
            }
            guard let session = await currentSession(for: candidate) else { throw ConversationServiceError.cancelled }
            let source = await session.client.snapshots(for: prompt)
            for try await snapshot in source {
                try Task.checkCancellation()
                response = snapshot
                continuation.yield(snapshot)
            }
            try Task.checkCancellation()
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationServiceError.modelGenerationFailed
            }
            ReplyTraceContext.current?.mark(.generationFinished, outcome: .success)
            candidate.turns.append(ConversationMemoryTurn(prompt: prompt, response: response))
            guard !Task.isCancelled, epoch == operationEpoch else { throw ConversationServiceError.cancelled }
            memory = candidate
            revision &+= 1
            // 集計はこのターンを生成したセッションのモデルで行う（設定変更は次のセッションから）。
            await usage.recordTurn(model: session.model, promptCharacters: prompt.count, responseCharacters: response.count)
            try? await saveMemory(epoch: epoch)
        } catch {
            failure = Task.isCancelled || epoch != operationEpoch ? .cancelled : ClaudeErrorMapper.map(error)
            invalidateSession()
        }
        generation = nil
        ReplyTraceContext.current?.mark(.streamFinished, outcome: failure == nil ? .success : .generationFailure)
        continuation.finish(throwing: failure)
    }

    /// セッションとそのモデルをまとめて無効化し、世代を進める。
    private func invalidateSession() {
        session = nil
        sessionEpoch &+= 1
    }

    private func currentSession() async -> CachedSession? { await currentSession(for: memory) }

    /// 生きているセッションを返す。無ければ memory から作って登録する。
    /// memory・sessionEpoch・operationEpoch は呼び出し側の判定と同じ actor 区間（最初の await の前）で採取する。
    /// 生成の await 中に無効化（圧縮・失敗・reset・forget・外部往復）が入ったら、作ったものは登録せず nil を返す。
    /// 無効化は無いが他の生成が先に登録していた場合（prewarm と返答が同時に作ったとき）は、先に登録された方に揃える。
    private func currentSession(for memory: ShortTermMemory) async -> CachedSession? {
        if let session { return session }
        let expectedSession = sessionEpoch
        let epoch = operationEpoch
        let trace = ReplyTraceContext.current
        trace?.mark(.sessionStarted)
        let settings = await configuration()
        // 世代を先に読む。間に削除が入っても次の返答で作り直すだけで、古い事実を抱え続けることはない。
        let factsRevision = await longTermMemory.factsRevision
        let facts = await longTermMemory.renderedBlock()
        let writer = await longTermMemory.makeWriter()
        let instructions = ConversationInstructions(longTermFacts: facts, summary: memory.summary, recentTurns: memory.turns).text
        let client = await factory.makeReplySession(
            ConversationSessionConfiguration(model: settings.model, effort: settings.effort, instructions: instructions),
            tools: toolProvider.tools(memory: writer))
        guard sessionEpoch == expectedSession, operationEpoch == epoch, forgetting == nil else {
            trace?.mark(.sessionFinished, outcome: .cancelled)
            return nil
        }
        if let session {
            trace?.mark(.sessionFinished, outcome: .success)
            return session
        }
        let created = CachedSession(client: client, model: settings.model)
        session = created
        sessionFactsRevision = factsRevision
        trace?.mark(.sessionFinished, outcome: .success)
        return created
    }

    private func compact(_ original: ShortTermMemory) async throws -> ShortTermMemory {
        let keepFrom = original.retentionStart(minimumCharacters: budget.retainedCharacters)
        guard keepFrom > 0 else { return original }
        let trace = ReplyTraceContext.current
        trace?.mark(.compactionStarted)
        var outcome = ReplyTraceOutcome.generationFailure
        defer { trace?.mark(.compactionFinished, outcome: outcome) }
        let request = ConversationSummaryRequest(previousSummary: original.summary,
                                                 evictedTurns: Array(original.turns[..<keepFrom]),
                                                 characterLimit: budget.summaryCharacterLimit)
        let summary = try await factory.summarize(request)
        guard !summary.isEmpty, summary.count <= budget.summaryCharacterLimit else {
            throw ConversationServiceError.modelGenerationFailed
        }
        outcome = .success
        return ShortTermMemory(summary: summary, turns: Array(original.turns[keepFrom...]))
    }

    // MARK: ConversationMemoryManaging（Gemma 版から移植。トークン数の検査は文字数に置き換え）

    func memoryState() -> ConversationMemoryState { persistenceState }

    func memoryUpdates() -> AsyncStream<ConversationMemoryState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConversationMemoryState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(persistenceState)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func publishMemory(_ state: ConversationMemoryState) {
        persistenceState = state
        for subscriber in subscribers.values { subscriber.yield(state) }
    }

    func prepareMemory() async throws {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        if case .forgetFailed = persistenceState { throw ConversationMemoryError.unavailable }
        if prepared { return }
        if case .restoreFailed(let error) = persistenceState { throw error }
        if let preparation { try await preparation.value; return }
        let epoch = operationEpoch
        publishMemory(.loading)
        let task = Task { try await self.restoreMemory(epoch: epoch) }
        preparation = task
        try await task.value
    }

    private func restoreMemory(epoch: UInt64) async throws {
        defer { if operationEpoch == epoch { preparation = nil } }
        do {
            let snapshot = try await memoryStore.load()
            var restored = ShortTermMemory()
            if let snapshot {
                try snapshot.validate(expectedCompatibilityID: compatibilityID)
                guard snapshot.summary.count <= budget.summaryCharacterLimit else { throw ConversationMemoryError.invalidData }
                restored.summary = snapshot.summary
                restored.turns = snapshot.turns
            }
            guard operationEpoch == epoch, forgetting == nil else { throw CancellationError() }
            memory = restored
            revision = snapshot?.revision ?? 0
            prepared = true
            publishMemory(.ready)
        } catch {
            guard operationEpoch == epoch, forgetting == nil else { throw CancellationError() }
            let issue = error as? ConversationMemoryError ?? .readFailed
            publishMemory(.restoreFailed(issue))
            throw issue
        }
    }

    private func snapshot() -> ConversationMemorySnapshot {
        ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: compatibilityID, revision: revision,
                                   savedAt: Date(), summary: memory.summary, turns: memory.turns)
    }

    /// ストア書き込み（save / clear）は開始順に完了させる。古い保存が clear を追い越して記憶を復活させないため。
    /// 待つのは直前のストア操作だけなので、generation / retry / forget のような所有者を待つ循環は生じない。
    /// 直前の操作が失敗しても次の操作は実行され、各呼び出し元には自分の操作のエラーだけが返る。
    /// 積んだ操作は呼び出し元の取消では追跡から外さない（storeTail を無条件に nil へ戻さない）。
    private var storeTail: Task<Void, Error>?
    /// 最新の保存要求の番号。古い保存の完了が最新の保存状態（.saving / .unsaved）を .ready に上書きしないための照合に使う。
    private var saveSerial: UInt64 = 0

    private func serializedStoreOperation(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = storeTail
        let task = Task<Void, Error> {
            _ = try? await previous?.value
            try await operation()
        }
        storeTail = task
        try await task.value
    }

    private func saveMemory(epoch: UInt64) async throws {
        // forget 開始後（operationEpoch が進んだ後）、forget 中、削除失敗中は新しい保存を始めない。
        guard operationEpoch == epoch, forgetting == nil else { throw ConversationMemoryError.unavailable }
        if case .forgetFailed = persistenceState { throw ConversationMemoryError.unavailable }
        let trace = ReplyTraceContext.current
        trace?.mark(.saveStarted)
        var outcome = ReplyTraceOutcome.saveWarning
        defer { trace?.mark(.saveFinished, outcome: outcome) }
        // snapshot の採取・保存番号の更新・enqueue の間に await を挟まない。
        let value = snapshot()
        saveSerial &+= 1
        let serial = saveSerial
        publishMemory(.saving)
        let store = memoryStore
        do {
            // クロージャはストア I/O だけ。同じキューやサービスへ呼び戻さない。
            try await serializedStoreOperation { try await store.save(value) }
            outcome = .success
            if operationEpoch == epoch, serial == saveSerial { publishMemory(.ready) }
        } catch {
            if operationEpoch == epoch, serial == saveSerial { publishMemory(.unsaved) }
            throw error
        }
    }

    func retryMemoryOperation() async throws {
        guard forgetting == nil else { throw ConversationMemoryError.unavailable }
        if let saveRetry { try await saveRetry.value; return }
        guard !isGenerating, preparation == nil else { throw ConversationServiceError.modelBusy }
        switch persistenceState {
        case .unsaved:
            let epoch = operationEpoch
            let task = Task { try await self.saveMemory(epoch: epoch) }
            saveRetry = task
            defer { saveRetry = nil }
            try await task.value
        case .restoreFailed:
            publishMemory(.unprepared)
            try await prepareMemory()
        case .forgetFailed:
            try await forgetConversation()
        default:
            break
        }
    }

    func forgetConversation() async throws {
        if let forgetting { try await forgetting.value; return }
        operationEpoch &+= 1
        publishMemory(.forgetting)
        let oldGeneration = generation
        let oldPreparation = preparation
        let oldRetry = saveRetry
        let task = Task {
            await oldGeneration?.value
            _ = try? await oldPreparation?.value
            _ = try? await oldRetry?.value
            self.preparation = nil
            self.saveRetry = nil
            do {
                let store = self.memoryStore
                // 先に始まった保存の完了を待ってから消す（クロージャはストア I/O だけ）。
                try await self.serializedStoreOperation { try await store.clear() }
                try await self.longTermMemory.clear()
                self.invalidateSession()
                self.memory = ShortTermMemory()
                self.revision = 0
                self.prepared = true
                self.publishMemory(.ready)
            } catch {
                self.publishMemory(.forgetFailed(.deleteFailed))
                throw ConversationMemoryError.deleteFailed
            }
        }
        forgetting = task
        defer { forgetting = nil }
        try await task.value
    }
}
