import Foundation
import XCTest
@testable import CatRobot

@MainActor
final class HermesProbeDeviceTests: XCTestCase {
#if DEBUG
    private enum ProbeFailure: Error { case criterion(String) }
    private var receipt: [String: Any] = [:]
    private var records: [[String: Any]] = []
    private var resultFile: URL?
    private var phase = "preflight"

    func testSelectedStage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HERMES_PROBE"] == "1", let id = env["HERMES_PROBE_RUN_ID"], UUID(uuidString: id) != nil,
              let stage = env["HERMES_PROBE_STAGE"], ["lifetime1", "lifetime2"].contains(stage) else {
            throw XCTSkip("Use the dedicated Hermes probe runner")
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("HermesProbe/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        resultFile = directory.appendingPathComponent("results.json")
        receipt = ["schemaVersion": 1, "runID": id, "stage": stage,
                   "sourceInputSHA256": env["HERMES_PROBE_SOURCE_SHA256"] ?? "unknown",
                   "startedAt": ISO8601DateFormatter().string(from: Date()),
                   "physicalOperations": false]
#if targetEnvironment(simulator)
        receipt["target"] = "simulator"
#else
        receipt["target"] = "device"
#endif
        do {
            try require(CatRobotApp(environment: env).composition == nil, "probe composition must be nil")
            receipt["compositionCreated"] = false
            phase = "bootstrap"
#if targetEnvironment(simulator)
            guard let path = env["HERMES_PROBE_BOOTSTRAP"] else { throw ProbeFailure.criterion("bootstrap path missing") }
            let bootstrap = URL(fileURLWithPath: path)
#else
            let bootstrap = documents.appendingPathComponent("hermes-probe-bootstrap.json")
#endif
            let credentials = KeychainHermesCredentialStore()
            guard let defaults = UserDefaults(suiteName: "com.kamby.CatRobot.hermes-probe") else {
                throw ProbeFailure.criterion("probe defaults unavailable")
            }
            let configurations = HermesProbeConfigurationStore(defaults: defaults)
            let imported = await HermesBootstrapImporter(file: bootstrap, credentials: credentials,
                                                         configurations: configurations).import()
            switch imported {
            case .imported: receipt["bootstrap"] = "imported"
            case .notImported(let reason): receipt["bootstrap"] = "notImported:\(reason.rawValue)"
            case .importFailedBootstrapRemains(let rolledBack):
                receipt["bootstrap"] = "importFailedBootstrapRemains"
                receipt["credentialRollbackSucceeded"] = rolledBack
            }
            try save()
            // A malformed or undeletable bootstrap must never fall back to an old credential.
            try require(imported.permitsStoredCredentials, "bootstrap does not permit stored credentials")
            guard let configuration = configurations.load(), let credential = try await credentials.load() else {
                throw ProbeFailure.criterion("probe configuration or credential missing")
            }
            receipt["key_present"] = !credential.apiKey.isEmpty
            receipt["bootstrapRemoved"] = !FileManager.default.fileExists(atPath: bootstrap.path)
            receipt["endpoint"] = configuration.endpoint.absoluteString
            try require(!credential.apiKey.isEmpty, "probe credential empty")
            let transport = PinnedURLSessionTransport(configuration: configuration)
            let runs = HermesRunClient(configuration: configuration, credential: credential, transport: transport)
            let bridge = HermesBridgeClient(configuration: configuration, credential: credential, transport: transport)

            if stage == "lifetime1" {
                phase = "authentication"
                for (name, headers) in [("absent", [String: String]()),
                                        ("wrong", ["Authorization": "Bearer probe-invalid-\(UUID().uuidString)"])] {
                    let response = try await transport.send(.init(method: "GET",
                        url: configuration.endpoint.appending(path: "v1/capabilities"), headers: headers, body: nil, timeout: 15))
                    records.append(["operation": "capabilities", "credential": name, "status": response.statusCode])
                    try require(response.statusCode == 401, "invalid credential must return 401")
                }
                _ = try await runs.capabilities()
                records.append(["operation": "capabilities", "credential": "present", "status": 200])
                try save()
                phase = "plain"
                let nonce = UUID().uuidString
                let start = Date()
                let plain = try await runs.createRun(input: "CatRobot probe: echo back exactly: \(nonce)")
                let terminal = try await runs.awaitTerminal(id: plain.runID, deadline: .seconds(120))
                let matched = terminal.output?.contains(nonce) == true
                records.append(["operation": "plain", "runID": terminal.runID, "status": terminal.status.rawValue,
                                "nonceMatched": matched, "seconds": Date().timeIntervalSince(start)])
                try save()
                try require(terminal.status == .completed && matched, "plain nonce round trip failed")
            }

            phase = "bound"
            let started = Date()
            let binding = try await bridge.bind()
            let nonce = UUID().uuidString
            let run = try await bridge.submitRun(input: "Use the echo tool exactly once with text \"\(nonce)\" and reply with exactly what it returned.")
            records.append(["operation": "boundSubmit", "bindingID": binding.bindingID, "generation": binding.generation,
                            "runID": run.runID, "status": run.status.rawValue])
            try save()
            let call = try await waitForCall(bridge)
            try require(call.bindingID == binding.bindingID && call.runID == run.runID && call.generation == binding.generation,
                        "call identity mismatch")
            try require(call.tool == "echo" && call.arguments["text"] == nonce, "echo argument mismatch")
            try require(call.expiresAt > Date(), "echo call expired before the device received it")
            records.append(["operation": "callReceived", "bindingID": call.bindingID, "runID": call.runID,
                            "generation": call.generation, "callID": call.callID, "seconds": Date().timeIntervalSince(started)])
            try save()
            if stage == "lifetime1" {
                phase = "echoResult"
                let outcome = await bridge.process(call)
                records.append(["operation": "mockEcho", "accepted": outcome == .accepted])
                try save()
                try require(outcome == .accepted, "mock echo result was not acknowledged")
                let terminal = try await runs.awaitTerminal(id: run.runID, deadline: .seconds(120))
                let matched = terminal.output?.contains(nonce) == true
                records.append(["operation": "boundTerminal", "runID": terminal.runID, "status": terminal.status.rawValue,
                                "nonceMatched": matched, "seconds": Date().timeIntervalSince(started)])
                try save()
                try require(terminal.status == .completed && matched, "bound echo round trip failed")
            } else {
                phase = "cancel"
                // Hold the call: never pass it to the mock before local invalidation/revoke.
                let result = try await bridge.cancel(using: runs, deadline: .seconds(45))
                let discarded = await bridge.process(call) == .discarded
                records.append(["operation": "cancel", "runID": result.terminal.runID,
                                "status": result.terminal.status.rawValue, "revokeAccepted": result.revokeAccepted,
                                "stopAccepted": result.stopAccepted, "heldCallDiscarded": discarded,
                                "mockExecuted": false, "seconds": Date().timeIntervalSince(started)])
                try save()
                try require(result.revokeAccepted && result.terminal.status.isTerminal && discarded,
                            "revoke acknowledgement, cancel terminal or invalidation missing")
            }
            receipt["outcome"] = "success"
            receipt["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            try save()
        } catch {
            receipt["outcome"] = "failed"
            receipt["failedPhase"] = phase
            // Never describe arbitrary errors or requests; external messages may include credentials.
            if case HermesProbeError.transport(let reason) = error { receipt["transportDiagnostic"] = reason }
            if case HermesProbeError.httpStatus(let status) = error { receipt["httpStatus"] = status }
            receipt["errorType"] = String(reflecting: type(of: error))
            try? save()
            XCTFail("Hermes probe failed in \(phase); see sanitized results.json")
        }
    }

    private func waitForCall(_ bridge: HermesBridgeClient) async throws -> HermesDeviceCall {
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            let calls = try await bridge.pollCalls()
            if let call = calls.first {
                try require(calls.count == 1, "expected exactly one echo call")
                return call
            }
        }
        throw ProbeFailure.criterion("echo call deadline exceeded")
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw ProbeFailure.criterion(reason) }
    }

    private func save() throws {
        guard let resultFile else { return }
        receipt["records"] = records
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: resultFile, options: .atomic)
    }
#else
    func testSelectedStage() throws { throw XCTSkip("Hermes probe requires a Debug test host") }
#endif
}
