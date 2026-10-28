import Foundation
import Observation

/// 設定画面の「覚えていること」一覧。読み込み失敗は隠さず表示に出す。
@MainActor @Observable
final class LongTermMemoryViewModel {
    private(set) var facts: [LongTermFact] = []
    private(set) var loadFailed = false
    @ObservationIgnored private let memory: LongTermMemoryManager

    init(memory: LongTermMemoryManager) { self.memory = memory }

    func load() async {
        do {
            facts = LongTermMemoryPolicy.ordered(try await memory.facts())
            loadFailed = false
        } catch {
            facts = []
            loadFailed = true
        }
    }

    func forget(_ fact: LongTermFact) async {
        do {
            try await memory.forget(id: fact.id)
            facts.removeAll { $0.id == fact.id }
        } catch {
            loadFailed = true
        }
    }
}
