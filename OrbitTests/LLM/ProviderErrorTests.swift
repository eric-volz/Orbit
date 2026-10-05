import Foundation
import Testing
@testable import Orbit

/// D2: what a failed request tells the user: the error kinds the providers
/// report, and messages that name the model and say what to check where the
/// requests go.
@Suite("Provider errors: kinds, messages and destinations")
struct ProviderErrorTests {
    private static let ollama = URL(string: "http://localhost:11434/v1")

    // MARK: Where requests go

    @Test(arguments: [
        (ProviderKind.claudeCode, nil, ProviderDestination.claudeSubscription),
        (.anthropic, nil, .anthropicAPI),
        (.anthropic, "https://api.anthropic.com", .anthropicAPI),
        (.anthropic, "HTTPS://API.ANTHROPIC.COM/v1", .anthropicAPI),
        (.anthropic, "http://127.0.0.1:11434", .thisMac(address: "127.0.0.1:11434")),
        (.anthropic, "https://proxy.example.com", .server(address: "proxy.example.com")),
        (.openAICompatible, nil, .thisMac(address: "localhost:11434")),
        (.openAICompatible, "http://localhost:1234/v1", .thisMac(address: "localhost:1234")),
        (.openAICompatible, "http://[::1]:8080/v1", .thisMac(address: "[::1]:8080")),
        (.openAICompatible, "https://api.openai.com/v1", .server(address: "api.openai.com")),
        (.openAICompatible, "http://192.168.1.20:11434/v1", .server(address: "192.168.1.20:11434")),
    ] as [(ProviderKind, String?, ProviderDestination)])
    func destinations(kind: ProviderKind, base: String?, expected: ProviderDestination) {
        #expect(ProviderDestination(kind: kind, baseURL: base.flatMap(URL.init(string:))) == expected)
    }

    // MARK: Messages

