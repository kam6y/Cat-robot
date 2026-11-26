import Foundation
import Observation

/// 設定「返答モデル」のモデルと effort。候補は保存済みの接続先の Hermes から読み、選択は接続先の origin ごとに
/// UserDefaults に置く（別の接続先のモデルを送らない）。会話はターンの初めに `options(for:)` を 1 回だけ読む
/// （保存した次のターンから効き、同じターンの再送では変えない）。モデルを変えても新しい会話には切り替えない。
@MainActor @Observable
final class HermesModelSettings {
    enum Phase: Equatable {
        case idle, loaded
        case loading(manual: Bool)
        case failed(String)
    }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private static let optionsKeyPrefix = "hermesRunOptions."

    /// 保存済みの接続先の origin。nil は接続先が未設定。
    private(set) var origin: String?
    /// 最後に読めた候補（今の origin のもの）。読めていなければ nil。
    private(set) var catalog: HermesModelCatalog?
    private(set) var phase: Phase = .idle
    /// 候補に無くなった選択を既定に戻したときの知らせ。
    private(set) var notice: String?
    /// 今の origin の選択（UI 用）。
    private(set) var current = HermesRunOptions()
    /// 接続先かキーを保存・削除するたびに変わる（設定画面が候補を読み直す合図）。
    private(set) var connectionRevision = UUID()
    @ObservationIgnored private var loadRevision = UUID()
    /// 候補の要求に 401 を返した接続。同じ接続では自動で読み直さない（明示の再取得か、キーの変更で外す）。
    @ObservationIgnored private var refused: HermesConnection?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: any HermesTransport

    init(defaults: UserDefaults, transport: any HermesTransport, origin: String?) {
        self.defaults = defaults
        self.transport = transport
        self.origin = origin
        current = origin.map { Self.load(defaults, origin: $0) } ?? HermesRunOptions()
    }

    /// その origin で run に付ける選択。既定なら nil。
    func options(for origin: String) -> HermesRunOptions? {
        let stored = Self.load(defaults, origin: origin)
        return stored.isServerDefault ? nil : stored
    }

    /// 接続先かキーを保存・削除した。前のキーで読んだ候補と読み込み中の結果は捨てる（前の接続・前のキーの答えを今の設定に当てない）。
    /// origin が変わったら、その origin の選択に切り替える。設定画面は `connectionRevision` の変化で読み直す。
    func connectionChanged(origin: String?) {
        loadRevision = UUID()
        connectionRevision = UUID()
        catalog = nil
        phase = .idle
        notice = nil
        guard origin != self.origin else { return }
        self.origin = origin
        current = origin.map { Self.load(defaults, origin: $0) } ?? HermesRunOptions()
    }

    /// モデルを選ぶ（nil は Hermes の既定）。新しいモデルで使えない effort は既定に戻す。
    func select(model: HermesModelID?) {
        guard let origin else { return }
        var next = current
        next.model = model
        if let effort = next.effort, let catalog, !catalog.effortChoices(for: model).contains(effort) { next.effort = nil }
        notice = nil
        store(next, origin: origin)
    }

    /// effort を選ぶ（nil は Hermes の既定）。
    func select(effort: HermesReasoningEffort?) {
        guard let origin else { return }
        var next = current
        next.effort = effort
        notice = nil
        store(next, origin: origin)
    }

    /// 今のモデルで選べる effort。候補を読めていなければ、保存済みの値だけ（既定へ戻せるように）。
    var effortChoices: [HermesReasoningEffort] {
        guard let catalog else { return current.effort.map { [$0] } ?? [] }
        if let saved = current.model, catalog.model(for: saved) == nil { return current.effort.map { [$0] } ?? [] }
        return catalog.effortChoices(for: current.model)
    }

    /// 候補を読む。force は利用者の明示の再取得（Hermes に provider を probe し直させる）。
    /// 読めたら、候補に無い選択を既定に戻す。読めなければ（通信・401）、選択はそのまま残す。
    func refresh(connection: HermesConnection?, force: Bool) async {
        guard let connection, connection.origin == origin else { return }
        if !force, phase == .loading(manual: true) { return }
        if !force, refused == connection {
            phase = .failed(Self.message(for: HermesClientError.unauthorized))
            return
        }
        let revision = UUID()
        loadRevision = revision
        phase = .loading(manual: force)
        // refresh=true は Hermes が custom provider ごとに最大 5 秒 probe するので、普段の要求より長く待つ。
        let client = HermesRunClient(endpoint: connection.endpoint, credential: connection.credential,
                                     transport: transport, requestTimeout: force ? 60 : 15)
        do {
            let loaded = try await client.modelCatalog(refresh: force)
            guard loadRevision == revision, origin == connection.origin else { return }
            refused = nil
            catalog = loaded
            phase = .loaded
            reconcile(with: loaded, origin: connection.origin, force: force)
        } catch {
            guard loadRevision == revision, origin == connection.origin else { return }
            if error as? HermesClientError == .unauthorized { refused = connection }
            if Task.isCancelled {
                phase = catalog == nil ? .idle : .loaded
            } else {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    private func reconcile(with catalog: HermesModelCatalog, origin: String, force: Bool) {
        notice = nil
        // キャッシュでの一覧取得時は、利用資格やプロバイダーの確認中で候補が一時的に欠けることがある。
        if !force && catalog.source == .inventory {
            if let saved = current.model, catalog.model(for: saved) == nil {
                notice = "保存済みのモデルは現在の候補にありません。「モデルの候補を再取得」で確認できます。"
                return
            }
            if catalog.providers.isEmpty { return }
        }
        var next = current
        var dropped: [String] = []
        if let model = next.model, catalog.model(for: model) == nil {
            next.model = nil
            dropped.append("モデル（\(model.model)）")
        }
        if let effort = next.effort, !catalog.effortChoices(for: next.model).contains(effort) {
            next.effort = nil
            dropped.append("effort（\(effort.label)）")
        }
        guard !dropped.isEmpty else { return }
        notice = "前に選んだ\(dropped.joined(separator: "と"))はこの Hermes の候補に無いため、Hermes の既定に戻しました。"
        store(next, origin: origin)
    }

    private func store(_ options: HermesRunOptions, origin: String) {
        let key = Self.optionsKeyPrefix + origin
        if options.isServerDefault {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: key)
        }
        if origin == self.origin { current = options }
    }

    private static func load(_ defaults: UserDefaults, origin: String) -> HermesRunOptions {
        guard let data = defaults.data(forKey: optionsKeyPrefix + origin),
              let options = try? JSONDecoder().decode(HermesRunOptions.self, from: data) else { return HermesRunOptions() }
        return options
    }

    private static func message(for error: any Error) -> String {
        switch error as? HermesClientError {
        case .unauthorized?:
            "この接続先が API キーを拒否しました（401）。別のキーを保存するか、「モデルの候補を再取得」で確かめ直してください。"
        case .httpStatus(let status)?:
            "モデルの候補を読めませんでした（HTTP \(status)）。"
        case .malformedResponse?:
            "モデルの候補の形を読めませんでした。"
        default:
            "Hermes に接続できず、モデルの候補を読めませんでした。接続先とネットワークを確かめてください。"
        }
    }
}
