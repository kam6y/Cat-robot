import CryptoKit
import Foundation
import FoundationModels
import XCTest
@testable import CatRobot

/// Explicit paid acceptance run only. The inventory test is local and never constructs a model.
@MainActor
final class ClarificationHistoryModelTests: XCTestCase {
    private static let fixtureVersion = "issue29-v1"
    private static let sdkRevision = "0262e1a766c461a4268dcec656eca95dd74cebf8"
    private static let repetitions = 3
    private static let referenceOnly = "REFERENCE_ONLY_29"
    private static let preference = "私の好きな飲み物はほうじ茶です。覚えておいて。"
    private static let previous = "- 利用者の好きな音楽はジャズ。"

    private struct Classification: Sendable {
        let id: String
        let utterance: String
        let expected: [String]
        var request: AddressClassificationRequest {
            .init(utterance: utterance, clarification: .init(originalUtterance: "今日の天気はどう？"))
        }
    }
    private static let classifications: [Classification] = [
        .init(id: "hai", utterance: "はい", expected: ["addressed"]),
        .init(id: "un", utterance: "うん", expected: ["addressed"]),
        .init(id: "iie", utterance: "いいえ", expected: ["addressed"]),
        .init(id: "uun", utterance: "ううん", expected: ["addressed"]),
        .init(id: "ittayo", utterance: "言ったよ", expected: ["addressed"]),
        .init(id: "weather-confirmation", utterance: "そうそう、天気の", expected: ["addressed"]),
        .init(id: "denied-addressee", utterance: "いいえ、あなたには言ってない", expected: ["addressed"]),
        .init(id: "denied-mom", utterance: "違うよ、ママに言ったの", expected: ["addressed"]),
        .init(id: "cat-new-question", utterance: "猫ちゃん、5たす4はいくつ？", expected: ["addressed"]),
        .init(id: "unrelated-question", utterance: "明日の予定は？", expected: ["ambiguous"]),
        .init(id: "other-addressee", utterance: "ママ、鍵はどこ？", expected: ["notAddressed"]),
        .init(id: "self-talk", utterance: "これは独り言。疲れたな。", expected: ["notAddressed"]),
        .init(id: "unspecified-addressee", utterance: "部長に電話しておいて。", expected: ["notAddressed", "ambiguous"])
    ]

    private struct Reply: Sendable {
        let id: String
        let original: String
        let utterance: String
        let expectation: String
        let remember: String
    }
    private static let replies: [Reply] = [
        .init(id: "math-hai", original: "7たす5はいくつ？", utterance: "はい", expectation: "元の算数に12と答える", remember: "any"),
        .init(id: "math-natural", original: "7たす5はいくつ？", utterance: "言ったよ", expectation: "元の算数に12と答える", remember: "any"),
        .init(id: "math-denial", original: "7たす5はいくつ？", utterance: "いいえ、あなたには言ってない", expectation: "通常の1〜2文で短く受け止め、元の算数に12と回答しない", remember: "any"),
        .init(id: "new-question", original: "7たす5はいくつ？", utterance: "猫ちゃん、5たす4は？", expectation: "新しい算数に9と答える", remember: "any"),
        .init(id: "preference-denial", original: preference, utterance: "いいえ、それはママのこと。あなたには言ってない", expectation: "本人の好みとして保存しない。短く受け止める", remember: "none"),
        .init(id: "preference-confirmation", original: preference, utterance: "うん、私の好みだから覚えて", expectation: "本人のほうじ茶の好みをrememberで保存する", remember: "required")
    ]

