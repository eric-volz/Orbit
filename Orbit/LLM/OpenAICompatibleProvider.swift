import Foundation

/// Chat Completions (`POST {base}/chat/completions`) for OpenAI and compatible
/// servers such as Ollama, LM Studio or vLLM. The base URL includes the version
/// path, e.g. `http://localhost:11434/v1`.
///
/// The model's reasoning in the tool loop in progress is sent back with the
/// assistant messages, in the field the server streamed it in (gpt-oss expects
/// it there), see `OpenAIWire.reasoningToEcho(in:)`.
///
/// Resilience matches `AnthropicProvider`: transient failures before any output
/// are retried, and a 400 or 422 about `reasoning_effort` or the echoed
/// reasoning is retried once without it (remembered per host and model for the
/// app session). A rejection that names no cause while reasoning is echoed is
/// retried once without the echo, which is remembered only if that works.
struct OpenAICompatibleProvider: LLMProvider {
    /// Used when the configuration has no base URL (Ollama on this Mac).
    static let defaultBaseURL = URL(string: "http://localhost:11434/v1")!

    let kind = ProviderKind.openAICompatible
    let baseURL: URL
    private let apiKey: String
    private let transport: ProviderTransport

    /// Throws `LLMError.invalidBaseURL` for unusable base URLs.
    init(configuration: ProviderConfiguration, transport: ProviderTransport = .live) throws {
        baseURL = try ProviderEndpoint.normalizedBaseURL(
            configuration.baseURL ?? Self.defaultBaseURL,
            removingSuffixes: ["/chat/completions"]
        )
        apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    var displayName: String {
        ProviderEndpoint.displayName(for: baseURL)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        ProviderHTTP.makeStream { emitter in
            try await run(request, emitter: emitter)
        }
    }

    /// `GET {base}/models`; fails with `.modelNotFound` when the list is readable
    /// and does not contain `model`, and with `.toolsNotSupported` when Ollama
    /// says the model cannot use tools (Orbit's requests always offer them).
    /// Spends no tokens and loads no model.
    func validateConfiguration(model: String) async throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try ProviderEndpoint.url(baseURL, appendingPath: "models")
        let data: Data
        do {
            data = try await ProviderHTTP.fetch(makeRequest(url: url), session: transport.session)
        } catch {
            throw explainingMissingKey(ProviderHTTP.llmError(error, model: model))
        }
        if !model.isEmpty, let ids = ModelList.ids(in: data), !ModelList.contains(ids, model: model) {
            throw LLMError.modelNotFound(model: model)
        }
        if !model.isEmpty, await ollamaReportsNoTools(model: model) {
            throw LLMError.toolsNotSupported(model: model)
        }
    }

    /// Ollama lists a model's capabilities (`POST {root}/api/show`, beside its
    /// `/v1`, metadata only). True only for such a list without "tools"; any
    /// other answer (another server, an older Ollama, a failure) says nothing.
    private func ollamaReportsNoTools(model: String) async -> Bool {
        guard let url = Self.ollamaShowURL(for: baseURL) else { return false }
        var request = makeRequest(url: url, body: JSONValue.object(["model": .string(model)]).jsonData())
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 10
        guard let data = try? await ProviderHTTP.fetch(request, session: transport.session),
              let capabilities = (try? JSONValue.parse(data))?["capabilities"]?.arrayValue else { return false }
        return !capabilities.contains { $0.stringValue == "tools" }
    }

    /// Where Ollama answers `/api/show` for an OpenAI-compatible address ending
    /// in `/v1` ("http://localhost:11434/v1" → "http://localhost:11434/api/show"); nil for others.
    static func ollamaShowURL(for baseURL: URL) -> URL? {
        guard baseURL.lastPathComponent.lowercased() == "v1" else { return nil }
        return try? ProviderEndpoint.url(baseURL.deletingLastPathComponent(), appendingPath: "api/show")
    }

    // MARK: Private

