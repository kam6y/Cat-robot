#if DEBUG
import Foundation

enum HermesBootstrapResult: Equatable, Sendable {
    enum Reason: String, Sendable {
        case fileMissing, unreadableFile, invalidFormat, credentialWriteFailed
    }
    case imported
    case importFailedBootstrapRemains(credentialRollbackSucceeded: Bool)
    case notImported(Reason)

    var permitsStoredCredentials: Bool {
        self == .imported || self == .notImported(.fileMissing)
    }
}

/// API key は保存しない。bootstrap 削除後の再実行に必要な接続情報だけを保持する。
@MainActor
final class HermesProbeConfigurationStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() -> HermesProbeConfiguration? {
        guard let object = defaults.dictionary(forKey: "configuration"),
              let endpoint = object["endpoint"] as? String, let url = URL(string: endpoint),
              let pins = object["pins"] as? [String], let deviceID = object["deviceID"] as? String else { return nil }
        return try? HermesProbeConfiguration(endpoint: url, pins: pins, deviceID: deviceID)
    }
    func save(_ configuration: HermesProbeConfiguration) {
        defaults.set(["endpoint": configuration.endpoint.absoluteString,
                      "pins": configuration.pins, "deviceID": configuration.deviceID], forKey: "configuration")
    }
}

@MainActor
final class HermesBootstrapImporter {
    private let file: URL
    private let credentials: any HermesCredentialStore
    private let configurations: HermesProbeConfigurationStore
    private let removeFile: (URL) throws -> Void

    init(file: URL, credentials: any HermesCredentialStore, configurations: HermesProbeConfigurationStore,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.file = file
        self.credentials = credentials
        self.configurations = configurations
        self.removeFile = removeFile
    }

    func `import`() async -> HermesBootstrapResult {
        guard FileManager.default.fileExists(atPath: file.path) else { return .notImported(.fileMissing) }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { return .notImported(.unreadableFile) }

        let payload: Payload
        let configuration: HermesProbeConfiguration
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
            guard !payload.apiKey.isEmpty, !payload.deviceID.isEmpty else { return .notImported(.invalidFormat) }
            configuration = try HermesProbeConfiguration(endpoint: payload.endpoint, pins: payload.pins,
                                                         deviceID: payload.deviceID)
        } catch { return .notImported(.invalidFormat) }

        do { try await credentials.save(HermesCredential(apiKey: payload.apiKey)) }
        catch { return .notImported(.credentialWriteFailed) }

        // 削除が成功するまで非秘密設定も更新しない。失敗なら保存したキーを取り消し、呼出元は停止する。
        for _ in 0..<2 {
            do {
                try removeFile(file)
                configurations.save(configuration)
                return .imported
            } catch { continue }
        }
        do {
            try await credentials.delete()
            return .importFailedBootstrapRemains(credentialRollbackSucceeded: true)
        } catch {
            return .importFailedBootstrapRemains(credentialRollbackSucceeded: false)
        }
    }

    private struct Payload: Decodable {
        let endpoint: URL
        let pins: [String]
        let deviceID: String
        let apiKey: String
    }
}
#endif
