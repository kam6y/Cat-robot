import Foundation

/// Hermes で選べるモデルの候補（設定「Hermes 接続」が表示する）。
/// - native inventory（`GET /api/model/options?include_unconfigured=false`）: provider ごとのモデルと、推論の対応。
/// - 一覧に対応しない古い Hermes（404・405・501）: `GET /v1/models` の model_routes の別名だけ（provider は持たない）。
/// Hermes はモデルごとの effort の段階を返さない。推論に対応するかと、推論を止められるかだけを読む。
struct HermesModelCatalog: Equatable, Sendable {
    enum Source: Equatable, Sendable { case inventory, routes }

    struct Model: Equatable, Sendable, Identifiable {
        let id: String
        /// false なら推論の設定を持たない（effort の欄を出さない）。nil は Hermes の catalog に記載がない。
        let reasoning: Bool?
        /// false なら推論を止められない（「オフ」を出さない）。nil は記載がない。
        let canDisableReasoning: Bool?
    }

    struct Provider: Equatable, Sendable, Identifiable {
        /// Hermes の provider の slug。model_routes の別名（provider を送らない）は nil。
        let slug: String?
        let name: String
        let models: [Model]
        var id: String { slug ?? "" }
    }

    let source: Source
    let providers: [Provider]
    /// Hermes が既定で使うモデル（config の model.default。別名の一覧では Hermes の仮想 model 名）。
    let defaultModel: String?
    /// 既定の provider。行が分かれば、その行の slug（custom provider の `custom:<key>` も行の slug にそろえる）。
    let defaultProvider: String?

    func model(for id: HermesModelID) -> Model? {
        providers.first { $0.slug == id.provider }?.models.first { $0.id == id.model }
    }

    /// 選んだモデル（nil は Hermes の既定）で出す effort。空なら effort の欄を出さない。
    /// 段階は Hermes の UI と同じ標準の全段階。推論に対応しないモデル、別名の一覧（対応が分からない）では出さない。
    func effortChoices(for selected: HermesModelID?) -> [HermesReasoningEffort] {
        guard source == .inventory, !providers.isEmpty else { return [] }
        let info: Model?
        if let selected {
            info = model(for: selected)
        } else if let defaultModel {
            info = model(for: HermesModelID(provider: defaultProvider, model: defaultModel))
        } else {
            info = nil
        }
        if info?.reasoning == false { return [] }
        return HermesReasoningEffort.levels + (info?.canDisableReasoning == false ? [] : [.off])
    }
}

/// Hermes の reasoning effort。`off` は推論を止める（`model_options.reasoning.enabled = false`）。
enum HermesReasoningEffort: String, CaseIterable, Codable, Sendable {
    case minimal, low, medium, high, xhigh, max, ultra
    case off

    /// 弱い順（Hermes の REASONING_EFFORTS と同じ）。
    static let levels = allCases.filter { $0 != .off }

    var label: String { self == .off ? "オフ" : rawValue }
}

/// 選んだモデル。provider が nil なら model だけを送る（model_routes の別名）。
struct HermesModelID: Codable, Hashable, Sendable {
    let provider: String?
    let model: String
}

/// その run に付けるモデルと effort。両方 nil なら Hermes の既定（body に何も足さない）。
/// Hermes 側で会話ごとにモデルを固定している場合（/model）は、そちらが優先される。
struct HermesRunOptions: Codable, Equatable, Sendable {
    var model: HermesModelID?
    var effort: HermesReasoningEffort?

    init(model: HermesModelID? = nil, effort: HermesReasoningEffort? = nil) {
        self.model = model
        self.effort = effort
    }

    var isServerDefault: Bool { model == nil && effort == nil }
}

extension HermesModelCatalog {
    /// `GET /api/model/options` の本文。使えない行（未認証・モデルなし）と、使えないモデル（unavailable_models）は除く。
    /// 1 行が読めなくても、ほかの行は残す。
    static func inventory(from body: Data) throws -> HermesModelCatalog {
        guard let payload = try? JSONDecoder().decode(InventoryPayload.self, from: body) else {
            throw HermesClientError.malformedResponse
        }
        let rows = payload.providers.compactMap(\.value)
        // model.provider は custom provider で `custom:<key>` になり、行の slug（bare key）と一致しない。
        // is_current か aliases で今の行を探し、その slug にそろえる（推論の対応を正しい行から読むため）。
        let current = rows.first { $0.isCurrent } ?? payload.provider.flatMap { provider in
            rows.first { $0.slug == provider || $0.aliases.contains(provider) }
        }
        return HermesModelCatalog(source: .inventory, providers: rows.compactMap(\.provider),
                                  defaultModel: payload.model, defaultProvider: current?.slug ?? payload.provider)
    }

