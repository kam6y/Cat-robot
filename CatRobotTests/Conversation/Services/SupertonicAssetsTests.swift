import CryptoKit
import XCTest
@testable import CatRobot

final class SupertonicAssetsTests: XCTestCase {
    func testMissingManifestFails() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SupertonicAssets.validate(root: root, manifest: root.appendingPathComponent("manifest.json")))
    }
    func testCorruptFileAndPathEscapeAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a")
        try Data("abc".utf8).write(to: file)
        let hash = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = root.appendingPathComponent("manifest.json")
        func write(_ path: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["revision": "test", "files": [["path": path, "size": 3, "sha256": hash]]])
            try data.write(to: manifest)
        }
        try write("a")
        try SupertonicAssets.validate(root: root, manifest: manifest)
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try SupertonicAssets.validate(root: root, manifest: manifest))
        for path in ["../a", "/tmp/a", "nested/../a"] {
            try write(path)
            XCTAssertThrowsError(try SupertonicAssets.validate(root: root, manifest: manifest))
        }
        try write("link")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try SupertonicAssets.validate(root: root, manifest: manifest))
    }
}
