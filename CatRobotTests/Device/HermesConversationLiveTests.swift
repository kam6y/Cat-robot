import Foundation
import XCTest
@testable import CatRobot

#if DEBUG
/// Only the dedicated runner opts into real HTTP. Offline tests below exercise the
/// fault fixture against the normal service without touching a device or network.
actor HermesConversationFaultTransport: HermesTransport {
    enum Fault: Sendable { case none, loseAcceptedReceipt, holdCompletedPoll }
    struct Proof: Sendable {
        var droppedOnce = false
        var sameKeyAndBody = false
        var replayed = false
        var uniqueRunCount = 0
        var heldRunID: String?
        var stopObserved = false
        var gateTimedOut = false
    }
    private let upstream: any HermesTransport
    private(set) var proof = Proof()
    private var fault = Fault.none
    private var submissions: [(key: String?, body: Data?)] = []
    private var accepted: Set<String> = []
    private var gate: CheckedContinuation<Void, Never>?
    private var watchdog: Task<Void, Never>?
    init(_ upstream: any HermesTransport) { self.upstream = upstream }
    func arm(_ fault: Fault) {
        releaseHeld()
        self.fault = fault
        proof = Proof()
        submissions = []
        accepted = []
    }
    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        // A stop request observation is not a stop ACK or proof of termination.
        if request.method == "POST", request.url.path.hasSuffix("/stop") { proof.stopObserved = true }
        let isSubmission = request.method == "POST" && request.url.path == "/v1/runs"
        if isSubmission, case .loseAcceptedReceipt = fault {
            submissions.append((request.headers["Idempotency-Key"], request.body))
        }
        let response = try await upstream.send(request)
        let payload = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if isSubmission, response.statusCode == 202, let id = payload?["run_id"] as? String,
           case .loseAcceptedReceipt = fault {
            accepted.insert(id)
            proof.uniqueRunCount = accepted.count
            proof.replayed = proof.replayed || payload?["replayed"] as? Bool == true
            if let first = submissions.first {
                proof.sameKeyAndBody = submissions.count >= 2 && first.key != nil && first.body != nil
                    && submissions.allSatisfy { $0.key == first.key && $0.body == first.body }
            }
            if !proof.droppedOnce {
                proof.droppedOnce = true
                throw HermesClientError.transport("acceptance: accepted response lost")
            }
        }
        if case .holdCompletedPoll = fault, request.method == "GET", request.url.path.hasPrefix("/v1/runs/"),
           response.statusCode == 200, payload?["status"] as? String == "completed",
           let id = payload?["run_id"] as? String, let output = payload?["output"] as? String, !output.isEmpty {
            fault = .none
            proof.heldRunID = id
            // A test failure must not strand the production worker forever.
            watchdog = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self.expireGate()
            }
            await withCheckedContinuation { gate = $0 }
        }
        return response
    }
    func waitForHeld(seconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while gate == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return gate != nil
    }
    func releaseHeld() {
        watchdog?.cancel()
        watchdog = nil
        gate?.resume()
        gate = nil
    }
    private func expireGate() {
        proof.gateTimedOut = true
        releaseHeld()
    }
}

/// Uses the production composition, reply service, persistence, history and pinned
/// HTTP. Only hardware and transport failure timing are test dependencies.
@MainActor
final class HermesConversationLiveTests: XCTestCase {
    private enum Failure: Error { case criterion }
    private var receipt: [String: Any] = [:]
    private var phase = "bootstrap"

