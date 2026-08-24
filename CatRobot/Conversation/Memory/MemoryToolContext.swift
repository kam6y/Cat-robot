import Foundation

enum MemoryNotice: Equatable, Sendable {
    case remembered(String)
    case forgotten(String)
}

actor MemoryToolContext {
    private static let maximumSearchResults = 8
    private static let maximumSearchBytes = 1_024

    private let store: LocalMemoryStore
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var currentTurnID: UInt64?
    private var normalizedUserText = ""
    private var committedSnapshot: [MemoryFact] = []
    private var candidateFacts: [MemoryFact] = []
    private var searchedMemoryIDs = Set<UUID>()
    private var exposedSearchResultCount = 0
    private var exposedSearchByteCount = 0
    private var notices: [MemoryNotice] = []

    init(
        store: LocalMemoryStore,
        now: @escaping @Sendable () -> Date = { .now },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.now = now
        self.makeUUID = makeUUID
    }

    func beginTurn(id: UInt64, userText: String) async {
        generation &+= 1
        revision &+= 1
        let expectedGeneration = generation
        currentTurnID = nil
        normalizedUserText = ""
        committedSnapshot = []
        candidateFacts = []
        searchedMemoryIDs.removeAll()
        exposedSearchResultCount = 0
        exposedSearchByteCount = 0
        notices.removeAll()

        let snapshot = await store.committedFacts()
        guard generation == expectedGeneration else { return }

        currentTurnID = id
        normalizedUserText = normalized(userText)
        committedSnapshot = snapshot
        candidateFacts = snapshot
    }

    func search(query: String, limit: Int) async -> [MemoryFact] {
        guard limit > 0 else { return [] }

        let normalizedQuery = normalized(query)
        let ranked = candidateFacts.compactMap { fact -> (fact: MemoryFact, rank: Int)? in
            if normalizedQuery.isEmpty {
                return (fact, 0)
            }
            if fact.fact == normalizedQuery {
                return (fact, 0)
            }
            if fact.fact.range(of: normalizedQuery) != nil {
                return (fact, 1)
            }
            return nil
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.fact.updatedAt != rhs.fact.updatedAt { return lhs.fact.updatedAt > rhs.fact.updatedAt }
            return lowercaseID(lhs.fact) < lowercaseID(rhs.fact)
        }

        let countLimit = min(limit, Self.maximumSearchResults - exposedSearchResultCount)
        guard countLimit > 0 else { return [] }

        var selected: [MemoryFact] = []
        for item in ranked {
            guard selected.count < countLimit else { break }
            let proposed = selected + [item.fact]
            guard let byteCount = encodedSearchByteCount(for: proposed),
                  exposedSearchByteCount + byteCount <= Self.maximumSearchBytes else {
                break
            }
            selected = proposed
        }

        guard !selected.isEmpty else { return [] }
        searchedMemoryIDs.formUnion(selected.map(\.id))
        exposedSearchResultCount += selected.count
        exposedSearchByteCount += encodedSearchByteCount(for: selected) ?? 0
        return selected
    }

    func stageRemember(fact: String, supportingQuote: String) async -> String {
        let normalizedFact = normalized(fact)
        let normalizedQuote = normalized(supportingQuote)
        guard !normalizedFact.isEmpty, !normalizedQuote.isEmpty else {
            return "Remember rejected: fact and supporting quote are required."
        }
        guard normalizedUserText.range(of: normalizedQuote) != nil else {
            return "Remember rejected: supporting quote must match the current user text."
        }
        guard let turnID = currentTurnID else {
            return "Remember rejected: supporting quote must match the current user text."
        }

        let timestamp = now()
        if let index = candidateFacts.firstIndex(where: { $0.fact == normalizedFact }) {
            candidateFacts[index].supportingQuote = normalizedQuote
            candidateFacts[index].updatedAt = timestamp
            candidateFacts[index].sourceTurnID = turnID
        } else {
            candidateFacts.append(
                MemoryFact(
                    id: makeUUID(),
                    fact: normalizedFact,
                    supportingQuote: normalizedQuote,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    sourceTurnID: turnID
                )
            )
        }
        revision &+= 1
        notices.append(.remembered(normalizedFact))
        return "Remember staged: \(normalizedFact)"
    }

    func stageForget(memoryIDs: [UUID], supportingQuote: String) async -> String {
        guard !memoryIDs.isEmpty else {
            return "Forget rejected: provide at least one memory ID."
        }

        let normalizedQuote = normalized(supportingQuote)
        guard !normalizedQuote.isEmpty, normalizedUserText.range(of: normalizedQuote) != nil else {
            return "Forget rejected: supporting quote must match the current user text."
        }
        let requestedIDs = Set(memoryIDs)
        guard requestedIDs.count == memoryIDs.count,
              requestedIDs.isSubset(of: searchedMemoryIDs),
              requestedIDs.allSatisfy({ id in candidateFacts.contains(where: { $0.id == id }) }) else {
            return "Forget rejected: search for every memory ID in this turn first."
        }

        candidateFacts.removeAll { requestedIDs.contains($0.id) }
        revision &+= 1
        notices.append(.forgotten("\(memoryIDs.count) memory item(s)"))
        return "Forget staged: \(memoryIDs.count) memory item(s)."
    }

    func commitTurn() async throws -> [MemoryNotice] {
        let expectedGeneration = generation
        let expectedRevision = revision
        let factsToCommit = candidateFacts
        let noticesToReturn = notices

        try await store.replaceCommittedFacts(factsToCommit)

        guard generation == expectedGeneration, revision == expectedRevision else {
            return noticesToReturn
        }
        committedSnapshot = factsToCommit
        notices.removeAll()
        return noticesToReturn
    }

    func rollbackTurn() async {
        generation &+= 1
        revision &+= 1
        currentTurnID = nil
        normalizedUserText = ""
        candidateFacts = committedSnapshot
        searchedMemoryIDs.removeAll()
        exposedSearchResultCount = 0
        exposedSearchByteCount = 0
        notices.removeAll()
    }

    private func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    private func lowercaseID(_ fact: MemoryFact) -> String {
        fact.id.uuidString.lowercased()
    }

    private func encodedSearchByteCount(for facts: [MemoryFact]) -> Int? {
        let results = facts.map { MemorySearchResult(id: lowercaseID($0), fact: $0.fact) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(results).count
    }
}
