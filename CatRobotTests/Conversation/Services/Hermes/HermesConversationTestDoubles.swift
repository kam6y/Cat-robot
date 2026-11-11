import Foundation
@testable import CatRobot

/// Hermes API の fake。path で振り分け、run の作成・poll・stop・履歴を台本どおりに返す。
/// gated は test が release するまで応答を止める（取消と遅延応答の順序を固定するため）。
actor FakeHermesServer: HermesTransport {
    indirect enum Reply: Sendable {
        case json(Int, String)
        case transportFailure
        case gated(String, Reply)
    }

    private(set) var requests: [HermesHTTPRequest] = []
    private var runReplies: [Reply]
    private var pollReplies: [String: [Reply]]
    private var stopReplies: [String: [Reply]]
    private var historyReplies: [Reply]
    private var capabilityReplies: [Reply]
    private var blocked: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    /// polls と stops は run id ごと。最後の 1 件はくり返す。stops の既定は installed Hermes の stopping 応答。
    init(runs: [Reply] = [], polls: [String: [Reply]] = [:], stops: [String: [Reply]] = [:], history: [Reply] = [],
         capabilities: [Reply] = []) {
        runReplies = runs
        pollReplies = polls
        stopReplies = stops
        historyReplies = history
        capabilityReplies = capabilities
    }

    func send(_ request: HermesHTTPRequest) async throws -> HermesHTTPResponse {
        requests.append(request)
        let path = request.url.path
        let reply: Reply
        if request.method == "POST", path.hasSuffix("/v1/runs") {
            reply = runReplies.isEmpty ? .transportFailure : runReplies.removeFirst()
        } else if request.method == "POST", path.hasSuffix("/stop") {
            let id = String(path.split(separator: "/").dropLast().last ?? "")
            reply = Self.next(&stopReplies, id) ?? .json(200, #"{"run_id":"\#(id)","status":"stopping"}"#)
        } else if request.method == "GET", path.contains("/v1/runs/") {
            let id = String(path.split(separator: "/").last ?? "")
            reply = Self.next(&pollReplies, id) ?? .transportFailure
        } else if request.method == "GET", path.hasSuffix("/messages") {
            reply = historyReplies.isEmpty ? .transportFailure : historyReplies.removeFirst()
        } else if request.method == "GET", path.hasSuffix("/v1/capabilities") {
            reply = capabilityReplies.isEmpty ? .transportFailure : capabilityReplies.removeFirst()
        } else {
            reply = .json(404, #"{"detail":"not routed"}"#)
        }
        return try await respond(reply)
    }

    private static func next(_ queues: inout [String: [Reply]], _ id: String) -> Reply? {
        guard var queue = queues[id], let first = queue.first else { return nil }
        if queue.count > 1 { queue.removeFirst() }
        queues[id] = queue
        return first
    }

    private func respond(_ reply: Reply) async throws -> HermesHTTPResponse {
        switch reply {
        case .json(let status, let body):
            return HermesHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        case .transportFailure:
            throw HermesClientError.transport("NSURLErrorDomain -1005")
        case .gated(let name, let next):
            blocked.insert(name)
            await withCheckedContinuation { gates[name] = $0 }
            return try await respond(next)
        }
    }

    func release(_ name: String) {
        blocked.remove(name)
        gates.removeValue(forKey: name)?.resume()
    }

    func isBlocked(_ name: String) -> Bool { blocked.contains(name) }

    /// 実時間で待つ（worker は消費側と独立に進むため）。2 秒で諦める。
    func waitUntilBlocked(_ name: String) async {
        for _ in 0..<400 where !blocked.contains(name) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func waitForRequest(_ matches: @Sendable (HermesHTTPRequest) -> Bool) async {
        for _ in 0..<400 where !requests.contains(where: matches) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    var runPosts: [HermesHTTPRequest] { requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/v1/runs") } }
    var stops: [HermesHTTPRequest] { requests.filter { $0.url.path.hasSuffix("/stop") } }
}

actor InMemoryHermesSessionRecordStore: HermesSessionRecordStore {
    private(set) var record: HermesSessionRecord?
    init(_ record: HermesSessionRecord? = nil) { self.record = record }
    func load() -> HermesSessionRecord? { record }
    func save(_ record: HermesSessionRecord?) { self.record = record }

    /// 消費側と独立に進む worker の書き込みを実時間で待つ。2 秒で諦める。
    func waitUntil(_ matches: @Sendable (HermesSessionRecord?) -> Bool) async {
        for _ in 0..<400 where !matches(record) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// sleep を test が起こすまで止める仮想時計（poll の待ちの途中で取り消す順序を固定するため）。時刻は起こしたときに進む。
actor GatedSleepHermesClock: HermesClock {
    private var current = Date(timeIntervalSince1970: 10_000)
    private var sleeper: CheckedContinuation<Void, Never>?
    func now() -> Date { current }
    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { sleeper = $0 }
        current += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    func wake() {
        sleeper?.resume()
        sleeper = nil
    }

    /// 実時間で待つ（worker は消費側と独立に進むため）。2 秒で諦める。
    func waitUntilAsleep() async {
        for _ in 0..<400 where sleeper == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// 1 秒単位で進む仮想時計（sleep は即座に返り、時刻だけ進む）。
actor SteppingHermesClock: HermesClock {
    private var current = Date(timeIntervalSince1970: 10_000)
    func now() -> Date { current }
    func sleep(for duration: Duration) async throws {
        current = current.addingTimeInterval(TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18)
        await Task.yield()
    }
}

extension HermesHTTPRequest {
    var jsonBody: [String: String]? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }
}

func hermesRun(_ id: String, _ status: String, output: String? = nil) -> FakeHermesServer.Reply {
    let outputField = output.map { #","output":"\#($0)""# } ?? ""
    return .json(200, #"{"run_id":"\#(id)","status":"\#(status)","session_id":"s"\#(outputField)}"#)
}

func hermesAccepted(_ id: String) -> FakeHermesServer.Reply {
    .json(202, #"{"run_id":"\#(id)","status":"started","replayed":false}"#)
}
