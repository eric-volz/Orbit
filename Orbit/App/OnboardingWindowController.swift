import AppKit
import SwiftUI

/// The onboarding window ("Set Up Orbit"). AppDelegate shows it at launch
/// until the user has seen it once, and once more (with only those steps)
/// after an update that brought permissions the user never had a step for
/// (`OnboardingPlan`); the menu bar menu reopens the whole onboarding
/// ("Setup…"). Closing it in any way ("Done", "Later", the close
/// button, ⌘W) counts as seen, with all of its permission steps; the next
/// opening starts at its first step again.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let environment: AppEnvironment
    private let hidePanel: () -> Void
    private(set) var window: NSWindow?
    private(set) var model: OnboardingModel?

    init(environment: AppEnvironment, hidePanel: @escaping () -> Void) {
        self.environment = environment
        self.hidePanel = hidePanel
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window (a running onboarding stays at its step and in its
    /// mode), optionally at `step`; a new one shows the steps of `mode`.
    func show(at step: OnboardingModel.Step? = nil, mode: OnboardingModel.Mode = .full) {
        hidePanel()
        let window = prepareWindow(mode: mode)
        if let step {
            model?.go(to: step)
        }
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14; the window still comes to the front.
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        didClose()
        // Like Settings: hand the focus back to the app the user came from
        // instead of leaving a windowless Orbit active.
        guard NSApp.isActive, !environment.panelState.isVisible,
              !NSApp.hasOtherTitledWindow(besides: closing) else { return }
        Task { @MainActor in
            NSApp.hide(nil)
        }
    }

    /// The onboarding was seen, with all of its permission steps, so an
    /// update shows only steps that are new since; the next opening starts
    /// from the beginning. An API key typed but not saved yet is stored first
    /// (the close button and ⌘W leave from any step).
    func didClose() {
        model?.saveDraftIfNeeded()
        if let steps = model?.permissionSteps, !steps.isEmpty {
            environment.settings.presentedOnboardingPermissions.formUnion(steps)
        }
        environment.settings.hasCompletedOnboarding = true
        window = nil
        model = nil
        Log.app.info("Onboarding closed")
    }

    /// The window and its model, made on first use (not shown yet).
    func prepareWindow(mode: OnboardingModel.Mode = .full) -> NSWindow {
        window ?? makeWindow(mode: mode)
    }

    private func makeWindow(mode: OnboardingModel.Mode) -> NSWindow {
        let model = makeModel(mode: mode)
        let hostingController = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Set Up Orbit")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.setContentSize(OnboardingView.size)
        window.center()
        self.window = window
        self.model = model
        return window
    }

    private func makeModel(mode: OnboardingModel.Mode) -> OnboardingModel {
        let agentLoop = environment.agentLoop
        return OnboardingModel(
            settings: environment.settings,
            permissions: environment.permissions,
            secrets: environment.secrets,
            validate: { configuration, model in
                try await agentLoop.validate(configuration: configuration, model: model)
            },
            claudeCodeAccount: ClaudeCodeAccountModel(
                loadStatus: { await agentLoop.claudeCodeStatus() },
                signIn: { try await agentLoop.signInToClaudeCode() },
                announcer: environment.services.announcer
            ),
            announcer: environment.services.announcer,
            mode: mode,
            onFinish: { [weak self] in
                // Not from inside the button action that hosts it.
                Task { @MainActor in self?.close() }
            }
        )
    }
}
