import Foundation
import Observation
import os

/// Everything the agent loop needs. The composition root (AppEnvironment)
/// builds the live version; tests inject mocks.
struct AgentDependencies {
    var settings: SettingsStore
    var secrets: any SecretStoring
    var registry: ToolRegistry
    var store: (any ConversationStoring)?
    var permissions: any PermissionStatusProviding
    var providerFactory: LLMProviderFactory
    /// The user's name for the system prompt (Contacts "My Card", if permitted).
    var userName: @Sendable () async -> String?
    var now: @Sendable () -> Date = { Date() }
    /// Autoupdating: Orbit runs for days, and the user may travel meanwhile.
    var timeZone: TimeZone = .autoupdatingCurrent
    /// Its region and clock are named in the system prompt (conventions for
    /// dates and numbers), not its language, which follows Orbit's interface.
    var locale: Locale = .autoupdatingCurrent
    /// How long a single tool call may run before it fails with `ToolError.timedOut`.
    var toolTimeout: Duration = .seconds(90)
    /// Status and sign-in of Claude Code (settings); nil where not available.
    var claudeCodeAccount: (any ClaudeCodeAccountServicing)? = nil
    /// VoiceOver hears every notice once, when it appears (errors interrupt),
    /// and what a request does while the keyboard stays in the input: each
    /// tool's outcome, a confirmation card that waits, the complete answer
    /// (`ChatAnnouncement`).
    var announcer: (any Announcing)? = nil
    /// Whether the panel is shown and has the keyboard: only then do keys such
    /// as ⌘↩ reach it; a waiting card's announcement names them only then (not
    /// while the panel is hidden, or while Mail's reply window has the keyboard
    /// Orbit handed it).
    var panelHasKeyboard: @MainActor () -> Bool = { true }
}

/// Runs conversations with the LLM and its tools. The UI only talks to this
/// class (and InstantSearch), never to tools or providers directly.
///
/// One `send(_:attachments:)` starts a *run*: the loop streams a model turn,
/// executes the tool calls it contains (after confirmation where required) and
/// repeats until the model answers without tools, the tool call limit is hit,
/// an error occurs or the user stops it.
///
/// Providers that run the tool loop themselves (Claude Code) call Orbit's tools
/// through a `ToolExecuting` the loop hands them; each call goes through the same
/// checks, confirmation cards, status rows and limits, and the run is recorded
/// in the history as the same alternating sequence of tool calls and results.
///
/// History rules (see LLM/Models.swift): `Conversation.messages` is append-only,
/// the system prompt and tool list are frozen with the first request, every
/// `tool_use` gets a `tool_result` in the next user message, and user messages
/// never follow each other (new content is appended to a trailing user message).
@MainActor
@Observable
final class AgentLoop {
    /// Tool calls allowed per user request, across all model turns.
    nonisolated static let maxToolCallsPerRequest = 15
    /// How often streamed text is published to the chat.
    nonisolated static let streamPublishInterval: Duration = .milliseconds(33)
    /// How long a provider's tool call waits for the stream to announce it.
    nonisolated static let announcementTimeout: Duration = .seconds(1)
    /// At launch, conversations older than this are not restored.
    nonisolated static let restoreWindow: TimeInterval = 12 * 60 * 60
    /// Characters of the first user message used as the conversation title.
    nonisolated static let titleLength = 60
    /// How long the first request waits for the user's name.
    nonisolated static let userNameTimeout: Duration = .seconds(2)

    /// Rows the chat shows, in order.
    private(set) var items: [ChatItem] = []
    /// True while a request is in flight (streaming, running tools or waiting
    /// for a confirmation).
    private(set) var isRunning = false
    /// Identifies the current conversation.
    private(set) var conversationID = UUID()
    /// The latest usage-limit state of the Claude subscription (Claude Code), if reported.
    private(set) var providerUsage: RateLimitInfo?
    /// True while "Sign In…" of a notice runs Claude Code's sign-in (`signInAndRetry()`).
    private(set) var isSigningIn = false

    @ObservationIgnored let dependencies: AgentDependencies
    /// Hands the user's decisions on confirmation cards to waiting tool calls.
    @ObservationIgnored let confirmations = ConfirmationBroker()

    /// The current conversation. Its `items` stay empty: the rows live in
    /// `items` and are merged in when saving (see `currentConversation`).
    @ObservationIgnored private(set) var conversation: Conversation
    @ObservationIgnored private var run: ActiveRun?
    /// Availability when the tool list was frozen, for the system prompt.
    @ObservationIgnored private var frozenAvailability: [ToolAvailability]?
    @ObservationIgnored private var frozenAt: Date?
    /// What the model was last told about tool availability; nil = unknown
    /// (restored conversation), so the next turn states it in full.
    @ObservationIgnored private var availabilityBaseline: AvailabilityStatement?
    /// User content in the history that no request has carried to the provider yet.
    @ObservationIgnored private var unsentDisclosures: [ContentDisclosure] = []
    /// Tool calls run for the current user request, across retries.
    @ObservationIgnored private var requestToolCallCount = 0
    /// Calls per tool name in the current user request (`Tool.maxCallsPerRequest`), across retries.
    @ObservationIgnored private var requestCallsByTool: [String: Int] = [:]
    /// What the user typed for the current request (`UserRequest`), across retries.
    @ObservationIgnored private var requestText = ""
    /// Streamed text not yet shown: deltas reach `items` at most every
    /// `streamPublishInterval`, so long chats do not re-render for every token.
    @ObservationIgnored private var pendingStreamText = ""
    @ObservationIgnored private var streamPublishTask: Task<Void, Never>?
    /// Partial output of the last failed attempt; `retry()` removes it.
    @ObservationIgnored private var failedAttemptItemIDs: Set<UUID> = []
    /// Serializes store operations so they land in order.
    @ObservationIgnored private var storeQueue: Task<Bool, Never>?
    /// Store operations enqueued but not finished yet.
    @ObservationIgnored private var pendingStoreOperations = 0
    /// Usage warnings already shown in this app session ("<window>-<threshold>").
    @ObservationIgnored private var usageWarningsShown: Set<String> = []
    /// Provider tool calls waiting until the stream announced them (see `waitForAnnouncement`).
    @ObservationIgnored private var announcementWaiters: [UUID: (callID: String, continuation: CheckedContinuation<Void, Never>)] = [:]
    /// Display name of the provider used last, with the settings it was made for.
    private var lastProvider: ProviderName?
    /// The sign-in started from a notice (`signInAndRetry()`).
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    init(dependencies: AgentDependencies) {
        self.dependencies = dependencies
        let now = dependencies.now()
        conversation = Conversation(createdAt: now, updatedAt: now)
        conversationID = conversation.id
    }

    /// True once the chat has content (the panel is in chat mode).
    var hasConversation: Bool { !items.isEmpty }

    /// The confirmation currently waiting for the user, if any.
    var pendingConfirmation: ConfirmationRequest? {
        for item in items.reversed() {
            if case .confirmation(let state) = item.kind, state.status == .pending {
                return state.request
            }
        }
        return nil
    }

    /// What a new chat carries over to its input (`AppEnvironment.startNewChat()`
    /// via ⌘N, the input's button, the menus and the notice's "New Chat"): the
    /// request the conversation could no longer answer (it no longer fits the
    /// model, or a refusal blocks it), as the user typed it, to send again or
    /// change. nil unless the chat ends with a notice that offers "New Chat".
    var requestForNewChat: String? {
        guard !isRunning, let last = items.last(where: { item in
            if case .disclosure = item.kind { return false }
            return true
        }), Self.offers(.newChat, last) else { return nil }
        return items.lazy.reversed().compactMap { item -> String? in
            if case .user(let text, _) = item.kind { return text }
            return nil
        }.first
    }

    /// Who receives content with the active provider, named like
    /// `LLMProvider.displayName` ("Claude", a host, `ProviderRecipient.localModel`).
    var providerDisplayName: String {
        let settings = dependencies.settings
        if let lastProvider, lastProvider.kind == settings.providerKind, lastProvider.baseURL == settings.baseURL {
            return lastProvider.name
        }
        switch settings.providerKind {
        case .claudeCode:
            return "Claude"
        case .anthropic:
            guard let url = settings.baseURL, url.host()?.lowercased() != AnthropicProvider.officialHost else { return "Claude" }
            return ProviderEndpoint.displayName(for: url)
        case .openAICompatible:
            return settings.baseURL.map(ProviderEndpoint.displayName(for:)) ?? ProviderRecipient.languageModel
        }
    }

    /// Tools for the settings screen.
    var toolInfos: [ToolInfo] { dependencies.registry.infos }

    /// The conversation as it is persisted (history plus chat rows).
    var currentConversation: Conversation {
        var snapshot = conversation
        snapshot.items = items
        return snapshot
    }

    // MARK: - Actions

