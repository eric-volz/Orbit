import Foundation
import os
import Testing
@testable import Orbit

/// A settable clock for `AgentDependencies.now`.
final class AgentTestClock: Sendable {
    /// 2026-09-28 21:30 in Berlin (a Monday).
    static let start = FlexibleDate.parse("2026-09-28T21:30:00+02:00")!.date

    private let state = OSAllocatedUnfairLock(initialState: AgentTestClock.start)

    var now: Date {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Permission states a test can change; everything not set is granted.
/// Records what the agent loop reports through `permissionsMayHaveChanged`.
final class AgentTestPermissions: PermissionStatusProviding {
    private let state = OSAllocatedUnfairLock<(statuses: [PermissionKind: PermissionStatus], changes: [[PermissionKind]])>(
        initialState: ([:], [])
    )

    func status(of permission: PermissionKind) -> PermissionStatus {
        state.withLock { $0.statuses[permission] ?? .granted }
    }

    func set(_ status: PermissionStatus, for permission: PermissionKind) {
        state.withLock { $0.statuses[permission] = status }
    }

    func permissionsMayHaveChanged(_ permissions: [PermissionKind]) {
        state.withLock { $0.changes.append(permissions) }
    }

    /// Every `permissionsMayHaveChanged` call, in order.
    var reportedChanges: [[PermissionKind]] { state.withLock { $0.changes } }
}

/// `UserDefaults` that never touch the disk, so tests leave no preference files behind.
final class AgentTestDefaults: UserDefaults, @unchecked Sendable {
    // `values` is guarded by `lock`.
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func url(forKey url: String) -> URL? { object(forKey: url) as? URL }
    override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
    override func integer(forKey defaultName: String) -> Int { object(forKey: defaultName) as? Int ?? 0 }
    override func double(forKey defaultName: String) -> Double { object(forKey: defaultName) as? Double ?? 0 }
    override func float(forKey defaultName: String) -> Float { object(forKey: defaultName) as? Float ?? 0 }
}

/// Provider configurations the factory was asked for.
final class AgentTestConfigurationLog: Sendable {
    private let state = OSAllocatedUnfairLock<[ProviderConfiguration]>(initialState: [])
    var all: [ProviderConfiguration] { state.withLock { $0 } }
    func record(_ configuration: ProviderConfiguration) { state.withLock { $0.append(configuration) } }
}

/// An `AgentLoop` wired to mocks.
@MainActor
final class AgentHarness {
    nonisolated static let berlin = TimeZone(identifier: "Europe/Berlin")!

    let provider: MockLLMProvider
    /// What the provider factory hands out (the mock unless a test passes another).
    let servedProvider: any LLMProvider
    let store: MockConversationStore
    let settings: SettingsStore
    let secrets: InMemorySecretStore
    let permissions = AgentTestPermissions()
    let clock: AgentTestClock
    let registry: ToolRegistry
    let configurations = AgentTestConfigurationLog()
    let toolTimeout: Duration
    let userName: String?
    let claudeCodeAccount: (any ClaudeCodeAccountServicing)?
    /// What VoiceOver would hear.
    let announcer = RecordingAnnouncer()
    /// Whether the panel is shown with the keyboard (`AgentDependencies.panelHasKeyboard`).
    var panelHasKeyboard = true
    /// Reading the keychain fails (locked, or access denied).
    var keychainFails = false
    private(set) var agent: AgentLoop!

    init(tools: [any Tool] = [], scripts: [[MockLLMProvider.Step]] = [], apiKey: String? = "test-key",
         store: MockConversationStore = MockConversationStore(), clock: AgentTestClock = AgentTestClock(),
         provider: MockLLMProvider? = nil, serving: (any LLMProvider)? = nil, toolTimeout: Duration = .seconds(90),
         userName: String? = "Erika Mustermann", claudeCodeAccount: (any ClaudeCodeAccountServicing)? = nil) {
        self.claudeCodeAccount = claudeCodeAccount
        let mock = provider ?? MockLLMProvider(scripts: scripts)
        self.provider = mock
        servedProvider = serving ?? mock
        self.store = store
        self.clock = clock
        self.toolTimeout = toolTimeout
        self.userName = userName
        settings = SettingsStore(defaults: AgentTestDefaults())
        secrets = InMemorySecretStore(apiKey.map { [SecretAccount.anthropicAPIKey: $0] } ?? [:])
        registry = ToolRegistry(tools: tools)
        agent = makeAgent()
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    static func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    /// A fresh agent loop on the same mocks (e.g. to simulate a relaunch).
    func makeAgent() -> AgentLoop {
        let provider = servedProvider
        let configurations = configurations
        let clock = clock
        let userName = userName
        return AgentLoop(dependencies: AgentDependencies(
            settings: settings,
            secrets: keychainFails ? FailingSecretStore() : secrets,
            registry: registry,
            store: store,
            permissions: permissions,
            providerFactory: LLMProviderFactory { configuration in
                configurations.record(configuration)
                if configuration.kind == .anthropic, configuration.apiKey.isEmpty {
                    throw LLMError.missingAPIKey
                }
                return provider
            },
            userName: { userName },
            now: { clock.now },
            timeZone: Self.berlin,
            locale: Locale(identifier: "de_DE"),
            toolTimeout: toolTimeout,
            claudeCodeAccount: claudeCodeAccount,
            announcer: announcer,
            panelHasKeyboard: { [weak self] in self?.panelHasKeyboard ?? true }
        ))
    }

    /// Replaces `agent` with a fresh instance (relaunch).
    func relaunch() {
        agent = makeAgent()
    }

    /// Sends and waits until the run is over.
    func send(_ text: String, attachments: [ContextAttachment] = []) async {
        agent.send(text, attachments: attachments)
        await agent.waitUntilIdle()
    }

    var messages: [Message] { agent.conversation.messages }
    var requests: [LLMRequest] { provider.requests }

    var notices: [Notice] {
        agent.items.compactMap { item in
            if case .notice(let notice) = item.kind { return notice }
            return nil
        }
    }

    var statuses: [ToolStatus] {
        agent.items.compactMap { item in
            if case .toolStatus(let status) = item.kind { return status }
            return nil
        }
    }

    var cards: [ResultCard] {
        agent.items.compactMap { item in
            if case .card(let card) = item.kind { return card }
            return nil
        }
    }

    var assistantTexts: [String] {
        agent.items.compactMap { item in
            if case .assistant(let text, _) = item.kind { return text }
            return nil
        }
    }

    var confirmations: [ConfirmationState] {
        agent.items.compactMap { item in
            if case .confirmation(let state) = item.kind { return state }
            return nil
        }
    }

    var disclosures: [[ContentDisclosure]] {
        agent.items.compactMap { item in
            if case .disclosure(let items, _) = item.kind { return items }
            return nil
        }
    }

    /// The tool results the model received for `callID`.
    func result(for callID: String) -> ToolResultBlock? {
        messages.flatMap(\.toolResults).last { $0.toolCallID == callID }
    }

    /// Checks structural validity and the append-only rule for everything sent so far.
    func expectValidHistory(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(HistoryCheck.problems(in: messages) == [], sourceLocation: sourceLocation)
        let requests = requests
        for (earlier, later) in zip(requests, requests.dropFirst()) {
            #expect(HistoryCheck.isAppendOnly(earlier.messages, later.messages), sourceLocation: sourceLocation)
        }
    }
}

/// Validity rules every provider enforces.
enum HistoryCheck {
    static func problems(in messages: [Message]) -> [String] {
        var problems: [String] = []
        if let first = messages.first, first.role != .user {
            problems.append("history starts with \(first.role)")
        }
        for (index, message) in messages.enumerated() {
            if message.content.isEmpty {
                problems.append("message \(index) is empty")
            }
            for case .text(let text) in message.content where !text.contains(where: { !$0.isWhitespace }) {
                problems.append("message \(index) has a blank text block")
            }
            if index > 0, messages[index - 1].role == message.role {
                problems.append("messages \(index - 1) and \(index) are both \(message.role)")
            }
            if message.role == .user {
                // tool_result blocks come first and answer the previous assistant message.
                let results = message.toolResults
                let leading = message.content.prefix { if case .toolResult = $0 { true } else { false } }
                if leading.count != results.count {
                    problems.append("message \(index) has tool results after other content")
                }
                let expected = index > 0 ? messages[index - 1].toolCalls.map(\.id) : []
                if results.map(\.toolCallID) != expected {
                    problems.append("message \(index) answers \(results.map(\.toolCallID)) instead of \(expected)")
                }
            }
        }
        if let last = messages.last, last.role == .assistant, !last.toolCalls.isEmpty {
            problems.append("the last message has unanswered tool calls")
        }
        return problems
    }

    /// True when `later` only appends to `earlier`: every earlier message is
    /// unchanged, except that the last one may have gained trailing blocks
    /// (a user message extended by the next request).
    static func isAppendOnly(_ earlier: [Message], _ later: [Message]) -> Bool {
        guard later.count >= earlier.count else { return false }
        for index in earlier.indices {
            let old = earlier[index]
            let new = later[index]
            if index == earlier.count - 1 {
                guard old.id == new.id, old.role == new.role, old.model == new.model,
                      new.content.starts(with: old.content) else { return false }
            } else if old != new {
                return false
            }
        }
        return true
    }
}

extension Message {
    /// Text blocks of the message, in order.
    var textBlocks: [String] {
        content.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }
    }
}

/// A keychain that cannot be read.
struct FailingSecretStore: SecretStoring {
    struct Failure: Error {}

    func secret(for account: String) throws -> String? {
        throw Failure()
    }

    func setSecret(_ secret: String?, for account: String) throws {
        throw Failure()
    }
}