    @Test func modelErrorsNameTheModel() {
        #expect(LLMError.modelNotFound(model: "llama3").userMessage
                == "The model “llama3” is not available. Choose a different model in Settings.")
        #expect(LLMError.modelNotFound(model: " ").userMessage
                == "No model is set. Enter a model in Settings.")
        #expect(LLMError.toolsNotSupported(model: "gemma3:4b").userMessage
                == "The model “gemma3:4b” cannot use tools. Choose a model with tool support in Settings, for example gpt-oss or qwen3.")
        #expect(LLMError.toolsNotSupported(model: "").userMessage.hasPrefix("The selected model cannot use tools."))
        // A model id is shown on one line and capped.
        let shown = LLMError.modelNotFound(model: "a\nb" + String(repeating: "x", count: 200)).userMessage
        #expect(!shown.contains("\n"))
        #expect(shown.count < 200)
    }

    @Test func rateLimitsSayWhenToTryAgain() {
        #expect(LLMError.rateLimited(retryAfter: 30).userMessage
                == "Too many requests in a short time. Please try again in 30 seconds.")
        #expect(LLMError.rateLimited(retryAfter: 61).userMessage.contains("in 2 minutes"))
        #expect(LLMError.rateLimited(retryAfter: nil).userMessage
                == "Too many requests in a short time. Please try again in a moment.")
        #expect(LLMError.waitText(0.4) == nil)
        #expect(LLMError.waitText(.infinity) == nil)
        #expect(LLMError.waitText(2 * 86_400) == nil)
        #expect(LLMError.waitText(5.2, locale: Locale(identifier: "en_US")) == "6 seconds")
        #expect(LLMError.waitText(3_600, locale: Locale(identifier: "de_DE")) == "1 Stunde")
    }

    @Test func usageLimitsSayWhenTheyReset() {
        let reset = Date(timeIntervalSince1970: 1_790_700_000)
        let message = LLMError.usageLimitReached(resetsAt: reset).userMessage
        #expect(message.hasPrefix("Your Claude subscription’s usage limit has been reached. It resets on "))
        #expect(message.contains(ProviderUsage.resetDate(reset)))
    }

    /// Unreachable servers: a server on this Mac is probably not started,
    /// another one may have a wrong address, Anthropic's API needs the internet.
    @Test func connectionErrorsSayWhatToCheck() {
        let cannotConnect = LLMError.network(.cannotConnect)
        #expect(cannotConnect.userMessage(for: .thisMac(address: "localhost:11434"))
                == "The server on this Mac (localhost:11434) cannot be reached. Start it (for example Ollama or LM Studio) and try again.")
        #expect(cannotConnect.userMessage(for: .server(address: "192.168.1.20:11434"))
                == "The server 192.168.1.20:11434 cannot be reached. Check the address in Settings and your network connection.")
        #expect(cannotConnect.userMessage(for: .anthropicAPI)
                == "The Anthropic API cannot be reached. Check your internet connection.")
        #expect(cannotConnect.userMessage(for: .claudeSubscription) == cannotConnect.userMessage)
        #expect(cannotConnect.userMessage(for: nil) == cannotConnect.userMessage)
        #expect(LLMError.network(.secureConnection).userMessage(for: .server(address: "llm.example.com"))
                == "A secure connection to llm.example.com could not be established. Check the server’s address and certificate.")
        #expect(LLMError.network(.secureConnection).userMessage(for: .anthropicAPI)
                == LLMError.network(.secureConnection).userMessage)
    }

    @Test func modelAndAccessErrorsDependOnTheDestination() {
        #expect(LLMError.modelNotFound(model: "llama3").userMessage(for: .thisMac(address: "localhost:11434"))
                == "The model “llama3” is not installed on this Mac. Download it in Ollama or LM Studio, or choose a different model in Settings.")
        #expect(LLMError.modelNotFound(model: "").userMessage(for: .thisMac(address: "localhost:11434"))
                == LLMError.modelNotFound(model: "").userMessage)
        #expect(LLMError.modelNotFound(model: "x").userMessage(for: .server(address: "api.openai.com"))
                == LLMError.modelNotFound(model: "x").userMessage)
        #expect(LLMError.permissionDenied.userMessage(for: .claudeSubscription)
                == "Your Claude subscription does not include the selected model. Choose a different model in Settings.")
        #expect(LLMError.permissionDenied.userMessage(for: .anthropicAPI) == LLMError.permissionDenied.userMessage)
    }

    @Test func claudeCodeErrorsSayWhatToDo() {
        #expect(LLMError.claudeCodeNotLoggedIn.userMessage
                == "Claude Code is not signed in. Sign in with your Claude account. Signing in happens in your browser, through Anthropic.")
        #expect(LLMError.claudeCodeOutdated.userMessage.hasPrefix("This version of Claude Code is too old for Orbit."))
        #expect(!LLMError.claudeCodeOutdated.isRetryable)
        #expect(ProviderHTTP.logName(of: .claudeCodeOutdated) == "claudeCodeOutdated")
        #expect(ProviderHTTP.logName(of: .toolsNotSupported(model: "secret-model")) == "toolsNotSupported")
        #expect(AgentLoop.logName(for: .toolsNotSupported(model: "secret-model")) == "toolsNotSupported")
    }

    // MARK: Mapping HTTP errors

    @Test(arguments: [
        // Ollama, OpenAI-compatible and Anthropic-compatible routes.
        #"{"error":{"message":"registry.ollama.ai/library/gemma3:4b does not support tools","type":"api_error","param":null,"code":null}}"#,
        #"{"type":"error","error":{"type":"invalid_request_error","message":"gemma3:4b does not support tools"}}"#,
        #"{"error":{"message":"Tool calling is not supported for this model.","type":"invalid_request_error"}}"#,
    ])
    func modelsWithoutToolsAreRecognized(body: String) {
        let error = HTTPStatusError(status: 400, headers: [:], body: Data(body.utf8))
        #expect(error.llmError(model: "gemma3:4b") == .toolsNotSupported(model: "gemma3:4b"))
    }

    @Test func otherBadRequestsAreNotAboutTools() {
        let thinking = HTTPStatusError(status: 400, headers: [:], body: Data(#"{"error":{"message":"\"llama3.2\" does not support thinking"}}"#.utf8))
        #expect(thinking.llmError(model: "llama3.2") == .invalidRequest(message: #""llama3.2" does not support thinking"#))
        let notFound = HTTPStatusError(status: 404, headers: [:],
                                       body: Data(#"{"error":{"message":"model \"llama3\" not found, try pulling it first","type":"api_error"}}"#.utf8))
        #expect(notFound.llmError(model: "llama3") == .modelNotFound(model: "llama3"))
    }

    // MARK: Providers

    @Test func anOpenAICompatibleModelWithoutToolsIsNotRetried() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(.json(status: 400, #"{"error":{"message":"registry.ollama.ai/library/gemma3:4b does not support tools","type":"api_error","param":null,"code":null}}"#))
        let provider = try OpenAICompatibleProvider(
            configuration: ProviderConfiguration(kind: .openAICompatible, apiKey: "", baseURL: Self.ollama),
            transport: server.transport(sleeps: sleeps))
        let request = LLMRequest(model: "gemma3:4b", systemPrompt: "You are Orbit.", messages: [.user("Hallo")],
                                 tools: [LLMTest.weatherTool])
        let result = await LLMTest.collect(provider.stream(request))
        #expect(result.llmError == .toolsNotSupported(model: "gemma3:4b"))
        #expect(server.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    /// A server that rejects a request without a key wants one: "no key
    /// stored" says what to do, "the key was rejected" would not.
    @Test func aServerThatWantsAKeyWithoutOneGetsTheMissingKeyError() async throws {
        let unauthorized = #"{"error":{"message":"You didn't provide an API key.","type":"invalid_request_error"}}"#
        let remote = URL(string: "https://api.openai.com/v1")
        for (key, expected) in [("", LLMError.missingAPIKey), ("sk-wrong", .invalidAPIKey)] {
            let server = MockServer()
            server.enqueue(.json(status: 401, unauthorized), .json(status: 401, unauthorized))
            let provider = try OpenAICompatibleProvider(
                configuration: ProviderConfiguration(kind: .openAICompatible, apiKey: key, baseURL: remote),
                transport: server.transport())
            let result = await LLMTest.collect(provider.stream(LLMRequest(model: "gpt-5", systemPrompt: "", messages: [.user("Hi")])))
            #expect(result.llmError == expected)
            await #expect(throws: expected) { try await provider.validateConfiguration(model: "gpt-5") }
        }
    }

    @Test func anAnthropicCompatibleServerThatWantsAKeyGetsTheMissingKeyError() async throws {
        let unauthorized = #"{"type":"error","error":{"type":"authentication_error","message":"x-api-key header is required"}}"#
        let proxy = URL(string: "https://proxy.example.com")
        for (key, expected) in [("", LLMError.missingAPIKey), ("sk-wrong", .invalidAPIKey)] {
            let server = MockServer()
            server.enqueue(.json(status: 401, unauthorized), .json(status: 401, unauthorized))
            let provider = try AnthropicProvider(
                configuration: ProviderConfiguration(kind: .anthropic, apiKey: key, baseURL: proxy),
                transport: server.transport())
            let result = await LLMTest.collect(provider.stream(LLMRequest(model: "claude-sonnet-5-5", systemPrompt: "",
                                                                         messages: [.user("Hi")])))
            #expect(result.llmError == expected)
            await #expect(throws: expected) { try await provider.validateConfiguration(model: "claude-sonnet-5-5") }
        }
    }
}
