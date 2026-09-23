import Foundation
import XCTest
@testable import CatRobot

final class ConversationMemorySnapshotTests: XCTestCase {
    func testRejectsIncompatibleOrMalformedMemory() throws {
        for (schema, id, revision, prompt, expected) in [
            (2, "test", UInt64(1), "A", ConversationMemoryError.unsupportedSchema),
            (1, "other", 1, "A", .incompatibleModel),
            (1, "test", 0, "A", .invalidData),
            (1, "test", 1, " \n", .invalidData)
        ] {
            let snapshot = ConversationMemorySnapshot(schemaVersion: schema, memoryCompatibilityID: id,
                revision: revision, savedAt: Date(), summary: "", turns: [.init(prompt: prompt, response: "B")])
            XCTAssertThrowsError(try snapshot.validate(expectedCompatibilityID: "test")) {
                XCTAssertEqual($0 as? ConversationMemoryError, expected)
            }
        }
    }

    func testValidSnapshotRoundTripsWithoutChangingJapaneseOrOrder() throws {
        let snapshot = ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: "test",
            revision: 3, savedAt: Date(timeIntervalSince1970: 42), summary: "好きな飲み物はほうじ茶",
            turns: [.init(prompt: "昨日は？", response: "金沢に行ったね"), .init(prompt: "ありがとう", response: "どういたしまして")])
        try snapshot.validate(expectedCompatibilityID: "test")
        let restored = try JSONDecoder().decode(ConversationMemorySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }

    func testEmptyMemoryIsValid() throws {
        try ConversationMemorySnapshot(schemaVersion: 1, memoryCompatibilityID: "test", revision: 0,
            savedAt: Date(), summary: "", turns: []).validate(expectedCompatibilityID: "test")
    }
}
