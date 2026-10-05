import SwiftUI

/// A short note the model wrote between tool calls.
struct ProgressNoteView: View, Equatable {
    let text: String

    var body: some View {
        Text(MarkdownInline.attributedString(from: text, fontSize: 12.5))
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineSpacing(1.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A subtle status line for a tool call: "Searching mail…" → "Found 12 emails".
struct ToolStatusRow: View, Equatable {
    let status: ToolStatus

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: status.category?.systemImage ?? "wrench.and.screwdriver")
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(verbatim: status.text)
                .lineLimit(2)
                .truncationMode(.tail)
            stateIndicator
                .frame(width: 14, height: 14)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: status.text))
        .accessibilityValue(Self.stateDescription(status.state))
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch status.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    static func stateDescription(_ state: ToolStatus.State) -> Text {
        switch state {
        case .running: Text("Running")
        case .succeeded: Text("Completed")
        case .failed: Text("Failed")
        case .cancelled: Text("Canceled")
        }
    }
}

/// An info, warning or error message with up to two buttons, the fitting one
/// first ("Open Settings", "Try Again", "Sign In…", "New Chat").
struct NoticeRow: View {
    let notice: Notice
    /// Whether the buttons that act on the request are offered (retry,
    /// sign-in, new chat): only for the latest notice while nothing is running.
    /// Settings stay reachable.
    let isActionAvailable: Bool
    /// "Sign In…" of this notice is running: progress and "Cancel" instead of the buttons.
    var isSigningIn = false
    let onAction: (Notice.Action) -> Void
    var onCancelSignIn: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: Self.systemImage(notice.style))
                .font(.system(size: 15))
                .foregroundStyle(Self.color(notice.style))
                .accessibilityHidden(true)
            Text(verbatim: notice.message)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The symbol's meaning, which VoiceOver does not see.
                .accessibilityLabel(Text(verbatim: Self.accessibilityLabel(notice)))
            if isSigningIn {
                signInProgress
            } else {
                ForEach(Self.offeredActions(notice, isActionAvailable: isActionAvailable), id: \.self) { action in
                    actionButton(action)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(Self.color(notice.style).opacity(notice.style == .info ? 0.08 : 0.1))
        )
        .contrastEdge(RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous),
                      color: Self.color(notice.style))
        .accessibilityElement(children: .contain)
    }

    /// What VoiceOver reads: the message, for a warning or an error with what it is
    /// ("Error: The server … cannot be reached."); the symbol says it on the screen.
    static func accessibilityLabel(_ notice: Notice) -> String {
        switch notice.style {
        case .info: notice.message
        case .warning: String(format: String(localized: "Warning: %@"), notice.message)
        case .error: String(format: String(localized: "Error: %@"), notice.message)
        }
    }

    /// The buttons shown: "Open Settings" always, the others only while available.
    static func offeredActions(_ notice: Notice, isActionAvailable: Bool) -> [Notice.Action] {
        notice.actions.filter { $0.settingsTab != nil || isActionAvailable }
    }

    private var signInProgress: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text("Signing in through your browser…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Cancel", action: onCancelSignIn)
                .controlSize(.small)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func actionButton(_ action: Notice.Action) -> some View {
        let button = Button {
            onAction(action)
        } label: {
            Label(Self.title(action), systemImage: Self.actionImage(action))
        }
        .controlSize(.small)
        .fixedSize()
        switch action {
        case .retry:
            // ⌘R: only the latest notice offers retry, so the shortcut is unambiguous.
            button
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("Try Again (⌘R)"))
        case .openSettings:
            button
                .help(Text("Open Settings (⌘,)"))
        case .openPermissionSettings:
            button
                .help(Text("Opens Orbit’s settings under “Permissions”"))
                .accessibilityHint(Text("Opens Orbit’s settings under “Permissions”"))
        case .signIn:
            button
                .help(Text("Opens Anthropic’s sign-in in your browser. Orbit never sees your credentials."))
                .accessibilityHint(Text("Opens Anthropic’s sign-in in your browser. Orbit then sends the request again."))
        case .newChat:
            button
                .help(Text("New Chat (⌘N)"))
        }
    }

    static func systemImage(_ style: Notice.Style) -> String {
        switch style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    static func color(_ style: Notice.Style) -> Color {
        switch style {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }

    static func title(_ action: Notice.Action) -> String {
        switch action {
        case .retry: String(localized: "Try Again")
        case .openSettings, .openPermissionSettings: String(localized: "Open Settings")
        case .signIn: String(localized: "Sign In…")
        case .newChat: String(localized: "New Chat")
        }
    }

    static func actionImage(_ action: Notice.Action) -> String {
        switch action {
        case .retry: "arrow.clockwise"
        case .openSettings, .openPermissionSettings: "gearshape"
        case .signIn: "person.crop.circle"
        case .newChat: "square.and.pencil"
        }
    }
}

/// Footnote on what was sent to the provider: "3 emails and 1 file sent to Claude".
struct DisclosureRow: View, Equatable {
    let items: [ContentDisclosure]
    let providerName: String

    var body: some View {
        if let text = DisclosurePhrase.text(for: items, providerName: providerName) {
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: "arrow.up.forward.circle")
            }
            .font(Theme.footnoteFont)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Text("This content was sent to the provider for the answer."))
        }
    }
}
