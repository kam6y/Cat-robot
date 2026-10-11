import Foundation

enum LongTermMemoryWriteResult: Equatable, Sendable { case saved, duplicate, rejected }

protocol LongTermMemoryWriting: Sendable {
    func remember(_ text: String, category: LongTermFactCategory) async throws -> LongTermMemoryWriteResult
}

/// 長期メモの一覧と世代を管理する。cache の読み書きはすべてロックの中で行い、戻りの遅れた読み込みが
/// その間の削除を上書きしない。`consolidate` はロック保持中に呼ばれるので、マネージャへ呼び戻してはいけない。
actor LongTermMemoryManager: LongTermMemoryWriting {
    private let store: any LongTermMemoryStore
    private let consolidate: @Sendable ([LongTermFact]) async throws -> [LongTermFact]
    private var cached: [LongTermFact]?
    /// clear() のたびに進む。古い世代の writer からの書き込みは拒否する。
    private var generation: UInt64 = 0
    /// 読み書きを到着順に直列化する簡単なロック。await 中に別の変更が割り込み、古い一覧を保存し直すのを防ぐ。
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: any LongTermMemoryStore,
         consolidate: @escaping @Sendable ([LongTermFact]) async throws -> [LongTermFact] = { $0 }) {
        self.store = store
        self.consolidate = consolidate
    }

    func facts() async throws -> [LongTermFact] {
        await acquire(); defer { release() }
        return try await loadIfNeeded()
    }

    func remember(_ text: String, category: LongTermFactCategory) async throws -> LongTermMemoryWriteResult {
        try await remember(text, category: category, generation: generation)
    }

    func forget(id: UUID) async throws {
        await acquire(); defer { release() }
        var current = try await loadIfNeeded()
        current.removeAll { $0.id == id }
        try await store.save(current)
        cached = current
    }

    func clear() async throws {
        await acquire(); defer { release() }
        try await store.clear()
        cached = []
        generation &+= 1
    }

    func renderedBlock() async -> String {
        LongTermMemoryPolicy.render((try? await facts()) ?? [])
    }

    func makeWriter() -> any LongTermMemoryWriting {
        GenerationScopedWriter(manager: self, generation: generation)
    }

    fileprivate func remember(_ text: String, category: LongTermFactCategory, generation expected: UInt64) async throws -> LongTermMemoryWriteResult {
        let normalized = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LongTermMemoryPolicy.maximumFactLength))
        guard !normalized.isEmpty else { return .duplicate }
        await acquire(); defer { release() }
        guard generation == expected else { return .rejected }
        var current = try await loadIfNeeded()
        if current.contains(where: { $0.text == normalized }) { return .duplicate }
        current.append(LongTermFact(id: UUID(), category: category, text: normalized, createdAt: Date()))
        if LongTermMemoryPolicy.exceedsLimits(current) {
            if let merged = try? await consolidate(current), !LongTermMemoryPolicy.exceedsLimits(merged), !merged.isEmpty {
                current = merged
            } else {
                current = LongTermMemoryPolicy.trimmed(current)
            }
        }
        try await store.save(current)
        cached = current
        return .saved
    }

    /// ロック保持中にだけ呼ぶ。読み込みに失敗したときは cache せず、次回に読み直す。
    private func loadIfNeeded() async throws -> [LongTermFact] {
        if let cached { return cached }
        let loaded = try await store.load()
        cached = loaded
        return loaded
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// 作成時点の世代に固定された書き込み口。セッションごとに 1 つ作ってツールに渡す。
private struct GenerationScopedWriter: LongTermMemoryWriting {
    let manager: LongTermMemoryManager
    let generation: UInt64
    func remember(_ text: String, category: LongTermFactCategory) async throws -> LongTermMemoryWriteResult {
        try await manager.remember(text, category: category, generation: generation)
    }
}