    /// Sends a user request (plus context chips) and runs the agent loop.
    func send(_ text: String, attachments: [ContextAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let now = dependencies.now()
        // Older retry buttons would re-run a request that has been superseded.
        retireRetryActions()
        failedAttemptItemIDs = []
        items.append(ChatItem(kind: .user(text: trimmed, attachments: attachments), createdAt: now))
        if conversation.title == nil {
            conversation.title = Self.title(for: trimmed)
        }
        freezeToolListIfNeeded(at: now)
        let context = turnContext(attachments: attachments, now: now)
        appendUserContent([.text(context), .text(trimmed)])
        addDisclosures(TurnContext.disclosures(for: attachments))
        requestToolCallCount = 0
        requestCallsByTool = [:]
        // Only what the user typed: the chips come from the screen, not from the user.
        requestText = trimmed
        save()
        startRun()
    }

    /// Stops the running request (streaming, tools, pending confirmation).
    func cancel() {
        guard run != nil else { return }
        // Text still buffered belongs to the answer that is kept.
        publishStreamedText()
        guard var active = run else { return }
        run = nil
        active.task?.cancel()
        confirmations.cancelAll()
        resumeAllAnnouncementWaiters()
        // An action that was executing may still happen: say so instead of "cancelled".
        markExecutingSideEffectsUnknown(&active)

        // Keep the history valid: every tool call gets a result, and streamed
        // text is kept as a text-only answer (never partial thinking or tool use).
        if active.providerManaged {
            appendProviderHistory(of: active, includingTrailingText: true, fallback: ModelText.cancelledByUser)
        } else if let open = active.openToolCalls {
            appendToolResults(for: open, results: active.results, fallback: ModelText.cancelledByUser)
        } else {
            let partial = turnText(of: active)
            if partial.contains(where: { !$0.isWhitespace }) {
                conversation.messages.append(Message(role: .assistant, content: [.text(partial)],
                                                     createdAt: dependencies.now()))
            }
        }

        finishStreamingItems()
        closeOpenRows()
        addNotice(.info, String(localized: "Canceled."))
        appendDisclosure(active.sentDisclosures, providerName: active.providerName)
        isRunning = false
        Log.agent.info("Run cancelled after \(active.toolCallCount) tool calls")
        save()
    }

    /// App termination: stops a running request like `cancel()`, so what
    /// streamed so far is kept and saved (the caller then awaits `waitForPendingSaves()`).
    func stopForTermination() {
        guard isRunning else { return }
        cancel()
    }

    /// Resolves a pending confirmation card.
    func resolveConfirmation(_ requestID: UUID, decision: ConfirmationDecision) {
        guard let index = items.lastIndex(where: { Self.isPendingConfirmation($0, id: requestID) }),
              case .confirmation(var state) = items[index].kind else { return }
        if confirmations.resolve(requestID, decision: decision) {
            switch decision {
            case .approved(let edits):
                // "Running…" until the tool reports its outcome.
                state.status = .confirmed
                for fieldIndex in state.request.fields.indices {
                    if let value = edits[state.request.fields[fieldIndex].id] {
                        state.request.fields[fieldIndex].value = value
                    }
                }
            case .cancelled:
                state.status = .cancelled
            }
        } else {
            // Nothing waits for this card any more (e.g. restored after a relaunch).
            state.status = .expired
        }
        items[index].kind = .confirmation(state)
        save()
    }

    /// The panel has the keyboard again, because it was shown or took the keyboard
    /// back from Mail's reply window (`PanelState.keyboardDidReturn`): VoiceOver
    /// hears a card that still waits, now with the keys that decide it; said
    /// before, they would have reached another app.
    func announcePendingConfirmation() {
        guard let request = pendingConfirmation else { return }
        announce(ChatAnnouncement.confirmation(title: request.title), interrupting: true)
    }

    /// Retries the last request after a retryable error.
    func retry() {
        guard !isRunning, conversation.messages.last?.role == .user else { return }
        if let index = items.lastIndex(where: Self.isErrorNotice) {
            items.remove(at: index)
        }
        if !failedAttemptItemIDs.isEmpty {
            items.removeAll { failedAttemptItemIDs.contains($0.id) }
            failedAttemptItemIDs = []
        }
        startRun()
    }

    /// "Sign In…" of the notice that Claude Code is not signed in: runs
    /// Anthropic's own sign-in (`claude auth login`, in the browser). Once it
    /// worked, the request is sent again if the chat still ends with such a
    /// notice (a request the user replaced meanwhile is not); a failed
    /// sign-in says so in that notice.
    func signInAndRetry() {
        guard signInTask == nil, let account = dependencies.claudeCodeAccount,
              items.contains(where: { Self.offers(.signIn, $0) }) else { return }
        isSigningIn = true
        Log.agent.info("Signing in to Claude Code from a notice")
        signInTask = Task { [weak self] in
            let outcome: Result<Void, any Error>
            do {
                try await account.signIn()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self?.finishSignIn(outcome)
        }
    }

    /// Stops the sign-in `signInAndRetry()` started (the browser flow ends with it).
    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// The sign-in belongs to the account, not to a chat: it ends the notice
    /// the chat shows now (also after a new chat or message meanwhile).
    private func finishSignIn(_ outcome: Result<Void, any Error>) {
        signInTask = nil
        isSigningIn = false
        switch outcome {
        case .success:
            Log.agent.info("Claude Code sign-in finished")
            guard !isRunning, let last = items.last, Self.offers(.signIn, last) else { return }
            retry()
        case .failure(let error):
            if error is CancellationError || (error as? LLMError) == .cancelled { return }
            let llmError = error as? LLMError
            Log.agent.error("Claude Code sign-in failed: \(llmError.map(Self.logName(for:)) ?? "unexpected", privacy: .public)")
            guard let index = items.lastIndex(where: { Self.offers(.signIn, $0) }),
                  case .notice(var notice) = items[index].kind else { return }
            notice.message = llmError.flatMap { $0 == .claudeCodeNotLoggedIn ? nil : $0.userMessage }
                ?? String(localized: "Sign-in was not completed. Please try again.")
            items[index].kind = .notice(notice)
            dependencies.announcer?.announce(notice.message, priority: .high)
            save()
        }
    }

    /// Starts a new, empty chat. The previous one stays in the history store but
    /// is not restored at the next launch.
    func newChat() {
        // A running chat is saved by cancel(); an idle one was saved when its run ended.
        cancel()
        if !(items.isEmpty && conversation.messages.isEmpty) {
            dependencies.settings.dismissedConversationID = conversation.id
        }
        resetConversation()
    }

    /// Restores the most recent conversation at launch, if it was active within
    /// the last 12 hours.
    func restoreMostRecentConversation() async {
        guard let store = dependencies.store else { return }
        let stored: Conversation?
        do {
            stored = try await store.mostRecent()
        } catch {
            Log.storage.error("Loading the last conversation failed: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        guard var restored = stored, !restored.isEmpty, restored.id != dependencies.settings.dismissedConversationID,
              dependencies.now().timeIntervalSince(restored.updatedAt) <= Self.restoreWindow else { return }
        // The user may have started a chat while the store was loading.
        guard !isRunning, items.isEmpty, conversation.messages.isEmpty else { return }

        // Calls whose card was never confirmed certainly did not run.
        var notRun: Set<String> = []
        var declined: Set<String> = []
        for item in restored.items {
            guard case .confirmation(let state) = item.kind, !state.request.toolCallID.isEmpty else { continue }
            switch state.status {
            case .pending, .expired: notRun.insert(state.request.toolCallID)
            case .cancelled: declined.insert(state.request.toolCallID)
            default: break
            }
        }
        let restoredItems = Self.sanitized(restored.items)
        let restoredMessages = Self.closingDanglingToolCalls(in: restored.messages, now: dependencies.now(),
                                                             notRun: notRun, declined: declined)
        let needsSave = restoredItems != restored.items || restoredMessages != restored.messages
        restored.items = []
        restored.messages = restoredMessages
        resetConversation()
        conversation = restored
        conversationID = restored.id
        items = restoredItems
        // Content that entered the history but was never sent still gets its note.
        unsentDisclosures = restored.pendingDisclosures ?? []
        Log.agent.info("Restored a conversation with \(restoredMessages.count) messages")
        if needsSave { save() }
    }

    /// Deletes all stored chats and starts a new one. Returns whether the
    /// store was cleared; the caller (Settings) reports a failure.
    @discardableResult
    func clearHistory() async -> Bool {
        cancel()
        // Not saved: the old chat is about to be deleted.
        resetConversation()
        guard let store = dependencies.store else { return true }
        return await enqueueStoreOperation { try await store.deleteAll() }.value
    }

    /// Validates a provider configuration for the settings "Test" button.
    func validate(configuration: ProviderConfiguration, model: String) async throws {
        let provider = try dependencies.providerFactory.make(configuration)
        try await provider.validateConfiguration(model: model)
    }

    /// Claude Code's installation and sign-in state (settings); nil when not available.
    func claudeCodeStatus() async -> ClaudeCodeStatus? {
        await dependencies.claudeCodeAccount?.status()
    }

    /// Signs in to Claude Code through Anthropic's own flow (opens the browser).
    func signInToClaudeCode() async throws {
        guard let account = dependencies.claudeCodeAccount else { throw LLMError.claudeCodeNotInstalled }
        try await account.signIn()
    }

    /// Whether chat saves are still queued or running.
    var hasPendingSaves: Bool { pendingStoreOperations > 0 }

    /// Waits until all queued store operations are done (tests, termination).
    func waitForPendingSaves() async {
        _ = await storeQueue?.value
    }

    /// Waits until the running request, if any, has finished or stopped.
    func waitUntilIdle() async {
        while let task = run?.task {
            await task.value
            if run?.task == task { return }
        }
    }

    // MARK: - Run

    private struct ActiveRun {
        let id = UUID()
        var task: Task<Void, Never>?
        let startedAt = ContinuousClock.now
        /// Name of the provider serving this run (for the disclosure note).
        var providerName: String?
        /// Where this run's requests go (for the wording of an error).
        var destination: ProviderDestination?
        /// The usage warning this run showed: a usage-limit error replaces it.
        var usageNoticeID: UUID?
        /// Tool calls run in this run (for the log; the budget is per request).
        var toolCallCount = 0
        /// Calls of non-read tools that are executing right now (by result slot):
        /// if the run stops, their outcome is unknown.
        var executingSideEffects: [Int: ExecutingCall] = [:]
        /// User content carried to the provider during this run.
        var sentDisclosures: [ContentDisclosure] = []
        /// Rows created while the current model turn streams (answer text,
        /// progress notes), in order.
        var turnItemIDs: [UUID] = []
        var streamingItemID: UUID?
        /// Tool calls of the last assistant message that have no results in the
        /// history yet, and the results collected for them so far (by position:
        /// providers do not always guarantee unique call ids).
        var openToolCalls: [ToolCall]?
        var results: [Int: ToolResultBlock] = [:]
        /// The provider runs the tool loop itself (see `executeProviderToolCall`).
        var providerManaged = false
        /// Provider-managed runs: answer text and tool calls in order, for the
        /// history. A call's result is `results[index]`.
        var segments: [RunSegment] = []
        /// Provider-managed runs: result slot of the next tool call.
        var nextCallIndex = 0
        var toolLimitNoticeShown = false
        /// Permissions whose notice ("Orbit is not allowed to control Mail.") this run showed.
        var permissionNoticesShown: Set<PermissionKind> = []
        /// Provider-managed runs: tool calls the stream announced (`.toolCallStarted`).
        var announcedCallIDs: Set<String> = []
    }

    private enum RunSegment {
        case text(String)
        case toolCall(ToolCall, index: Int)
    }

    private struct ExecutingCall {
        var callID: String
        var statusID: UUID
        var confirmationID: UUID?
    }

    private struct ProviderSession {
        var provider: any LLMProvider
        var model: String
        var effort: ReasoningEffort?
        /// Who receives the history (see `recipientKey`).
        var recipient: String
        var destination: ProviderDestination
    }

    private struct ProviderName: Equatable {
        var kind: ProviderKind
        var baseURL: URL?
        var name: String
    }

    private enum TurnOutcome {
        case finished
        /// The turn was appended and asks for these tools.
        case toolCalls([ToolCall], StopReason)
    }

    private func startRun() {
        let active = ActiveRun()
        let runID = active.id
        run = active
        isRunning = true
        run?.task = Task { [weak self] in
            await self?.execute(runID: runID)
        }
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        run?.id == runID
    }

    private func execute(runID: UUID) async {
        await buildSystemPromptIfNeeded(runID: runID)
        guard isCurrent(runID) else { return }

        let session: ProviderSession
        do {
            session = try await makeProviderSession()
        } catch {
            guard isCurrent(runID) else { return }
            fail(with: error)
            return
        }
        guard isCurrent(runID) else { return }
        run?.providerName = session.provider.displayName
        run?.destination = session.destination
        let providerManaged = session.provider.executesToolsInternally
        run?.providerManaged = providerManaged

        while isCurrent(runID) {
            let request = LLMRequest(
                model: session.model,
                systemPrompt: conversation.systemPrompt ?? "",
                messages: conversation.messages,
                tools: frozenToolDefinitions(),
                maxTokens: nil,
                effort: session.effort,
                conversationID: conversation.id,
                toolExecutor: providerManaged ? ProviderToolExecutor(loop: self, runID: runID) : nil
            )
            noteRecipient(session.recipient)
            run?.sentDisclosures += unsentDisclosures
            unsentDisclosures = []

            let turn: AssistantTurn
            do {
                turn = try await streamTurn(session.provider, request: request, runID: runID)
            } catch {
                guard isCurrent(runID) else { return }
                fail(with: error)
                return
            }
            guard isCurrent(runID) else { return }

            if providerManaged {
                // The provider already ran the tools; `turn` ends the whole run.
                completeProviderRun(turn)
                finishRun()
                return
            }

            switch completeTurn(turn) {
            case .finished:
                finishRun()
                return

            case .toolCalls(let calls, let stopReason):
                if stopReason == .contextWindowExceeded {
                    closeOpenToolCalls(fallback: ModelText.contextWindowFull)
                    addNotice(.warning, Self.contextFullMessage, actions: [.newChat])
                    finishRun()
                    return
                }
                let allowed = max(0, Self.maxToolCallsPerRequest - requestToolCallCount)
                guard allowed > 0 else {
                    closeOpenToolCalls(fallback: ModelText.toolLimitReached)
                    addToolLimitNotice()
                    finishRun()
                    return
                }
                if stopReason == .maxTokens {
                    // The calls may be incomplete; let the model try again. They
                    // count toward the budget, which bounds this loop.
                    requestToolCallCount += min(calls.count, allowed)
                    closeOpenToolCalls(fallback: ModelText.outputCutOff)
                    save()
                    continue
                }
                // Calls beyond the budget are not run; the ones before them are.
                for index in calls.indices where index >= allowed {
                    record(ToolResultBlock(toolCallID: calls[index].id, content: ModelText.toolLimitReached, isError: true),
                           at: index)
                }
                let runnable = Array(calls.prefix(allowed))
                requestToolCallCount += runnable.count
                run?.toolCallCount += runnable.count
                guard await runTools(runnable, runID: runID) else { return }
                if runnable.count < calls.count {
                    addToolLimitNotice()
                    finishRun()
                    return
                }
            }
        }
    }

    /// Freezes the system prompt with the first request of the conversation.
    private func buildSystemPromptIfNeeded(runID: UUID) async {
        guard conversation.systemPrompt == nil else { return }
        let userName = await Self.lookUpUserName(dependencies.userName, timeout: Self.userNameTimeout)
        guard isCurrent(runID), conversation.systemPrompt == nil else { return }
        conversation.systemPrompt = SystemPrompt.build(
            now: frozenAt ?? dependencies.now(),
            timeZone: dependencies.timeZone,
            locale: dependencies.locale,
            userName: userName,
            tools: frozenAvailability ?? currentAvailability()
        )
    }

    private func makeProviderSession() async throws -> ProviderSession {
        let settings = dependencies.settings
        var configuration = settings.providerConfiguration(apiKey: "")
        let model = settings.model
        let effort = settings.effort
        if configuration.kind.usesAPIKey {
            configuration.apiKey = try await Self.readAPIKey(from: dependencies.secrets,
                                                             account: SecretAccount.apiKey(for: configuration.kind))
        }
        let provider = try dependencies.providerFactory.make(configuration)
        lastProvider = ProviderName(kind: configuration.kind, baseURL: configuration.baseURL, name: provider.displayName)
        return ProviderSession(provider: provider, model: model, effort: effort,
                               recipient: Self.recipientKey(kind: configuration.kind, baseURL: configuration.baseURL),
                               destination: ProviderDestination(kind: configuration.kind, baseURL: configuration.baseURL))
    }

    /// Streams one model turn into the chat and returns it once complete.
    private func streamTurn(_ provider: any LLMProvider, request: LLMRequest, runID: UUID) async throws -> AssistantTurn {
        for try await event in provider.stream(request) {
            guard isCurrent(runID) else { throw CancellationError() }
            switch event {
            case .textDelta(let delta):
                appendStreamedText(delta)
                appendSegmentText(delta)
            case .progressNote(let note):
                addProgressNote(note)
            case .toolCallStarted(let id, _):
                // The text before a tool call is complete.
                finishStreamingItems()
                announceToolCall(id)
            case .toolCall:
                break
            case .historyThinkingStripped:
                stripThinkingFromHistory()
            case .rateLimit(let info):
                updateProviderUsage(info)
            case .end(let turn):
                return turn
            }
        }
        guard isCurrent(runID), !Task.isCancelled else { throw CancellationError() }
        throw LLMError.invalidResponse(detail: "The stream ended without a final event.")
    }

    /// Records a finished model turn in the history and the chat.
    private func completeTurn(_ turn: AssistantTurn) -> TurnOutcome {
        finishStreamingItems()

        if case .refusal = turn.stopReason {
            // Partial output of a refused turn is discarded; nothing is appended,
            // and the refused request leaves the history (see Models.swift).
            Log.agent.notice("The model refused the request")
            removeTurnItems()
            addRefusalNotice(removedRequest: dropRefusedRequest())
            return .finished
        }

        let calls = turn.toolCalls
        let hasText = turn.text.contains { !$0.isWhitespace }
        guard hasText || !calls.isEmpty else {
            // Nothing usable (e.g. only reasoning). Not appended, so the history
            // still ends with the user's message and the request can be retried.
            removeTurnItems()
            addNoAnswerNotice(turn.stopReason)
            return .finished
        }

        if hasText, run?.turnItemIDs.isEmpty == true {
            // The provider delivered the text without streaming it.
            items.append(ChatItem(kind: .assistant(text: turn.text, isStreaming: false), createdAt: dependencies.now()))
        }
        conversation.messages.append(Message(role: .assistant, content: turn.content,
                                             createdAt: dependencies.now(), model: turn.model))
        run?.turnItemIDs = []

        guard !calls.isEmpty else {
            // The answer is complete: VoiceOver reads it (before a notice about it).
            announce(ChatAnnouncement.answer(turn.text))
            switch turn.stopReason {
            case .maxTokens:
                addNotice(.info, Self.cutShortMessage)
            case .contextWindowExceeded:
                addNotice(.warning, Self.contextFullMessage, actions: [.newChat])
            default:
                break
            }
            return .finished
        }
        run?.openToolCalls = calls
        run?.results = [:]
        save()
        return .toolCalls(calls, turn.stopReason)
    }

    // MARK: - Provider-managed tool loop

    /// A tool call from a provider that runs the tool loop itself: the same
    /// checks, confirmation card, status row, card, disclosure and truncation as
    /// `runTools`, and the same per-request budget: once it is used up, further
    /// calls get an error result so the model answers with what it has.
    fileprivate func executeProviderToolCall(_ call: ToolCall, runID: UUID) async -> ToolResultBlock {
        let stopped = ToolResultBlock(toolCallID: call.id, content: ModelText.cancelledByUser, isError: true)
        // The call may arrive before the stream delivered the text written before it.
        await waitForAnnouncement(of: call.id, runID: runID)
        guard isCurrent(runID), run?.providerManaged == true, let index = run?.nextCallIndex else { return stopped }
        run?.nextCallIndex = index + 1
        // The text before the call is complete; it is no longer a failed attempt's output.
        finishStreamingItems()
        run?.turnItemIDs = []
        run?.segments.append(.toolCall(call, index: index))

        if requestToolCallCount >= Self.maxToolCallsPerRequest {
            record(ToolResultBlock(toolCallID: call.id, content: ModelText.toolLimitReachedForProvider, isError: true), at: index)
            if run?.toolLimitNoticeShown == false {
                run?.toolLimitNoticeShown = true
                Log.agent.notice("Tool call limit reached")
                addNotice(.warning, String(format: String(localized: "Orbit stopped running tools after %lld tool calls. Make your request more specific if the answer is incomplete."), Self.maxToolCallsPerRequest))
            }
        } else {
            requestToolCallCount += 1
            run?.toolCallCount += 1
            switch check(call, index: index) {
            case .run(let plan):
                await runSequentially(plan, runID: runID)
            case .reject(let rejection):
                reject(rejection, callID: call.id)
            }
        }
        guard isCurrent(runID), let result = run?.results[index] else { return stopped }
        // The result goes to the provider right away, with what it discloses.
        run?.sentDisclosures += unsentDisclosures
        unsentDisclosures = []
        save()
        return result
    }

    /// Suspends until the stream announced `callID`, so everything streamed
    /// before the call is recorded before it. Gives up after
    /// `announcementTimeout` (a provider that announces calls under other ids).
    private func waitForAnnouncement(of callID: String, runID: UUID) async {
        guard isCurrent(runID), run?.providerManaged == true, run?.announcedCallIDs.contains(callID) == false else { return }
        let waiterID = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.announcementTimeout)
            self?.resumeAnnouncementWaiter(waiterID)
        }
        await withCheckedContinuation { continuation in
            announcementWaiters[waiterID] = (callID, continuation)
        }
        timeout.cancel()
    }

    private func announceToolCall(_ callID: String) {
        guard run?.providerManaged == true else { return }
        run?.announcedCallIDs.insert(callID)
        for (waiterID, waiter) in announcementWaiters where waiter.callID == callID {
            resumeAnnouncementWaiter(waiterID)
        }
    }

    private func resumeAnnouncementWaiter(_ waiterID: UUID) {
        announcementWaiters.removeValue(forKey: waiterID)?.continuation.resume()
    }

    /// Lets waiting tool calls go on (they see that their run ended).
    private func resumeAllAnnouncementWaiters() {
        for waiterID in Array(announcementWaiters.keys) {
            resumeAnnouncementWaiter(waiterID)
        }
    }

    /// Records streamed answer text of a provider-managed run.
    private func appendSegmentText(_ delta: String) {
        guard run?.providerManaged == true, !delta.isEmpty else { return }
        if let last = run?.segments.indices.last, case .text(let text)? = run?.segments[last] {
            run?.segments[last] = .text(text + delta)
        } else {
            run?.segments.append(.text(delta))
        }
    }

    /// Records the end of a provider-managed run. Its tool calls already ran;
    /// the history gets them with their results, then the final answer.
    private func completeProviderRun(_ turn: AssistantTurn) {
        finishStreamingItems()
        guard var active = run else { return }

        if case .refusal = turn.stopReason {
            Log.agent.notice("The model refused the request")
            removeTurnItems()
            let ranTools = active.segments.contains { if case .toolCall = $0 { true } else { false } }
            if ranTools {
                // The tools ran, so they stay; the refused answer after them does not.
                appendProviderHistory(of: active, includingTrailingText: false, fallback: ModelText.unexpectedFailure,
                                      model: turn.model)
            }
            addRefusalNotice(removedRequest: !ranTools && dropRefusedRequest())
            return
        }

        let hasCalls = active.segments.contains { if case .toolCall = $0 { true } else { false } }
        let hasStreamedText = active.segments.contains { segment in
            if case .text(let text) = segment { text.contains { !$0.isWhitespace } } else { false }
        }
        if !hasStreamedText, !hasCalls, turn.text.contains(where: { !$0.isWhitespace }) {
            // The provider delivered the answer without streaming it.
            items.append(ChatItem(kind: .assistant(text: turn.text, isStreaming: false), createdAt: dependencies.now()))
            active.segments = [.text(turn.text)]
        } else if !hasStreamedText, !hasCalls {
            removeTurnItems()
            addNoAnswerNotice(turn.stopReason)
            return
        }

        appendProviderHistory(of: active, includingTrailingText: true, fallback: ModelText.unexpectedFailure,
                              model: turn.model)
        run?.turnItemIDs = []
        // The answer after the last tool call is complete: VoiceOver reads it.
        announce(ChatAnnouncement.answer(Self.trailingText(of: active.segments)))
        switch turn.stopReason {
        case .maxTokens:
            addNotice(.info, Self.cutShortMessage)
        case .contextWindowExceeded:
            addNotice(.warning, Self.contextFullMessage, actions: [.newChat])
        default:
            break
        }
    }

    /// Appends a provider-managed run to the history as API providers would
    /// have produced it: assistant (text, tool calls) → user (their results) → …
    /// → assistant (final text). Calls without a result get `fallback`.
    private func appendProviderHistory(of active: ActiveRun, includingTrailingText: Bool, fallback: String,
                                       model: String? = nil) {
        let now = dependencies.now()
        var text = ""
        var calls: [ToolCall] = []
        var results: [ToolResultBlock] = []
        func appendCalls() {
            guard !calls.isEmpty else { return }
            var content: [ContentBlock] = text.contains(where: { !$0.isWhitespace }) ? [.text(text)] : []
            content += calls.map(ContentBlock.toolUse)
            conversation.messages.append(Message(role: .assistant, content: content, createdAt: now, model: model))
            appendUserContent(results.map(ContentBlock.toolResult))
            text = ""
            calls = []
            results = []
        }
        for segment in active.segments {
            switch segment {
            case .text(let fragment):
                appendCalls()
                text += fragment
            case .toolCall(let call, let index):
                calls.append(call)
                results.append(active.results[index] ?? ToolResultBlock(toolCallID: call.id, content: fallback, isError: true))
            }
        }
        appendCalls()
        if includingTrailingText, text.contains(where: { !$0.isWhitespace }) {
            conversation.messages.append(Message(role: .assistant, content: [.text(text)], createdAt: now, model: model))
        }
    }

    // MARK: - Usage

    /// Remembers the subscription's usage state and warns once per window when
    /// it gets close to the limit.
    private func updateProviderUsage(_ info: RateLimitInfo) {
        providerUsage = info
        guard let threshold = ProviderUsage.warningThreshold(for: info) else { return }
        let key = "\(info.window ?? "unknown")-\(threshold)"
        guard usageWarningsShown.insert(key).inserted else { return }
        run?.usageNoticeID = addNotice(.info, ProviderUsage.warningMessage(for: info))
    }

    private func finishRun() {
        guard let active = run else { return }
        run = nil
        resumeAllAnnouncementWaiters()
        appendDisclosure(active.sentDisclosures, providerName: active.providerName)
        isRunning = false
        let duration = ContinuousClock.now - active.startedAt
        Log.agent.info("Run finished: \(active.toolCallCount) tool calls in \(duration.components.seconds) s")
        save()
    }

    /// Shows an error notice and ends the run. The history is not touched, so
    /// it still ends with the user message (or tool results) and `retry()` can
    /// re-run the loop.
    private func fail(with error: any Error) {
        finishStreamingItems()
        if var active = run, active.providerManaged {
            // Tools that already ran stay in the history (they happened); the
            // unfinished answer after them does not, so `retry()` can continue.
            confirmations.cancelAll()
            markExecutingSideEffectsUnknown(&active)
            run = active
            appendProviderHistory(of: active, includingTrailingText: false, fallback: ModelText.unexpectedFailure)
            closeOpenRows()
        }
        failedAttemptItemIDs = Set(run?.turnItemIDs ?? [])
        run?.turnItemIDs = []
        if let reported = error as? LLMError {
            let llmError = withKnownReset(reported)
            Log.agent.error("Request failed: \(Self.logName(for: llmError), privacy: .public)")
            if case .usageLimitReached = llmError, let warning = run?.usageNoticeID {
                // One notice: the error says the same, and when the limit resets.
                items.removeAll { $0.id == warning }
            }
            // nil when the provider could not be created (a missing key, an invalid address).
            let destination = run?.destination
            addNotice(.error, llmError.userMessage(for: destination),
                      actions: Self.noticeActions(for: llmError, destination: destination))
        } else {
            Log.agent.error("Request failed: \(String(describing: type(of: error)), privacy: .public)")
            addNotice(.error, String(localized: "An unexpected error occurred. Please try again."),
                      actions: [.retry])
        }
        finishRun()
    }

    /// A usage limit without its reset time (e.g. reported only in Claude
    /// Code's output) gets the one Claude Code sent with the rejection.
    private func withKnownReset(_ error: LLMError) -> LLMError {
        guard case .usageLimitReached(resetsAt: nil) = error, let usage = providerUsage, usage.isRejected,
              let reset = usage.resetsAt, reset > dependencies.now() else { return error }
        return .usageLimitReached(resetsAt: reset)
    }

    // MARK: - Tools

    /// A tool call that passed all checks. `index` is its position in the turn.
    private struct ToolPlan {
        var index: Int
        var call: ToolCall
        var tool: any Tool
        var arguments: ToolArguments
        /// This call's risk level (`Tool.review(_:for:)`): it decides about the card.
        var riskLevel: ToolRiskLevel
        /// The confirmation card the user approved, if the tool needed one.
        var confirmationID: UUID?
    }

    /// A tool call that is not run.
    private struct Rejection {
        var index: Int
        var modelMessage: String
        /// Status line for problems the user can fix; nil = no line.
        var status: (tool: any Tool, text: String)?
        /// The macOS permission whose absence refused the call.
        var missingPermission: PermissionKind?
    }

    private enum CallCheck {
        case run(ToolPlan)
        case reject(Rejection)
    }

    private enum Confirmation {
        case approved(ToolArguments, resultPrefix: String, requestID: UUID)
        /// Declined or invalid after editing; the result is recorded.
        case notApproved
        /// The run was stopped while waiting.
        case interrupted
    }

    /// Runs one batch of tool calls and appends their results. Returns false
    /// when the run was stopped meanwhile.
    private func runTools(_ calls: [ToolCall], runID: UUID) async -> Bool {
        let checks = calls.enumerated().map { index, call in check(call, index: index) }
        let plans = checks.compactMap { check -> ToolPlan? in
            if case .run(let plan) = check { return plan }
            return nil
        }

        if plans.count > 1, plans.allSatisfy({ $0.riskLevel == .read }) {
            // Status lines in call order first, then all calls at once.
            var statusIDs: [Int: UUID] = [:]
            for check in checks {
                switch check {
                case .run(let plan):
                    statusIDs[plan.index] = appendStatus(for: plan.tool, callID: plan.call.id,
                                                         text: plan.tool.statusText(for: plan.arguments), state: .running)
                case .reject(let rejection):
                    reject(rejection, callID: calls[rejection.index].id)
                }
            }
            await runConcurrently(plans, statusIDs: statusIDs, runID: runID)
        } else {
            for check in checks {
                guard isCurrent(runID) else { return false }
                switch check {
                case .run(let plan):
                    await runSequentially(plan, runID: runID)
                case .reject(let rejection):
                    reject(rejection, callID: calls[rejection.index].id)
                }
            }
        }
        guard isCurrent(runID) else { return false }
        closeOpenToolCalls(fallback: ModelText.unexpectedFailure)
        save()
        return true
    }

    private func check(_ call: ToolCall, index: Int) -> CallCheck {
        func rejected(_ message: String, status: (tool: any Tool, text: String)? = nil,
                      missingPermission: PermissionKind? = nil) -> CallCheck {
            .reject(Rejection(index: index, modelMessage: message, status: status, missingPermission: missingPermission))
        }
        guard let tool = dependencies.registry.tool(named: call.name) else {
            return rejected(ModelText.unknownTool(call.name, available: usableToolNames()))
        }
        if call.inputParseError != nil {
            return rejected(ModelText.invalidJSON(call.rawInput ?? ""))
        }
        guard conversation.toolNames?.contains(tool.name) == true else {
            return rejected(ModelText.notInThisChat(tool.name), status: (tool, String(localized: "Not turned on in this chat")))
        }
        guard dependencies.settings.isToolEnabled(tool.name) else {
            return rejected(ModelText.disabledByUser(tool.name), status: (tool, String(localized: "Turned off in Settings")))
        }
        if let missing = tool.requiredPermissions.first(where: { !dependencies.permissions.status(of: $0).allowsUse }) {
            return rejected(ToolError.permissionDenied(missing).modelMessage,
                            status: (tool, String(format: String(localized: "Missing permission: %@"), missing.displayName)),
                            missingPermission: missing)
        }
        let validation = tool.inputSchema.validate(call.input)
        guard validation.isValid else {
            return rejected(ModelText.invalidArguments(validation.errors))
        }
        if let limit = tool.maxCallsPerRequest {
            let used = requestCallsByTool[tool.name, default: 0]
            guard used < limit else {
                return rejected(ModelText.callLimitReached(tool.name, limit: limit),
                                status: (tool, String(format: String(localized: "At most %lld times per request"), limit)))
            }
            requestCallsByTool[tool.name] = used + 1
        }
        let reviewed = tool.review(ToolArguments(json: validation.value), for: UserRequest(text: requestText))
        return .run(ToolPlan(index: index, call: call, tool: tool, arguments: reviewed.arguments, riskLevel: reviewed.riskLevel))
    }

    private func reject(_ rejection: Rejection, callID: String) {
        record(ToolResultBlock(toolCallID: callID, content: rejection.modelMessage, isError: true), at: rejection.index)
        if let status = rejection.status {
            appendStatus(for: status.tool, callID: callID, text: status.text, state: .failed)
        }
        if let permission = rejection.missingPermission {
            // The notice says it (and is announced), once.
            addPermissionNotice(permission)
        } else if let status = rejection.status {
            announce(ChatAnnouncement.toolFinished(toolName: status.tool.displayName, status: status.text, failed: true,
                                                   hasSummary: true))
        }
    }

    /// Once per run and permission: what macOS does not allow, with a button that opens
    /// Settings on Permissions.
    private func addPermissionNotice(_ permission: PermissionKind) {
        guard run?.permissionNoticesShown.contains(permission) == false else { return }
        run?.permissionNoticesShown.insert(permission)
        addNotice(.info, Self.permissionNotice(for: permission), actions: [.openPermissionSettings])
    }

    private func runSequentially(_ plan: ToolPlan, runID: UUID) async {
        var plan = plan
        var resultPrefix = ""
        if plan.riskLevel.requiresConfirmation {
            switch await confirm(plan, runID: runID) {
            case .approved(let arguments, let prefix, let requestID):
                plan.arguments = arguments
                plan.confirmationID = requestID
                resultPrefix = prefix
            case .notApproved, .interrupted:
                return
            }
        }
        let statusID = appendStatus(for: plan.tool, callID: plan.call.id,
                                    text: plan.tool.statusText(for: plan.arguments), state: .running)
        if plan.riskLevel != .read {
            run?.executingSideEffects[plan.index] = ExecutingCall(callID: plan.call.id, statusID: statusID,
                                                                  confirmationID: plan.confirmationID)
        }
        let outcome = await Self.perform(plan.tool, arguments: plan.arguments, timeout: deadline(for: plan.tool))
        guard isCurrent(runID) else { return }
        run?.executingSideEffects[plan.index] = nil
        complete(plan, statusID: statusID, outcome: outcome, resultPrefix: resultPrefix)
    }

    /// Independent read-only calls run at the same time; results keep call order.
    private func runConcurrently(_ plans: [ToolPlan], statusIDs: [Int: UUID], runID: UUID) async {
        await withTaskGroup(of: (Int, ToolOutcome).self) { group in
            for (position, plan) in plans.enumerated() {
                let tool = plan.tool
                let arguments = plan.arguments
                let timeout = deadline(for: tool)
                group.addTask {
                    (position, await Self.perform(tool, arguments: arguments, timeout: timeout))
                }
            }
            for await (position, outcome) in group where isCurrent(runID) {
                let plan = plans[position]
                guard let statusID = statusIDs[plan.index] else { continue }
                complete(plan, statusID: statusID, outcome: outcome, resultPrefix: "")
            }
        }
    }

    /// How long a run of `tool` may take: the loop's deadline, or the tool's
    /// own when it needs longer (`Tool.executionTimeout`).
    private func deadline(for tool: any Tool) -> Duration {
        max(dependencies.toolTimeout, tool.executionTimeout ?? .zero)
    }

    /// Shows the confirmation card and waits for the user's decision. The tool
    /// first checks and completes the arguments (`prepareForConfirmation`): a
    /// call it refuses gets no card, and the card shows the completed values.
    /// After edits the tool checks the edited values again before it runs.
    private func confirm(_ plan: ToolPlan, runID: UUID) async -> Confirmation {
        let prepared: ToolArguments
        switch await Self.prepare(plan.tool, arguments: plan.arguments, timeout: dependencies.toolTimeout) {
        case .prepared(let arguments):
            guard isCurrent(runID) else { return .interrupted }
            prepared = arguments
        case .refused(let refusal):
            guard isCurrent(runID) else { return .interrupted }
            refuseBeforeConfirmation(plan, refusal)
            return .notApproved
        }

        var request = plan.tool.confirmationRequest(for: prepared)
        request.id = UUID()
        request.toolCallID = plan.call.id
        request.toolName = plan.tool.name
        request.riskLevel = plan.riskLevel
        items.append(ChatItem(kind: .confirmation(ConfirmationState(request: request, status: .pending)),
                              createdAt: dependencies.now()))
        save()
        // The keyboard stays in the input: VoiceOver says that a card waits and how to decide it, with its keys
        // only while the panel has the keyboard (they would reach another app; see `announcePendingConfirmation`).
        announce(ChatAnnouncement.confirmation(title: request.title, hasKeyboard: dependencies.panelHasKeyboard()),
                 interrupting: true)

        let decision = await confirmations.request(request)
        guard isCurrent(runID) else { return .interrupted }

        switch decision {
        case .cancelled:
            setConfirmationStatus(request.id, .cancelled)
            record(ToolResultBlock(toolCallID: plan.call.id, content: ModelText.declined, isError: false), at: plan.index)
            appendStatus(for: plan.tool, callID: plan.call.id, text: String(localized: "Not run"), state: .cancelled)
            return .notApproved

        case .approved(let edits):
            // The card shows "Running…" (set when the user clicked) until the outcome is known.
            setConfirmationStatus(request.id, .confirmed)
            guard !edits.isEmpty else { return .approved(prepared, resultPrefix: "", requestID: request.id) }
            // Tool-private values (e.g. the calendar the card names) are no parameters: edits never
            // change them, the schema checks the parameters only, and the tool's check gets them back.
            let edited = plan.tool.applyingEdits(edits.filter { !ToolArguments.isPrivateKey($0.key) }, to: prepared)
            let validation = plan.tool.inputSchema.validate(.object(edited.parameters.values))
            guard validation.isValid else {
                notRunAfterEdits(plan, requestID: request.id, message: ModelText.invalidEdits(validation.errors))
                return .notApproved
            }
            var editedArguments = ToolArguments(json: validation.value)
            editedArguments.values.merge(prepared.privateValues) { parameter, _ in parameter }
            // The tool checks the edited values too (e.g. that an event still ends after it starts).
            switch await Self.prepare(plan.tool, arguments: editedArguments, timeout: dependencies.toolTimeout) {
            case .prepared(let checked):
                guard isCurrent(runID) else { return .interrupted }
                return .approved(checked, resultPrefix: ModelText.editedValues(edits), requestID: request.id)
            case .refused(let refusal):
                guard isCurrent(runID) else { return .interrupted }
                if refusal.isInvalidArgument {
                    notRunAfterEdits(plan, requestID: request.id, message: ModelText.invalidEdits([refusal.detail]))
                } else {
                    // Not the edited values: what the card showed no longer holds (e.g. another output device).
                    notRunAfterEdits(plan, requestID: request.id, message: ModelText.refusedAfterEdits(refusal.modelMessage),
                                     status: refusal.statusText)
                }
                addDisclosures(refusal.disclosures)
                if let permission = refusal.missingPermission {
                    dependencies.permissions.permissionsMayHaveChanged([permission])
                    addPermissionNotice(permission)
                }
                return .notApproved
            }
        }
    }

    /// The tool refused the call before its card appeared: the model gets the
    /// reason, the chat a status row (and, for a missing permission, the notice)
    /// and VoiceOver hears one of them.
    private func refuseBeforeConfirmation(_ plan: ToolPlan, _ refusal: PreparationRefusal) {
        Log.tools.error("\(plan.tool.name, privacy: .public) refused before confirmation (\(refusal.logName, privacy: .public))")
        record(ToolResultBlock(toolCallID: plan.call.id, content: refusal.modelMessage, isError: true), at: plan.index)
        appendStatus(for: plan.tool, callID: plan.call.id, text: refusal.statusText, state: .failed)
        addDisclosures(refusal.disclosures)
        if let permission = refusal.missingPermission {
            dependencies.permissions.permissionsMayHaveChanged([permission])
            addPermissionNotice(permission)
        } else {
            announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: refusal.statusText, failed: true,
                                                   hasSummary: true))
        }
    }

