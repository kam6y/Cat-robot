import Foundation
import XCTest
@testable import CatRobot

/// 設定「Hermes 接続」のモデルと effort。候補の読み取り（native inventory と古い Hermes の別名）、run の body、
/// 接続先ごとの保存、ターンごとの固定を確かめる。
final class HermesModelSelectionTests: XCTestCase {
    private let connection = HermesConnection(endpoint: URL(string: "https://hermes.test:8443/")!,
                                              credential: HermesCredential(apiKey: "client-key"))
    private let otherConnection = HermesConnection(endpoint: URL(string: "https://other.test/")!,
                                                   credential: HermesCredential(apiKey: "other-key"))

    private static let inventory = #"""
    {"model":"gpt-5","provider":"custom:lab","providers":[
      {"slug":"openrouter","name":"OpenRouter","is_current":false,"models":["a","b","b"],"unavailable_models":["b"],
       "capabilities":{"a":{"fast":false,"reasoning":true,"can_disable_reasoning":false}},"pricing":{"a":{"prompt":"1"}}},
      {"slug":"anthropic","name":"Anthropic","models":["claude"],"authenticated":false,"warning":"paste a key"},
      {"slug":"openai","name":"OpenAI","models":[],"source":"canonical"},
      {"slug":"broken","models":"not-a-list"},
      {"name":"no slug","models":["x"]},
      {"slug":"lab","name":"Lab","is_user_defined":true,"aliases":["custom:lab","lab"],"models":["gpt-5","plain"],
       "capabilities":{"gpt-5":{"reasoning":false}}}
    ]}
    """#
    private static let routes = #"""
    {"object":"list","data":[{"id":"hermes-agent","object":"model","root":"hermes-agent","parent":null},
      {"id":"fast","object":"model","root":"gpt-5-mini","parent":"hermes-agent"}]}
    """#

    // MARK: - 候補の読み取り

    func testInventoryOffersOnlyUsableProvidersAndModels() throws {
        let catalog = try HermesModelCatalog.inventory(from: Data(Self.inventory.utf8))
        XCTAssertEqual(catalog.source, .inventory)
        XCTAssertEqual(catalog.providers.map(\.slug), ["openrouter", "lab"], "unauthenticated, empty and unreadable rows are left out")
        XCTAssertEqual(catalog.providers.first?.models.map(\.id), ["a"], "unavailable and duplicate models are left out")
        XCTAssertEqual(catalog.defaultModel, "gpt-5")
        XCTAssertEqual(catalog.defaultProvider, "lab", "custom:<key> resolves to the row the default runs on")
    }

    func testEffortChoicesFollowTheModelsReasoningSupport() throws {
        let catalog = try HermesModelCatalog.inventory(from: Data(Self.inventory.utf8))
        XCTAssertEqual(catalog.effortChoices(for: HermesModelID(provider: "openrouter", model: "a")), HermesReasoningEffort.levels,
                       "a model that cannot turn reasoning off offers every level but no off")
        XCTAssertEqual(catalog.effortChoices(for: HermesModelID(provider: "lab", model: "plain")),
                       HermesReasoningEffort.levels + [.off], "an unlisted capability keeps every choice")
        XCTAssertEqual(catalog.effortChoices(for: HermesModelID(provider: "lab", model: "gpt-5")), [])
        XCTAssertEqual(catalog.effortChoices(for: nil), [], "the default model has no reasoning control either")
        XCTAssertEqual(HermesReasoningEffort.levels.map(\.rawValue), ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"])
    }

    func testOlderHermesOffersItsRouteAliasesWithoutAProviderOrEffort() throws {
        let catalog = try HermesModelCatalog.routes(from: Data(Self.routes.utf8))
        XCTAssertEqual(catalog.source, .routes)
        XCTAssertEqual(catalog.defaultModel, "hermes-agent")
        XCTAssertEqual(catalog.providers.map(\.slug), [nil])
        XCTAssertEqual(catalog.providers.first?.models.map(\.id), ["fast"])
        XCTAssertEqual(catalog.effortChoices(for: HermesModelID(provider: nil, model: "fast")), [])
        XCTAssertEqual(catalog.effortChoices(for: nil), [])
    }

    func testUnreadableCatalogIsMalformed() {
        XCTAssertThrowsError(try HermesModelCatalog.inventory(from: Data(#"{"providers":"no"}"#.utf8))) {
            XCTAssertEqual($0 as? HermesClientError, .malformedResponse)
        }
        XCTAssertThrowsError(try HermesModelCatalog.routes(from: Data("[]".utf8))) {
            XCTAssertEqual($0 as? HermesClientError, .malformedResponse)
        }
    }

    // MARK: - 候補の要求

    func testCatalogAsksOnlyForConfiguredProvidersAndRefreshesOnlyWhenAsked() async throws {
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, Self.inventory), (200, Self.inventory)]])
        let client = HermesRunClient(endpoint: connection.endpoint, credential: connection.credential, transport: transport)
        _ = try await client.modelCatalog()
        _ = try await client.modelCatalog(refresh: true)
        let queries = await transport.requests.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        XCTAssertEqual(queries, [[URLQueryItem(name: "include_unconfigured", value: "false")],
                                 [URLQueryItem(name: "include_unconfigured", value: "false"), URLQueryItem(name: "refresh", value: "true")]])
        let authorized = await transport.requests.allSatisfy { $0.headers["Authorization"] == "Bearer client-key" }
        XCTAssertTrue(authorized)
    }

    func testCatalogFallsBackToRouteAliasesOnlyWhenTheInventoryIsMissing() async throws {
        for status in [404, 405, 501] {
            let transport = RoutedHermesTransport(["GET /api/model/options": [(status, "{}")], "GET /v1/models": [(200, Self.routes)]])
            let client = HermesRunClient(endpoint: connection.endpoint, credential: connection.credential, transport: transport)
            let catalog = try await client.modelCatalog()
            XCTAssertEqual(catalog.source, .routes, "HTTP \(status)")
        }
        let refusals: [(Int, HermesClientError)] = [(401, .unauthorized), (500, .httpStatus(500))]
        for (status, expected) in refusals {
            let transport = RoutedHermesTransport(["GET /api/model/options": [(status, "{}")], "GET /v1/models": [(200, Self.routes)]])
            let client = HermesRunClient(endpoint: connection.endpoint, credential: connection.credential, transport: transport)
            do {
                _ = try await client.modelCatalog()
                XCTFail("HTTP \(status) is not a missing inventory")
            } catch {
                XCTAssertEqual(error as? HermesClientError, expected)
            }
            let paths = await transport.requests.map(\.url.path)
            XCTAssertEqual(paths, ["/api/model/options"], "HTTP \(status) does not fall back")
        }
    }

    // MARK: - run の body

    func testDefaultOptionsKeepTheRunBodyUnchanged() async throws {
        let body = try await runBody(options: nil)
        XCTAssertEqual(Set(body.keys), ["input", "session_id", "instructions"])
        let explicitDefault = try await runBody(options: HermesRunOptions())
        XCTAssertEqual(Set(explicitDefault.keys), ["input", "session_id", "instructions"])
    }

    func testSelectedModelAndEffortTravelWithTheRun() async throws {
        let body = try await runBody(options: HermesRunOptions(model: HermesModelID(provider: "openrouter", model: "a"), effort: .high))
        XCTAssertEqual(body["model"] as? String, "a")
        XCTAssertEqual(body["provider"] as? String, "openrouter")
        let reasoning = (body["model_options"] as? [String: Any])?["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
        XCTAssertNil(reasoning?["enabled"])

        let off = try await runBody(options: HermesRunOptions(effort: .off))
        XCTAssertNil(off["model"])
        XCTAssertNil(off["provider"])
        let disabled = (off["model_options"] as? [String: Any])?["reasoning"] as? [String: Any]
        XCTAssertEqual(disabled?["enabled"] as? Bool, false)
        XCTAssertNil(disabled?["effort"])

        let alias = try await runBody(options: HermesRunOptions(model: HermesModelID(provider: nil, model: "fast")))
        XCTAssertEqual(alias["model"] as? String, "fast")
        XCTAssertNil(alias["provider"], "a route alias is sent without a provider")
        XCTAssertNil(alias["model_options"])
    }


    private func runBody(options: HermesRunOptions?) async throws -> [String: Any] {
        let transport = RoutedHermesTransport(["POST /v1/runs": [(202, #"{"run_id":"run-1","status":"started"}"#)]])
        let client = HermesRunClient(endpoint: connection.endpoint, credential: connection.credential, transport: transport)
        _ = try await client.createRun(input: "ねえ", sessionID: "catrobot-s1", idempotencyKey: UUID(), instructions: "persona",
                                       options: options)
        let request = await transport.requests.first
        let data = try XCTUnwrap(request?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - ターンごとの固定

    func testATurnReadsTheSelectionOnceForItsOriginAndResendsTheSameBody() async throws {
        let server = FakeHermesServer(runs: [.transportFailure, hermesAccepted("run-1")],
                                      polls: ["run-1": [hermesRun("run-1", "completed", output: "やあ")]])
        let reads = OptionReads([HermesRunOptions(model: HermesModelID(provider: "openrouter", model: "a"), effort: .low),
                                 HermesRunOptions(model: HermesModelID(provider: "lab", model: "plain"))])
        let resolved = connection
        let service = HermesConversationService(
            connection: { resolved }, runOptions: { await reads.next(for: $0) }, transport: server,
            records: InMemoryHermesSessionRecordStore(), clock: SteppingHermesClock(),
            timing: HermesConversationTiming(pollInterval: .seconds(1), turnDeadline: .seconds(10), submitRetryDelay: .seconds(1)),
            makeSessionID: { "catrobot-s1" })
        for try await _ in try await service.streamReply(to: "ねえ") {}
        let posts = await server.runPosts
        XCTAssertEqual(posts.count, 2, "the uncertain first POST is resent")
        XCTAssertEqual(posts.first?.body, posts.last?.body, "a resend keeps the same body")
        let body = try XCTUnwrap(posts.first?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["model"] as? String, "a")
        XCTAssertEqual(body["provider"] as? String, "openrouter")
        let origins = await reads.origins
        XCTAssertEqual(origins, [connection.origin], "the selection is read once, for this connection's origin")
    }

    // MARK: - 接続先ごとの保存

    @MainActor
    func testSelectionsAreKeptPerOriginAndStartAtTheHermesDefault() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let settings = HermesModelSettings(defaults: defaults, transport: RoutedHermesTransport([:]), origin: connection.origin)
        XCTAssertEqual(settings.current, HermesRunOptions())
        XCTAssertNil(settings.options(for: connection.origin), "nothing is added to the run until something is chosen")
        settings.select(model: HermesModelID(provider: "openrouter", model: "a"))
        settings.select(effort: .high)
        settings.connectionChanged(origin: otherConnection.origin)
        XCTAssertEqual(settings.current, HermesRunOptions(), "another server starts at its own default")
        XCTAssertNil(settings.options(for: otherConnection.origin))
        XCTAssertEqual(settings.options(for: connection.origin),
                       HermesRunOptions(model: HermesModelID(provider: "openrouter", model: "a"), effort: .high))
        let reopened = HermesModelSettings(defaults: defaults, transport: RoutedHermesTransport([:]), origin: connection.origin)
        XCTAssertEqual(reopened.current.model?.model, "a", "the choice survives a relaunch")
        settings.connectionChanged(origin: connection.origin)
        settings.select(model: nil)
        settings.select(effort: nil)
        XCTAssertNil(settings.options(for: connection.origin), "choosing the defaults again stops sending a selection")
    }

    @MainActor
    func testChangingTheModelDropsAnEffortTheNewModelCannotUse() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, Self.inventory)]])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        await settings.refresh(connection: connection, force: false)
        XCTAssertEqual(settings.phase, .loaded)
        settings.select(model: HermesModelID(provider: "lab", model: "plain"))
        settings.select(effort: .off)
        settings.select(model: HermesModelID(provider: "openrouter", model: "a"))
        XCTAssertNil(settings.current.effort, "this model cannot turn reasoning off")
        settings.select(effort: .ultra)
        settings.select(model: HermesModelID(provider: "lab", model: "gpt-5"))
        XCTAssertNil(settings.current.effort, "this model has no reasoning control")
        XCTAssertEqual(settings.effortChoices, [])
    }

    @MainActor
    func testOpeningSettingsWhileHermesWarmsItsCatalogPreservesTheSelection() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pending = #"{"providers":[{"slug":"nous","models":["paid"],"free_tier_pending":true,"unavailable_models":["paid"]}]}"#
        let ready = #"{"providers":[{"slug":"nous","models":["paid"],"capabilities":{"paid":{"reasoning":true}}}]}"#
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, pending), (200, ready)]])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        let choice = HermesModelID(provider: "nous", model: "paid")
        settings.select(model: choice)
        settings.select(effort: .high)
        await settings.refresh(connection: connection, force: false)
        XCTAssertEqual(settings.options(for: connection.origin), HermesRunOptions(model: choice, effort: .high))
        XCTAssertNil(settings.catalog?.model(for: choice))
        await settings.refresh(connection: connection, force: false)
        XCTAssertNotNil(settings.catalog?.model(for: choice))
        XCTAssertEqual(settings.current, HermesRunOptions(model: choice, effort: .high))
    }

    @MainActor
    func testSavingANewKeyWhileThePreviousKeyLoadsDiscardsTheOldLookup() async throws {
        actor DelayedCredentials: HermesCredentialStore {
            let gate = ConversationTestGate()
            var credential: HermesCredential?
            init(_ key: HermesCredential) { credential = key }
            func load() async throws -> HermesCredential? {
                let saved = credential
                if saved?.apiKey == "old" { await gate.wait() }
                return saved
            }
            func save(_ value: HermesCredential) { credential = value }
            func delete() { credential = nil }
        }
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(connection.endpoint.absoluteString, forKey: HermesConnectionSettings.endpointKey)
        let keys = DelayedCredentials(HermesCredential(apiKey: "old"))
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, Self.inventory), (401, "{}")]])
        let settings = HermesConnectionSettings(defaults: defaults, credentials: { _ in keys }, transport: transport)
        let old = Task { await settings.refreshModels(force: false) }
        await keys.gate.waitUntilEntered()
        try await settings.save(endpointText: connection.endpoint.absoluteString, apiKey: "new")
        await settings.refreshModels(force: false)
        await keys.gate.open()
        await old.value
        let authorizations = await transport.requests.compactMap { $0.headers["Authorization"] }
        XCTAssertEqual(authorizations, ["Bearer new"])
        XCTAssertEqual(settings.models.phase, .loaded)
    }

    @MainActor
    func testALoadedCatalogResetsAChoiceTheServerNoLongerOffers() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, Self.inventory)]])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        settings.select(model: HermesModelID(provider: "openrouter", model: "retired"))
        settings.select(effort: .high)
        await settings.refresh(connection: connection, force: true)
        XCTAssertNil(settings.options(for: connection.origin))
        XCTAssertNotNil(settings.notice)
    }

    @MainActor
    func testAFailedLoadKeepsTheChoiceAndARefusalIsNotRetriedAutomatically() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let transport = RoutedHermesTransport(["GET /api/model/options": [(401, "{}"), (200, Self.inventory)]])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        settings.select(model: HermesModelID(provider: "openrouter", model: "a"))
        await settings.refresh(connection: connection, force: false)
        guard case .failed = settings.phase else { return XCTFail("a refusal is shown") }
        XCTAssertEqual(settings.options(for: connection.origin)?.model?.model, "a", "a failed load keeps the choice")
        await settings.refresh(connection: connection, force: false)
        var count = await transport.requests.count
        XCTAssertEqual(count, 1, "the same refused key is not asked again on its own")
        await settings.refresh(connection: connection, force: true)
        count = await transport.requests.count
        XCTAssertEqual(count, 2, "an explicit refresh asks again")
        XCTAssertEqual(settings.phase, .loaded)
    }

    @MainActor
    func testALateCatalogForAnEarlierConnectionIsDiscarded() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let gate = ConversationTestGate()
        let transport = RoutedHermesTransport(["GET /api/model/options": [(200, Self.inventory)]], gates: ["GET /api/model/options": gate])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        let earlier = connection
        let load = Task { await settings.refresh(connection: earlier, force: false) }
        await gate.waitUntilEntered()
        settings.connectionChanged(origin: otherConnection.origin)
        await gate.open()
        await load.value
        XCTAssertNil(settings.catalog, "the answer for the earlier server is not shown for the new one")
        XCTAssertEqual(settings.phase, .idle)
    }

    @MainActor
    func testReopeningSettingsKeepsAnExplicitRefreshInFlight() async throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = ConversationTestGate()
        let route = "GET /api/model/options"
        let transport = RoutedHermesTransport([route: [(200, Self.inventory)]], gates: [route: gate])
        let settings = HermesModelSettings(defaults: defaults, transport: transport, origin: connection.origin)
        let manual = Task { await settings.refresh(connection: connection, force: true) }
        await gate.waitUntilEntered()
        await settings.refresh(connection: connection, force: false)
        await gate.open()
        await manual.value
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(settings.phase, .loaded)
    }

    @MainActor
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "hermes-model-selection-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
}

/// 設定の選択を読むたびに次の値を返し、読んだ origin を記録する。
private actor OptionReads {
    private var values: [HermesRunOptions]
    private(set) var origins: [String] = []
    init(_ values: [HermesRunOptions]) { self.values = values }
    func next(for origin: String) -> HermesRunOptions? {
        origins.append(origin)
        return values.isEmpty ? nil : values.removeFirst()
    }
}
