import Foundation
import OnnxRuntimeBindings

/// Records the pinned upstream preprocessing; it does not alter model input.
struct SpeechTextAudit: Codable, Sendable {
    let original: String
    let processedChunks: [String]
    let removedOrReplaced: String
    init(input: String) {
        original = input
        processedChunks = chunkText(input, maxLen: 120).map { preprocessText($0, lang: "ja") }
        let normalized = Array(input.decomposedStringWithCompatibilityMapping.unicodeScalars)
        let processed = processedChunks.map { String($0.dropFirst(4).dropLast(5)) }.joined(separator: " ")
        let changes = Array(processed.unicodeScalars).difference(from: normalized)
        let removed = changes.compactMap { change -> (Int, Unicode.Scalar)? in
            if case let .remove(offset, element, _) = change { return (offset, element) }
            return nil
        }.sorted { $0.0 < $1.0 }
        removedOrReplaced = removed.map { String($0.1) }.joined()
    }
}

struct SpeechPCM: Sendable {
    let samples: [Float]
    let sampleRate: Double
    func validate() throws {
        guard (8_000...96_000).contains(sampleRate), !samples.isEmpty,
              samples.count <= Int(sampleRate * 60), samples.allSatisfy(\.isFinite) else {
            throw SupertonicError.invalidPCM
        }
    }
}

actor SupertonicEngine {
    private let root: URL
    private let manifest: URL
    private var env: ORTEnv?
    private var tts: TextToSpeech?
    private var voices: Set<String> = []
    init(root: URL, manifest: URL) { self.root = root; self.manifest = manifest }
    func prepare() throws {
        if tts != nil { return }
        let files = try SupertonicAssets.validate(root: root, manifest: manifest)
        guard files.revision == "aafc6e32416a594460b32413efc49d7fe4ce6d46" else { throw SupertonicError.invalidAssets }
        voices = Set(files.files.filter { $0.path.hasPrefix("voice_styles/") && $0.path.hasSuffix(".json") }
            .map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent })
        let environment = try ORTEnv(loggingLevel: .warning)
        let model = try loadTextToSpeech(root.appendingPathComponent("onnx").path, false, environment)
        guard (8_000...96_000).contains(model.sampleRate) else { throw SupertonicError.invalidAssets }
        env = environment; tts = model
    }
    func synthesize(text: String, voiceID: String, steps: Int) throws -> SpeechPCM {
        try Task.checkCancellation()
        try prepare()
        guard voices.contains(voiceID) else { throw SupertonicError.unsupportedVoice }
        guard let tts, (1...32).contains(steps), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 2000 else { throw SupertonicError.inferenceFailed }
        // Reject unmapped codepoints before they reach ONNX embedding lookup.
        let (ids, _) = tts.textProcessor.call([text], ["ja"])
        guard ids.allSatisfy({ $0.allSatisfy { $0 >= 0 } }) else { throw SupertonicError.inferenceFailed }
        let style = try loadVoiceStyle([root.appendingPathComponent("voice_styles/\(voiceID).json").path], verbose: false)
        let (samples, duration) = try tts.call(text, "ja", style, steps)
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0, duration <= 60 else { throw SupertonicError.invalidPCM }
        let pcm = SpeechPCM(samples: Array(samples.prefix(Int(Double(tts.sampleRate) * Double(duration)))), sampleRate: Double(tts.sampleRate))
        try pcm.validate()
        return pcm
    }
}
