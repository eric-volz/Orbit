import Foundation

/// URL handling shared by the providers.
enum ProviderEndpoint {
    /// Checks a configured base URL (http or https with a host) and removes
    /// trailing slashes plus the first matching path suffix (case-insensitive),
    /// so users may paste e.g. both "http://localhost:11434" and ".../v1/".
    static func normalizedBaseURL(_ url: URL, removingSuffixes suffixes: [String] = []) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw LLMError.invalidBaseURL
        }
        var path = trimmingTrailingSlashes(components.percentEncodedPath)
        if let suffix = suffixes.first(where: { path.lowercased().hasSuffix($0.lowercased()) }) {
            path = trimmingTrailingSlashes(String(path.dropLast(suffix.count)))
        }
        components.percentEncodedPath = path
        components.fragment = nil
        guard let normalized = components.url else { throw LLMError.invalidBaseURL }
        return normalized
    }

    /// `base` with a relative, already percent-encoded path appended.
    static func url(_ base: URL, appendingPath path: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw LLMError.invalidBaseURL
        }
        components.percentEncodedPath = trimmingTrailingSlashes(components.percentEncodedPath) + "/" + path
        guard let url = components.url else { throw LLMError.invalidBaseURL }
        return url
    }

    /// Percent-encodes one path segment, including "/".
    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The request with its model id trimmed (as typed into the settings).
    /// Throws `.modelNotFound` for an empty id instead of sending a request.
    static func normalizedModel(of request: LLMRequest) throws -> LLMRequest {
        var request = request
        request.model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.model.isEmpty else { throw LLMError.modelNotFound(model: "") }
        return request
    }

    /// Whether the URL points at this Mac: `localhost` and `*.localhost` (the
    /// system resolver maps them to loopback), an IPv4 address in 127.0.0.0/8
    /// or 0.0.0.0, or the IPv6 loopback, unspecified or IPv4-mapped loopback
    /// address. Host names are never matched by prefix: "127.example.com" is
    /// a remote host.
    static func isLocal(_ url: URL) -> Bool {
        let host = hostName(of: url)
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        return name == "localhost" || name.hasSuffix(".localhost") || isLoopbackAddress(host)
    }

    private static let numericIPv4Characters = CharacterSet(charactersIn: "0123456789abcdefx.")

    /// Whether `host` (lowercased) is a numeric address of this Mac. IPv4 is
    /// parsed like the system resolver does (`inet_aton`, so "127.1" and
    /// "0x7f000001" count), but only hosts made of hex digits, "x" and dots are
    /// tried: `inet_aton` would accept trailing text after a space.
    private static func isLoopbackAddress(_ host: String) -> Bool {
        if !host.isEmpty, host.unicodeScalars.allSatisfy(numericIPv4Characters.contains) {
            var address = in_addr()
            if inet_aton(host, &address) != 0 {
                let value = UInt32(bigEndian: address.s_addr)
                return value >> 24 == 127 || value == 0
            }
        }
        var address6 = in6_addr()
        guard inet_pton(AF_INET6, host, &address6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address6) { Array($0) }
        let isLoopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isMappedIPv4Loopback = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
            && bytes[12] == 127
        return isLoopback || isUnspecified || isMappedIPv4Loopback
    }

    /// Name of a non-default endpoint for the disclosure note: the host name,
    /// or `ProviderRecipient.localModel` for a server on this Mac.
    static func displayName(for url: URL) -> String {
        isLocal(url) ? ProviderRecipient.localModel : hostName(of: url)
    }

    /// "host:port", the key for per-endpoint memories.
    static func hostKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let port = components?.port ?? (components?.scheme?.lowercased() == "http" ? 80 : 443)
        return "\(hostName(of: url)):\(port)"
    }

    /// The server as people write it in a message: "localhost:11434",
    /// "api.openai.com" (the port only when the URL names one).
    static func address(of url: URL) -> String {
        let host = hostName(of: url)
        guard !host.isEmpty else { return "" }
        guard let port = URLComponents(url: url, resolvingAgainstBaseURL: true)?.port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func hostName(of url: URL) -> String {
        var host = URLComponents(url: url, resolvingAgainstBaseURL: true)?.host?.lowercased() ?? ""
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Where requests go, so an error can say what to check
/// (`LLMError.userMessage(for:)`): the Claude subscription through Claude Code,
/// Anthropic's API, a server on this Mac (Ollama, LM Studio) or another server.
enum ProviderDestination: Sendable, Hashable {
    case claudeSubscription
    case anthropicAPI
    /// A server on this Mac, by its address ("localhost:11434").
    case thisMac(address: String)
    /// Another server, by its address ("api.openai.com", "192.168.1.20:11434").
    case server(address: String)

    /// Where requests of `kind` go with this base URL (nil: the provider's default).
    init(kind: ProviderKind, baseURL: URL?) {
        switch kind {
        case .claudeCode:
            self = .claudeSubscription
        case .anthropic:
            guard let baseURL, let host = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)?.host,
                  !host.isEmpty, host.lowercased() != AnthropicProvider.officialHost else {
                self = .anthropicAPI
                return
            }
            self = Self.endpoint(baseURL)
        case .openAICompatible:
            self = Self.endpoint(baseURL ?? OpenAICompatibleProvider.defaultBaseURL)
        }
    }

    private static func endpoint(_ url: URL) -> ProviderDestination {
        let address = ProviderEndpoint.address(of: url)
        return ProviderEndpoint.isLocal(url) ? .thisMac(address: address) : .server(address: address)
    }
}

/// Who gets the content the disclosure note lists ("3 emails sent to
/// Claude"). Chats keep the name as it was: a product name or host as it is,
/// a generic recipient as a fixed marker, so the note names it in the
/// language Orbit shows now, also in chats saved before. The markers are the
/// German texts older versions stored; they are identifiers, never shown.
enum ProviderRecipient {
    /// A server on this Mac.
    static let localModel = "das lokale Modell"
    /// An OpenAI-compatible server without a usable address.
    static let languageModel = "das Sprachmodell"

    /// The stored name as the note shows it; an empty one is "the provider".
    static func shown(_ stored: String) -> String {
        switch stored.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "": String(localized: "the provider")
        case localModel: String(localized: "the local model")
        case languageModel: String(localized: "the language model")
        case let name: name
        }
    }
}

