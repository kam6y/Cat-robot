import Foundation

/// 通常会話の接続先と鍵。どちらかが無ければ未設定（nil）として扱う。
struct HermesConnection: Equatable, Sendable {
    let endpoint: URL
    let credential: HermesCredential

    /// 鍵と session を結びつける単位（scheme・host・port）。path の違いは同じ origin とみなさない設定側で弾く。
    var origin: String { Self.origin(of: endpoint) }

    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

/// 端末に残す非秘密の識別子だけ。会話の本文は Hermes が正本なので保存しない。
/// 送信の前後で書き換え、アプリがどこで落ちても次の起動で状態を区別できるようにする。
struct HermesSessionRecord: Codable, Equatable, Sendable {
    /// この session を作った接続先。違う接続先へ session id も run id も送らない。
    var origin: String
    var sessionID: String
    /// Hermes がこの session の run を受け付けたことがある（Hermes 側に session と行がある）。
    /// これが立った session を Hermes が知らなければ、失われた session として扱う。
    var hasTurns: Bool = false
    /// 受付が分からない送信がある（POST の途中で落ちた、または通信が切れたまま諦めた）。run id は分からない。
    /// Hermes 側に行がある可能性があるので履歴は読むが、session が無くても失われたとはみなさない。
    var hasUncertainSubmission: Bool = false
    /// 受け付けられたが終端を確かめていない run。次のターンの前に stop して確かめ、確かめられるまで残す。
    var unsettledRunIDs: [String] = []
}

protocol HermesSessionRecordStore: Sendable {
    func load() async -> HermesSessionRecord?
    func save(_ record: HermesSessionRecord?) async
}

/// UserDefaults に JSON で 1 件だけ持つ。
final class UserDefaultsHermesSessionRecordStore: HermesSessionRecordStore, @unchecked Sendable {
    static let key = "hermesConversationSession"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() async -> HermesSessionRecord? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HermesSessionRecord.self, from: $0) }
    }

    func save(_ record: HermesSessionRecord?) async {
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
