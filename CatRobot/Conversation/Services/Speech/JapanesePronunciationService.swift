import CJPPronunciation
import Foundation

enum JapanesePronunciationError: Error, Equatable, Sendable {
    case dictionaryUnavailable
    case invalidInput
    case conversionFailed
    case outputTooLong
}

/// Owns one dictionary off MainActor. All native calls are synchronous and actor-serialized.
actor JapanesePronunciationService {
    static let shared = JapanesePronunciationService(
        root: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("dictionary"))

    private enum State {
        case unprepared
        case ready(NativePronouncer)
        case failed
    }
    private let root: URL
    private var state: State = .unprepared

    init(root: URL) { self.root = root }

    func prepare() throws {
        try Task.checkCancellation()
        switch state {
        case .ready: break
        case .failed: throw JapanesePronunciationError.dictionaryUnavailable
        case .unprepared:
            do { state = .ready(try NativePronouncer(root: root)) }
            catch { state = .failed; throw JapanesePronunciationError.dictionaryUnavailable }
        }
        try Task.checkCancellation()
    }

    func normalize(_ original: String) throws -> String {
        try Task.checkCancellation()
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              original.count <= 2_000, original.utf8.count <= 32_768,
              !original.utf8.contains(0) else { throw JapanesePronunciationError.invalidInput }
        try prepare()
        guard case let .ready(native) = state else { throw JapanesePronunciationError.dictionaryUnavailable }
        let spoken = try native.normalize(original)
        try Task.checkCancellation()
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JapanesePronunciationError.conversionFailed
        }
        guard spoken.count <= 2_000 else { throw JapanesePronunciationError.outputTooLong }
        return spoken
    }
}

/// Kept inside the actor; ARC releases the native allocation after its last use.
private final class NativePronouncer {
    private let handle: UnsafeMutableRawPointer

    init(root: URL) throws {
        var output: UnsafeMutableRawPointer?
        let status = root.path.withCString { cjp_create($0, &output) }
        guard status == 0, let output else { throw JapanesePronunciationError.dictionaryUnavailable }
        handle = output
    }

    deinit { cjp_destroy(handle) }

    func normalize(_ original: String) throws -> String {
        let input = Array(original.utf8)
        var output: UnsafeMutablePointer<CChar>?
        let status = input.withUnsafeBufferPointer { cjp_convert(handle, $0.baseAddress, $0.count, &output) }
        defer { cjp_string_free(output) }
        guard status == 0, let output, let result = String(validatingCString: output) else {
            throw JapanesePronunciationError.conversionFailed
        }
        return result
    }
}
