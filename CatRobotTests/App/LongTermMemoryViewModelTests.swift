import XCTest
@testable import CatRobot

@MainActor
final class LongTermMemoryViewModelTests: XCTestCase {
    func testLoadsSortedFactsAndForgetRemovesOne() async throws {
        let store = InMemoryLongTermMemoryStore()
        let manager = LongTermMemoryManager(store: store)
        _ = try await manager.remember("B", category: .other); _ = try await manager.remember("A", category: .person)
        let model = LongTermMemoryViewModel(memory: manager)
        await model.load()
        XCTAssertEqual(model.facts.map(\.text), ["B", "A"], "古い順")
        await model.forget(model.facts[0])
        XCTAssertEqual(model.facts.map(\.text), ["A"])
        let remaining = try await manager.facts().map(\.text)
        XCTAssertEqual(remaining, ["A"])
    }
    func testLoadFailureIsReportedNotHidden() async {
        let store = SpyLongTermMemoryStore()
        await store.setFailsLoad(true)
        let model = LongTermMemoryViewModel(memory: LongTermMemoryManager(store: store))
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.facts.isEmpty)
    }

    func testForgetFailureKeepsTheRowAndReportsIt() async throws {
        let store = SpyLongTermMemoryStore()
        let manager = LongTermMemoryManager(store: store)
        _ = try await manager.remember("A", category: .person)
        let model = LongTermMemoryViewModel(memory: manager)
        await model.load()
        XCTAssertEqual(model.facts.map(\.text), ["A"])
        await store.setFailsSave(true)
        await model.forget(model.facts[0])
        XCTAssertEqual(model.facts.map(\.text), ["A"], "削除に失敗した行は成功扱いで消さない")
        XCTAssertTrue(model.loadFailed)
    }
}