    /// A server that rejects a request without a key wants one (local servers need none).
    private func explainingMissingKey(_ error: LLMError) -> LLMError {
        error == .invalidAPIKey && apiKey.isEmpty ? .missingAPIKey : error
    }

    private func run(_ request: LLMRequest, emitter: StreamEmitter) async throws {
        do {
            try await send(request, emitter: emitter)
        } catch let error as LLMError {
            throw explainingMissingKey(error)
        }
    }

    private func send(_ request: LLMRequest, emitter: StreamEmitter) async throws {
        let request = try ProviderEndpoint.normalizedModel(of: request)
        let url = try ProviderEndpoint.url(baseURL, appendingPath: "chat/completions")
        let host = ProviderEndpoint.hostKey(for: baseURL)
        let memory = transport.featureMemory
        var sendsEffort = request.effort != nil
            && !memory.isDisabled(.openAIReasoningEffort, host: host, model: request.model)
        // Until the server streamed reasoning, assume Ollama's field name.
        let reasoningField = memory.reasoningField(host: host, model: request.model) ?? .reasoning
        var echoesReasoning = !OpenAIWire.reasoningToEcho(in: request.messages).isEmpty
            && !memory.isDisabled(.openAIReasoningEcho, host: host, model: request.model)
        // Retrying without the echo after an error that named no cause; the echo
        // is only remembered as rejected when that retry succeeds.
        var suspectsEcho = false

        try await ProviderHTTP.performWithRetries(
            transport: transport, model: request.model, emitter: emitter, logLabel: "openai-compatible"
        ) { failure in
            guard failure.status == 400 || failure.status == 422 else { return false }
            let message = failure.normalizedMessage
            var retries = false
            // Checked first: a complaint about the echoed "reasoning" field would
            // also pass for one about reasoning_effort.
            if echoesReasoning, OpenAIWire.rejectsReasoningEcho(message, field: reasoningField) {
                echoesReasoning = false
                memory.disable(.openAIReasoningEcho, host: host, model: request.model)
                Log.llm.notice("openai-compatible: echoed reasoning rejected; retrying without it")
                retries = true
            }
            let rejectsEffort = retries
                ? OpenAIWire.mentionsReasoningEffort(message)
                : OpenAIWire.rejectsReasoningEffort(message)
            if sendsEffort, rejectsEffort {
                sendsEffort = false
                memory.disable(.openAIReasoningEffort, host: host, model: request.model)
                Log.llm.notice("openai-compatible: reasoning_effort rejected; retrying without it")
                retries = true
            }
            // Servers that reject unknown fields do not always say which one;
            // the echo is the field they are least likely to know.
            if !retries, echoesReasoning, case .invalidRequest = failure.llmError(model: request.model) {
                echoesReasoning = false
                suspectsEcho = true
                Log.llm.notice("openai-compatible: request rejected; retrying once without echoed reasoning")
                retries = true
            }
            return retries
        } attempt: {
            let body = OpenAIWire.requestBody(for: request, includesReasoningEffort: sendsEffort,
                                              reasoningEcho: echoesReasoning ? reasoningField : nil)
            let bytes = try await ProviderHTTP.openStream(makeRequest(url: url, body: body.jsonData()), session: transport.session)
            var decoder = OpenAIStreamDecoder()
            try await ProviderHTTP.readEvents(from: bytes) { event in
                for output in try decoder.consume(event) {
                    emitter.yield(output)
                }
                return !decoder.isFinished
            }
            for output in try decoder.finishAtEndOfStream() {
                emitter.yield(output)
            }
            if let field = decoder.reasoningField {
                memory.rememberReasoningField(field, host: host, model: request.model)
            }
            if suspectsEcho {
                memory.disable(.openAIReasoningEcho, host: host, model: request.model)
            }
        }
    }

    /// A POST with a JSON body that streams SSE, or a GET (no body) for JSON.
    private func makeRequest(url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "accept")
        }
        return request
    }
}
