import CryptoKit
import Darwin
import Foundation
import XCTest
@preconcurrency import LiteRTLM

/// Opt-in, physical-device experiment. All prompts are synthetic; no personal conversation is logged.
final class GemmaDeviceTests: XCTestCase {
    func testJapaneseConversationAndLongContextOnDevice() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Gemma performance must be measured on a physical iPhone.")
#else
        guard ProcessInfo.processInfo.environment["GEMMA_DEVICE_TESTS"] == "1" else {
            throw XCTSkip("Run the GemmaDeviceTests scheme explicitly.")
        }
        executionTimeAllowance = 600
        ExperimentalFlags.optIntoExperimentalAPIs()
        let priorBenchmark = ExperimentalFlags.enableBenchmark
        ExperimentalFlags.enableBenchmark = true
        defer { ExperimentalFlags.enableBenchmark = priorBenchmark }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let model = support.appendingPathComponent(
            "CatRobot/LanguageModels/Gemma4E2B/gemma-4-E2B-it.litertlm"
        )
        guard FileManager.default.fileExists(atPath: model.path) else {
            XCTFail("Provision the pinned model using scripts/run_gemma_device_test.sh.")
            return
        }
        let digest = try modelDigest(model)
        XCTAssertEqual(digest, "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")
        guard digest == "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c" else { return }
        let output = support.appendingPathComponent("GemmaDeviceTest-20260921", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cache = output.appendingPathComponent("cache-0.17.1-8192", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let engine = Engine(engineConfig: try EngineConfig(
            modelPath: model.path, backend: .gpu, maxNumTokens: 8192, cacheDir: cache.path
        ))
        var records: [[String: Any]] = []
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await engine.initialize()
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let metadata: [String: Any] = [
            "model": "gemma-4-E2B-it.litertlm", "sha256": digest,
            "runtime": "LiteRT-LM 0.17.1 (official package binary 0.17.0)",
            "backend": "gpu", "contextCapacity": 8192,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "initializationSeconds": loadSeconds,
            "initializationThermalState": ProcessInfo.processInfo.thermalState.rawValue
        ]
        func save() throws {
            let report: [String: Any] = ["metadata": metadata, "turns": records]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        try save()
        let instruction = "あなたは親しみやすいAIの猫です。日本語の短い一文か二文で答えてください。ユーザーが訂正した情報を優先してください。"
        func conversation() async throws -> Conversation {
            try await engine.createConversation(with: ConversationConfig(
                systemMessage: Message(instruction, role: .system),
                samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
                thinkingConfig: ThinkingConfig(enableThinking: false)
            ))
        }
        // Real inference: warm latency, Japanese output, and retention after a correction.
        do {
            let chat = try await conversation()
            let prompts = [
                "猫ちゃん、短く自己紹介して。",
                "今日は少し疲れたよ。ひとこと励まして。",
                "雨の日に家でできる遊びを一つ教えて。",
                "私の好きな飲み物は麦茶です。覚えてね。",
                "訂正です。好きな飲み物はほうじ茶です。麦茶ではありません。",
                "私の好きな飲み物は何ですか？"
            ]
            for (index, prompt) in prompts.enumerated() {
                let record = try await measure(chat, prompt: prompt, label: "conversation-\(index + 1)")
                records.append(record)
                try save()
                let response = record["response"] as? String ?? ""
                XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertNotNil(response.range(of: "[ぁ-んァ-ン一-龯]", options: .regularExpression))
                if index == 5 { XCTAssertTrue(response.contains("ほうじ茶"), response) }
            }
        }
        // Fresh session: the answer occurs only at the beginning, beyond a >4K-token distractor.
        do {
            let chat = try await conversation()
            let filler = (1...360).map {
                "Record \($0): the quiet garden has green leaves and a small stone path."
            }.joined(separator: "\n")
            let prompt = "最初に覚える合言葉は『紫の風船』です。\n" + filler
                + "\n最初に指定した合言葉だけを日本語で答えてください。"
            let record = try await measure(chat, prompt: prompt, label: "long-context-recall")
            records.append(record)
            try save()
            XCTAssertGreaterThan(try XCTUnwrap(record["prefillTokens"] as? Int), 4096)
            XCTAssertTrue((record["response"] as? String ?? "").contains("紫の風船"))
        }
        let data = try Data(contentsOf: output.appendingPathComponent("results.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Gemma 4 E2B real-device results"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    private func measure(_ conversation: Conversation, prompt: String, label: String) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        var first: Double?
        var text = ""
        for try await part in conversation.sendMessageStream(Message(prompt), maxOutputTokens: 160) {
            let delta = part.toString
            if first == nil && !delta.isEmpty { first = ProcessInfo.processInfo.systemUptime - start }
            text += delta
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let benchmark = try conversation.getBenchmarkInfo()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let record: [String: Any] = [
            "label": label, "prompt": prompt, "response": text,
            "firstVisibleSeconds": first.map { $0 as Any } ?? NSNull(),
            "completionSeconds": elapsed,
            "prefillTokens": benchmark.lastPrefillTokenCount,
            "decodeTokens": benchmark.lastDecodeTokenCount,
            "decodeTokensPerSecond": benchmark.lastDecodeTokensPerSecond,
            "totalTokens": try conversation.getTokenCount(),
            "processPeakResidentBytes": usage.ru_maxrss,
            "thermalBefore": thermalBefore,
            "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue
        ]
        print("GEMMA_DEVICE_RESULT \(label) first=\(first ?? -1) completion=\(elapsed) prefill=\(benchmark.lastPrefillTokenCount) response=\(text)")
        return record
    }

    private func modelDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