    private struct Summary: Sendable {
        let id: String
        let previousSummary: String
        let reference: [ConversationMemoryTurn]
        let expectation: String
        let requiresNoContent: Bool
        @MainActor var request: ConversationSummaryRequest {
            .init(previousSummary: previousSummary,
                  evictedTurns: [.init(prompt: ClarificationHistoryModelTests.preference, response: ClarificationContext.question)],
                  referenceTurns: reference, characterLimit: 1_200)
        }
    }
    private static var summaries: [Summary] {
        let referenceFact = ConversationMemoryTurn(prompt: "参考だけの新しい話。合言葉は\(referenceOnly)。", response: "聞いたよ。")
        let confirmation = ConversationMemoryTurn(prompt: "うん、私の好みだよ。", response: "わかったよ。")
        let denial = ConversationMemoryTurn(prompt: "いいえ、それはママのこと。あなたには言ってない", response: "そっか、わかった。")
        return [
            .init(id: "confirmed-across-boundary", previousSummary: "", reference: [confirmation, referenceFact], expectation: "本人のほうじ茶の好みを残し、参考だけの合言葉を追加しない", requiresNoContent: false),
            .init(id: "denied-across-boundary", previousSummary: "", reference: [denial, referenceFact], expectation: "否定された発言を本人の好みや未解決の質問として残さず、参考だけの合言葉を追加しない", requiresNoContent: false),
            .init(id: "unconfirmed-empty", previousSummary: "", reference: [], expectation: "認められず残すものがないのでraw結果はnoContent、解決後の要約は空", requiresNoContent: true),
            .init(id: "previous-and-reference-only", previousSummary: previous, reference: [referenceFact], expectation: "前回の確定したジャズの好みを保ち、未確認のほうじ茶と参考だけの合言葉を追加しない", requiresNoContent: false),
            .init(id: "previous-and-denied", previousSummary: previous, reference: [denial], expectation: "否定された追加内容を混入せず、前回のジャズの好みを保つ。rawがnoContentなら前回要約をそのまま使う", requiresNoContent: false)
        ]
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func render(_ turns: [ConversationMemoryTurn], speaker: String = "猫") -> String {
        turns.map { "利用者: \($0.prompt)\n\(speaker): \($0.response)" }.joined(separator: "\n")
    }
    private static func model(_ choice: ConversationModelChoice) -> String { ClaudeSessionFactory.claudeModel(for: choice).id }
    private static func inventory() async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for fixture in classifications {
            let input = try ClaudeAddressModelClient.requestInput(for: fixture.request)
            // The production encoder may vary JSON key order. Hash the canonical logical input, not an unobserved wire body.
            let canonical = String(decoding: try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(input.prompt.utf8)), options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            rows.append(item(kind: "classification", id: fixture.id, model: model(.haiku5_5), instructions: input.instructions,
                             prompt: canonical, history: "", expectation: fixture.expected.joined(separator: "|"), outputLimit: nil))
        }
        for fixture in replies {
            let probe = try await replyProbe(fixture)
            let history = await probe.store.load()?.turns ?? []
            _ = try await collect(probe.service, prompt: fixture.utterance)
            guard let configuration = await probe.factory.replyConfiguration,
                  history == [.init(prompt: fixture.original, response: ClarificationContext.question)],
                  await probe.factory.replySessionCount == 1 else { throw TrialFailure.invalidProbe }
            rows.append(item(kind: "reply", id: fixture.id, model: model(.opus5_5), instructions: configuration.instructions,
                             prompt: fixture.utterance, history: render(history), expectation: fixture.expectation,
                             outputLimit: ClaudeSessionFactory.maximumResponseTokens))
        }
        for fixture in summaries {
            let probe = summaryProbe(fixture)
            _ = try await collect(probe.service, prompt: "要約の検証用の入力")
            guard let request = await probe.factory.summaryRequest, request == fixture.request,
                  await probe.factory.summaryCallCount == 1 else { throw TrialFailure.invalidProbe }
            rows.append(item(kind: "summary", id: fixture.id, model: model(.haiku5_5), instructions: ConversationSummaryRequest.instructions,
                             prompt: request.prompt, history: render(request.evictedTurns + request.referenceTurns, speaker: "AI"),
                             expectation: fixture.expectation, outputLimit: ClaudeSessionFactory.summaryMaximumResponseTokens))
        }
        return rows
    }
    private static func item(kind: String, id: String, model: String, instructions: String, prompt: String,
                             history: String, expectation: String, outputLimit: Int?) -> [String: Any] {
        ["kind": kind, "fixtureID": id, "model": model, "effort": "low", "repetitions": repetitions,
         "instructions": instructions, "prompt": prompt, "history": history, "expectation": expectation,
         "instructionsCharacters": instructions.count, "promptCharacters": prompt.count, "historyCharacters": history.count,
         "instructionsSHA256": hash(instructions), "promptSHA256": hash(prompt), "inputSHA256": hash(instructions + "\n\n" + prompt),
         "promptHashBasis": kind == "classification" ? "canonical logical JSON from production requestInput; internal encoder key order is not observed" : "production instructions and top-level prompt text; excludes tool/schema/wire encoding",
         "maximumResponseTokens": outputLimit.map { $0 as Any } ?? NSNull()]
    }