/// Numbers read from untrusted wire JSON.
enum WireNumber {
    /// A whole number within ±2^53, else nil. Unlike `JSONValue.intValue`, this
    /// never traps (that accessor crashes for exactly 2^63).
    static func int(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.rounded() == number,
              abs(number) <= 9_007_199_254_740_992 else { return nil }
        return Int(number)
    }

    /// A token count: a non-negative whole number.
    static func count(_ value: JSONValue?) -> Int? {
        int(value).map { max(0, $0) }
    }
}

/// Builds tool calls from streamed argument JSON (shared by the providers).
enum ToolCallDecoding {
    /// Model-facing explanations, set as `ToolCall.inputParseError`.
    static let invalidJSONMessage = "The tool arguments are not valid JSON."
    static let notAnObjectMessage = "The tool arguments must be a JSON object."

    /// Parses the complete argument text of a tool call strictly. Empty text
    /// means "no arguments"; a JSON string that itself holds an object (double
    /// encoding, seen with some local models) is unwrapped.
    static func toolCall(id: String, name: String, arguments: String) -> ToolCall {
        guard !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolCall(id: id, name: name, input: .object([:]))
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(arguments)
        } catch {
            return ToolCall(id: id, name: name, rawInput: arguments, inputParseError: invalidJSONMessage)
        }
        switch value {
        case .object:
            return ToolCall(id: id, name: name, input: value, rawInput: arguments)
        case .string(let inner):
            if case .object(let object)? = try? JSONValue.parse(inner) {
                return ToolCall(id: id, name: name, input: .object(object), rawInput: arguments)
            }
            return ToolCall(id: id, name: name, rawInput: arguments, inputParseError: notAnObjectMessage)
        default:
            return ToolCall(id: id, name: name, rawInput: arguments, inputParseError: notAnObjectMessage)
        }
    }
}

/// `/models` responses.
enum ModelList {
    /// The model ids of a model list (`{"data": [{"id": …}]}` as sent by OpenAI,
    /// Anthropic and Ollama, `{"models": […]}`, or a bare array); nil when the
    /// body is not a recognizable list.
    static func ids(in data: Data) -> [String]? {
        guard let json = try? JSONValue.parse(data),
              let entries = json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? json.arrayValue
        else {
            return nil
        }
        return entries.compactMap { entry in
            entry["id"]?.stringValue ?? entry["name"]?.stringValue ?? entry["model"]?.stringValue ?? entry.stringValue
        }
    }

    /// Whether `ids` lists `model`. Ollama's implicit ":latest" tag counts as equal.
    static func contains(_ ids: [String], model: String) -> Bool {
        let wanted = withoutLatestTag(model)
        return ids.contains { withoutLatestTag($0) == wanted }
    }

    private static func withoutLatestTag(_ id: String) -> String {
        id.hasSuffix(":latest") ? String(id.dropLast(":latest".count)) : id
    }
}
