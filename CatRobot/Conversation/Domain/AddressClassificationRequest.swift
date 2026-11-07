struct ClarificationContext: Equatable, Sendable {
    static let question = "今の、ぼくに言った？"
    let originalUtterance: String
}

struct AddressClassificationRequest: Equatable, Sendable {
    let utterance: String
    let clarification: ClarificationContext?

    init(utterance: String, clarification: ClarificationContext? = nil) {
        self.utterance = utterance
        self.clarification = clarification
    }
}