    /// Edited values the tool cannot use (or what the card showed no longer
    /// holds): nothing runs, the card says so.
    private func notRunAfterEdits(_ plan: ToolPlan, requestID: UUID, message: String,
                                  status: String = String(localized: "Invalid input")) {
        record(ToolResultBlock(toolCallID: plan.call.id, content: message, isError: true), at: plan.index)
        updateConfirmationStatus(requestID, .notRun)
        appendStatus(for: plan.tool, callID: plan.call.id, text: status, state: .failed)
        announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: status, failed: true, hasSummary: true))
    }

    /// Records a finished tool call: result for the model, status, card and disclosure.
    private func complete(_ plan: ToolPlan, statusID: UUID, outcome: ToolOutcome, resultPrefix: String) {
        notePermissions(of: plan.tool, after: outcome)
        let callID = plan.call.id
        let hasSideEffects = plan.riskLevel != .read
        func recordUnknownOutcome(status: String) {
            // Orbit stopped waiting, but the action may still complete.
            record(ToolResultBlock(toolCallID: callID, content: resultPrefix + ModelText.outcomeUnknown, isError: true),
                   at: plan.index)
            updateStatus(statusID, state: .failed, text: status)
            plan.confirmationID.map { updateConfirmationStatus($0, .outcomeUnknown) }
            announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: status, failed: true, hasSummary: true))
        }
        switch outcome {
        case .success(let result):
            // Already capped by `perform`.
            let text = result.text.contains(where: { !$0.isWhitespace }) ? result.text : ModelText.emptyResult
            record(ToolResultBlock(toolCallID: callID, content: resultPrefix + text, isError: result.isError), at: plan.index)
            let fallback = result.isError ? String(localized: "Failed") : String(localized: "Completed")
            updateStatus(statusID, state: result.isError ? .failed : .succeeded, text: result.summary ?? fallback)
            // A reply hands the keyboard to Mail's window: the panel says where its text is (RootView).
            if !ChatAnnouncement.isAnnouncedByThePanel(result.card) {
                announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: result.summary ?? fallback,
                                                       failed: result.isError, hasSummary: result.summary != nil))
            }
            plan.confirmationID.map { updateConfirmationStatus($0, result.isError ? .failed : .approved) }
            if let card = result.card {
                insertCard(card, after: statusID)
            }
            let disclosures = result.disclosures
            if !disclosures.isEmpty {
                addDisclosures(disclosures)
            }

        case .failure(.timedOut) where hasSideEffects:
            recordUnknownOutcome(status: String(localized: "Timed out, result unknown"))

        case .failure(let error):
            record(ToolResultBlock(toolCallID: callID, content: resultPrefix + error.modelMessage, isError: true), at: plan.index)
            updateStatus(statusID, state: .failed, text: Self.statusText(for: error))
            plan.confirmationID.map { updateConfirmationStatus($0, .failed) }
            addDisclosures(error.disclosures)
            if case .permissionDenied(let permission) = error.underlying {
                // The notice says it (and is announced), once.
                addPermissionNotice(permission)
            } else {
                announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: Self.statusText(for: error),
                                                       failed: true, hasSummary: true))
            }

        case .unexpected, .cancelled:
            if hasSideEffects {
                recordUnknownOutcome(status: String(localized: "Result unknown"))
                return
            }
            record(ToolResultBlock(toolCallID: callID, content: resultPrefix + ModelText.unexpectedFailure, isError: true),
                   at: plan.index)
            updateStatus(statusID, state: .failed, text: String(localized: "Failed"))
            announce(ChatAnnouncement.toolFinished(toolName: plan.tool.displayName, status: String(localized: "Failed"),
                                                   failed: true, hasSummary: true))
        }
    }

    /// The run may have shown macOS's prompt (first use of a permission), or
    /// macOS refused one: those permissions are read again, so the next turn
    /// tells the model when a tool became unavailable or available.
    private func notePermissions(of tool: any Tool, after outcome: ToolOutcome) {
        guard !tool.requiredPermissions.isEmpty else { return }
        let permissions = dependencies.permissions
        if case .failure(.permissionDenied(let refused)) = outcome {
            permissions.permissionsMayHaveChanged([refused])
            return
        }
        let undecided = tool.requiredPermissions.filter { permissions.status(of: $0) != .granted }
        if !undecided.isEmpty {
            permissions.permissionsMayHaveChanged(undecided)
        }
    }

    private func record(_ result: ToolResultBlock, at index: Int) {
        run?.results[index] = result
    }

    /// Appends the results of the open tool calls as one user message, in call
    /// order. Calls without a recorded result get `fallback` as error result.
    private func closeOpenToolCalls(fallback: String) {
        guard let open = run?.openToolCalls else { return }
        appendToolResults(for: open, results: run?.results ?? [:], fallback: fallback)
        run?.openToolCalls = nil
        run?.results = [:]
    }

    private func appendToolResults(for calls: [ToolCall], results: [Int: ToolResultBlock], fallback: String) {
        let blocks = calls.enumerated().map { index, call in
            results[index] ?? ToolResultBlock(toolCallID: call.id, content: fallback, isError: true)
        }
        appendUserContent(blocks.map(ContentBlock.toolResult))
    }

    /// Frozen tools that can be used right now.
    private func usableToolNames() -> [String] {
        let frozen = Set(conversation.toolNames ?? [])
        return currentAvailability().filter { frozen.contains($0.info.name) && $0.isAvailable }.map(\.info.name)
    }

    private func frozenToolDefinitions() -> [ToolDefinition] {
        // The exact definitions of the first request: rebuilding them (a runtime
        // description, an app update) would break preserved thinking and the cache.
        if let frozen = conversation.toolDefinitions {
            return frozen
        }
        let tools = dependencies.registry.tools
        return (conversation.toolNames ?? []).compactMap { name in
            tools.first { $0.name == name }?.definition
        }
    }

    // MARK: - History

    /// Appends blocks as a user message, or to the trailing user message so two
    /// user messages never follow each other (e.g. after a cancel or an error).
    private func appendUserContent(_ blocks: [ContentBlock]) {
        if let last = conversation.messages.indices.last, conversation.messages[last].role == .user {
            conversation.messages[last].content.append(contentsOf: blocks)
        } else {
            conversation.messages.append(Message(role: .user, content: blocks, createdAt: dependencies.now()))
        }
    }

    /// The provider dropped thinking blocks to recover from an error; the
    /// stored history must match what it sends from now on.
    private func stripThinkingFromHistory() {
        for index in conversation.messages.indices {
            conversation.messages[index].content.removeAll { block in
                switch block {
                case .thinking, .redactedThinking: true
                default: false
                }
            }
        }
        Log.agent.info("Stripped thinking blocks from the stored history")
    }

    private func freezeToolListIfNeeded(at date: Date) {
        guard conversation.toolNames == nil else { return }
        let availability = currentAvailability()
        let offered = availability.filter { $0.unavailableReason != .disabledByUser }.map(\.info.name)
        conversation.toolNames = offered
        conversation.toolDefinitions = offered.compactMap { dependencies.registry.tool(named: $0)?.definition }
        frozenAvailability = availability
        frozenAt = date
        availabilityBaseline = AvailabilityStatement(availability: availability, offered: Set(offered))
    }

    private func turnContext(attachments: [ContextAttachment], now: Date) -> String {
        let statement = AvailabilityStatement(availability: currentAvailability(),
                                              offered: Set(conversation.toolNames ?? []))
        let note: String?
        if let availabilityBaseline {
            note = statement.changes(since: availabilityBaseline)
        } else {
            note = statement.fullDescription
        }
        availabilityBaseline = statement
        return TurnContext(now: now, timeZone: dependencies.timeZone, attachments: attachments,
                           availabilityNote: note).render()
    }

    private func currentAvailability() -> [ToolAvailability] {
        dependencies.registry.availability(disabledToolNames: dependencies.settings.disabledToolNames,
                                           permissions: dependencies.permissions)
    }

    private func resetConversation() {
        let now = dependencies.now()
        conversation = Conversation(createdAt: now, updatedAt: now)
        conversationID = conversation.id
        items = []
        frozenAvailability = nil
        frozenAt = nil
        availabilityBaseline = nil
        unsentDisclosures = []
        failedAttemptItemIDs = []
        requestToolCallCount = 0
        requestCallsByTool = [:]
        requestText = ""
    }

    // MARK: - Chat rows

    private func appendStreamedText(_ delta: String) {
        guard !delta.isEmpty, run != nil else { return }
        pendingStreamText += delta
        guard streamPublishTask == nil else { return }
        streamPublishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.streamPublishInterval)
            guard !Task.isCancelled else { return }
            self?.publishStreamedText()
        }
    }

    /// Shows the buffered text: appended to the streaming answer, or as a new one.
    private func publishStreamedText() {
        streamPublishTask?.cancel()
        streamPublishTask = nil
        let delta = pendingStreamText
        pendingStreamText = ""
        guard !delta.isEmpty, run != nil else { return }
        if let id = run?.streamingItemID, let index = items.indices.last, items[index].id == id,
           case .assistant(let text, true) = items[index].kind {
            items[index].kind = .assistant(text: text + delta, isStreaming: true)
            return
        }
        finishStreamingItems()
        let item = ChatItem(kind: .assistant(text: delta, isStreaming: true), createdAt: dependencies.now())
        items.append(item)
        run?.streamingItemID = item.id
        run?.turnItemIDs.append(item.id)
    }

    private func addProgressNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, run != nil else { return }
        finishStreamingItems()
        let item = ChatItem(kind: .progress(text: trimmed), createdAt: dependencies.now())
        items.append(item)
        run?.turnItemIDs.append(item.id)
    }

    /// Running status rows end as cancelled, pending confirmation cards as expired.
    private func closeOpenRows() {
        for index in items.indices {
            switch items[index].kind {
            case .toolStatus(var status) where status.state == .running:
                status.state = .cancelled
                status.text = String(localized: "Canceled")
                items[index].kind = .toolStatus(status)
            case .confirmation(var state) where state.status == .pending:
                state.status = .expired
                items[index].kind = .confirmation(state)
            case .confirmation(var state) where state.status == .confirmed:
                // Confirmed, but stopped before it started.
                state.status = .notRun
                items[index].kind = .confirmation(state)
            default:
                break
            }
        }
    }

    /// Calls of non-read tools that were executing when the run stopped: they
    /// may still complete, so the model, the status row and the card say so.
    private func markExecutingSideEffectsUnknown(_ active: inout ActiveRun) {
        for (index, call) in active.executingSideEffects where active.results[index] == nil {
            active.results[index] = ToolResultBlock(toolCallID: call.callID, content: ModelText.outcomeUnknown, isError: true)
            updateStatus(call.statusID, state: .cancelled, text: String(localized: "Stopped, result unknown"))
            call.confirmationID.map { updateConfirmationStatus($0, .outcomeUnknown) }
        }
        active.executingSideEffects = [:]
    }

    private func finishStreamingItems() {
        publishStreamedText()
        run?.streamingItemID = nil
        for index in items.indices.reversed() {
            if case .assistant(let text, true) = items[index].kind {
                items[index].kind = .assistant(text: text, isStreaming: false)
            }
        }
    }

    /// Text streamed in the current turn of `active`.
    private func turnText(of active: ActiveRun) -> String {
        active.turnItemIDs.compactMap { id -> String? in
            guard let item = items.last(where: { $0.id == id }),
                  case .assistant(let text, _) = item.kind else { return nil }
            return text
        }.joined()
    }

    private func removeTurnItems() {
        guard let ids = run?.turnItemIDs, !ids.isEmpty else { return }
        let removed = Set(ids)
        items.removeAll { removed.contains($0.id) }
        run?.turnItemIDs = []
    }

    @discardableResult
    private func appendStatus(for tool: any Tool, callID: String, text: String, state: ToolStatus.State) -> UUID {
        let status = ToolStatus(toolCallID: callID, toolName: tool.name, category: tool.category, text: text, state: state)
        let item = ChatItem(kind: .toolStatus(status), createdAt: dependencies.now())
        items.append(item)
        return item.id
    }

    private func updateStatus(_ id: UUID, state: ToolStatus.State, text: String) {
        guard let index = items.lastIndex(where: { $0.id == id }),
              case .toolStatus(var status) = items[index].kind else { return }
        status.state = state
        status.text = text
        items[index].kind = .toolStatus(status)
    }

    /// Cards go right below their status line, also when calls run in parallel.
    private func insertCard(_ card: ResultCard, after statusID: UUID) {
        let item = ChatItem(kind: .card(card), createdAt: dependencies.now())
        if let index = items.lastIndex(where: { $0.id == statusID }) {
            items.insert(item, at: index + 1)
        } else {
            items.append(item)
        }
    }

    private func setConfirmationStatus(_ requestID: UUID, _ status: ConfirmationState.Status) {
        guard let index = items.lastIndex(where: { Self.isPendingConfirmation($0, id: requestID) }),
              case .confirmation(var state) = items[index].kind else { return }
        state.status = status
        items[index].kind = .confirmation(state)
    }

    /// Sets the status of a card whatever its current status.
    private func updateConfirmationStatus(_ requestID: UUID, _ status: ConfirmationState.Status) {
        guard let index = items.lastIndex(where: { item in
            if case .confirmation(let state) = item.kind { return state.request.id == requestID }
            return false
        }), case .confirmation(var state) = items[index].kind else { return }
        state.status = status
        items[index].kind = .confirmation(state)
    }

    private func addToolLimitNotice() {
        Log.agent.notice("Tool call limit reached")
        addNotice(.warning, String(format: String(localized: "Orbit stopped the request after %lld tool calls. Make it more specific, or send a new message to continue."), requestToolCallCount))
    }

    /// No answer text and no tool calls.
    private func addNoAnswerNotice(_ stopReason: StopReason) {
        switch stopReason {
        case .maxTokens:
            addNotice(.warning, String(localized: "The model reached its output limit before it could answer."),
                      actions: [.retry])
        case .contextWindowExceeded:
            addNotice(.warning, Self.contextFullMessage, actions: [.newChat])
        default:
            addNotice(.warning, String(localized: "The model did not return an answer."), actions: [.retry])
        }
    }

    /// Removes a refused request that has no answer, so a follow-up does not
    /// carry it again: the one exception to append-only (see Models.swift).
    /// Returns false when the history cannot drop it (it ends with tool results).
    private func dropRefusedRequest() -> Bool {
        guard let last = conversation.messages.last, last.role == .user, last.toolResults.isEmpty else { return false }
        conversation.messages.removeLast()
        // The removed message carried the last availability statement.
        availabilityBaseline = nil
        return true
    }

    private func addRefusalNotice(removedRequest: Bool) {
        if removedRequest {
            addNotice(.warning, String(localized: "The model declined this request."))
        } else {
            addNotice(.warning, String(localized: "The model declined this request. Start a new chat to continue."),
                      actions: [.newChat])
        }
    }

    /// Appends a notice with up to two buttons (`actions`, the fitting one
    /// first). VoiceOver hears it once, now; an error interrupts.
    @discardableResult
    private func addNotice(_ style: Notice.Style, _ message: String, actions: [Notice.Action] = []) -> UUID {
        let notice = Notice(style: style, message: message, action: actions.first, secondaryAction: actions.dropFirst().first)
        let item = ChatItem(kind: .notice(notice), createdAt: dependencies.now())
        items.append(item)
        dependencies.announcer?.announce(message, priority: style == .error ? .high : .medium)
        return item.id
    }

    /// VoiceOver hears an event of the request (`ChatAnnouncement`) after
    /// what it is saying (`interrupting`: at once).
    private func announce(_ text: String?, interrupting: Bool = false) {
        guard let text, !text.isEmpty else { return }
        dependencies.announcer?.announce(text, priority: interrupting ? .high : .medium)
    }

    /// The note goes before a closing notice, so the notice (and its retry
    /// button) stays the last row.
    private func appendDisclosure(_ disclosures: [ContentDisclosure], providerName: String?) {
        let merged = Self.merged(disclosures)
        guard !merged.isEmpty else { return }
        let item = ChatItem(kind: .disclosure(items: merged, providerName: providerName ?? providerDisplayName),
                            createdAt: dependencies.now())
        if let last = items.indices.last, case .notice = items[last].kind {
            items.insert(item, at: last)
        } else {
            items.append(item)
        }
    }

    /// User content entered the history: it is disclosed with the next request,
    /// and counted for providers that receive the history later.
    private func addDisclosures(_ disclosures: [ContentDisclosure]) {
        let nonEmpty = disclosures.filter { $0.count > 0 }
        guard !nonEmpty.isEmpty else { return }
        unsentDisclosures += nonEmpty
        conversation.disclosedContent = Self.merged((conversation.disclosedContent ?? []) + nonEmpty)
    }

    /// A provider that has not received this conversation before gets all of
    /// it, so its note covers everything in the history, not only the new content.
    private func noteRecipient(_ recipient: String) {
        var recipients = conversation.recipients ?? []
        guard !recipients.contains(recipient) else { return }
        if !recipients.isEmpty, let everything = conversation.disclosedContent {
            unsentDisclosures = everything
        }
        recipients.append(recipient)
        conversation.recipients = recipients
    }

    /// Buttons that would send a superseded request again ("Try Again",
    /// "Sign In…", which retries after signing in) go; "Open Settings"
    /// stays.
    private func retireRetryActions() {
        for index in items.indices {
            guard case .notice(var notice) = items[index].kind else { continue }
            let kept = notice.actions.filter { $0 != .retry && $0 != .signIn }
            guard kept != notice.actions else { continue }
            notice.action = kept.first
            notice.secondaryAction = kept.dropFirst().first
            items[index].kind = .notice(notice)
        }
    }

    // MARK: - Persistence

    /// Saves the conversation (in the background, in order). Empty chats are not stored.
    private func save() {
        guard let store = dependencies.store, !(items.isEmpty && conversation.messages.isEmpty) else { return }
        conversation.updatedAt = dependencies.now()
        conversation.pendingDisclosures = unsentDisclosures.isEmpty ? nil : Self.merged(unsentDisclosures)
        let snapshot = currentConversation
        enqueueStoreOperation { try await store.save(snapshot) }
    }

    @discardableResult
    private func enqueueStoreOperation(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Bool, Never> {
        let previous = storeQueue
        pendingStoreOperations += 1
        let task = Task<Bool, Never> {
            defer { pendingStoreOperations -= 1 }
            _ = await previous?.value
            do {
                try await operation()
                return true
            } catch {
                Log.storage.error("Conversation store operation failed: \(String(describing: type(of: error)), privacy: .public)")
                return false
            }
        }
        storeQueue = task
        return task
    }
}

