import Foundation
import os

// MARK: - Transport

/// How the providers talk HTTP. `live` uses the shared session; tests inject a
/// mock session, an instant sleep and a fresh feature memory.
struct ProviderTransport: Sendable {
    var session: URLSession
    var retryPolicy: RetryPolicy
    /// Waits before a retry. Injectable so tests never really sleep.
    var sleep: @Sendable (Duration) async throws -> Void
    var featureMemory: ProviderFeatureMemory

    init(
        session: URLSession,
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        featureMemory: ProviderFeatureMemory = .shared
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.featureMemory = featureMemory
    }

    static let live = ProviderTransport(session: ProviderHTTP.session)
}

/// Automatic retries of transient failures that happen before any output.
struct RetryPolicy: Sendable, Hashable {
    var maxRetries = 2
    /// Delay before the first, second, … retry when the server sent no retry-after.
    var backoff: [Duration] = [.seconds(1), .seconds(3)]
    /// Upper bound when honoring a retry-after header.
    var maxRetryAfter: Duration = .seconds(20)

    /// The delay before retry number `index` (0-based).
    func delay(forRetry index: Int, retryAfter: TimeInterval?) -> Duration {
        if let retryAfter, retryAfter.isFinite, retryAfter >= 0 {
            // Clamp before converting: a server may send any number.
            let limit = maxRetryAfter.components
            let cap = Double(limit.seconds) + Double(limit.attoseconds) / 1e18
            return .milliseconds(Int64((min(retryAfter, cap) * 1000).rounded(.up)))
        }
        guard let last = backoff.last else { return .zero }
        return index < backoff.count ? backoff[index] : last
    }
}

/// Remembers for the rest of the app session which endpoint/model pairs rejected
/// optional request features, so later requests leave them out right away
/// instead of failing first, and in which field an OpenAI-compatible endpoint
/// streams reasoning, so it can be echoed in the same field.
final class ProviderFeatureMemory: Sendable {
    enum Feature: String, Sendable {
        /// Anthropic beta features, top-level cache_control and effort.
        case anthropicOptionalFeatures
        /// The system prompt's cache breakpoint (only dropped for compatible servers).
        case anthropicSystemPromptCaching
        /// OpenAI-compatible `reasoning_effort`.
        case openAIReasoningEffort
        /// OpenAI-compatible: the model's reasoning echoed with the assistant
        /// messages of the tool loop in progress.
        case openAIReasoningEcho
    }

    private struct Endpoint: Hashable, Sendable {
        var host: String
        var model: String
    }

    private struct State: Sendable {
        var disabled: [Endpoint: Set<Feature>] = [:]
        var reasoningFields: [Endpoint: OpenAIReasoningField] = [:]
    }

    static let shared = ProviderFeatureMemory()

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    func isDisabled(_ feature: Feature, host: String, model: String) -> Bool {
        let endpoint = Endpoint(host: host, model: model)
        return state.withLock { $0.disabled[endpoint]?.contains(feature) ?? false }
    }

    func disable(_ feature: Feature, host: String, model: String) {
        let endpoint = Endpoint(host: host, model: model)
        state.withLock { _ = $0.disabled[endpoint, default: []].insert(feature) }
    }

    /// The field the endpoint last streamed reasoning in; nil until it did.
    func reasoningField(host: String, model: String) -> OpenAIReasoningField? {
        let endpoint = Endpoint(host: host, model: model)
        return state.withLock { $0.reasoningFields[endpoint] }
    }

    func rememberReasoningField(_ field: OpenAIReasoningField, host: String, model: String) {
        let endpoint = Endpoint(host: host, model: model)
        state.withLock { $0.reasoningFields[endpoint] = field }
    }
}

// MARK: - HTTP errors

/// A non-2xx HTTP response, before it is mapped to `LLMError`.
struct HTTPStatusError: Error, Sendable, Hashable {
    var status: Int
    /// From `retry-after-ms` or `retry-after` (seconds or HTTP date), in seconds.
    var retryAfter: TimeInterval?
    /// The body's error message (an API error's `message`, or plain text).
    /// May echo request content: never log it publicly.
    var message: String?
    /// The API's error type and code, e.g. `invalid_request_error`, `insufficient_quota`.
    var type: String?
    var code: String?
    /// Whether the body was a JSON object, i.e. an API (not just a web server) answered.
    var isAPIError: Bool

