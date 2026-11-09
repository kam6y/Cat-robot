import CryptoKit
import Foundation
import XCTest
@testable import CatRobot

/// Explicit, paid real-device acceptance only. The inventory never resolves auth or creates a model.
@MainActor
final class HaikuAddressingModelTests: XCTestCase {
    private static let fixtureVersion = "issue30-v1"
    private static let sdkRevision = "0262e1a766c461a4268dcec656eca95dd74cebf8"
    private static let repetitions = 3
    private static let contextA = [ConversationMemoryTurn(prompt: "今日の天気はどう？", response: "晴れだよ")]
    private static let contextB = [ConversationMemoryTurn(prompt: "お姉ちゃんが来るんだ", response: "楽しみだね")]
    private static let contextC = [ConversationMemoryTurn(prompt: "ねこ、おはよう", response: "おはよう！今日も元気だね")]

    private struct Classification: Sendable {
        let id: String
        let utterance: String
        let expected: [String]
        var recentTurns: [ConversationMemoryTurn] = []
        var clarification: ClarificationContext? = nil
        var request: AddressClassificationRequest {
            .init(utterance: utterance, clarification: clarification, recentTurns: recentTurns)
        }
    }

    private static func clarification(_ id: String, _ utterance: String,
                                      expected: [String] = ["addressed"]) -> Classification {
        .init(id: "clar-" + id, utterance: utterance, expected: expected, recentTurns: contextC,
              clarification: .init(originalUtterance: "今日の天気はどう？"))
    }

