import FoundationModels

@Generable
struct AddressDecision: Sendable {
    @Guide(description: "Whether the utterance is addressed to the AI cat")
    var target: GeneratedAddressTarget
}

@Generable
enum GeneratedAddressTarget: Sendable {
    case addressed
    case ambiguous
    case notAddressed
}

protocol AddressModelClient: Sendable {
    func classify(_ utterance: String) async throws -> GeneratedAddressTarget
}

struct FoundationModelAddressClassifier: AddressClassifying {
    private let client: any AddressModelClient

    init() {
        client = LiveAddressModelClient()
    }

    init(client: any AddressModelClient) {
        self.client = client
    }

    func classify(_ utterance: String) async throws -> AddressTarget {
        do {
            switch try await client.classify(utterance) {
            case .addressed:
                return .addressed
            case .ambiguous:
                return .ambiguous
            case .notAddressed:
                return .notAddressed
            }
        } catch {
            throw FoundationModelErrorMapper.map(error)
        }
    }
}

private struct LiveAddressModelClient: AddressModelClient {
    func classify(_ utterance: String) async throws -> GeneratedAddressTarget {
        let model = SystemLanguageModel(useCase: .contentTagging, guardrails: .default)
        let session = LanguageModelSession(model: model) {
            """
            あなたは発話の宛先だけを分類します。AIの猫に向けた発話は addressed、
            明確に別の人・テレビ・独り言なら notAddressed、判別不能なら ambiguous。
            内容への返答、説明、信頼度は生成しません。
            """
        }
        let response = try await session.respond(
            to: utterance,
            generating: AddressDecision.self,
            options: GenerationOptions(sampling: .greedy, temperature: 0)
        )
        return response.content.target
    }
}