    func testFixtureInventoryAndPromptSizes() async throws {
        let rows = try await Self.inventory()
        XCTAssertEqual(Self.classifications.count, 13)
        XCTAssertEqual(Self.replies.count, 6)
        XCTAssertEqual(Self.summaries.count, 5)
        XCTAssertEqual(rows.count * Self.repetitions, 72)
        XCTAssertEqual(Set(rows.map { "\($0["kind"]!)/\($0["fixtureID"]!)" }).count, 24)
        let metadata: [String: Any] = ["fixtureVersion": Self.fixtureVersion, "sdkRevision": Self.sdkRevision,
                                     "topLevelTrials": 72, "haikuTrials": 54, "opusTrials": 18, "fixtures": rows,
                                     "usageAvailability": "notExposedByProductionAPI", "networkCalls": 0]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        let attachment = XCTAttachment(string: text)
        attachment.name = "clarification-fixture-inventory.json"; attachment.lifetime = .keepAlways
        add(attachment)
        print("CLARIFICATION_FIXTURE_INVENTORY " + text)
    }

    func testAcceptanceMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        let deviceDebug: Bool
#if targetEnvironment(simulator) || !DEBUG
        deviceDebug = false
#else
        deviceDebug = true
#endif
        // No auth lookup, model construction, or paid operation occurs before every gate passes.
        guard deviceDebug, environment["CLARIFICATION_HISTORY_MODEL_TESTS"] == "1",
              let runID = environment["CLARIFICATION_HISTORY_RUN_ID"], UUID(uuidString: runID) != nil else {
            throw XCTSkip("Explicit Debug real-device opt-in required; 0 model calls")
        }
        guard let head = environment["CLARIFICATION_HISTORY_SOURCE_HEAD"], head.count == 40,
              let digest = environment["CLARIFICATION_HISTORY_INPUT_SHA256"], digest.count == 64,
              environment["CLARIFICATION_HISTORY_SDK_REVISION"] == Self.sdkRevision else {
            XCTFail("The dedicated runner must provide the frozen source/SDK metadata")
            return
        }
        executionTimeAllowance = 3_600
        let inventory = try await Self.inventory()
        let evidence = try Evidence(runID: runID, metadata: [
            "schemaVersion": 1, "fixtureVersion": Self.fixtureVersion, "sourceHEAD": head, "inputSHA256": digest,
            "sdkRevision": Self.sdkRevision, "sdkVersion": "0.2.3", "repetitions": Self.repetitions,
            "expectedTrials": 72, "expectedHaikuTrials": 54, "expectedOpusTrials": 18,
            "fixtures": inventory, "usage": NSNull(), "usageAvailability": "notExposedByProductionAPI",
            "inputOrigin": "reply: production external record and session; summary: production compact request forwarded unchanged",
            "summaryReplyAfterCompaction": "fixed non-network client; no additional paid reply",
            "semanticReview": "required for every reply and summary; automatic completion is not final acceptance"
        ])
        let auth = ClaudeAuthConfiguration.live()
        guard auth != .missing else {
            try evidence.failRun("claudeCredentialMissing")
            XCTFail("The live app authentication is unavailable")
            return
        }
        do { try await ClaudeSessionFactory(auth: auth).authenticateIfNeeded() }
        catch { try evidence.failRun(Self.failure(error)); XCTFail("Authentication failed: " + Self.failure(error)); return }
        for repetition in 1...Self.repetitions {
            for fixture in Self.classifications {
                let row = inventory.first { $0["kind"] as? String == "classification" && $0["fixtureID"] as? String == fixture.id }!
                let index = try evidence.begin(row, repetition: repetition)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let target = try await Self.deadline(seconds: 25) { try await ClaudeAddressModelClient(auth: auth).classify(fixture.request) }
                    let name: String
                    switch target { case .addressed: name = "addressed"; case .ambiguous: name = "ambiguous"; case .notAddressed: name = "notAddressed" }
                    try evidence.finish(index, started: start, values: ["target": name], checks: ["expectedEnum": fixture.expected.contains(name)])
                } catch { try evidence.finish(index, started: start, error: error) }
            }
            for fixture in Self.replies {
                let row = inventory.first { $0["kind"] as? String == "reply" && $0["fixtureID"] as? String == fixture.id }!
                let index = try evidence.begin(row, repetition: repetition)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let probe = try await Self.replyProbe(fixture, live: ClaudeSessionFactory(auth: auth),
                        tools: AuditedRememberProvider(evidence: evidence, trialIndex: index))
                    let response = try await Self.deadline(seconds: 90) {
                        try await Self.collect(probe.service, prompt: fixture.utterance)
                    }
                    let facts = try await probe.memory.facts()
                    let callCount = evidence.toolCount(index)
                    var checks = ["nonempty": !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty]
                    let configuration = await probe.factory.replyConfiguration
                    checks["productionInstructionsMatchInventory"] = configuration?.instructions == row["instructions"] as? String
                    checks["oneReplySession"] = await probe.factory.replySessionCount == 1
                    if fixture.remember == "none" { checks["rememberCallCountZero"] = callCount == 0 }
                    if fixture.remember == "required" { checks["rememberCalledAndStored"] = callCount > 0 && !facts.isEmpty }
                    try evidence.finish(index, started: start, values: ["response": response,
                        "storedFacts": facts.map { ["text": $0.text, "category": $0.category.rawValue] }, "semanticReview": "pending"], checks: checks)
                } catch { try evidence.finish(index, started: start, error: error) }
            }
            for fixture in Self.summaries {
                let row = inventory.first { $0["kind"] as? String == "summary" && $0["fixtureID"] as? String == fixture.id }!
                let index = try evidence.begin(row, repetition: repetition)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let probe = Self.summaryProbe(fixture, live: ClaudeSessionFactory(auth: auth))
                    _ = try await Self.deadline(seconds: 45) { try await Self.collect(probe.service, prompt: "要約の検証用の入力") }
                    guard let result = await probe.factory.summaryResult, let request = await probe.factory.summaryRequest,
                          let saved = await probe.store.load() else { throw TrialFailure.invalidProbe }
                    let resolved = saved.summary
                    let rawKind: String, rawText: String
                    switch result { case .noContent: rawKind = "noContent"; rawText = ""; case .text(let text): rawKind = "text"; rawText = text }
                    var checks = ["lengthAtMost1200": resolved.count <= 1_200,
                                  "noReferenceOnlySentinel": !resolved.lowercased().contains(Self.referenceOnly.lowercased()),
                                  "productionCompactionRequestMatchesInventory": request == fixture.request && request.prompt == row["prompt"] as? String]
                    checks["oneSummaryCall"] = await probe.factory.summaryCallCount == 1
                    if fixture.requiresNoContent { checks["explicitNoContentAndEmpty"] = rawKind == "noContent" && resolved.isEmpty }
                    if fixture.id == "confirmed-across-boundary" || !fixture.previousSummary.isEmpty { checks["requiredContentNonempty"] = !resolved.isEmpty }
                    try evidence.finish(index, started: start, values: ["rawResultKind": rawKind, "rawResultText": rawText,
                        "resolvedSummary": resolved, "previousSummary": fixture.previousSummary, "semanticReview": "pending"], checks: checks)
                } catch { try evidence.finish(index, started: start, error: error) }
            }
        }
        try evidence.complete()
        XCTAssertEqual(evidence.count, 72)
        XCTAssertTrue(evidence.automaticChecksPassed, "Every trial must succeed; review all reply/summary semantics separately")
    }

    private enum TrialFailure: Error { case timeout, invalidProbe, unexpectedOperation }
    private static func deadline<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TrialFailure.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private static func failure(_ error: any Error) -> String {
        if let failure = error as? TrialFailure { return String(describing: failure) }
        return String(describing: ClaudeErrorMapper.map(error))
    }

    private struct Probe: Sendable {
        let service: ClaudeConversationService
        let factory: ProbeFactory
        let store: InMemoryConversationMemoryStore
        let memory: LongTermMemoryManager
    }
    private static func replyProbe(_ fixture: Reply, live: ClaudeSessionFactory? = nil,
                                   tools: any ConversationToolProvider = StaticToolProvider([])) async throws -> Probe {
        let factory = ProbeFactory(purpose: .reply, live: live)
        let store = InMemoryConversationMemoryStore()
        let memory = LongTermMemoryManager(store: InMemoryLongTermMemoryStore())
        let service = ClaudeConversationService(factory: factory, memoryStore: store, longTermMemory: memory,
            tools: tools, configuration: { .init(model: .opus5_5, effort: .low) })
        try await service.prepareMemory()
        await service.recordExternalTurn(prompt: fixture.original, response: ClarificationContext.question)
        return Probe(service: service, factory: factory, store: store, memory: memory)
    }
    private static func summaryProbe(_ fixture: Summary, live: ClaudeSessionFactory? = nil) -> Probe {
        let expected = fixture.request
        let snapshot = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: ClaudeMemoryCompatibility.current,
            revision: 1, savedAt: Date(), summary: expected.previousSummary, turns: expected.evictedTurns + expected.referenceTurns)
        let retainedCharacters = expected.referenceTurns.reduce(0) { $0 + $1.prompt.count + $1.response.count }
        let factory = ProbeFactory(purpose: .summary, live: live)
        let store = InMemoryConversationMemoryStore(snapshot: snapshot)
        let memory = LongTermMemoryManager(store: InMemoryLongTermMemoryStore())
        let service = ClaudeConversationService(factory: factory, memoryStore: store, longTermMemory: memory,
            tools: StaticToolProvider([]), configuration: { .init(model: .opus5_5, effort: .low) },
            budget: .init(compactionTriggerCharacters: 1, retainedCharacters: retainedCharacters))
        return Probe(service: service, factory: factory, store: store, memory: memory)
    }
    private nonisolated static func collect(_ service: ClaudeConversationService, prompt: String) async throws -> String {
        var text = ""
        for try await snapshot in try await service.streamReply(to: prompt) { text = snapshot }
        return text
    }
    private enum ProbePurpose: Equatable, Sendable { case reply, summary }
    /// Captures the actual production inputs; live mode forwards the selected operation unchanged.
    private actor ProbeFactory: ConversationSessionFactory {
        let purpose: ProbePurpose
        let live: ClaudeSessionFactory?
        private(set) var replyConfiguration: ConversationSessionConfiguration?
        private(set) var replySessionCount = 0
        private(set) var summaryRequest: ConversationSummaryRequest?
        private(set) var summaryResult: ConversationSummaryResult?
        private(set) var summaryCallCount = 0
        init(purpose: ProbePurpose, live: ClaudeSessionFactory?) { self.purpose = purpose; self.live = live }
        func authenticateIfNeeded() async throws { try await live?.authenticateIfNeeded() }
        func makeReplySession(_ configuration: ConversationSessionConfiguration, tools: [any Tool]) async -> any ConversationSessionClient {
            replyConfiguration = configuration; replySessionCount += 1
            if purpose == .reply, let live { return await live.makeReplySession(configuration, tools: tools) }
            return ProbeReply()
        }
        func summarize(_ request: ConversationSummaryRequest) async throws -> ConversationSummaryResult {
            guard purpose == .summary else { throw TrialFailure.unexpectedOperation }
            summaryRequest = request; summaryCallCount += 1
            let result: ConversationSummaryResult
            if let live { result = try await live.summarize(request) }
            else { result = .noContent }
            summaryResult = result
            return result
        }
        func consolidateFacts(_ facts: [LongTermFact]) async throws -> [LongTermFact] { throw TrialFailure.unexpectedOperation }
    }
    private struct ProbeReply: ConversationSessionClient {
        func prewarm() async {}
        func snapshots(for prompt: String) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.yield("要約と入力配線の検証用の固定返答。"); $0.finish() }
        }
    }
    private struct AuditedRememberProvider: ConversationToolProvider {
        let evidence: Evidence
        let trialIndex: Int
        func tools(memory: any LongTermMemoryWriting) -> [any Tool] {
            [AuditedRemember(actual: RememberTool(memory: memory), evidence: evidence, trialIndex: trialIndex)]
        }
    }

    /// Wraps the production tool without changing its definition or persistence behavior.
    private struct AuditedRemember: Tool {
        let actual: RememberTool
        let evidence: Evidence
        let trialIndex: Int
        var name: String { actual.name }
        var description: String { actual.description }
        func call(arguments: RememberTool.Arguments) async throws -> String {
            let id = try await evidence.beginTool(trialIndex, fact: arguments.fact, category: arguments.category)
            do {
                let output = try await actual.call(arguments: arguments)
                try await evidence.finishTool(trialIndex, id: id, output: output)
                return output
            } catch {
                try? await evidence.finishTool(trialIndex, id: id, output: nil, failure: String(describing: ClaudeErrorMapper.map(error)))
                throw error
            }
        }
    }

    @MainActor
    private final class Evidence {
        private let runID: String
        private let url: URL
        private var metadata: [String: Any]
        private var records: [[String: Any]] = []
        var count: Int { records.count }
        var automaticChecksPassed: Bool { count == 72 && records.allSatisfy { $0["outcome"] as? String == "success" } }
        init(runID: String, metadata: [String: Any]) throws {
            self.runID = runID; self.metadata = metadata
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClarificationHistory/\(runID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("results.json")
            self.metadata["state"] = "running"
            try save()
        }
        func begin(_ fixture: [String: Any], repetition: Int) throws -> Int {
            var record = fixture
            record["trialID"] = "\(fixture["kind"]!)/\(fixture["fixtureID"]!)/\(repetition)"
            record["repetition"] = repetition; record["outcome"] = "running"
            record["startedAt"] = ISO8601DateFormatter().string(from: Date())
            record["tools"] = [[String: Any]](); record["usage"] = NSNull()
            record["usageAvailability"] = "notExposedByProductionAPI"
            records.append(record); try save()
            return records.count - 1
        }
        func beginTool(_ index: Int, fact: String, category: String) throws -> String {
            let id = UUID().uuidString
            var tools = records[index]["tools"] as! [[String: Any]]
            tools.append(["id": id, "name": "remember", "fact": fact, "category": category, "outcome": "running"])
            records[index]["tools"] = tools; try save(); return id
        }
        func finishTool(_ index: Int, id: String, output: String?, failure: String? = nil) throws {
            var tools = records[index]["tools"] as! [[String: Any]]
            let position = tools.firstIndex { $0["id"] as? String == id }!
            tools[position]["output"] = output ?? ""
            tools[position]["error"] = failure ?? ""
            tools[position]["outcome"] = failure == nil ? "success" : "failed"
            records[index]["tools"] = tools; try save()
        }
        func toolCount(_ index: Int) -> Int { (records[index]["tools"] as! [[String: Any]]).count }
        func finish(_ index: Int, started: TimeInterval, values: [String: Any] = [:], checks: [String: Bool] = [:], error: (any Error)? = nil) throws {
            records[index].merge(values) { _, new in new }
            records[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            records[index]["automaticChecks"] = checks
            records[index]["error"] = error.map { ClarificationHistoryModelTests.failure($0) } ?? ""
            records[index]["errorType"] = error.map { String(reflecting: type(of: $0)) } ?? ""
            records[index]["outcome"] = error == nil && checks.values.allSatisfy { $0 } ? "success" : "failed"
            try save()
        }
        func failRun(_ error: String) throws { metadata["state"] = "failed"; metadata["error"] = error; try save() }
        func complete() throws { metadata["state"] = "completed"; metadata["automaticChecksPassed"] = automaticChecksPassed; try save() }
        private func save() throws {
            var value = metadata
            value["runID"] = runID; value["records"] = records
            value["recordCount"] = records.count
            value["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
    }
}