// MARK: - Helpers

extension AgentLoop {
    private static let cutShortMessage = String(localized: "The answer was cut off because it reached the maximum length.")
    private static let contextFullMessage = String(localized: "This conversation has become too long for the model. Start a new chat.")

    /// The result of running one tool.
    enum ToolOutcome: Sendable {
        case success(ToolResult)
        case failure(ToolError)
        /// Any other error; only its type is kept (for logging).
        case unexpected(String)
        case cancelled
    }

    /// Why a tool refused a call before its confirmation card (or after the
    /// user edited the card): see `Tool.prepareForConfirmation`.
    struct PreparationRefusal: Sendable {
        /// nil: the tool failed unexpectedly.
        var error: ToolError?
        /// For logs: the error kind or type, never its message.
        var logName: String

        var modelMessage: String { error?.modelMessage ?? ModelText.unexpectedFailure }

        /// Whether the arguments were refused (not, e.g., a missing permission).
        var isInvalidArgument: Bool {
            if case .invalidArgument = error?.underlying { return true }
            return false
        }

        /// What was wrong, without the "Invalid arguments:" prefix.
        var detail: String {
            if case .invalidArgument(let message) = error?.underlying { return message }
            return modelMessage
        }

        var statusText: String { error.map(AgentLoop.statusText(for:)) ?? String(localized: "Failed") }

