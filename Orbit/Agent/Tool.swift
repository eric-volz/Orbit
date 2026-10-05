import Foundation

/// A capability the agent can use. Tools are stateless value types or actors;
/// system access goes through injected protocols so tests can replace it.
///
/// Conventions:
/// - `name` is English snake_case; `description` tells the model precisely what
///   the tool does and WHEN to call it.
/// - `run` throws `ToolError` for expected failures (the message goes to the
///   model); anything else is reported as a generic failure.
/// - Results for the model must be compact and truncated (see `Truncation`).
/// - Tools never log user content (mail, notes, file contents).
protocol Tool: Sendable {
    var name: String { get }
    /// Short name for the settings screen, e.g. "Search files" (localized).
    var displayName: String { get }
    var description: String { get }
    var inputSchema: JSONSchema { get }
    var riskLevel: ToolRiskLevel { get }
    var category: ToolCategory { get }
    /// Permissions the tool cannot work without. If one is denied, the tool is
    /// disabled and the agent is told so.
    var requiredPermissions: [PermissionKind] { get }

    /// How long `run` may take before the agent loop stops waiting. nil (the
    /// default): the loop's deadline (90 s). A tool whose own work may take
    /// longer (`run_shortcut` gives a shortcut up to two minutes) sets a
    /// longer one; a shorter value never shortens the loop's deadline.
    var executionTimeout: Duration? { get }

    /// How often the tool may be called per user request (across the model's
    /// turns and retries); further calls are refused with a message for the
    /// model. nil (the default): only the loop's overall limit
    /// (`AgentLoop.maxToolCallsPerRequest`).
    var maxCallsPerRequest: Int? { get }

    /// Status line while the tool runs, e.g. "Durchsuche Mails…" (localized).
    func statusText(for arguments: ToolArguments) -> String

    /// Decides how one call is carried out, knowing the user request it
    /// belongs to (`UserRequest`: what the user typed, never what the model
    /// says): its risk level (a confirmation card exactly when that requires
    /// one) and its arguments, which may gain tool-private values (see
    /// `prepareForConfirmation`). Runs on the main actor right after the
    /// arguments were validated; keep it quick. The default: `riskLevel` and
    /// the arguments unchanged. `open_url` (`write`) opens a link the user
    /// typed in this request's message without a card (`draft`).
    func review(_ arguments: ToolArguments, for request: UserRequest) -> ReviewedCall

    /// For `write`/`destructive` tools: checks and completes the arguments
    /// before the confirmation card appears (and again after the user edited
    /// the card), e.g. validates dates or resolves a calendar name to the one
    /// it will use. Throwing a `ToolError` refuses the call without a card (or,
    /// after edits, does not run it): the message goes to the model. Runs off
    /// the main actor with the tool deadline; it may ask macOS for a permission
    /// the call needs (the user started the request). The default returns the
    /// arguments unchanged.
    ///
    /// It may add tool-private values under keys starting with "_"
    /// (`ToolArguments.isPrivateKey`), e.g. the identifier of the calendar the
    /// card names: they are no parameters, so the model cannot pass them; the
    /// card's edits never change them; and the agent loop keeps them through
    /// the user's edits: the check after edits and `run` get them, and act on
    /// exactly what the card showed.
    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments

    /// For `write`/`destructive` tools: what the confirmation card shows (for
    /// the arguments `prepareForConfirmation` returned). The default
    /// implementation builds a generic card from the arguments.
    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest

    /// Applies values the user edited on the confirmation card. Keys are field
    /// ids (= argument names). The default sets them as strings, never a
    /// tool-private value.
    func applyingEdits(_ edits: [String: String], to arguments: ToolArguments) -> ToolArguments

    func run(arguments: ToolArguments) async throws -> ToolResult
}

extension Tool {
    var displayName: String { name }

    var requiredPermissions: [PermissionKind] { [] }

    var executionTimeout: Duration? { nil }

    var maxCallsPerRequest: Int? { nil }

    func statusText(for arguments: ToolArguments) -> String {
        String(format: String(localized: "Running %@…"), name)
    }