    func testNormalConversationLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HERMES_CONVERSATION_LIVE"] == "1",
              let id = env["HERMES_CONVERSATION_RUN_ID"], UUID(uuidString: id) != nil,
              let source = env["HERMES_CONVERSATION_SOURCE_SHA256"], source.count == 64 else {
            throw XCTSkip("Use run_hermes_conversation_live_test.py after the UI-complete final freeze")
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("HermesConversation/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = directory.appendingPathComponent("results.json")
        let suite = "com.kamby.CatRobot.hermes-conversation-live.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
#if targetEnvironment(simulator)
        let target = "simulator"
        let bootstrap = URL(fileURLWithPath: try XCTUnwrap(env["HERMES_CONVERSATION_BOOTSTRAP"]))
#else
        let target = "device"
        let bootstrap = documents.appendingPathComponent("hermes-conversation-bootstrap.json")
#endif
        receipt = ["schemaVersion": 1, "runID": id, "sourceInputSHA256": source, "target": target,
                   "startedAt": ISO8601DateFormatter().string(from: Date()), "physicalOperations": false,
                   "normalComposition": false, "processRestart": false, "outcome": "failed"]
        var credentials: KeychainHermesCredentialStore?
        var fault: HermesConversationFaultTransport?
        var recordsForCleanup: UserDefaultsHermesSessionRecordStore?
        var compositions: [ConversationComposition] = []
        let radio = FakeRobotTransport(), camera = FakeFaceCaptureSource(authorization: .denied)
        do {
            try require(CatRobotApp(environment: env).composition == nil)
            struct Endpoint: Decodable { let endpoint: URL }
            let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: bootstrap)).endpoint
            let origin = HermesConnection.origin(of: endpoint)
            let store = KeychainHermesCredentialStore(service: suite, account: origin)
            credentials = store
            let configurations = HermesProbeConfigurationStore(defaults: defaults)
            let imported = await HermesBootstrapImporter(file: bootstrap, credentials: store, configurations: configurations).import()
            try require(imported == .imported)
            let configuration = try XCTUnwrap(configurations.load())
            let storedCredential = try await store.load()
            let credential = try XCTUnwrap(storedCredential)
            receipt["bootstrapRemoved"] = !FileManager.default.fileExists(atPath: bootstrap.path)
            let pinned = PinnedURLSessionTransport(configuration: configuration)
            let transport = HermesConversationFaultTransport(pinned)
            fault = transport
            let settings = HermesConnectionSettings(defaults: defaults, credentials: {
                KeychainHermesCredentialStore(service: suite, account: $0)
            })
            try await settings.save(endpointText: configuration.endpoint.absoluteString, apiKey: "")
            let records = UserDefaultsHermesSessionRecordStore(defaults: defaults)
            recordsForCleanup = records
            let preferences = RobotPreferences(defaults: defaults)
            preferences.trackingEnabled = false
            preferences.idleEnabled = false
            let first = makeComposition(defaults, settings, transport, records, radio, camera, preferences)
            compositions.append(first)
            let firstService = try service(first)
            receipt["normalComposition"] = true

            phase = "twoTurns"
            let nonce = "cat" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let prompt = "会話の確認です。合言葉は \(nonce) です。覚えたら短く返事をしてください。"
            _ = try await collect(try await first.dependencies.reply.streamReply(to: prompt))
            // No nonce and no local transcript in turn two: only the server can supply the context.
            let recalled = try await collect(try await first.dependencies.reply.streamReply(to: "さっき教えた合言葉を、そのまま答えてください。"))
            let history = try await transcript(first, users: 2)
            let two = counts(history)
            receipt["twoTurns"] = ["contextMatched": recalled.joined().contains(nonce),
                                   "userRows": two.users, "assistantRows": two.assistants]
            try require(recalled.joined().contains(nonce) && two.users == 2 && two.assistants == 2)
            let storedRecord = await records.load()
            let saved = try XCTUnwrap(storedRecord)
            receipt["sessionID"] = saved.sessionID

            phase = "reconstruction"
            // A new consumer and store instances over persisted IDs; this is not a claim of a process restart.
            await first.dependencies.serviceTeardown()
            let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let restoredSettings = HermesConnectionSettings(defaults: restoredDefaults, credentials: {
                KeychainHermesCredentialStore(service: suite, account: $0)
            })
            let restoredRecords = UserDefaultsHermesSessionRecordStore(defaults: restoredDefaults)
            let restored = makeComposition(restoredDefaults, restoredSettings, transport, restoredRecords, radio, camera, preferences)
            compositions.append(restored)
            let restoredService = try service(restored)
            try require(restoredService !== firstService)
            try await restored.dependencies.memory.prepareMemory()
            let restoredHistory = try await transcript(restored, users: 2)
            let restoredID = await restoredRecords.load()?.sessionID
            receipt["reconstruction"] = ["sameSession": restoredID == saved.sessionID, "historyMatched": restoredHistory == history]
            try require(restoredID == saved.sessionID && restoredHistory == history)

            phase = "cancellation"
            await transport.arm(.holdCompletedPoll)
            let cancelPrompt = "取り消しの確認です。短く返事をしてください。"
            let cancelledStream = try await restored.dependencies.reply.streamReply(to: cancelPrompt)
            let consumer = Task { try await collect(cancelledStream) }
            guard await transport.waitForHeld(seconds: 70) else {
                consumer.cancel()
                _ = try? await consumer.value
                throw Failure.criterion
            }
            consumer.cancel() // Invalidates the real service's local generation before delivering the held result.
            let cancelledOutput = (try? await consumer.value) ?? []
            let stopDeadline = Date().addingTimeInterval(5)
            while !(await transport.proof.stopObserved), Date() < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
            await transport.releaseHeld()
            let cancelProof = await transport.proof
            let runID = try XCTUnwrap(cancelProof.heldRunID)
            let client = HermesRunClient(endpoint: configuration.endpoint, credential: credential, transport: pinned)
            let terminal = try await client.awaitTerminal(id: runID, deadline: .seconds(15))
            receipt["cancellation"] = ["runID": runID, "terminal": terminal.status.rawValue,
                                       "lateOutputRejected": cancelledOutput.isEmpty,
                                       "stopObserved": cancelProof.stopObserved, "gateTimedOut": cancelProof.gateTimedOut]
            try require(cancelledOutput.isEmpty && cancelProof.stopObserved && !cancelProof.gateTimedOut && terminal.status.isTerminal)

            phase = "reconnect"
            await transport.arm(.loseAcceptedReceipt)
            _ = try await collect(try await restored.dependencies.reply.streamReply(to: "再接続の確認です。一言だけ返事をしてください。"))
            let finalHistory = try await transcript(restored, users: 4)
            let finalCounts = counts(finalHistory)
            let replay = await transport.proof
            let localTurns = await restoredService.recentTurns()
            let lateRejected = cancelledOutput.isEmpty && !localTurns.contains { $0.prompt == cancelPrompt }
            var cancellation = receipt["cancellation"] as? [String: Any] ?? [:]
            cancellation["lateOutputRejected"] = lateRejected
            receipt["cancellation"] = cancellation
            receipt["reconnect"] = ["fault": "accepted-response-loss", "droppedOnce": replay.droppedOnce,
                                    "sameKeyAndBody": replay.sameKeyAndBody, "replayed": replay.replayed,
                                    "uniqueRunCount": replay.uniqueRunCount, "userRows": finalCounts.users,
                                    "assistantRows": finalCounts.assistants]
            try require(lateRejected && localTurns.count == 3 && replay.droppedOnce && replay.sameKeyAndBody
                        && replay.replayed && replay.uniqueRunCount == 1 && finalCounts.users == 4 && finalCounts.assistants == 4)
            try require(radio.starts == 0 && radio.writtenData.isEmpty && camera.requests == 0
                        && camera.starts.isEmpty && camera.snapshotRequests.isEmpty)
            receipt["outcome"] = "success"
        } catch {
            // Fixed phase only: underlying errors can contain URLs or HTTP data.
            receipt["failurePhase"] = phase
        }
        await fault?.releaseHeld()
        for composition in compositions { await composition.dependencies.serviceTeardown() }
        // Preserve nonsecret recovery identifiers before removing this test's local state, including on failure.
        if let record = await recordsForCleanup?.load() {
            receipt["persistedSessionID"] = record.sessionID
            receipt["unsettledRunIDs"] = record.unsettledRunIDs
            receipt["uncertainSubmission"] = record.hasUncertainSubmission
        }
        do { try await credentials?.delete() } catch { receipt["outcome"] = "failed" }
        defaults.removePersistentDomain(forName: suite)
        let keyRemoved: Bool
        do { keyRemoved = try await credentials?.load() == nil } catch { keyRemoved = false }
        receipt["taskStateRemoved"] = keyRemoved && (defaults.persistentDomain(forName: suite) ?? [:]).isEmpty
        if receipt["taskStateRemoved"] as? Bool != true { receipt["outcome"] = "failed" }
        receipt["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: result, options: .atomic)
        XCTAssertEqual(receipt["outcome"] as? String, "success", "normal conversation acceptance failed at \(phase)")
    }

