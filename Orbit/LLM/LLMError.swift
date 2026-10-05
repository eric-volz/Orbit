import Foundation

enum NetworkFailure: String, Sendable, Hashable, Codable {
    case offline
    /// An open connection was dropped (e.g. the server restarted or crashed).
    case connectionLost
    case timedOut
    case cannotConnect
    case secureConnection
    /// Plain http:// to a host name was blocked (App Transport Security).
    case insecureConnectionBlocked
    case other
}

/// Errors surfaced by LLM providers. `userMessage` is what the UI shows, never
/// raw error strings from the network stack or the API.
enum LLMError: Error, Sendable, Hashable {
    case missingAPIKey
    /// The keychain could not be read (locked, or access was denied).
    case keychainUnavailable
    case invalidAPIKey
    case permissionDenied
    case billing
    /// The endpoint does not offer `model` (an empty id: none is set).
    case modelNotFound(model: String)
    /// The model cannot use tools (e.g. Ollama's "… does not support tools"),
    /// and Orbit always offers them.
    case toolsNotSupported(model: String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case server(status: Int)
    case requestTooLarge
    case contextTooLong
    /// HTTP 400 with the API's message (logged privately, not shown verbatim).
    case invalidRequest(message: String)
    case network(NetworkFailure)
    case invalidResponse(detail: String)
    /// An `error` event in the middle of a stream.
    case streamError(type: String, message: String)
    case invalidBaseURL
    case cancelled
    /// Claude Code (`claude`) was not found.
    case claudeCodeNotInstalled
    /// Claude Code is installed but not signed in.
    case claudeCodeNotLoggedIn
    /// Claude Code rejected an option Orbit starts it with: it is too old.
    case claudeCodeOutdated
    /// The subscription's usage limit is reached (until `resetsAt`, if known).
    case usageLimitReached(resetsAt: Date?)
    /// A provider process (Claude Code) failed or exited unexpectedly.
    case providerProcessFailed(detail: String)

    /// Whether retrying the same request later may succeed.
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .streamError, .invalidResponse, .providerProcessFailed,
             .keychainUnavailable:
            true
        case .network(let failure):
            // Blocked plain http:// only changes with a different base URL.
            failure != .insecureConnectionBlocked
        default:
            false
        }
    }

    /// A short, friendly explanation for the user (localized).
    var userMessage: String {
        switch self {
        case .missingAPIKey:
            String(localized: "No API key is set. Enter it in Settings.")
        case .keychainUnavailable:
            String(localized: "The API key could not be read from the keychain. Allow Orbit access and try again.")
        case .invalidAPIKey:
            String(localized: "The API key was rejected. Check it in Settings.")
        case .permissionDenied:
            String(localized: "This API key does not have access to the selected model.")
        case .billing:
            String(localized: "There is a billing problem with the provider. Check your account with the provider.")
        case .modelNotFound(let model):
            if Self.isUnset(model) {
                String(localized: "No model is set. Enter a model in Settings.")
            } else {
                String(format: String(localized: "The model “%@” is not available. Choose a different model in Settings."),
                       Self.shown(model))
            }
        case .toolsNotSupported(let model):
            if Self.isUnset(model) {
                String(localized: "The selected model cannot use tools. Choose a model with tool support in Settings, for example gpt-oss or qwen3.")
            } else {
                String(format: String(localized: "The model “%@” cannot use tools. Choose a model with tool support in Settings, for example gpt-oss or qwen3."),
                       Self.shown(model))
            }
        case .rateLimited(let retryAfter):
            if let wait = Self.waitText(retryAfter) {
                String(format: String(localized: "Too many requests in a short time. Please try again in %@."), wait)
            } else {
                String(localized: "Too many requests in a short time. Please try again in a moment.")
            }
        case .overloaded:
            String(localized: "The service is overloaded right now. Please try again in a moment.")
        case .server:
            String(localized: "The provider ran into an error. Please try again later.")
        case .requestTooLarge, .contextTooLong:
            String(localized: "This conversation has become too long. Start a new chat.")
        case .invalidRequest:
            String(localized: "The provider rejected the request. Check the model and your settings.")
        case .network(let failure):
            switch failure {
            case .offline:
                String(localized: "No internet connection.")
            case .connectionLost:
                String(localized: "The connection to the provider was interrupted. Please try again.")
            case .timedOut:
                String(localized: "The provider is not responding. Please try again.")
            case .cannotConnect:
                String(localized: "The server cannot be reached. Check the address in Settings.")
            case .secureConnection:
                String(localized: "A secure connection could not be established.")
            case .insecureConnectionBlocked:
                String(localized: "Orbit allows unencrypted connections (http://) only to this Mac, to IP addresses and to .local addresses. Use https:// or the server’s IP address.")
            case .other:
                String(localized: "Network error. Please try again.")
            }
        case .invalidResponse, .streamError:
            String(localized: "The provider’s response was incomplete. Please try again.")
        case .invalidBaseURL:
            String(localized: "The server address in Settings is invalid.")
        case .cancelled:
            String(localized: "Canceled.")
        case .claudeCodeNotInstalled:
            String(localized: "Claude Code was not found. Install the Claude app or Claude Code, or choose another provider in Settings.")
        case .claudeCodeNotLoggedIn:
            String(localized: "Claude Code is not signed in. Sign in with your Claude account. Signing in happens in your browser, through Anthropic.")
        case .claudeCodeOutdated:
            String(localized: "This version of Claude Code is too old for Orbit. Update the Claude app or Claude Code, then try again.")
        case .usageLimitReached(let resetsAt):
            if let resetsAt {
                String(format: String(localized: "Your Claude subscription’s usage limit has been reached. It resets on %@."),
                       ProviderUsage.resetDate(resetsAt))
            } else {
                String(localized: "Your Claude subscription’s usage limit has been reached.")
            }
        case .providerProcessFailed:
            String(localized: "Claude Code quit unexpectedly. Please try again.")
        }
    }

    /// `userMessage`, saying what to check where requests go: a server on this
    /// Mac that does not answer is most likely not started, another server's
    /// address (or certificate) may be wrong, and Anthropic's API only needs
    /// the internet.
    func userMessage(for destination: ProviderDestination?) -> String {
        switch (self, destination) {
        case (.network(.cannotConnect), .thisMac(let address)?) where !address.isEmpty:
            String(format: String(localized: "The server on this Mac (%@) cannot be reached. Start it (for example Ollama or LM Studio) and try again."),
                   address)
        case (.network(.cannotConnect), .server(let address)?) where !address.isEmpty:
            String(format: String(localized: "The server %@ cannot be reached. Check the address in Settings and your network connection."),
                   address)
        case (.network(.cannotConnect), .anthropicAPI?):
            String(localized: "The Anthropic API cannot be reached. Check your internet connection.")
        case (.network(.secureConnection), .thisMac(let address)?) where !address.isEmpty,
             (.network(.secureConnection), .server(let address)?) where !address.isEmpty:
            String(format: String(localized: "A secure connection to %@ could not be established. Check the server’s address and certificate."),
                   address)
        case (.permissionDenied, .claudeSubscription?):
            String(localized: "Your Claude subscription does not include the selected model. Choose a different model in Settings.")
        case (.modelNotFound(let model), .thisMac?) where !Self.isUnset(model):
            String(format: String(localized: "The model “%@” is not installed on this Mac. Download it in Ollama or LM Studio, or choose a different model in Settings."),
                   Self.shown(model))
        default:
            userMessage
        }
    }

    /// How long to wait before trying again, rounded up to one unit ("30
    /// Sekunden", "2 Minuten"); nil when unknown, under a second or over a day.
    static func waitText(_ seconds: TimeInterval?, locale: Locale = AppLanguage.locale) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1, seconds <= 86_400 else { return nil }
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide,
                                              maximumUnitCount: 1, fractionalPart: .hide(rounded: .up))
        return Duration.seconds(Int64(seconds.rounded(.up))).formatted(style.locale(locale))
    }

    /// A model id as a message shows it: one line, at most 60 characters.
    private static func shown(_ model: String) -> String {
        TurnContext.inline(model, maxCharacters: 60)
    }

    private static func isUnset(_ model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension LLMError {
    /// Maps a `URLError` to a network failure.
    init(urlError: URLError) {
        switch urlError.code {
        case .cancelled:
            self = .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .network(.offline)
        case .networkConnectionLost:
            self = .network(.connectionLost)
        case .timedOut:
            self = .network(.timedOut)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            self = .network(.cannotConnect)
        case .appTransportSecurityRequiresSecureConnection:
            self = .network(.insecureConnectionBlocked)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            self = .network(.secureConnection)
        case .badURL, .unsupportedURL:
            self = .invalidBaseURL
        default:
            self = .network(.other)
        }
    }
}
