import ClaudeForFoundationModels
import Foundation

enum ClaudeAuthConfiguration: Equatable, Sendable {
    case apiKey(String)
    case appAttest(clientID: String)
    case missing

    static let clientIDInfoKey = "CatRobotClaudeClientID"
    static let apiKeyEnvironmentKey = "ANTHROPIC_API_KEY"
    static let apiKeyBundleFile = "claude-api-key.txt"

    static func resolve(environment: [String: String], infoDictionary: [String: Any],
                        bundledKey: String?, isDebugBuild: Bool) -> Self {
        if isDebugBuild {
            if let key = environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return .apiKey(key)
            }
            if let key = bundledKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return .apiKey(key)
            }
        }
        if let clientID = infoDictionary[clientIDInfoKey] as? String, clientID.hasPrefix("clid_") {
            return .appAttest(clientID: clientID)
        }
        return .missing
    }

    static func live() -> Self {
        var bundledKey: String?
#if DEBUG
        if let url = Bundle.main.url(forResource: "claude-api-key", withExtension: "txt") {
            bundledKey = try? String(contentsOf: url, encoding: .utf8)
        }
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        return resolve(environment: ProcessInfo.processInfo.environment,
                       infoDictionary: Bundle.main.infoDictionary ?? [:],
                       bundledKey: bundledKey, isDebugBuild: isDebugBuild)
    }

    var authMode: AuthMode? {
        switch self {
        case .apiKey(let key): .apiKey(key)
        case .appAttest(let clientID): .appAttest(clientID: clientID)
        case .missing: nil
        }
    }
}
