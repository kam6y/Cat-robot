import CryptoKit
import Foundation

enum SupertonicError: Error, Equatable { case missingAssets, invalidAssets, unsupportedVoice, invalidPCM, inferenceFailed }

struct SupertonicManifest: Codable, Sendable {
    struct File: Codable, Sendable { let path: String; let size: Int64; let sha256: String }
    let revision: String
    let files: [File]
}

enum SupertonicAssets {
    static func loadManifest(_ url: URL) throws -> SupertonicManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SupertonicError.missingAssets }
        do { return try JSONDecoder().decode(SupertonicManifest.self, from: Data(contentsOf: url)) }
        catch { throw SupertonicError.invalidAssets }
    }
    @discardableResult
    static func validate(root: URL, manifest: URL) throws -> SupertonicManifest {
        let value = try loadManifest(manifest)
        guard !value.files.isEmpty, Set(value.files.map(\.path)).count == value.files.count else { throw SupertonicError.invalidAssets }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for entry in value.files {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !entry.path.split(separator: "/").contains(".."), entry.size > 0 else { throw SupertonicError.invalidAssets }
            let file = root.appendingPathComponent(entry.path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(canonical) else { throw SupertonicError.invalidAssets }
            guard FileManager.default.fileExists(atPath: file.path) else { throw SupertonicError.missingAssets }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == entry.size else { throw SupertonicError.invalidAssets }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw SupertonicError.invalidAssets }
        }
        return value
    }
}