        var missingPermission: PermissionKind? {
            if case .permissionDenied(let permission) = error?.underlying { return permission }
            return nil
        }

        /// What the refusal's message sends of the user's data (e.g. names of similar shortcuts).
        var disclosures: [ContentDisclosure] { error?.disclosures ?? [] }
    }

    enum PreparationOutcome: Sendable {
        case prepared(ToolArguments)
        case refused(PreparationRefusal)
    }

    /// Lets a tool check and complete its arguments before its confirmation
    /// card, off the main actor, with the tool deadline.
    nonisolated static func prepare(_ tool: any Tool, arguments: ToolArguments, timeout: Duration) async -> PreparationOutcome {
        do {
            return .prepared(try await runWithDeadline(timeout) { try await tool.prepareForConfirmation(arguments) })
        } catch let error as ToolError {
            return .refused(PreparationRefusal(error: error, logName: logName(for: error)))
        } catch {
            return .refused(PreparationRefusal(error: nil, logName: String(describing: type(of: error))))
        }
    }

    /// Runs a tool off the main actor with a deadline and caps its text for the model.
    nonisolated static func perform(_ tool: any Tool, arguments: ToolArguments, timeout: Duration) async -> ToolOutcome {
        let start = ContinuousClock.now
        let outcome: ToolOutcome
        do {
            var result = try await runWithDeadline(timeout) { try await tool.run(arguments: arguments) }
            result.text = Truncation.capToolResult(result.text)
            outcome = .success(result)
        } catch let error as ToolError {
            outcome = .failure(error)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .unexpected(String(describing: type(of: error)))
        }
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        switch outcome {
        case .success:
            Log.tools.info("\(tool.name, privacy: .public) finished in \(milliseconds) ms")
        case .failure(let error):
            Log.tools.error("\(tool.name, privacy: .public) failed (\(Self.logName(for: error), privacy: .public)) after \(milliseconds) ms")
        case .unexpected(let type):
            Log.tools.error("\(tool.name, privacy: .public) threw \(type, privacy: .public) after \(milliseconds) ms")
        case .cancelled:
            Log.tools.info("\(tool.name, privacy: .public) cancelled after \(milliseconds) ms")
        }
        return outcome
    }

