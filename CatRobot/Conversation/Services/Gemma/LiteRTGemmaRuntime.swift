import Foundation
import CLiteRTLM

/// The pinned native API exposes the tokenizer and explicit conversation release,
/// which the Swift wrapper does not. Keep that detail behind the same app boundary.
actor LiteRTGemmaRuntime: GemmaRuntime {
    private var engine: GemmaNativeEngine?

    func prepare() async throws { _ = try loadedEngine() }

    func countTokens(_ text: String) async throws -> Int {
        try loadedEngine().tokens(text)
    }

    func makeSession(_ configuration: GemmaSessionConfiguration) async throws -> any GemmaSession {
        try LiteRTGemmaSession(engine: loadedEngine(), configuration: configuration)
    }

    private func loadedEngine() throws -> GemmaNativeEngine {
#if targetEnvironment(simulator)
        throw GemmaRuntimeFailure.unavailable
#else
        if let engine { return engine }
        let model = try GemmaModelFile.installed()
        // Release validation's temporary file buffers before allocating the GPU model.
        try autoreleasepool { try model.validate() }
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let cache = caches.appendingPathComponent("Gemma4E2B-0.17.1-\(GemmaContext.capacity)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let result = try GemmaNativeEngine(model: model.url.path, cache: cache.path)
        engine = result
        return result
#endif
    }
}

private enum GemmaNativeError: Error {
    case initialization, configuration, closed, tokenization, invalidResponse, streamStart(Int32), inference(String)
}

private final class GemmaNativeEngine: @unchecked Sendable {
    let handle: OpaquePointer

    init(model: String, cache: String) throws {
        guard let settings = litert_lm_engine_settings_create(model, "gpu", nil, nil) else {
            throw GemmaRuntimeFailure.unavailable
        }
        defer { litert_lm_engine_settings_delete(settings) }
        litert_lm_engine_settings_set_max_num_tokens(settings, Int32(GemmaContext.capacity))
        litert_lm_engine_settings_set_cache_dir(settings, cache)
        guard let handle = litert_lm_engine_create(settings) else { throw GemmaRuntimeFailure.unavailable }
        self.handle = handle
    }

    deinit { litert_lm_engine_delete(handle) }

    func tokens(_ text: String) throws -> Int {
        guard let result = litert_lm_engine_tokenize(handle, text) else { throw GemmaNativeError.tokenization }
        defer { litert_lm_tokenize_result_delete(result) }
        return Int(litert_lm_tokenize_result_get_num_tokens(result))
    }
}

private final class LiteRTGemmaSession: GemmaSession, @unchecked Sendable {
    private let engine: GemmaNativeEngine
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(engine: GemmaNativeEngine, configuration: GemmaSessionConfiguration) throws {
        self.engine = engine
        guard let config = litert_lm_conversation_config_create() else { throw GemmaNativeError.configuration }
        defer { litert_lm_conversation_config_delete(config) }
        guard let session = litert_lm_session_config_create() else { throw GemmaNativeError.configuration }
        defer { litert_lm_session_config_delete(session) }
        guard let sampler = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP) else { throw GemmaNativeError.configuration }
        defer { litert_lm_sampler_params_delete(sampler) }
        guard let thinking = litert_lm_thinking_config_create() else { throw GemmaNativeError.configuration }
        defer { litert_lm_thinking_config_delete(thinking) }
        litert_lm_sampler_params_set_top_k(sampler, 1)
        litert_lm_sampler_params_set_top_p(sampler, 1)
        litert_lm_sampler_params_set_temperature(sampler, 0)
        litert_lm_session_config_set_sampler_params(session, sampler)
        litert_lm_conversation_config_set_session_config(config, session)
        litert_lm_thinking_config_set_enable_thinking(thinking, false)
        litert_lm_conversation_config_set_thinking_config(config, thinking)
        litert_lm_conversation_config_set_system_message(config, try gemmaJSON([["type": "text", "text": configuration.instruction]]))
        if !configuration.history.isEmpty {
            let messages = configuration.history.flatMap {
                [gemmaMessage($0.prompt), gemmaMessage($0.response, role: "model")]
            }
            litert_lm_conversation_config_set_messages(config, try gemmaJSON(messages))
        }
        guard let handle = litert_lm_conversation_create(engine.handle, config) else { throw GemmaNativeError.initialization }
        self.handle = handle
    }

    deinit { close() }

    func close() {
        lock.withLock {
            if let handle {
                // Native deletion waits for the final callback to return.
                litert_lm_conversation_delete(handle)
                self.handle = nil
            }
        }
    }

    func tokenCount() throws -> Int {
        try lock.withLock {
            guard let handle else { throw GemmaNativeError.closed }
            return Int(litert_lm_conversation_get_token_count(handle))
        }
    }

    func inputTokenCount(_ prompt: String) throws -> Int {
        try lock.withLock {
            guard let handle,
                  let rendered = litert_lm_conversation_render_message_to_string(handle, try gemmaJSON(gemmaMessage(prompt))) else {
                throw GemmaNativeError.closed
            }
            return try engine.tokens(String(cString: rendered))
        }
    }

    func cancel() {
        lock.withLock {
            if let handle { litert_lm_conversation_cancel_process(handle) }
        }
    }

    func stream(_ prompt: String, outputLimit: Int) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        do {
            try lock.withLock {
                guard let handle, let options = litert_lm_conversation_optional_args_create() else {
                    throw GemmaNativeError.closed
                }
                defer { litert_lm_conversation_optional_args_delete(options) }
                litert_lm_conversation_optional_args_set_max_output_tokens(options, Int32(outputLimit))
                let message = try gemmaJSON(gemmaMessage(prompt))
                let context = Unmanaged.passRetained(GemmaStreamContext(continuation: continuation))
                let status = litert_lm_conversation_send_message_stream(
                    handle, message, nil, options, gemmaStreamCallback, context.toOpaque()
                )
                if status != 0 {
                    context.release()
                    throw GemmaNativeError.streamStart(status)
                }
            }
        } catch { continuation.finish(throwing: error) }
        return stream
    }
}

private func gemmaMessage(_ text: String, role: String = "user") -> [String: Any] {
    ["role": role, "content": [["type": "text", "text": text]]]
}

private func gemmaJSON(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

/// Accessed serially by native stream callbacks. The service retains the session
/// and consumes this stream through its terminal callback even after cancellation.
private final class GemmaStreamContext {
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    var decodingError: Error?
    init(continuation: AsyncThrowingStream<String, Error>.Continuation) { self.continuation = continuation }
}

private func gemmaStreamCallback(_ data: UnsafeMutableRawPointer?, _ chunk: OpaquePointer?) {
    guard let data else { return }
    let retained = Unmanaged<GemmaStreamContext>.fromOpaque(data)
    let context = retained.takeUnretainedValue()
    if let error = litert_lm_stream_chunk_get_error(chunk) {
        context.continuation.finish(throwing: GemmaNativeError.inference(String(cString: error)))
        retained.release()
        return
    }
    if let text = litert_lm_stream_chunk_get_text(chunk), context.decodingError == nil {
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any] else {
                throw GemmaNativeError.invalidResponse
            }
            let delta = (object["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            if !delta.isEmpty { context.continuation.yield(delta) }
        } catch {
            // Do not finish or release early: more native callbacks may follow.
            context.decodingError = error
        }
    }
    if litert_lm_stream_chunk_is_final(chunk) {
        context.continuation.finish(throwing: context.decodingError)
        retained.release()
    }
}