    private func makeComposition(_ defaults: UserDefaults, _ settings: HermesConnectionSettings,
                                 _ transport: any HermesTransport, _ records: any HermesSessionRecordStore,
                                 _ radio: FakeRobotTransport, _ camera: FakeFaceCaptureSource, _ preferences: RobotPreferences) -> ConversationComposition {
        ConversationComposition.live(voiceSettings: SpeechVoiceSettings(defaults: defaults), connectionSettings: settings,
            hermesTransport: transport, sessionRecords: records, auth: .missing, robotTransport: radio,
            robotPreferences: preferences, faceCaptureSource: camera)
    }
    private func service(_ composition: ConversationComposition) throws -> HermesConversationService {
        guard let service = composition.history as? HermesConversationService,
              let reply = composition.dependencies.reply as? MotionReplyGenerator,
              (reply.base as? HermesConversationService) === service,
              (composition.dependencies.memory as? HermesConversationService) === service,
              (composition.dependencies.modelAvailability as? HermesConversationService) === service else { throw Failure.criterion }
        return service
    }
    private func transcript(_ composition: ConversationComposition, users: Int) async throws -> [HermesTranscriptEntry] {
        var history: [HermesTranscriptEntry] = []
        for _ in 0..<40 {
            history = try await composition.history.transcript()
            let count = counts(history)
            if count.users == users && count.assistants == users { return history }
            try await Task.sleep(for: .milliseconds(250))
        }
        return history
    }
    private func counts(_ history: [HermesTranscriptEntry]) -> (users: Int, assistants: Int) {
        (history.filter { $0.speaker == .user }.count, history.filter { $0.speaker == .cat }.count)
    }
    private func require(_ condition: Bool) throws { if !condition { throw Failure.criterion } }
}