    func review(_ arguments: ToolArguments, for request: UserRequest) -> ReviewedCall {
        ReviewedCall(arguments: arguments, riskLevel: riskLevel)
    }

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        arguments
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        let fields = arguments.values.keys.sorted().map { key in
            ConfirmationField(id: key, label: key, value: arguments.values[key]?.displayText ?? "", kind: .readOnly)
        }
        return ConfirmationRequest(
            toolName: name,
            riskLevel: riskLevel,
            title: name,
            message: description,
            fields: fields
        )
    }

    func applyingEdits(_ edits: [String: String], to arguments: ToolArguments) -> ToolArguments {
        var result = arguments
        for (key, value) in edits where !ToolArguments.isPrivateKey(key) {
            result.values[key] = .string(value)
        }
        return result
    }

    /// The definition sent to the model.
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: inputSchema.jsonValue)
    }
}

// MARK: - Arguments

/// Validated, normalized tool arguments with typed accessors. Accessors throw
/// `ToolError.invalidArgument` with a message for the model.
struct ToolArguments: Sendable, Hashable {
    var values: [String: JSONValue]

    init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    init(json: JSONValue) {
        self.values = json.objectValue ?? [:]
    }

    subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    func has(_ key: String) -> Bool {
        if let value = values[key], !value.isNull { return true }
        return false
    }

    /// Whether `key` holds a tool-private value (see `Tool.prepareForConfirmation`).
    static func isPrivateKey(_ key: String) -> Bool {
        key.hasPrefix("_")
    }

    /// The tool-private values: set by `prepareForConfirmation`, no parameters.
    var privateValues: [String: JSONValue] {
        values.filter { Self.isPrivateKey($0.key) }
    }

    /// The arguments without the tool-private values: what the input schema checks.
    var parameters: ToolArguments {
        ToolArguments(values.filter { !Self.isPrivateKey($0.key) })
    }

    func string(_ key: String) throws -> String {
        guard let value = optionalString(key) else {
            throw ToolError.invalidArgument("Missing required parameter '\(key)'.")
        }
        return value
    }

