import AppKit
import SwiftUI

/// "Privacy": where chats are stored, deleting the history, and what
/// leaves the Mac.
struct PrivacySettingsView: View {
    let settings: SettingsStore
    /// Tells VoiceOver whether the history was deleted.
    var announcer: (any Announcing)? = nil
    /// Returns whether the history was deleted.
    let clearHistory: @MainActor () async -> Bool

    @State private var isConfirmingClear = false
    @State private var clearState: ClearState = .idle

    enum ClearState: Equatable {
        case idle
        case clearing
        case done
        case failed
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Show in Finder", action: revealDataFolder)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage location")
                        Text(verbatim: FilePathFormatter.abbreviate(AppPaths.applicationSupport.path))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button("Delete Chat History…", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .disabled(clearState == .clearing)
                    switch clearState {
                    case .idle:
                        EmptyView()
                    case .clearing:
                        ProgressView()
                            .controlSize(.small)
                    case .done:
                        Label(Self.clearOutcome(true), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    case .failed:
                        Label(Self.clearOutcome(false), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Chat History")
            } footer: {
                Text("Your chats are stored only on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Label {
                    Text(verbatim: Self.networkText(provider: settings.providerKind, host: providerHost))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "network")
                }
                Label("Orbit sends no telemetry or analytics data.", systemImage: "hand.raised")
                Label {
                    Text("Below each answer, the chat shows which content (such as emails or files) was sent to the provider.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.up.forward.circle")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the entire chat history?", isPresented: $isConfirmingClear) {
            Button("Delete Chat History", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All saved chats are removed from this Mac. This cannot be undone.")
        }
    }

    private var providerHost: String {
        if let host = settings.baseURL?.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        switch settings.providerKind {
        case .anthropic, .claudeCode: return "api.anthropic.com"
        case .openAICompatible: return String(localized: "not set up")
        }
    }

    /// Where content goes: with the Claude subscription Claude Code connects
    /// to Anthropic, not Orbit (it only listens on 127.0.0.1 for Claude Code's
    /// tool calls); otherwise Orbit connects to the provider's host.
    static func networkText(provider: ProviderKind, host: String) -> String {
        guard provider != .claudeCode else {
            return String(localized: "With the Claude subscription, Claude Code connects to Anthropic. Orbit itself makes no connection to the internet.")
        }
        return String(format: String(localized: "Orbit’s only network connection is to the language model provider you set up (%@)."), host)
    }

    private func clear() {
        clearState = .clearing
        Task {
            let cleared = await clearHistory()
            clearState = cleared ? .done : .failed
            announcer?.announce(Self.clearOutcome(cleared), priority: .high)
        }
    }

    /// What the label next to "Delete Chat History…" says afterwards.
    static func clearOutcome(_ cleared: Bool) -> String {
        cleared ? String(localized: "Chat history deleted")
            : String(localized: "The chat history could not be deleted. Please try again.")
    }

    private func revealDataFolder() {
        let folder = AppPaths.applicationSupport
        Task {
            await Task.detached(priority: .userInitiated) {
                try? AppPaths.ensureApplicationSupportExists()
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