@MainActor
final class HermesConversationLiveSupportTests: XCTestCase {
    func testNormalConversationAcceptanceHasItsOwnInertAppHost() {
        let app = CatRobotApp(environment: ["HERMES_CONVERSATION_LIVE": "1"])
        XCTAssertNil(app.composition, "a real app scene must not start audio/camera/BLE alongside the fixture")
        XCTAssertFalse(app.isHermesProbe, "normal conversation acceptance is separate from the diagnostic bridge probe")
    }

    func testLostAcceptedReceiptRetriesSameBodyAndKeyAndAdoptsOnlyOnce() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-one"), .json(202, #"{"run_id":"run-one","status":"started","replayed":true}"#)],
                                      polls: ["run-one": [hermesRun("run-one", "completed", output: "一度だけ")]])
        let transport = HermesConversationFaultTransport(server)
        await transport.arm(.loseAcceptedReceipt)
        let service = makeService(transport)
        let output = try await collect(try await service.streamReply(to: "質問"))
        XCTAssertEqual(output, ["一度だけ"])
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 2, "the fixture must really lose the accepted response")
        let proof = await transport.proof
        XCTAssertTrue(proof.droppedOnce)
        XCTAssertTrue(proof.sameKeyAndBody)
        XCTAssertTrue(proof.replayed)
        XCTAssertEqual(proof.uniqueRunCount, 1)
        let turns = await service.recentTurns()
        XCTAssertEqual(turns.count, 1)
    }

    func testCancellationRejectsAHeldCompletedResponseAndSendsTheRealStop() async throws {
        let server = FakeHermesServer(runs: [hermesAccepted("run-late")],
                                      polls: ["run-late": [hermesRun("run-late", "completed", output: "遅い返事")]])
        let transport = HermesConversationFaultTransport(server)
        await transport.arm(.holdCompletedPoll)
        let service = makeService(transport)
        let stream = try await service.streamReply(to: "取り消す")
        let consumer = Task { try await collect(stream) }
        guard await transport.waitForHeld() else {
            _ = try? await consumer.value
            XCTFail("completed HTTP response was delivered instead of being held for local cancellation")
            return
        }
        consumer.cancel()
        let adopted = (try? await consumer.value) ?? []
        await transport.releaseHeld()
        await server.waitForRequest { $0.url.path.hasSuffix("/stop") }
        XCTAssertTrue(adopted.isEmpty)
        let turns = await service.recentTurns()
        XCTAssertTrue(turns.isEmpty)
        let proof = await transport.proof
        XCTAssertEqual(proof.heldRunID, "run-late")
        XCTAssertTrue(proof.stopObserved)
        XCTAssertFalse(proof.gateTimedOut)
    }

    private func makeService(_ transport: any HermesTransport) -> HermesConversationService {
        let connection = HermesConnection(endpoint: URL(string: "https://hermes.test")!, credential: HermesCredential(apiKey: "dummy"))
        return HermesConversationService(connection: { connection }, transport: transport, records: InMemoryHermesSessionRecordStore(),
                                         clock: SteppingHermesClock(), makeSessionID: { "catrobot-fixture" })
    }
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var values: [String] = []
    for try await value in stream { values.append(value) }
    return values
}
#endif
