import Foundation
import UIKit

@MainActor
final class ConversationScreenWakeLock {
    struct Token: Hashable, Sendable {
        fileprivate let ownerID: UUID
        fileprivate let sequence: UInt64
    }

    private let ownerID = UUID()
    private let readIdleTimerDisabled: @MainActor () -> Bool
    private let writeIdleTimerDisabled: @MainActor (Bool) -> Void
    private var sequence: UInt64 = 0
    private var tokens: Set<Token> = []
    private var priorValue: Bool?

    init(
        readIdleTimerDisabled: @escaping @MainActor () -> Bool,
        writeIdleTimerDisabled: @escaping @MainActor (Bool) -> Void
    ) {
        self.readIdleTimerDisabled = readIdleTimerDisabled
        self.writeIdleTimerDisabled = writeIdleTimerDisabled
    }

    @discardableResult
    func acquire() -> Token {
        if tokens.isEmpty {
            priorValue = readIdleTimerDisabled()
            writeIdleTimerDisabled(true)
        }

        sequence &+= 1
        let token = Token(ownerID: ownerID, sequence: sequence)
        tokens.insert(token)
        return token
    }

    func release(_ token: Token) {
        guard token.ownerID == ownerID, tokens.remove(token) != nil else { return }
        guard tokens.isEmpty, let priorValue else { return }
        self.priorValue = nil
        writeIdleTimerDisabled(priorValue)
    }
}

extension ConversationScreenWakeLock {
    static func live() -> ConversationScreenWakeLock {
        ConversationScreenWakeLock(
            readIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled },
            writeIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 }
        )
    }
}
