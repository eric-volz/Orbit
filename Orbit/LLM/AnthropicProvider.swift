import Foundation

/// Claude via the Anthropic Messages API (raw HTTPS, SSE streaming), or any
/// Anthropic-compatible server such as a proxy or Ollama's `/v1/messages`.
///
/// Resilience: before any output, transient failures are retried (see
/// `ProviderHTTP.performWithRetries`); a 400 or 422 (strict compatible servers
/// such as FastAPI's) about optional features is retried once without them
/// (remembered per host and model for the app session; on compatible servers a
/// rejected `cache_control` also drops the system prompt's cache breakpoint); a
/// 400 or 422 about thinking blocks in the history is retried once without
/// them, emitting `.historyThinkingStripped`.
struct AnthropicProvider: LLMProvider {
    static let officialBaseURL = URL(string: "https://api.anthropic.com")!
    static let officialHost = "api.anthropic.com"

    let kind = ProviderKind.anthropic
    /// Server root without the version path, e.g. `http://127.0.0.1:11434`.
    let baseURL: URL
    /// Requests go to api.anthropic.com; only then beta features are used.
    let isOfficialAPI: Bool
    private let apiKey: String
    private let transport: ProviderTransport

    /// Throws `LLMError.invalidBaseURL` for unusable base URLs. The base may be
    /// given with or without a trailing "/v1" or "/".
    init(configuration: ProviderConfiguration, transport: ProviderTransport = .live) throws {
        baseURL = try ProviderEndpoint.normalizedBaseURL(
            configuration.baseURL ?? Self.officialBaseURL,
            removingSuffixes: ["/v1/messages", "/v1"]
        )
        isOfficialAPI = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)?.host?.lowercased() == Self.officialHost
        apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    var displayName: String {
        isOfficialAPI ? "Claude" : ProviderEndpoint.displayName(for: baseURL)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        ProviderHTTP.makeStream { emitter in
            try await run(request, emitter: emitter)
        }
    }

    /// `GET /v1/models/{model}`. Compatible servers that answer 404 for that
    /// route are asked for the model list instead.
    func validateConfiguration(model: String) async throws {
        try checkAPIKey()
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LLMError.modelNotFound(model: model) }
        let modelURL = try ProviderEndpoint.url(baseURL, appendingPath: "v1/models/" + ProviderEndpoint.pathSegment(model))
        do {
            _ = try await ProviderHTTP.fetch(makeRequest(url: modelURL), session: transport.session)
        } catch let error as HTTPStatusError where error.status == 404 && !isOfficialAPI {
            let listURL = try ProviderEndpoint.url(baseURL, appendingPath: "v1/models")
            let data: Data
            do {
                data = try await ProviderHTTP.fetch(makeRequest(url: listURL), session: transport.session)
            } catch {
                throw explainingMissingKey(ProviderHTTP.llmError(error, model: model))
            }
            if let ids = ModelList.ids(in: data), !ModelList.contains(ids, model: model) {
                throw LLMError.modelNotFound(model: model)
            }
        } catch {
            throw explainingMissingKey(ProviderHTTP.llmError(error, model: model))
        }
    }

    // MARK: Private

    /// A compatible server that rejects a request without a key wants one
    /// (the official API never gets one without: `checkAPIKey`).
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
        try checkAPIKey()
        let request = try ProviderEndpoint.normalizedModel(of: request)
        let url = try ProviderEndpoint.url(baseURL, appendingPath: "v1/messages")
        let host = ProviderEndpoint.hostKey(for: baseURL)
        let memory = transport.featureMemory
        var features = memory.isDisabled(.anthropicOptionalFeatures, host: host, model: request.model)
            ? .none
            : AnthropicFeatures.for(model: request.model, effort: request.effort, officialAPI: isOfficialAPI)
        var cachesSystemPrompt = !memory.isDisabled(.anthropicSystemPromptCaching, host: host, model: request.model)
        var messages = request.messages
        var didStripThinking = false

        try await ProviderHTTP.performWithRetries(
            transport: transport, model: request.model, emitter: emitter, logLabel: "anthropic"
        ) { failure in
            guard failure.status == 400 || failure.status == 422, let message = failure.message else { return false }
            // Checked first: this message also names the anthropic-beta header,
            // but it is never a reason to drop the optional features.
            if AnthropicWire.rejectsHistoryThinking(message) {
                guard !didStripThinking, AnthropicWire.containsThinking(messages) else { return false }
                didStripThinking = true
                messages = AnthropicWire.removingThinking(from: messages)
                Log.llm.notice("anthropic: thinking blocks of the history rejected; retrying without them")
                emitter.yield(.historyThinkingStripped)
                return true
            }
            guard AnthropicWire.rejectsOptionalFeature(message) else { return false }
            let dropsSystemCaching = !isOfficialAPI && cachesSystemPrompt && message.lowercased().contains("cache_control")
            guard features != .none || dropsSystemCaching else { return false }
            if features != .none {
                features = .none
                memory.disable(.anthropicOptionalFeatures, host: host, model: request.model)
            }
            if dropsSystemCaching {
                cachesSystemPrompt = false
                memory.disable(.anthropicSystemPromptCaching, host: host, model: request.model)
            }
            Log.llm.notice("anthropic: optional request features rejected; retrying without them")
            return true
        } attempt: {
            let body = AnthropicWire.requestBody(
                for: request, messages: messages, features: features, cachesSystemPrompt: cachesSystemPrompt
            )
            let urlRequest = makeRequest(url: url, body: body.jsonData(), beta: features.betaHeader)
            let bytes = try await ProviderHTTP.openStream(urlRequest, session: transport.session)
            var decoder = AnthropicStreamDecoder(emitsProgressNotes: features.progressUpdates)
            try await ProviderHTTP.readEvents(from: bytes) { event in
                for output in try decoder.consume(event) {
                    emitter.yield(output)
                }
                return !decoder.isFinished
            }
            for output in try decoder.finishAtEndOfStream() {
                emitter.yield(output)
            }
        }
    }

    /// The official API needs a key; compatible servers may not.
    private func checkAPIKey() throws {
        if isOfficialAPI, apiKey.isEmpty {
            throw LLMError.missingAPIKey
        }
    }

    /// A POST with a JSON body that streams SSE, or a GET (no body) for JSON.
    private func makeRequest(url: URL, body: Data? = nil, beta: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue(AnthropicWire.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "accept")
        }
        if let beta {
            request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }
}