    /// The trimmed string, or nil when absent or empty.
    func optionalString(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let text: String
        switch value {
        case .string(let string): text = string
        case .number, .bool: text = value.jsonString()
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(_ key: String, default defaultValue: Int) throws -> Int {
        try optionalInt(key) ?? defaultValue
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        if let int = value.intValue { return int }
        if let string = value.stringValue, let int = Int(string.trimmingCharacters(in: .whitespaces)) { return int }
        throw ToolError.invalidArgument("Parameter '\(key)' must be an integer.")
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = values[key], !value.isNull else { return nil }
        if let double = value.doubleValue { return double }
        if let string = value.stringValue, let double = Double(string) { return double }
        throw ToolError.invalidArgument("Parameter '\(key)' must be a number.")
    }

    func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values[key], !value.isNull else { return defaultValue }
        if let bool = value.boolValue { return bool }
        if let string = value.stringValue?.lowercased(), ["true", "false"].contains(string) { return string == "true" }
        throw ToolError.invalidArgument("Parameter '\(key)' must be true or false.")
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let value = values[key], !value.isNull else { return [] }
        if let string = value.stringValue { return [string] }
        guard let array = value.arrayValue else {
            throw ToolError.invalidArgument("Parameter '\(key)' must be an array of strings.")
        }
        return array.compactMap { element in
            element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// A date parameter. Date-only values resolve to the start of the day, or to
    /// the end of the day when `endOfDayIfDateOnly` is set (for "until" bounds).
    func optionalDate(_ key: String, endOfDayIfDateOnly: Bool = false, timeZone: TimeZone = .current) throws -> Date? {
        guard let text = optionalString(key) else { return nil }
        guard let parsed = FlexibleDate.parse(text, timeZone: timeZone) else {
            throw ToolError.invalidArgument("Parameter '\(key)' must be an ISO 8601 date like 2026-03-01 or 2026-03-01T14:30:00. Got '\(text)'.")
        }
        if parsed.isDateOnly && endOfDayIfDateOnly {
            return FlexibleDate.endOfDay(parsed.date, timeZone: timeZone)
        }
        return parsed.date
    }

    func date(_ key: String, endOfDayIfDateOnly: Bool = false, timeZone: TimeZone = .current) throws -> Date {
        guard let date = try optionalDate(key, endOfDayIfDateOnly: endOfDayIfDateOnly, timeZone: timeZone) else {
            throw ToolError.invalidArgument("Missing required parameter '\(key)'.")
        }
        return date
    }
}

extension JSONValue {
    /// Plain-text rendering for UI fields (strings without quotes).
    var displayText: String {
        switch self {
        case .string(let string): string
        case .null: ""
        case .array(let array): array.map(\.displayText).joined(separator: ", ")
        default: jsonString()
        }
    }
}

// MARK: - Requests

/// The user request a tool call belongs to, as the agent loop knows it
/// (`Tool.review(_:for:)`), never from the model.
struct UserRequest: Sendable, Hashable {
    /// What the user typed or pasted in the message that started the request:
    /// not the context chips, earlier messages, tool results or anything the
    /// model wrote. Empty when unknown (a request retried after a relaunch).
    var text: String
}

/// How the agent loop carries out one call (`Tool.review(_:for:)`).
struct ReviewedCall: Sendable, Hashable {
    var arguments: ToolArguments
    /// The risk level of this call: a confirmation card exactly when it
    /// `requiresConfirmation`; the card shows this level too.
    var riskLevel: ToolRiskLevel
}

// MARK: - Errors

enum ToolError: Error, Sendable, Hashable {
    /// Arguments are invalid. Message is for the model.
    case invalidArgument(String)
    /// A required permission is missing.
    case permissionDenied(PermissionKind)
    /// The requested item does not exist (message for the model).
    case notFound(String)
    /// The tool is disabled (by the user or because of a missing permission).
    case unavailable(String)
    /// The operation took too long.
    case timedOut
    /// Any other expected failure (message for the model).
    case failed(String)
    /// A failure whose message sends the user's data to the model (e.g. the
    /// names of similar shortcuts when a name does not exist): the chat notes
    /// what was sent, as for a result (see `disclosing(_:count:)`).
    indirect case withDisclosure(ToolError, ContentDisclosure)
    /// A failure whose status line in the chat says more than its kind's
    /// ("Invalid parameters"), e.g. that a link opens only when the user
    /// typed it. The model gets the failure's message.
    indirect case withStatus(ToolError, String)

    /// Text returned to the model as an error tool result.
    var modelMessage: String {
        switch self {
        case .invalidArgument(let message): "Invalid arguments: \(message)"
        case .permissionDenied(let permission):
            // Named as Orbit's settings show it, so the user finds it there.
            "Orbit does not have the macOS permission '\(permission.displayName)'\(Self.accessDetail(permission)). Tell the user they can allow it in Orbit's settings under '\(String(localized: "Permissions"))'; the chat shows a button that opens them."
        case .notFound(let message): "Not found: \(message)"
        case .unavailable(let message): "Tool unavailable: \(message)"
        case .timedOut: "The operation timed out. Try a narrower request (shorter time range, fewer results)."
        case .failed(let message): "Error: \(message)"
        case .withDisclosure(let error, _), .withStatus(let error, _): error.modelMessage
        }
    }

    /// This failure, noting that its message sends `count` items of `kind`
    /// of the user's data to the model (unchanged when `count` is 0).
    func disclosing(_ kind: ContentDisclosure.Kind, count: Int) -> ToolError {
        count > 0 ? .withDisclosure(self, ContentDisclosure(kind: kind, count: count)) : self
    }

    /// The failure itself, without what its message discloses or its own status.
    var underlying: ToolError {
        switch self {
        case .withDisclosure(let error, _), .withStatus(let error, _): error.underlying
        default: self
        }
    }

    /// What the message sends of the user's data (`disclosing(_:count:)`).
    var disclosures: [ContentDisclosure] {
        switch self {
        case .withDisclosure(let error, let disclosure): error.disclosures + [disclosure]
        case .withStatus(let error, _): error.disclosures
        default: []
        }
    }

    /// Calendars and reminders need full access: macOS's "add only" is not enough.
    private static func accessDetail(_ permission: PermissionKind) -> String {
        switch permission {
        case .calendars, .reminders: " with full access (\"add only\" access is not enough: Orbit reads them)"
        default: ""
        }
    }
}

// MARK: - Results

/// What a tool returns: text for the model plus optional structured data for a
/// result card in the UI.
struct ToolResult: Sendable, Hashable {
    /// Compact text for the model (already truncated by the tool).
    var text: String
    /// Structured data shown as a card in the chat.
    var card: ResultCard?
    var isError: Bool
    /// Completion status line for the UI, e.g. "Found 12 emails" (localized).
    var summary: String?
    /// Which user content this result sends to the LLM provider (for the
    /// "3 emails sent to Claude" note). nil when nothing personal is sent.
    var disclosure: ContentDisclosure?
    /// Further kinds of content the result sends, when it sends more than one
    /// (`get_frontmost_context`: a window title and the selected text).
    var additionalDisclosures: [ContentDisclosure]

    init(text: String, card: ResultCard? = nil, isError: Bool = false, summary: String? = nil, disclosure: ContentDisclosure? = nil,
         additionalDisclosures: [ContentDisclosure] = []) {
        self.text = text
        self.card = card
        self.isError = isError
        self.summary = summary
        self.disclosure = disclosure
        self.additionalDisclosures = additionalDisclosures
    }

    /// Every disclosure of the result, those with a count first.
    var disclosures: [ContentDisclosure] {
        ([disclosure].compactMap { $0 } + additionalDisclosures).filter { $0.count > 0 }
    }

    static func failure(_ message: String, summary: String? = nil) -> ToolResult {
        ToolResult(text: message, isError: true, summary: summary)
    }
}

/// A kind of user content sent to the LLM provider, with a count.
struct ContentDisclosure: Sendable, Hashable, Codable {
    enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case fileNames
        case fileContents
        case emails
        case notes
        case events
        case reminders
        case contacts
        case photos
        case selection
        /// Names of the user's shortcuts (`list_shortcuts`).
        case shortcuts
        /// What a shortcut returned (`run_shortcut`).
        case shortcutOutputs
        /// The title of the frontmost window (`get_frontmost_context`).
        case windowTitles
        /// Names of the user's calendars, listed when a name fits none or
        /// several, or naming the one an event went to.
        case calendarNames
        /// Names of the user's reminder lists (as `calendarNames`).
        case reminderListNames
        /// Names of folders in Notes or in the Shortcuts app.
        case folderNames
        /// Names of mailboxes in Mail (a mailbox that does not exist, or that
        /// Mail could not search).
        case mailboxNames
        /// Names of albums the user made in Photos.
        case albumNames
    }

    var kind: Kind
    var count: Int
}

// MARK: - Confirmation

struct ConfirmationField: Sendable, Hashable, Codable, Identifiable {
    enum Kind: String, Sendable, Hashable, Codable {
        case text
        case multilineText
        /// Edited as a date and time; the value is ISO 8601 (FlexibleDate).
        case dateTime
        case readOnly
    }

    /// The argument name the value maps back to.
    var id: String
    var label: String
    var value: String
    var kind: Kind
    /// `dateTime` only: the date may be removed (an empty value: none) or
    /// added, and switched between a day and a day with a time: a
    /// reminder's due date. Otherwise (event start and end, and chats saved
    /// before) the picker keeps the proposed form.
    var isOptionalDate: Bool? = nil
}

/// What the user must approve before a `write`/`destructive` tool runs. One
/// request covers exactly one tool call, never a blanket approval.
struct ConfirmationRequest: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    var toolCallID: String
    var toolName: String
    var riskLevel: ToolRiskLevel
    /// E.g. "Create event".
    var title: String
    /// What will happen, in plain words.
    var message: String
    /// Preview of the action; editable fields let the user adjust it first.
    var fields: [ConfirmationField]
    /// Shown prominently for destructive actions.
    var warning: String?
    /// Label of the run button; nil = "Run".
    var confirmLabel: String?

    init(id: UUID = UUID(), toolCallID: String = "", toolName: String, riskLevel: ToolRiskLevel, title: String,
         message: String, fields: [ConfirmationField] = [], warning: String? = nil, confirmLabel: String? = nil) {
        self.id = id
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.title = title
        self.message = message
        self.fields = fields
        self.warning = warning
        self.confirmLabel = confirmLabel
    }
}

enum ConfirmationDecision: Sendable, Hashable {
    /// Run the action; `edits` maps field ids to edited values (only changed fields).
    case approved(edits: [String: String])
    case cancelled
}