    /// `GET /v1/models` の本文。parent の無い先頭が Hermes の仮想 model（既定）、残りが model_routes の別名。
    static func routes(from body: Data) throws -> HermesModelCatalog {
        guard let payload = try? JSONDecoder().decode(RoutesPayload.self, from: body) else {
            throw HermesClientError.malformedResponse
        }
        let entries = payload.data.compactMap(\.value)
        let base = entries.first { $0.parent == nil }?.id
        var seen = Set<String>()
        let aliases = entries
            .filter { $0.parent != nil && !$0.id.isEmpty && $0.id != base && seen.insert($0.id).inserted }
            .map { Model(id: $0.id, reasoning: nil, canDisableReasoning: nil) }
        let providers = aliases.isEmpty ? [] : [Provider(slug: nil, name: "Hermes の別名（model_routes）", models: aliases)]
        return HermesModelCatalog(source: .routes, providers: providers, defaultModel: base, defaultProvider: nil)
    }
}

/// 読めない要素を nil にして、配列のほかの要素を残す。
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

private struct InventoryPayload: Decodable {
    let providers: [Lenient<InventoryRow>]
    let model: String?
    let provider: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        providers = try container.decode([Lenient<InventoryRow>].self, forKey: .providers)
        model = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .model))
        provider = Self.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .provider))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Key: String, CodingKey { case providers, model, provider }
}

private struct InventoryRow: Decodable {
    struct Capability: Decodable {
        let reasoning: Bool?
        let canDisableReasoning: Bool?
        private enum CodingKeys: String, CodingKey {
            case reasoning
            case canDisableReasoning = "can_disable_reasoning"
        }
    }

    let slug: String
    let name: String?
    let isCurrent: Bool
    let aliases: [String]
    let models: [String]
    let authenticated: Bool?
    let unavailable: [String]
    let capabilities: [String: Capability]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        slug = try container.decode(String.self, forKey: .slug).trimmingCharacters(in: .whitespacesAndNewlines)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        isCurrent = (try? container.decodeIfPresent(Bool.self, forKey: .isCurrent)) == true
        aliases = (try? container.decodeIfPresent([Lenient<String>].self, forKey: .aliases))?.compactMap(\.value) ?? []
        // try? は Optional を 1 段にまとめる（型が違う・無い field はどちらも nil）。
        models = (try? container.decodeIfPresent([Lenient<String>].self, forKey: .models))?.compactMap(\.value) ?? []
        authenticated = try? container.decodeIfPresent(Bool.self, forKey: .authenticated)
        unavailable = (try? container.decodeIfPresent([Lenient<String>].self, forKey: .unavailable))?.compactMap(\.value) ?? []
        capabilities = (try? container.decodeIfPresent([String: Lenient<Capability>].self, forKey: .capabilities))?
            .compactMapValues(\.value) ?? [:]
    }

    var provider: HermesModelCatalog.Provider? {
        guard !slug.isEmpty, authenticated != false else { return nil }
        let blocked = Set(unavailable)
        var seen = Set<String>()
        let offered = models
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !blocked.contains($0) && seen.insert($0).inserted }
            .map { HermesModelCatalog.Model(id: $0, reasoning: capabilities[$0]?.reasoning,
                                            canDisableReasoning: capabilities[$0]?.canDisableReasoning) }
        guard !offered.isEmpty else { return nil }
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HermesModelCatalog.Provider(slug: slug, name: title.isEmpty ? slug : title, models: offered)
    }

    private enum Key: String, CodingKey {
        case slug, name, models, authenticated, capabilities, aliases
        case isCurrent = "is_current"
        case unavailable = "unavailable_models"
    }
}

private struct RoutesPayload: Decodable {
    struct Entry: Decodable {
        let id: String
        let parent: String?
    }
    let data: [Lenient<Entry>]
}
