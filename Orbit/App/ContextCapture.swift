import Foundation
import Observation

/// Captures the context chips when the user opens the panel (hotkey or menu):
/// what is selected in the app they came from: the Finder selection or the
/// selected text (`FrontmostContextCapturing`).
///
/// - Only when the user opens the panel and "Use the selection when opening"
///   is on, never while typing, and never when Orbit shows the panel itself
///   (a second launch, the hand-off to Mail's reply window).
/// - The panel appears at once; the chips appear when the capture is done. A
///   capture that takes longer than `budget` is dropped, and so is one that
///   finishes after the user sent the message or closed the panel.
/// - An open replaces the chips of the previous one, unless the input still
///   holds text the user has not sent together with chips they kept: then
///   nothing is captured and both stay.
/// - No chip for the app alone (it reaches the model only through `get_frontmost_context`).
@MainActor
@Observable
final class ContextCapture {
    /// How long a capture may take before it is dropped (D5: about 300 ms).
    static let budget: Duration = .milliseconds(300)

    /// A capture is running.
    private(set) var isCapturing = false
    /// Captures started and how the last one ended (DEBUG automation reports them).
    private(set) var captureCount = 0
    private(set) var lastOutcome: Outcome?

    enum Outcome: String, Sendable, Hashable {
        /// Chips were added.
        case chips
        /// Nothing selected (or nothing Orbit may read).
        case nothing
        /// Over the budget, or the panel closed or the message was sent first.
        case dropped
    }

    @ObservationIgnored private let capturer: any FrontmostContextCapturing
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let panelState: PanelState
    @ObservationIgnored private let announcer: (any Announcing)?
    @ObservationIgnored private let budget: Duration
    /// Incremented by every open, close and sent message: a capture from an
    /// earlier generation is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(capturer: any FrontmostContextCapturing, settings: SettingsStore, panelState: PanelState,
         announcer: (any Announcing)? = nil, budget: Duration = ContextCapture.budget) {
        self.capturer = capturer
        self.settings = settings
        self.panelState = panelState
        self.announcer = announcer
        self.budget = budget
    }

    /// The user opened the panel (hotkey or menu), right before it appears.
    func panelOpened() {
        generation += 1
        task?.cancel()
        task = nil
        isCapturing = false
        guard Self.replacesChips(current: panelState.attachments, inputText: panelState.inputText) else { return }
        if !panelState.attachments.isEmpty {
            panelState.attachments = []
        }
        guard settings.capturesSelectionOnOpen else { return }
        let generation = generation
        let capturer = capturer
        let budget = budget
        captureCount += 1
        isCapturing = true
        task = Task { [weak self] in
            let context = try? await AgentLoop.runWithDeadline(budget) { await capturer.capture(.chips) }
            self?.finish(context, generation: generation)
        }
    }

    /// The panel closed: a capture still running is dropped.
    func panelClosed() {
        drop()
    }

    /// The user sent the message (the chips went with it): a capture still running is dropped.
    func messageSent() {
        drop()
    }

    /// Whether an open replaces the chips: always, unless the input holds
    /// unsent text and the user kept chips with it.
    nonisolated static func replacesChips(current: [ContextAttachment], inputText: String) -> Bool {
        current.isEmpty || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func drop() {
        generation += 1
        if task != nil, isCapturing { lastOutcome = .dropped }
        task?.cancel()
        task = nil
        isCapturing = false
    }

    private func finish(_ context: FrontmostContext?, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        isCapturing = false
        guard let context, panelState.isVisible else {
            lastOutcome = .dropped
            return
        }
        let chips = context.attachments()
        guard !chips.isEmpty else {
            lastOutcome = .nothing
            return
        }
        panelState.attachments = chips
        lastOutcome = .chips
        // The keyboard stays in the input: VoiceOver would not notice the chips.
        let labels = chips.map(\.label).joined(separator: ", ")
        announcer?.announce(String(format: String(localized: "Context added: %@"), labels), priority: .medium)
    }
}

/// Keeps `PermissionManager.featurePermissions` in step with what reads the
/// context of a request: Accessibility and Automation: Finder are listed in
/// Settings and the onboarding while the context chips ("Use the selection
/// when opening") or `get_frontmost_context` are on, and read again when they
/// come back.
@MainActor
final class ContextPermissionSync {
    private let settings: SettingsStore
    private let hasContextTool: Bool
    private weak var permissions: PermissionManager?

    init(settings: SettingsStore, registry: ToolRegistry, permissions: PermissionManager) {
        self.settings = settings
        hasContextTool = registry.tool(named: GetFrontmostContextTool.toolName) != nil
        self.permissions = permissions
        observe()
    }

    /// What the settings ask for right now.
    var wanted: Set<PermissionKind> {
        PermissionManager.contextPermissions(capturesSelection: settings.capturesSelectionOnOpen,
                                             contextToolEnabled: hasContextTool && settings.isToolEnabled(GetFrontmostContextTool.toolName))
    }

    /// Applies `wanted` now and again after every change of the settings it reads.
    private func observe() {
        let wanted = withObservationTracking {
            self.wanted
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        if let permissions, permissions.featurePermissions != wanted {
            permissions.featurePermissions = wanted
        }
    }
}