    init(status: Int, headers: [String: String], body: Data, now: Date = Date()) {
        self.status = status
        var lowercasedHeaders: [String: String] = [:]
        for (name, value) in headers {
            lowercasedHeaders[name.lowercased()] = value
        }
        retryAfter = Self.retryAfter(from: lowercasedHeaders, now: now)
        if case .object(let object)? = try? JSONValue.parse(body) {
            isAPIError = true
            let error = object["error"]
            message = error?["message"]?.stringValue ?? error?.stringValue
                ?? object["message"]?.stringValue ?? Self.detailMessage(object["detail"])
            type = error?["type"]?.stringValue
            code = error?["code"]?.stringValue ?? WireNumber.int(error?["code"]).map(String.init)
        } else {
            isAPIError = false
            let text = String(decoding: body.prefix(1024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? nil : text
        }
    }

    /// Lowercased message for keyword checks.
    var normalizedMessage: String { message?.lowercased() ?? "" }

    /// Quota or payment problems. Some APIs report them as 400 (Anthropic's
    /// "credit balance is too low") or 429 (OpenAI's `insufficient_quota`);
    /// retrying never helps.
    var isQuotaOrBillingProblem: Bool {
        let identifiers = [type, code].compactMap { $0 }
        if identifiers.contains(where: { $0 == "insufficient_quota" || $0 == "billing_error" }) { return true }
        let message = normalizedMessage
        return message.contains("credit balance") || message.contains("exceeded your current quota")
    }

    /// The conversation no longer fits into the model's context window.
    var isContextTooLong: Bool {
        if code == "context_length_exceeded" || type == "exceed_context_size_error" { return true }
        let message = normalizedMessage
        return ["prompt is too long", "context length", "context_length", "context window", "context limit",
                "context size", "maximum context", "too many tokens", "exceeds the context"]
            .contains { message.contains($0) }
    }

    /// A 400 some servers use for unknown models ("model … does not exist").
    private var mentionsMissingModel: Bool {
        let message = normalizedMessage
        return message.contains("model") && (message.contains("not found") || message.contains("does not exist"))
    }

    /// A 400 for a model that cannot call tools, e.g. Ollama's
    /// "registry.ollama.ai/library/gemma3:4b does not support tools".
    var rejectsTools: Bool {
        let message = normalizedMessage
        return ["does not support tools", "does not support tool", "tools are not supported", "tool use is not supported",
                "tool calling is not supported", "does not support function calling", "function calling is not supported"]
            .contains { message.contains($0) }
    }

    /// A 404 that names the route, not the model: the base URL is wrong, e.g.
    /// OpenAI's "Invalid URL (POST /chat/completions)" for a base without /v1,
    /// FastAPI's "Not Found", Express's "Cannot POST /…" or LM Studio's
    /// "Unexpected endpoint or method.".
    private var isUnknownRoute: Bool {
        let message = normalizedMessage
        let routeMarkers = ["invalid url", "unrecognized request url", "unknown url", "unexpected endpoint",
                            "unknown endpoint", "no route", "cannot post /", "cannot get /"]
        if routeMarkers.contains(where: message.contains) { return true }
        let bare = message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return ["not found", "404 not found", "page not found", "404 page not found", "file not found",
                "resource not found", "endpoint not found", "route not found", "path not found"].contains(bare)
    }

    func llmError(model: String) -> LLMError {
        switch status {
        case 400, 422:
            if isQuotaOrBillingProblem { return .billing }
            if isContextTooLong { return .contextTooLong }
            if rejectsTools { return .toolsNotSupported(model: model) }
            if mentionsMissingModel { return .modelNotFound(model: model) }
            return .invalidRequest(message: message ?? "HTTP \(status)")
        case 401:
            return .invalidAPIKey
        case 402:
            return .billing
        case 403:
            return .permissionDenied
        case 404:
            // A plain web server page ("404 page not found") or an API error that
            // names the route means the base URL is wrong; otherwise the API does
            // not know the model ("model: …", "model 'x' not found").
            return !isAPIError || isUnknownRoute ? .invalidBaseURL : .modelNotFound(model: model)
        case 408:
            return .network(.timedOut)
        case 413:
            return .requestTooLarge
        case 429:
            return isQuotaOrBillingProblem ? .billing : .rateLimited(retryAfter: retryAfter)
        case 529:
            return .overloaded
        case 500...599:
            return .server(status: status)
        case 400..<500:
            return .invalidRequest(message: message ?? "HTTP \(status)")
        default:
            return .invalidResponse(detail: "HTTP \(status)")
        }
    }

    /// FastAPI-style `detail`: a string, or validation entries like
    /// `{"loc": ["body", "reasoning_effort"], "msg": "Extra inputs are not permitted"}`.
    private static func detailMessage(_ detail: JSONValue?) -> String? {
        if let text = detail?.stringValue { return text }
        guard let entries = detail?.arrayValue, !entries.isEmpty else { return nil }
        return entries.map { entry in
            let location = (entry["loc"]?.arrayValue ?? []).compactMap { $0.stringValue ?? WireNumber.int($0).map(String.init) }
            let text = entry["msg"]?.stringValue ?? entry.jsonString()
            return location.isEmpty ? text : location.joined(separator: ".") + ": " + text
        }.joined(separator: "; ")
    }

    private static func retryAfter(from headers: [String: String], now: Date) -> TimeInterval? {
        if let text = headers["retry-after-ms"]?.trimmingCharacters(in: .whitespaces),
           let milliseconds = Double(text), milliseconds.isFinite, milliseconds >= 0 {
            return milliseconds / 1000
        }
        guard let text = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if let seconds = Double(text) {
            return seconds.isFinite ? max(0, seconds) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

// MARK: - Streaming plumbing

/// Hands provider events to the stream's consumer and records whether visible
/// output started (from then on, failures are never retried).
final class StreamEmitter {
    private let continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    private(set) var hasOutput = false

    init(_ continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: LLMEvent) {
        if case .historyThinkingStripped = event {} else {
            hasOutput = true
        }
        continuation.yield(event)
    }
}

/// Shared HTTP plumbing of the LLM providers.
enum ProviderHTTP {
    /// The one session for all provider traffic: ephemeral (no cookies, URL cache
    /// or credential storage), 120 s without data fails a request, and a single
    /// response may take at most 15 minutes.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Error bodies are only parsed for a message.
    static let maxErrorBodyBytes = 64 * 1024
    /// Non-streaming responses (model lists).
    static let maxResponseBodyBytes = 16 * 1024 * 1024

    /// Runs `body` in a task that feeds the returned stream. Terminating the
    /// stream (the consumer was cancelled or stopped iterating) cancels the task
    /// and with it the network request.
    static func makeStream(
        _ body: @escaping @Sendable (StreamEmitter) async throws -> Void
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let emitter = StreamEmitter(continuation)
                do {
                    try await body(emitter)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: isCancellation(error) ? LLMError.cancelled : llmError(error, model: ""))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts a request and returns the body of a 2xx response as a byte stream.
    /// Other statuses throw `HTTPStatusError` with the size-capped body.
    static func openStream(_ request: URLRequest, session: URLSession) async throws -> URLSession.AsyncBytes {
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let http = try httpResponse(response)
        Log.llm.info("HTTP \(http.statusCode, privacy: .public) after \(milliseconds(since: started), privacy: .public) ms")
        guard (200..<300).contains(http.statusCode) else {
            let body = try await read(bytes, limit: maxErrorBodyBytes)
            bytes.task.cancel()
            throw HTTPStatusError(status: http.statusCode, headers: headerFields(of: http), body: body)
        }
        return bytes
    }

    /// Performs a request and returns the (size-capped) body of a 2xx response.
    /// Other statuses throw `HTTPStatusError`.
    static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let http = try httpResponse(response)
        guard (200..<300).contains(http.statusCode) else {
            let body = try await read(bytes, limit: maxErrorBodyBytes)
            throw HTTPStatusError(status: http.statusCode, headers: headerFields(of: http), body: body)
        }
        return try await read(bytes, limit: maxResponseBodyBytes)
    }

    /// Parses a response body as Server-Sent Events and hands each event to
    /// `handle` until the body ends or `handle` returns false; the transfer is
    /// stopped in the latter case.
    ///
    /// Bytes are fed to the parser at line ends, so every event is handled as
    /// soon as its terminating blank line has arrived.
    static func readEvents(
        from bytes: URLSession.AsyncBytes,
        handle: (SSEEvent) throws -> Bool
    ) async throws {
        defer { bytes.task.cancel() }
        var parser = SSEParser()
        var pending: [UInt8] = []
        pending.reserveCapacity(4096)
        for try await byte in bytes {
            pending.append(byte)
            guard byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || pending.count >= 65_536 else {
                continue
            }
            try Task.checkCancellation()
            let events = parser.feed(pending)
            pending.removeAll(keepingCapacity: true)
            for event in events {
                guard try handle(event) else { return }
            }
        }
        try Task.checkCancellation()
        for event in parser.feed(pending) + parser.flush() {
            guard try handle(event) else { return }
        }
    }

    /// Runs `attempt` until it succeeds, applying the shared resilience rules:
    /// - nothing is retried once visible output was emitted;
    /// - after an HTTP error status, `recover` may change the next attempt (e.g.
    ///   leave out optional features after a 400 or 422) and return true to
    ///   retry right away, at most twice;
    /// - 408, 429, 5xx/529, stream `overloaded`/`rate_limit`/`api_error` events
    ///   and network failures are retried up to `maxRetries` times with backoff,
    ///   honoring retry-after.
    /// Errors leave as `LLMError`.
    static func performWithRetries(
        transport: ProviderTransport,
        model: String,
        emitter: StreamEmitter,
        logLabel: StaticString,
        recover: (HTTPStatusError) -> Bool,
        attempt: () async throws -> Void
    ) async throws {
        let label = "\(logLabel)"
        let started = ContinuousClock.now
        var retries = 0
        var recoveries = 0
        while true {
            do {
                try await attempt()
                Log.llm.info("\(label, privacy: .public): stream finished after \(milliseconds(since: started), privacy: .public) ms, \(retries + recoveries + 1, privacy: .public) attempt(s)")
                return
            } catch {
                if Task.isCancelled || isCancellation(error) {
                    Log.llm.info("\(label, privacy: .public): cancelled")
                    throw LLMError.cancelled
                }
                if !emitter.hasOutput {
                    if let status = error as? HTTPStatusError, recoveries < 2, recover(status) {
                        recoveries += 1
                        continue
                    }
                    if retries < transport.retryPolicy.maxRetries, isTransient(error) {
                        let delay = transport.retryPolicy.delay(forRetry: retries, retryAfter: retryAfter(of: error))
                        retries += 1
                        Log.llm.notice("\(label, privacy: .public): retry \(retries, privacy: .public) in \(milliseconds(of: delay), privacy: .public) ms after \(logName(of: llmError(error, model: model)), privacy: .public)")
                        do {
                            try await transport.sleep(delay)
                        } catch {
                            throw LLMError.cancelled
                        }
                        continue
                    }
                }
                let mapped = llmError(error, model: model)
                Log.llm.error("\(label, privacy: .public): failed with \(logName(of: mapped), privacy: .public)")
                throw mapped
            }
        }
    }

    // MARK: Error classification

    /// Maps anything thrown while talking to a provider to `LLMError`.
    static func llmError(_ error: any Error, model: String) -> LLMError {
        switch error {
        case let error as LLMError: error
        case let error as HTTPStatusError: error.llmError(model: model)
        case let error as URLError: LLMError(urlError: error)
        case is CancellationError: .cancelled
        default: .invalidResponse(detail: String(describing: type(of: error)))
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError: true
        case let error as URLError: error.code == .cancelled
        case let error as LLMError: error == .cancelled
        default: false
        }
    }

    /// Failures worth an automatic retry (only before any output was emitted).
    static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case let error as HTTPStatusError:
            guard !error.isQuotaOrBillingProblem else { return false }
            return error.status == 408 || error.status == 429 || (500...599).contains(error.status)
        case let error as URLError:
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        case let error as LLMError:
            switch error {
            case .overloaded, .rateLimited, .server: return true
            default: return false
            }
        default:
            return false
        }
    }

    static func retryAfter(of error: any Error) -> TimeInterval? {
        switch error {
        case let error as HTTPStatusError: error.retryAfter
        case LLMError.rateLimited(let retryAfter): retryAfter
        default: nil
        }
    }

    /// A content-free name of the error for logs. A stream error's type comes
    /// from the server and is only included when it looks like an identifier.
    static func logName(of error: LLMError) -> String {
        switch error {
        case .missingAPIKey: "missingAPIKey"
        case .invalidAPIKey: "invalidAPIKey"
        case .permissionDenied: "permissionDenied"
        case .billing: "billing"
        case .modelNotFound: "modelNotFound"
        case .toolsNotSupported: "toolsNotSupported"
        case .rateLimited: "rateLimited"
        case .overloaded: "overloaded"
        case .server(let status): "server(\(status))"
        case .requestTooLarge: "requestTooLarge"
        case .contextTooLong: "contextTooLong"
        case .invalidRequest: "invalidRequest"
        case .network(let failure): "network(\(failure.rawValue))"
        case .invalidResponse: "invalidResponse"
        case .streamError(let type, _): "streamError(\(isIdentifier(type) ? type : "other"))"
        case .invalidBaseURL: "invalidBaseURL"
        case .cancelled: "cancelled"
        case .claudeCodeNotInstalled: "claudeCodeNotInstalled"
        case .claudeCodeNotLoggedIn: "claudeCodeNotLoggedIn"
        case .claudeCodeOutdated: "claudeCodeOutdated"
        case .usageLimitReached: "usageLimitReached"
        case .providerProcessFailed: "providerProcessFailed"
        case .keychainUnavailable: "keychainUnavailable"
        }
    }

    // MARK: Private

    /// Short ASCII identifiers such as `overloaded_error`, never free text.
    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse(detail: "Not an HTTP response")
        }
        return http
    }

    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                fields[name] = value
            }
        }
        return fields
    }

    private static func read(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        milliseconds(of: start.duration(to: .now))
    }

    private static func milliseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