    /// Runs `operation` in its own task and returns its result, or throws
    /// `ToolError.timedOut` once `timeout` has passed. Unlike a task group this
    /// returns promptly on timeout or cancellation even if the operation ignores
    /// cancellation: the operation is cancelled and left to finish on its own.
    nonisolated static func runWithDeadline<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = DeadlineRace<T>()
        let work = Task.detached { try await operation() }
        let timer = Task.detached {
            try await Task.sleep(for: timeout)
            if race.finish(.failure(ToolError.timedOut)) {
                work.cancel()
            }
        }
        Task.detached {
            let result = await work.result
            timer.cancel()
            race.finish(result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            work.cancel()
            timer.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    nonisolated private static func lookUpUserName(_ lookup: @escaping @Sendable () async -> String?,
                                                   timeout: Duration) async -> String? {
        let name = try? await runWithDeadline(timeout) { await lookup() }
        return name ?? nil
    }

    /// Reads the API key off the main actor (keychain access can block). A
    /// keychain that cannot be read is reported as such, not as a missing key.
    nonisolated private static func readAPIKey(from secrets: any SecretStoring, account: String) async throws -> String {
        do {
            return try secrets.secret(for: account) ?? ""
        } catch {
            Log.agent.error("Reading the API key failed: \(String(describing: type(of: error)), privacy: .public)")
            throw LLMError.keychainUnavailable
        }
    }

    /// Identifies who receives a conversation's history: the API's host, or
    /// Anthropic for the Claude subscription (Claude Code talks to the same API).
    nonisolated static func recipientKey(kind: ProviderKind, baseURL: URL?) -> String {
        let anthropic = "anthropic@api.anthropic.com"
        switch kind {
        case .claudeCode:
            return anthropic
        case .anthropic, .openAICompatible:
            guard let baseURL, let host = baseURL.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
                return kind == .anthropic ? anthropic : "\(kind.rawValue)@default"
            }
            let port = baseURL.port.map { ":\($0)" } ?? ""
            return "\(kind.rawValue)@\(host)\(port)"
        }
    }

    nonisolated static func title(for text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(singleLine.prefix(titleLength))
    }

    /// The answer a provider-managed run wrote after its last tool call.
    private static func trailingText(of segments: [RunSegment]) -> String {
        let lastCall = segments.lastIndex { if case .toolCall = $0 { true } else { false } }
        let start = lastCall.map { $0 + 1 } ?? segments.startIndex
        return segments[start...].compactMap { segment in
            if case .text(let text) = segment { return text }
            return nil
        }.joined()
    }

    /// Sums counts per kind, keeping the order of first appearance.
    nonisolated static func merged(_ disclosures: [ContentDisclosure]) -> [ContentDisclosure] {
        var order: [ContentDisclosure.Kind] = []
        var counts: [ContentDisclosure.Kind: Int] = [:]
        for disclosure in disclosures where disclosure.count > 0 {
            if counts[disclosure.kind] == nil { order.append(disclosure.kind) }
            counts[disclosure.kind, default: 0] += disclosure.count
        }
        return order.map { ContentDisclosure(kind: $0, count: counts[$0] ?? 0) }
    }

    /// Rows of a stored chat as they must look after a relaunch.
    nonisolated static func sanitized(_ items: [ChatItem]) -> [ChatItem] {
        items.map { item in
            var item = item
            switch item.kind {
            case .assistant(let text, true):
                item.kind = .assistant(text: text, isStreaming: false)
            case .confirmation(var state) where state.status == .pending:
                state.status = .expired
                item.kind = .confirmation(state)
            case .confirmation(var state) where state.status == .confirmed:
                // Orbit quit while the action may have been running.
                state.status = .outcomeUnknown
                item.kind = .confirmation(state)
            case .toolStatus(var status) where status.state == .running:
                status.state = .cancelled
                status.text = String(localized: "Canceled")
                item.kind = .toolStatus(status)
            default:
                break
            }
            return item
        }
    }

    /// A history that ended with unanswered tool calls (the app quit while
    /// they ran) gets results for them, so it stays valid for the provider.
    /// `notRun`: calls whose confirmation card was never confirmed; `declined`:
    /// calls the user declined. Only the others may have run.
    nonisolated static func closingDanglingToolCalls(in messages: [Message], now: Date, notRun: Set<String> = [],
                                                     declined: Set<String> = []) -> [Message] {
        guard let last = messages.last, last.role == .assistant, !last.toolCalls.isEmpty else { return messages }
        let results = last.toolCalls.map { call in
            let result = if declined.contains(call.id) {
                ToolResultBlock(toolCallID: call.id, content: ModelText.declined, isError: false)
            } else if notRun.contains(call.id) {
                ToolResultBlock(toolCallID: call.id, content: ModelText.closedBeforeConfirmation, isError: true)
            } else {
                ToolResultBlock(toolCallID: call.id, content: ModelText.interrupted, isError: true)
            }
            return ContentBlock.toolResult(result)
        }
        return messages + [Message(role: .user, content: results, createdAt: now)]
    }

    /// The buttons of an error notice, the fitting one first: "Open
    /// Settings" where a setting is wrong (key, model, address, provider),
    /// "Sign In…" when Claude Code is signed out, "New Chat" when the chat
    /// no longer fits, and "Try Again" wherever the same request can
    /// work later (after a fixed setting, a reset limit, a started server).
    nonisolated static func noticeActions(for error: LLMError, destination: ProviderDestination? = nil) -> [Notice.Action] {
        switch error {
        case .missingAPIKey, .invalidAPIKey, .modelNotFound, .toolsNotSupported, .invalidBaseURL, .permissionDenied,
             .invalidRequest, .claudeCodeNotInstalled, .network(.insecureConnectionBlocked):
            [.openSettings, .retry]
        case .claudeCodeNotLoggedIn:
            [.signIn, .retry]
        case .requestTooLarge, .contextTooLong:
            [.newChat]
        case .claudeCodeOutdated:
            [.retry, .openSettings]
        case .network(.cannotConnect), .network(.secureConnection):
            // A server at a custom address: start it and try again, or correct the address.
            switch destination {
            case .thisMac?, .server?: [.retry, .openSettings]
            default: [.retry]
            }
        case .billing, .usageLimitReached, .cancelled:
            [.retry]
        default:
            error.isRetryable ? [.retry] : []
        }
    }

    nonisolated static func statusText(for error: ToolError) -> String {
        switch error {
        case .timedOut: String(localized: "Timed out")
        case .permissionDenied(let permission): String(format: String(localized: "Missing permission: %@"), permission.displayName)
        case .notFound: String(localized: "Not found")
        case .unavailable: String(localized: "Not available")
        case .invalidArgument: String(localized: "Invalid parameters")
        case .failed: String(localized: "Failed")
        case .withDisclosure(let error, _): statusText(for: error)
        case .withStatus(_, let status): status
        }
    }

    /// The notice for a permission macOS refused (`addPermissionNotice`).
    nonisolated static func permissionNotice(for permission: PermissionKind) -> String {
        switch permission {
        case .automationMail: String(localized: "Orbit is not allowed to control Mail.")
        case .automationNotes: String(localized: "Orbit is not allowed to control Notes.")
        case .contacts: String(localized: "Orbit is not allowed to access your contacts.")
        // Also when macOS allows adding only: Orbit needs full access.
        case .calendars: String(localized: "Orbit does not have full access to your calendars.")
        case .reminders: String(localized: "Orbit does not have full access to your reminders.")
        case .photos: String(localized: "Orbit is not allowed to access your photos.")
        case .automationPhotos: String(localized: "Orbit is not allowed to control Photos.")
        case .automationFinder: String(localized: "Orbit is not allowed to control Finder.")
        case .automationSystemEvents: String(localized: "Orbit is not allowed to control System Events.")
        default: String(format: String(localized: "Orbit does not have the permission “%@”."), permission.displayName)
        }
    }

    /// Error kinds for logs, never the associated messages (they may echo user content).
    nonisolated static func logName(for error: LLMError) -> String {
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
        case .streamError: "streamError"
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

    nonisolated static func logName(for error: ToolError) -> String {
        switch error {
        case .invalidArgument: "invalidArgument"
        case .permissionDenied(let permission): "permissionDenied(\(permission.rawValue))"
        case .notFound: "notFound"
        case .unavailable: "unavailable"
        case .timedOut: "timedOut"
        case .failed: "failed"
        case .withDisclosure(let error, _), .withStatus(let error, _): logName(for: error)
        }
    }

    nonisolated private static func isPendingConfirmation(_ item: ChatItem, id: UUID) -> Bool {
        if case .confirmation(let state) = item.kind {
            return state.request.id == id && state.status == .pending
        }
        return false
    }

    nonisolated private static func isErrorNotice(_ item: ChatItem) -> Bool {
        if case .notice(let notice) = item.kind {
            return notice.style == .error || notice.actions.contains(.retry)
        }
        return false
    }

    /// Whether `item` is a notice with the button `action`.
    nonisolated private static func offers(_ action: Notice.Action, _ item: ChatItem) -> Bool {
        if case .notice(let notice) = item.kind {
            return notice.actions.contains(action)
        }
        return false
    }
}

// MARK: - Model texts and deadline

extension AgentLoop {
    /// Texts for the model (English, not localized).
    enum ModelText {
        static let cancelledByUser = "Cancelled by the user."
        static let declined = "The user declined this action. Nothing was changed."
        static let outputCutOff = "Not run: your response reached the maximum output length and was cut off, so this tool call may be incomplete. Call the tool again and keep any text before tool calls short."
        static let contextWindowFull = "Not run: the conversation reached the model's context window limit."
        static let toolLimitReached = "Not run: Orbit's limit of \(AgentLoop.maxToolCallsPerRequest) tool calls per user request was reached, so Orbit stopped this request. If the user asks you to continue, build on the results you already have and use narrower searches."
        static let toolLimitReachedForProvider = "Not run: Orbit's limit of \(AgentLoop.maxToolCallsPerRequest) tool calls per user request was reached. Do not call more tools for this request; answer with the results you already have and tell the user that the answer may be incomplete."
        static let unexpectedFailure = "Error: the tool failed unexpectedly. Try a different approach or tell the user that it did not work."
        static let emptyResult = "(The tool returned no text.)"
        static let interrupted = "Not completed: Orbit was closed before this tool call finished, so it is unknown whether it ran."
        static let closedBeforeConfirmation = "Not run: Orbit was closed before the user confirmed this action. Nothing was changed."
        static let outcomeUnknown = "Orbit stopped waiting for this action before it reported a result (stopped by the user or timed out). It may still have been carried out. Do not call the tool again on your own; tell the user to check whether it happened and ask before retrying."

        static func unknownTool(_ name: String, available: [String]) -> String {
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "Error: there is no tool named '\(name)'. Available tools: \(list)."
        }

        /// The raw arguments the model sent, as `{"INVALID_JSON": "<raw input>"}`.
        static func invalidJSON(_ rawInput: String) -> String {
            JSONValue.object(["INVALID_JSON": .string(rawInput)]).jsonString()
        }

        static func invalidArguments(_ errors: [String]) -> String {
            ToolError.invalidArgument(errors.joined(separator: " ") + " The tool was not run; call it again with corrected arguments.").modelMessage
        }

        static func notInThisChat(_ name: String) -> String {
            ToolError.unavailable("'\(name)' is not enabled in this chat. The user can enable it in Orbit's settings (\(toolsSettings)); it can then be used in a new chat.").modelMessage
        }

        static func disabledByUser(_ name: String) -> String {
            ToolError.unavailable("'\(name)' was disabled by the user. Tell the user they can enable it again in Orbit's settings (\(toolsSettings)).").modelMessage
        }

        /// Where the tool switches are, named as Orbit shows it to the user ("Tools", "Tools"), so the
        /// agent can point there in the user's language.
        static var toolsSettings: String {
            let tab = String(localized: "Tools")
            return "\"\(tab)\" tab"
        }

        /// `Tool.maxCallsPerRequest` was reached.
        static func callLimitReached(_ name: String, limit: Int) -> String {
            "Not run: Orbit allows \(name) at most \(limit) times per user request, and this request reached that limit. Do not call \(name) again for this request; tell the user what is left so they can do it themselves, or ask again in a new message."
        }

        static func editedValues(_ edits: [String: String]) -> String {
            let values = JSONValue.object(edits.mapValues(JSONValue.string)).jsonString()
            return "The user edited the proposed values before confirming; the action ran with: \(values)\n\n"
        }

        static func invalidEdits(_ errors: [String]) -> String {
            "Not run: the user edited the values before confirming, but they are invalid: \(errors.joined(separator: " ")) Nothing was changed."
        }

        /// The check after the user's edits refused for another reason than the values.
        static func refusedAfterEdits(_ reason: String) -> String {
            "Not run: the user edited the values and confirmed, but then the tool refused. \(reason)"
        }
    }

    /// The first of result, timeout and cancellation to arrive wins; the
    /// continuation is resumed exactly once.
    private final class DeadlineRace<T: Sendable>: Sendable {
        private enum State: Sendable {
            /// Running; the continuation is nil until installed.
            case running(CheckedContinuation<T, any Error>?)
            /// Decided before the continuation was installed.
            case decided(Result<T, any Error>)
            case done
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: .running(nil))

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            let early: Result<T, any Error>? = state.withLock { state in
                switch state {
                case .running:
                    state = .running(continuation)
                    return nil
                case .decided(let result):
                    state = .done
                    return result
                case .done:
                    return nil
                }
            }
            if let early {
                continuation.resume(with: early)
            }
        }

        /// Returns true when `result` decided the race.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            let (won, continuation): (Bool, CheckedContinuation<T, any Error>?) = state.withLock { state in
                switch state {
                case .running(let continuation):
                    state = continuation == nil ? .decided(result) : .done
                    return (true, continuation)
                case .decided, .done:
                    return (false, nil)
                }
            }
            continuation?.resume(with: result)
            return won
        }
    }
}

/// Hands tool calls of a provider that runs the tool loop itself (Claude Code)
/// to the agent loop's run that started the request.
private struct ProviderToolExecutor: ToolExecuting {
    weak var loop: AgentLoop?
    let runID: UUID

    func execute(_ call: ToolCall) async -> ToolResultBlock {
        guard let loop else {
            return ToolResultBlock(toolCallID: call.id, content: AgentLoop.ModelText.cancelledByUser, isError: true)
        }
        return await loop.executeProviderToolCall(call, runID: runID)
    }
}