    private static let classifications: [Classification] = [
        .init(id: "ctx-followup-tomorrow", utterance: "それで、あしたは？", expected: ["addressed"], recentTurns: contextA),
        .init(id: "ctx-followup-repeat", utterance: "もう一回言って", expected: ["addressed"], recentTurns: contextA),
        .init(id: "ctx-followup-umbrella", utterance: "傘はいる？", expected: ["addressed"], recentTurns: contextA),
        .init(id: "ctx-other-addressee-same-topic", utterance: "ママ、あしたの天気どうだった？", expected: ["notAddressed"], recentTurns: contextA),
        .init(id: "ctx-addressee-from-history", utterance: "お姉ちゃん、傘どこ？", expected: ["notAddressed"], recentTurns: contextB),
        .init(id: "ctx-self-talk", utterance: "これは独り言。疲れたな。", expected: ["notAddressed"], recentTurns: contextB),
        .init(id: "ctx-unrelated", utterance: "明日の予定は？", expected: ["ambiguous"], recentTurns: contextA),
        .init(id: "plain-cat", utterance: "ねこ、元気？", expected: ["addressed"]),
        .init(id: "plain-papa", utterance: "パパ、鍵はどこ？", expected: ["notAddressed"]),
        .init(id: "plain-rain", utterance: "明日は雨かな。", expected: ["ambiguous"]),
        clarification("hai", "はい"),
        clarification("un", "うん"),
        clarification("iie", "いいえ"),
        clarification("uun", "ううん"),
        clarification("ittayo", "言ったよ"),
        clarification("weather-confirmation", "そうそう、天気の"),
        clarification("denied-addressee", "いいえ、あなたには言ってない"),
        clarification("denied-mom", "違うよ、ママに言ったの"),
        clarification("cat-new-question", "猫ちゃん、5たす4はいくつ？"),
        clarification("unrelated-question", "明日の予定は？", expected: ["ambiguous"]),
        clarification("other-addressee", "ママ、鍵はどこ？", expected: ["notAddressed"]),
        clarification("self-talk", "これは独り言。疲れたな。", expected: ["notAddressed"]),
        clarification("unspecified-addressee", "部長に電話しておいて。", expected: ["notAddressed", "ambiguous"]),
    ]

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func inventory() throws -> [[String: Any]] {
        try classifications.map { fixture in
            let input = try ClaudeAddressModelClient.requestInput(for: fixture.request)
            let object = try JSONSerialization.jsonObject(with: Data(input.prompt.utf8))
            let prompt = String(decoding: try JSONSerialization.data(withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            return ["kind": "classification", "fixtureID": fixture.id,
                    "model": ClaudeSessionFactory.claudeModel(for: .haiku5_5).id, "effort": "low",
                    "repetitions": repetitions, "instructions": input.instructions, "prompt": prompt,
                    "expectation": fixture.expected.joined(separator: "|"),
                    "instructionsCharacters": input.instructions.count, "promptCharacters": prompt.count,
                    "contextCharacters": fixture.recentTurns.reduce(0) { $0 + $1.prompt.count + $1.response.count },
                    "instructionsSHA256": hash(input.instructions), "promptSHA256": hash(prompt),
                    "inputSHA256": hash(input.instructions + "\n\n" + prompt),
                    "promptHashBasis": "canonical logical JSON from production requestInput; internal wire encoding/key order not observed"]
        }
    }

    func testFixtureInventory() throws {
        let rows = try Self.inventory()
        XCTAssertEqual(rows.count, 23)
        XCTAssertEqual(rows.count * Self.repetitions, 69)
        XCTAssertEqual(Set(Self.classifications.map(\.id)).count, 23)
        XCTAssertEqual(Self.classifications.filter { $0.id.hasPrefix("ctx-") }.count, 7)
        XCTAssertEqual(Self.classifications.filter { $0.id.hasPrefix("plain-") }.count, 3)
        XCTAssertEqual(Self.classifications.filter { $0.id.hasPrefix("clar-") }.count, 13)
        XCTAssertTrue(Self.classifications.allSatisfy { !$0.expected.isEmpty && Set($0.expected).isSubset(of: ["addressed", "ambiguous", "notAddressed"]) })
        let metadata: [String: Any] = ["fixtureVersion": Self.fixtureVersion, "sdkRevision": Self.sdkRevision,
            "topLevelTrials": 69, "haikuTrials": 69, "opusTrials": 0, "fixtures": rows,
            "usageAvailability": "notExposedByProductionAPI", "networkCalls": 0,
            "evaluationScope": "approved rule acceptance/regression fixtures; some examples overlap production instructions, not a held-out generalization benchmark"]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        let attachment = XCTAttachment(string: text)
        attachment.name = "haiku-addressing-fixture-inventory.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("HAIKU_ADDRESSING_FIXTURE_INVENTORY " + text)
    }

    func testAcceptanceMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        let deviceDebug: Bool
#if targetEnvironment(simulator) || !DEBUG
        deviceDebug = false
#else
        deviceDebug = true
#endif
        // No authentication lookup or model construction until every opt-in gate passes.
        guard deviceDebug, environment["HAIKU_ADDRESSING_MODEL_TESTS"] == "1",
              environment["SUPER_INTEGRATION_TESTS"] == "1",
              let runID = environment["HAIKU_ADDRESSING_RUN_ID"], UUID(uuidString: runID) != nil else {
            throw XCTSkip("Explicit Debug real-device dedicated-host opt-in required; 0 model calls")
        }
        guard let head = environment["HAIKU_ADDRESSING_SOURCE_HEAD"], head.count == 40,
              let digest = environment["HAIKU_ADDRESSING_INPUT_SHA256"], digest.count == 64,
              environment["HAIKU_ADDRESSING_SDK_REVISION"] == Self.sdkRevision else {
            XCTFail("The dedicated runner must provide the frozen source/SDK metadata")
            return
        }
        executionTimeAllowance = 3_600
        let rows = try Self.inventory()
        let evidence = try Evidence(runID: runID, metadata: [
            "schemaVersion": 1, "fixtureVersion": Self.fixtureVersion, "sourceHEAD": head,
            "inputSHA256": digest, "sdkRevision": Self.sdkRevision, "sdkVersion": "0.2.3",
            "repetitions": Self.repetitions, "expectedTrials": 69, "expectedHaikuTrials": 69,
            "expectedOpusTrials": 0, "fixtures": rows, "usage": NSNull(),
            "usageAvailability": "notExposedByProductionAPI", "inputOrigin": "production ClaudeAddressModelClient.requestInput and classify",
            "evaluationScope": "approved rule acceptance/regression fixtures; prompt example overlap retained as approved"
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
            for (position, fixture) in Self.classifications.enumerated() {
                let index = try evidence.begin(rows[position], repetition: repetition)
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let target = try await Self.deadline(seconds: 25) {
                        try await ClaudeAddressModelClient(auth: auth).classify(fixture.request)
                    }
                    let name: String
                    switch target {
                    case .addressed: name = "addressed"
                    case .ambiguous: name = "ambiguous"
                    case .notAddressed: name = "notAddressed"
                    }
                    try evidence.finish(index, started: start, target: name, expected: fixture.expected)
                } catch { try evidence.finish(index, started: start, error: error) }
            }
        }
        try evidence.complete()
        XCTAssertEqual(evidence.count, 69)
        XCTAssertTrue(evidence.automaticChecksPassed, "Every fixture must return an allowed target on all three trials")
    }

    private enum TrialFailure: Error { case timeout }

    private static func deadline<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TrialFailure.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TrialFailure.timeout }
            return result
        }
    }

    private static func failure(_ error: any Error) -> String {
        if error is TrialFailure { return "timeout" }
        return String(describing: ClaudeErrorMapper.map(error))
    }

    @MainActor
    private final class Evidence {
        private let runID: String
        private let url: URL
        private var metadata: [String: Any]
        private var records: [[String: Any]] = []
        var count: Int { records.count }
        var automaticChecksPassed: Bool { count == 69 && records.allSatisfy { $0["outcome"] as? String == "success" } }

        init(runID: String, metadata: [String: Any]) throws {
            self.runID = runID; self.metadata = metadata
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HaikuAddressing/\(runID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("results.json")
            self.metadata["state"] = "running"
            try save()
        }

        func begin(_ fixture: [String: Any], repetition: Int) throws -> Int {
            var record = fixture
            record["trialID"] = "classification/\(fixture["fixtureID"]!)/\(repetition)"
            record["repetition"] = repetition; record["outcome"] = "running"
            record["startedAt"] = ISO8601DateFormatter().string(from: Date())
            record["usage"] = NSNull(); record["usageAvailability"] = "notExposedByProductionAPI"
            records.append(record)
            try save()
            return records.count - 1
        }

        func finish(_ index: Int, started: TimeInterval, target: String? = nil, expected: [String] = [], error: (any Error)? = nil) throws {
            let passed = target.map { expected.contains($0) } ?? false
            records[index]["target"] = target ?? ""
            records[index]["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            records[index]["automaticChecks"] = ["expectedEnum": passed]
            records[index]["error"] = error.map { HaikuAddressingModelTests.failure($0) } ?? ""
            records[index]["outcome"] = error == nil && passed ? "success" : "failed"
            try save()
        }

        func failRun(_ error: String) throws { metadata["state"] = "failed"; metadata["error"] = error; try save() }
        func complete() throws { metadata["state"] = "completed"; metadata["automaticChecksPassed"] = automaticChecksPassed; try save() }
        private func save() throws {
            var value = metadata
            value["runID"] = runID; value["records"] = records; value["recordCount"] = records.count
            value["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
    }
}
