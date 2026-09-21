import CryptoKit
import Foundation

struct GemmaModelFile: Sendable {
    static let sha256 = "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    static let byteCount: Int64 = 2_588_147_712
    let url: URL

    static func installed() throws -> Self {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(url: support.appendingPathComponent("CatRobot/LanguageModels/Gemma4E2B/gemma-4-E2B-it.litertlm"))
    }

    // Called once per runtime load, off the main actor; never loads 2.6GB into RAM.
    func validate() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw GemmaRuntimeFailure.missingModel }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == Self.byteCount else {
            throw GemmaRuntimeFailure.invalidModel
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == Self.sha256 else { throw GemmaRuntimeFailure.invalidModel }
    }
}
