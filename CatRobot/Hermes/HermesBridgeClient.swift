#if DEBUG
import Foundation

struct HermesBinding: Decodable, Equatable, Sendable {
    let bindingID: String
    let generation: Int
    let expiresAt: Date
}

struct HermesDeviceCall: Decodable, Equatable, Sendable {
    var bindingID: String
    var runID: String
    var sessionID: String?
    var generation: Int
    var callID: String
    var tool: String
    var arguments: [String: String]
    var expiresAt: Date
}

enum HermesCallOutcome: Equatable, Sendable {
    case accepted, duplicate, discarded, unknown
    case rejected(Int)
}

struct HermesBridgeCancellation: Equatable, Sendable {
    let terminal: HermesRunState
    let revokeAccepted: Bool
    let stopAccepted: Bool
}

actor HermesBridgeClient {
    private enum Phase { case idle, binding, bound, submitting, running, revoked }
    private struct Receipt {
        let outcome: HermesCallOutcome
        let expiresAt: Date
    }

    /// 契約 r3 §2.5: relay は submit（capabilities 15 s + run 作成 15 s × 2）を 50 s の deadline で打ち切るので、端末の
    /// submit 要求だけその外側 60 s まで待つ。他の bridge 要求は既存の 15 s を維持する。
    static let requestTimeout: TimeInterval = 15
    static let submitRequestTimeout: TimeInterval = 60

    private let configuration: HermesProbeConfiguration
    private let credential: HermesCredential
    private let transport: any HermesTransport
    private let clock: any HermesClock
    private var phase = Phase.idle
    private var currentBinding: HermesBinding?
    private var currentRun: HermesRunState?
    private var generation = 0
    private var receipts: [String: Receipt] = [:]

    init(configuration: HermesProbeConfiguration, credential: HermesCredential, transport: any HermesTransport,
         clock: any HermesClock = SystemHermesClock()) {
        self.configuration = configuration
        self.credential = credential
        self.transport = transport
        self.clock = clock
    }

    func bind() async throws -> HermesBinding {
        guard phase == .idle else { throw HermesClientError.invalidBridgeState }
        phase = .binding
        do {
            let response = try await send("POST", path: "bridge/bindings", status: 201,
                                          body: JSONEncoder().encode(DeviceInput(deviceID: configuration.deviceID)))
            let binding: HermesBinding = try decode(response.body)
            guard Self.isSafeID(binding.bindingID), binding.generation > 0, (binding.generation < Int.max),
                  binding.expiresAt.timeIntervalSince1970.isFinite, binding.expiresAt > (await clock.now()) else {
                throw HermesClientError.malformedResponse
            }
            currentBinding = binding
            generation = binding.generation
            phase = .bound
            return binding
        } catch {
            invalidate()
            throw error
        }
    }

    func submitRun(input: String) async throws -> HermesRunState {
        guard phase == .bound, let binding = currentBinding else { throw HermesClientError.invalidBridgeState }
        phase = .submitting
        do {
            let response = try await send("POST", path: "bridge/bindings/\(binding.bindingID)/run", status: 202,
                                          body: JSONEncoder().encode(RunInput(input: input)), timeout: Self.submitRequestTimeout)
            let payload: RunPayload = try decode(response.body)
            guard Self.isSafeID(payload.runID), !payload.status.isEmpty else { throw HermesClientError.malformedResponse }
            guard phase == .submitting else { throw HermesClientError.invalidBridgeState }
            let run = HermesRunState(runID: payload.runID, status: .init(rawValue: payload.status),
                                     sessionID: payload.sessionID, output: nil)
            currentRun = run
            phase = .running
            return run
        } catch {
            invalidate()
            throw error
        }
    }

    func pollCalls() async throws -> [HermesDeviceCall] {
        guard phase == .running, let binding = currentBinding else { throw HermesClientError.invalidBridgeState }
        let response = try await send("GET", path: "bridge/bindings/\(binding.bindingID)/calls", status: 200,
                                      query: [URLQueryItem(name: "generation", value: String(generation)),
                                              URLQueryItem(name: "wait", value: "10")])
        guard phase == .running else { return [] }
        let payload: CallsPayload = try decode(response.body)
        return payload.calls
    }

    /// 配送は命令候補。現在の identity と期限を照合した後、Foundation の echo だけを実行する。
    func process(_ call: HermesDeviceCall) async -> HermesCallOutcome {
        let now = await clock.now()
        receipts = receipts.filter { $0.value.expiresAt > now }
        guard phase == .running, let binding = currentBinding, let run = currentRun,
              call.bindingID == binding.bindingID, call.runID == run.runID, call.generation == generation,
              Self.isSafeID(call.callID), call.expiresAt > now, binding.expiresAt > now else { return .discarded }
        if let receipt = receipts[call.callID] { return receipt.outcome }

        // await より前に予約する。同時配送も ACK 喪失も再実行・再 POST にはしない。
        receipts[call.callID] = Receipt(outcome: .unknown, expiresAt: now.addingTimeInterval(600))
        let result = MockDeviceToolExecutor().execute(tool: call.tool, arguments: call.arguments)
        let payload: ResultInput
        switch result {
        case .success(let text):
            payload = ResultInput(runID: run.runID, generation: generation, ok: true, text: text, error: nil)
        case .rejected(let reason):
            payload = ResultInput(runID: run.runID, generation: generation, ok: false, text: nil, error: reason.rawValue)
        }

        let outcome: HermesCallOutcome
        do {
            let response = try await send("POST", path: "bridge/bindings/\(binding.bindingID)/calls/\(call.callID)/result",
                                          status: 200, body: JSONEncoder().encode(payload))
            let acknowledgement: Acknowledgement = try decode(response.body)
            if acknowledgement.accepted && acknowledgement.duplicate != true {
                outcome = .accepted
            } else if !acknowledgement.accepted && acknowledgement.duplicate == true {
                outcome = .duplicate
            } else {
                outcome = .unknown
            }
        } catch HermesClientError.httpStatus(let code) {
            outcome = .rejected(code)
        } catch HermesClientError.unauthorized {
            outcome = .rejected(401)
        } catch {
            outcome = .unknown
        }
        receipts[call.callID] = Receipt(outcome: outcome, expiresAt: (await clock.now()).addingTimeInterval(600))
        return outcome
    }

    func revoke() async throws {
        guard let binding = currentBinding else { throw HermesClientError.invalidBridgeState }
        invalidate()
        _ = try await send("POST", path: "bridge/bindings/\(binding.bindingID)/revoke", status: 200)
    }

    func cancel(using runClient: HermesRunClient, deadline: Duration) async throws -> HermesBridgeCancellation {
        guard let run = currentRun else { throw HermesClientError.invalidBridgeState }
        let revoked: Bool
        do { try await revoke(); revoked = true } catch { revoked = false }
        let stopped: Bool
        do { try await runClient.stop(id: run.runID); stopped = true } catch { stopped = false }
        let terminal = try await runClient.awaitTerminal(id: run.runID, deadline: deadline)
        return HermesBridgeCancellation(terminal: terminal, revokeAccepted: revoked, stopAccepted: stopped)
    }

    private func invalidate() {
        if phase != .revoked { generation += 1 }
        phase = .revoked
    }

    private func send(_ method: String, path: String, status: Int, body: Data? = nil,
                      query: [URLQueryItem] = [], timeout: TimeInterval = HermesBridgeClient.requestTimeout) async throws -> HermesHTTPResponse {
        try Task.checkCancellation()
        let url = configuration.endpoint.appending(path: path).appending(queryItems: query)
        var headers = ["Authorization": "Bearer \(credential.apiKey)"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let response = try await transport.send(HermesHTTPRequest(method: method, url: url, headers: headers, body: body, timeout: timeout))
        if response.statusCode == 401 { throw HermesClientError.unauthorized }
        guard response.statusCode == status else { throw HermesClientError.httpStatus(response.statusCode) }
        return response
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let value = try? decoder.decode(T.self, from: data) else { throw HermesClientError.malformedResponse }
        return value
    }

    private static func isSafeID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct DeviceInput: Encodable { let deviceID: String }
    private struct RunInput: Encodable { let input: String }
    private struct RunPayload: Decodable { let runID: String; let status: String; let sessionID: String? }
    private struct CallsPayload: Decodable { let calls: [HermesDeviceCall] }
    private struct ResultInput: Encodable {
        let runID: String
        let generation: Int
        let ok: Bool
        let text: String?
        let error: String?
    }
    private struct Acknowledgement: Decodable { let accepted: Bool; let duplicate: Bool? }
}
#endif
