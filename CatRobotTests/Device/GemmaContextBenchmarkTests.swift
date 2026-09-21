import Darwin
import Foundation
import Metal
import os
import XCTest
@preconcurrency import LiteRTLM
@testable import CatRobot

/// Each method must be launched separately: one context size per fresh app process.
final class GemmaContextBenchmarkTests: XCTestCase {
    func test08K() async throws { try await run(capacity: 8_192) }
    func test12K() async throws { try await run(capacity: 12_288) }
    func test16K() async throws { try await run(capacity: 16_384) }
    func test24K() async throws { try await run(capacity: 24_576) }
    func test32K() async throws { try await run(capacity: 32_768) }

    func testValidation08K() async throws { try await run(capacity: 8_192, validation: true) }
    func testValidation12K() async throws { try await run(capacity: 12_288, validation: true) }
    func testValidation16K() async throws { try await run(capacity: 16_384, validation: true) }
    func testValidation24K() async throws { try await run(capacity: 24_576, validation: true) }
    func testValidation32K() async throws { try await run(capacity: 32_768, validation: true) }

    private func run(capacity: Int, validation: Bool = false) async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only")
#else
        guard ProcessInfo.processInfo.environment["GEMMA_CONTEXT_TESTS"] == "1" else {
            throw XCTSkip("Opt in with the GemmaContextBenchmarkTests scheme")
        }
        executionTimeAllowance = 900
        // Cooling reduces order effects; record remaining thermal state rather than hiding it.
        let coolingStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.thermalState != .nominal,
              ProcessInfo.processInfo.systemUptime - coolingStart < 120 {
            try await Task.sleep(for: .seconds(5))
        }
        ExperimentalFlags.optIntoExperimentalAPIs()
        let oldBenchmark = ExperimentalFlags.enableBenchmark
        ExperimentalFlags.enableBenchmark = true
        defer { ExperimentalFlags.enableBenchmark = oldBenchmark }
        let model = try GemmaModelFile.installed()
        try model.validate()
        let support = model.url.deletingLastPathComponent().deletingLastPathComponent()
        let output = support.appendingPathComponent("ContextBenchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cache = output.appendingPathComponent("cache-0.17.1-\(capacity)", isDirectory: true)
        let cached = FileManager.default.fileExists(atPath: cache.path)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sampler = ContextMemorySampler()
        let monitoring = Task {
            while !Task.isCancelled {
                await sampler.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitoring.cancel() }
        var records: [[String: Any]] = []
        var metadata: [String: Any] = [
            "protocolVersion": validation ? 4 : 2, "capacity": capacity, "runtime": "LiteRT-LM 0.17.1", "sha256": GemmaModelFile.sha256,
            "cacheAlreadyExisted": cached, "thermalAtStart": ProcessInfo.processInfo.thermalState.rawValue,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "startedAt": ISO8601DateFormatter().string(from: Date()),
            "coolingSeconds": ProcessInfo.processInfo.systemUptime - coolingStart
        ]
        func save(_ stage: String) async throws {
            let object: [String: Any] = ["metadata": metadata, "stage": stage, "records": records,
                                       "memory": await sampler.report()]
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results-\(capacity).json"), options: .atomic)
        }
        try await save("initializing")
        let engine = Engine(engineConfig: try EngineConfig(modelPath: model.url.path, backend: .gpu,
                                                            maxNumTokens: capacity, cacheDir: cache.path))
        let start = ProcessInfo.processInfo.systemUptime
        try await engine.initialize()
        metadata["initializationSeconds"] = ProcessInfo.processInfo.systemUptime - start
        try await save("initialized")
        func chat(_ kind: GemmaSessionKind = .reply) async throws -> Conversation {
            try await engine.createConversation(with: ConversationConfig(
                systemMessage: Message(kind.instruction, role: .system),
                samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
                thinkingConfig: ThinkingConfig(enableThinking: false)))
        }
        // Identical warm short-turn workload for every configured capacity.
        do {
            let conversation = try await chat()
            for (index, prompt) in ["短く自己紹介して。", "今日は少し疲れたよ。ひとこと励まして。",
                                    "家でできる遊びを一つだけ教えて。", "私の好きな飲み物は麦茶です。",
                                    "訂正です。私の好きな飲み物はほうじ茶です。", "私の好きな飲み物は何？"].enumerated() {
                records.append(try await measure(conversation, prompt: prompt, label: "short-\(index)", limit: 160,
                                                 expected: index == 5 ? ["ほうじ茶"] : []))
                try await save("short")
            }
        }
        // Same Japanese prompt at every size: isolates capacity overhead from workload size.
        do {
            let conversation = try await chat()
            let prompt = "覚えてください。猫の名前はこはく、待ち合わせは東口の時計台です。\n"
                + Self.notes(start: 1, count: validation ? 110 : 70, diverse: validation)
                + "\n猫の名前と待ち合わせ場所を、指定された情報だけで短く答えて。"
            records.append(try await measure(conversation, prompt: prompt, label: "common-japanese", limit: 64,
                                             expected: ["こはく", "東口の時計台"]))
            try await save("common-japanese")
        }
        // Grow real KV history with synthetic Japanese turns; measure recall and short follow-ups near capacity.
        do {
            let conversation = try await chat()
            records.append(try await measure(conversation,
                prompt: "この会話で覚えてください。猫の名前はこはく、待ち合わせは東口の時計台、好きな飲み物は麦茶です。返事は『覚えた』だけ。",
                label: "history-start", limit: 24))
            var index = 0
            var corrected = false
            var matchedRecall = false
            var estimatedChunk = 1_500
            while try conversation.getTokenCount() < Int(Double(capacity) * 0.90) {
                let used = try conversation.getTokenCount()
                // Keep a measured token reserve for the next chunk and the final recall turns.
                if used + estimatedChunk + 384 > capacity { break }
                if !corrected, used > (validation ? 2_500 : capacity / 2) {
                    records.append(try await measure(conversation,
                        prompt: "訂正です。好きな飲み物はほうじ茶でした。麦茶ではありません。返事は『訂正した』だけ。",
                        label: "history-correction", limit: 24))
                    corrected = true
                }
                let record = try await measure(conversation,
                    prompt: Self.notes(start: 1_000 + index * 15, count: 15, diverse: validation) + "\n返事は『読んだ』だけ。",
                    label: "history-fill-\(index)", limit: 16)
                estimatedChunk = (record["prefillTokens"] as? Int ?? estimatedChunk) + 128
                records.append(record)
                index += 1
                if validation, !matchedRecall, try conversation.getTokenCount() >= 5_000 {
                    records.append(try await measure(conversation,
                        prompt: "私の猫の名前、待ち合わせ場所、訂正後の好きな飲み物を短く答えて。",
                        label: "matched-history-recall", limit: 80, expected: ["こはく", "東口の時計台", "ほうじ茶"]))
                    matchedRecall = true
                }
                try await save("history-fill")
                guard index < 100 else { throw ContextBenchmarkError.noProgress }
            }
            if !corrected {
                records.append(try await measure(conversation,
                    prompt: "好きな飲み物をほうじ茶に訂正します。返事は『訂正した』だけ。", label: "history-correction", limit: 24))
            }
            let used = try conversation.getTokenCount()
            metadata["historyTokensBeforeRecall"] = used
            metadata["historyFractionBeforeRecall"] = Double(used) / Double(capacity)
            for (index, prompt) in ["私の猫の名前、待ち合わせ場所、訂正後の好きな飲み物を短く答えて。",
                                    "私の好きな飲み物だけ答えて。", "私の猫の名前だけ答えて。"].enumerated() {
                let expected = index == 0 ? ["こはく", "東口の時計台", "ほうじ茶"] : (index == 1 ? ["ほうじ茶"] : ["こはく"])
                records.append(try await measure(conversation, prompt: prompt, label: "near-limit-\(index)",
                                                 limit: 80, expected: expected))
                try await save("near-limit")
            }
            if validation {
                records.append(try await measure(conversation,
                    prompt: "今から合言葉は『さくら』です。今伝えた合言葉だけを答えて。",
                    label: "near-limit-current-input", limit: 24, expected: ["さくら"]))
                try await save("near-limit-current-input")
            }
            // Exercise an ephemeral classifier while the long reply session stays resident, as in the app.
            let classifier = try await chat(.classification)
            records.append(try await measure(classifier, prompt: "お母さん、お弁当を作ってください。",
                                             label: "classifier-with-long-history", limit: 16, expected: ["notAddressed"]))
            records.append(try await measure(conversation, prompt: "私の猫の名前だけ答えて。",
                                             label: "after-classifier-diagnostic", limit: 80, expected: ["こはく"]))
            try await save("after-classifier-diagnostic")
        }
        metadata["thermalAtEnd"] = ProcessInfo.processInfo.thermalState.rawValue
        try await save("complete")
        let data = try Data(contentsOf: output.appendingPathComponent("results-\(capacity).json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Gemma context \(capacity)"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    private func measure(_ conversation: Conversation, prompt: String, label: String, limit: Int,
                         expected: [String] = []) async throws -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        var first: Double?
        var response = ""
        for try await message in conversation.sendMessageStream(Message(prompt), maxOutputTokens: limit) {
            let delta = message.toString
            if first == nil, !delta.isEmpty { first = ProcessInfo.processInfo.systemUptime - start }
            response += delta
        }
        let totalSeconds = ProcessInfo.processInfo.systemUptime - start
        let info = try conversation.getBenchmarkInfo()
        let result: [String: Any] = [
            "label": label, "prompt": prompt, "response": response, "expected": expected,
            "expectedSubstringsPresent": expected.allSatisfy { response.contains($0) },
            "firstVisibleSeconds": first.map { $0 as Any } ?? NSNull(), "completionSeconds": totalSeconds,
            "prefillTokens": info.lastPrefillTokenCount, "decodeTokens": info.lastDecodeTokenCount,
            "decodeTokensPerSecond": info.lastDecodeTokensPerSecond, "totalTokens": try conversation.getTokenCount(),
            "thermal": ProcessInfo.processInfo.thermalState.rawValue
        ]
        print("CONTEXT_RESULT \(label) total=\(try conversation.getTokenCount()) first=\(first ?? -1) pass=\(result["expectedSubstringsPresent"] ?? false)")
        return result
    }

    private static func notes(start: Int, count: Int, diverse: Bool = false) -> String {
        if diverse {
            let places = ["植物園", "港", "科学館", "山道", "商店街", "美術館", "川沿い", "図書館", "展望台", "運動場", "駅前", "古い喫茶店", "水族館"]
            let activities = ["青い鳥を観察", "絵を描く練習", "木の実の形を比較", "写真を整理", "風の音を録音", "短い詩を作成", "看板の文字を調査", "地図の道順を確認", "建物の窓を数える作業", "新しい折り紙に挑戦", "昔の道具を見学"]
            let details = ["風が強く帽子を押さえた", "小雨が降り傘を差した", "日差しが暖かかった", "雲の形が変わっていた", "遠くから鐘が聞こえた", "夕焼けがきれいだった", "空気が涼しかった"]
            return (start..<(start + count)).map { i in
                "日誌\(i)：\(i % 12 + 1)月\(i % 28 + 1)日、\(places[i % places.count])で\(activities[(i / 3) % activities.count])。\(details[(i / 7) % details.count])。活動時間は\(15 + i % 80)分、発見は\(i % 9 + 1)個だった。"
            }.joined(separator: "\n")
        }
        let subjects = ["朝は公園を散歩して、帰りにパンを買いました。午後は本を読み、夕方に部屋を片付けました。",
                        "今日は野菜のスープを作りました。玉ねぎと人参をゆっくり煮て、明日の分も冷蔵庫にしまいました。",
                        "図書館で借りた本の続きを読みました。窓の外には鳥が来ていて、しばらく静かに眺めました。",
                        "机の上を整理してから、友人に手紙を書きました。夕方には洗濯物を取り込みました。",
                        "雨が降っていたので家で音楽を聴きました。お昼には温かいうどんを食べました。"]
        return (start..<(start + count)).map { "記録\($0)：\(subjects[$0 % subjects.count])" }.joined(separator: "\n")
    }
}

private enum ContextBenchmarkError: Error { case noProgress }

private actor ContextMemorySampler {
    private var peakFootprint: UInt64 = 0
    private var peakResident: UInt64 = 0
    private var peakMetal: UInt64 = 0
    private var minimumAvailable: UInt64 = .max
    private var peakThermal = 0
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            peakFootprint = max(peakFootprint, info.phys_footprint)
            peakResident = max(peakResident, info.resident_size)
        }
        peakMetal = max(peakMetal, UInt64(MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0))
        minimumAvailable = min(minimumAvailable, UInt64(os_proc_available_memory()))
        peakThermal = max(peakThermal, ProcessInfo.processInfo.thermalState.rawValue)
    }
    func report() -> [String: UInt64] {
        sample()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return ["sampledPeakFootprintBytes": peakFootprint, "sampledPeakResidentBytes": peakResident,
                "sampledPeakMetalAllocatedBytes": peakMetal, "minimumProcessAvailableBytes": minimumAvailable,
                "processPeakResidentBytes": UInt64(usage.ru_maxrss), "peakThermal": UInt64(peakThermal), "sampleIntervalMilliseconds": 100]
    }
}
