// FakeLLMServer: a scripted stand-in for the Anthropic Messages API and the
// OpenAI Chat Completions API, for testing Orbit without a real provider.
//
//   Scripts/swiftpm.sh run FakeLLMServer --port 8765 --log requests.jsonl
//
// The scenario is chosen from the last user text of each request (see `usage`).
import Foundation

let usage = """
    Usage: FakeLLMServer [--port <port>] [--log <file.jsonl>] [--delay <ms>]

    Listens on 127.0.0.1/::1 (loopback only). Routes:
      POST /v1/messages           Anthropic Messages API (SSE when "stream": true)
      POST /v1/chat/completions   OpenAI Chat Completions (SSE when "stream": true)
      GET  /v1/models             model list (readable by both dialects)
      GET  /v1/models/<id>        404 for ids starting with "missing"
    API keys starting with "invalid" get HTTP 401 on every route.

    Scenario = the last text block of the last user message:
      (anything)                  Markdown echo, streamed word by word
      #markdown                   heading, lists, table, code block
      #tool <name> [json]         tool call (arguments split into 2-3 fragments); the
                                  next request with tool results gets "Tool result: …"
      #thinking …                 flag: a signed thinking block first; the next request
                                  must echo it byte-identical (THINKING_ECHO_OK/_MISMATCH)
      #redacted …                 flag: a redacted_thinking block first
      #error <status> [message]   HTTP error with an error body (retry-after for 429)
      #midstream-error            some text, then an overloaded_error event
      #refusal                    some text, then stop_reason refusal (category cyber)
      #slow                       60 words, 300 ms apart (for cancel tests)
      #maxtokens                  tool call with truncated JSON, stop_reason max_tokens
    Flags combine with commands, e.g. "#thinking #tool search_files {\\"query\\":\\"x\\"}".

    --log appends every request body as one JSON line, plus event lines
    {"event":"THINKING_ECHO_OK"|"THINKING_ECHO_MISMATCH"|"CLIENT_DISCONNECTED",…}.
    """

func fail(_ message: String) -> Never {
    printError("FakeLLMServer: \(message)\n\n\(usage)")
    exit(64)
}

var options = ServerOptions()
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--port", "-p":
        guard let value = arguments.popFirst(), let port = UInt16(value), port > 0 else { fail("--port needs a port number") }
        options.port = port
    case "--log":
        guard let value = arguments.popFirst(), !value.isEmpty else { fail("--log needs a file path") }
        options.logURL = URL(fileURLWithPath: value)
    case "--delay":
        guard let value = arguments.popFirst(), let milliseconds = Int(value), milliseconds >= 0 else {
            fail("--delay needs milliseconds")
        }
        options.chunkDelay = .milliseconds(milliseconds)
    case "--help", "-h":
        printOutput(usage)
        exit(0)
    default:
        fail("unknown argument \(argument)")
    }
}

let state: ServerState
let server: FakeLLMServer
do {
    state = try ServerState(logURL: options.logURL)
    server = try FakeLLMServer(options: options, state: state)
    try await server.start()
} catch {
    printError("FakeLLMServer: cannot start on port \(options.port): \(error)")
    exit(1)
}

printOutput("FakeLLMServer listening on http://127.0.0.1:\(options.port)"
    + (options.logURL.map { " (log: \($0.path))" } ?? ""))

// Run until SIGINT/SIGTERM, then close the log cleanly.
let signals = AsyncStream<Int32> { continuation in
    let sources = [SIGINT, SIGTERM].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { continuation.yield(signalNumber) }
        source.resume()
        return source
    }
    continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
}
for await _ in signals {
    break
}
server.stop()
await state.close()
printOutput("FakeLLMServer stopped")
exit(0)
