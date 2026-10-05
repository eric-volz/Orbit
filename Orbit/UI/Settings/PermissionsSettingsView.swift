import AppKit
import SwiftUI

/// "Permissions": every permission Orbit uses with its status, why Orbit
/// needs it and a button to ask macOS or open System Settings, plus how mail
/// search works right now. Reading the statuses never asks the user.
struct PermissionsSettingsView: View {
    let manager: PermissionManager
    /// How `search_mail` searches (Spotlight or Mail); nil without mail tools.
    let mailSearch: (any MailSpotlightSearching)?
    /// "Restart Orbit" (after Full Disk Access was turned on).
    let relaunch: @MainActor () -> Void
    /// Tells VoiceOver what macOS answered to "Allow…".
    var announcer: (any Announcing)? = nil

    @State private var mailSearchMode: MailSearchMode?
    @State private var isCheckingMailSearch = false
    /// Accessibility is answered in System Settings: its status is read when Orbit reads a new one.
    @State private var answers = PermissionAnswers()

    var body: some View {
        Form {
            Section {
                ForEach(manager.permissions) { permission in
                    PermissionRow(
                        permission: permission,
                        status: manager.statuses[permission],
                        isRequesting: manager.requesting.contains(permission),
                        request: {
                            Task {
                                await manager.request(permission)
                                announcer?.announce(answers.requested(permission, status: manager.statuses[permission]),
                                                    priority: .high)
                            }
                        },
                        openSettings: { Task { await manager.openSystemSettings(for: permission) } }
                    )
                }
            } header: {
                Text("Access")
            } footer: {
                Text("Every permission is optional. Without one, Orbit turns off the related tools and tells the assistant. macOS asks only when you click “Allow…” here or when a tool needs access for the first time.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let mailSearch {
                Section {
                    mailSearchRow(mailSearch)
                } header: {
                    Text("Mail Search")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Refresh Status") {
                        Task { await manager.refresh() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await manager.refresh()
        }
        // Back from System Settings: show what changed there (Orbit itself only
        // re-reads the permissions its tools need when it becomes active).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await manager.refresh() }
        }
        .onChange(of: manager.statuses) { _, statuses in
            for answer in answers.statusesRead(statuses) {
                announcer?.announce(answer, priority: .high)
            }
        }
        .task {
            guard let mailSearch else { return }
            mailSearchMode = mailSearch.lastKnownSearchMode
            if mailSearchMode == nil {
                await checkMailSearch(mailSearch, again: false)
            }
        }
    }

    // MARK: Mail search

    @ViewBuilder
    private func mailSearchRow(_ mailSearch: any MailSpotlightSearching) -> some View {
        LabeledContent {
            if isCheckingMailSearch || mailSearchMode == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(verbatim: Self.modeTitle(mailSearchMode))
                    .foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("How Orbit Searches Mail")
                Text(verbatim: Self.modeExplanation(mailSearchMode))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 10) {
            Button("Check Again") {
                Task { await checkMailSearch(mailSearch, again: true) }
            }
            .disabled(isCheckingMailSearch)
            .help(Text("Asks Spotlight again whether it shows your mail to Orbit. No message is read."))
            if mailSearchMode == .appleScript {
                Button("Restart Orbit") {
                    relaunch()
                }
                .help(Text("If you just turned on Full Disk Access, it takes effect after Orbit restarts."))
            }
            Spacer()
        }
    }

    private func checkMailSearch(_ mailSearch: any MailSpotlightSearching, again: Bool) async {
        isCheckingMailSearch = true
        if again {
            mailSearch.forgetAvailability()
        }
        mailSearchMode = await mailSearch.searchMode()
        isCheckingMailSearch = false
    }

    static func modeTitle(_ mode: MailSearchMode?) -> String {
        switch mode {
        case .spotlight: String(localized: "Through Spotlight")
        case .appleScript: String(localized: "Through Mail")
        case nil: String(localized: "Checking…")
        }
    }

    static func modeExplanation(_ mode: MailSearchMode?) -> String {
        switch mode {
        case .spotlight:
            String(localized: "Fast, in all mailboxes at once, and also in the text of the messages. For unread mail and for Sent, Drafts, Junk and Trash, Orbit still asks Mail, which searches by subject and sender only.")
        case .appleScript:
            String(localized: "Orbit asks Mail directly. This always works but is slower with large mailboxes and searches only subjects and senders. With Full Disk Access, Spotlight may show your mail to Orbit; Orbit then searches there, including the text of the messages.")
        case nil:
            String(localized: "Orbit checks whether Spotlight shows your mail to Orbit. No message is read.")
        }
    }
}

/// One permission: icon, name, status, why Orbit needs it, a note for the
/// status and the button (ask macOS, or open System Settings).
struct PermissionRow: View {
    let permission: PermissionKind
    /// nil: not read yet.
    let status: PermissionStatus?
    let isRequesting: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: PermissionCopy.systemImage(permission))
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: permission.displayName)
                        .fontWeight(.medium)
                    PermissionStatusLabel(status: status, isRequesting: isRequesting)
                }
                Text(verbatim: PermissionCopy.purpose(permission))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = PermissionCopy.hint(permission, status: status) {
                    Text(verbatim: hint)
                        .font(.callout)
                        .foregroundStyle(PermissionCopy.isWarning(status) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // VoiceOver reads name, status and explanation as one; the button stays separate.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            actionButton
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let status {
            let canRequest = permission.canRequest(from: status)
            Button {
                canRequest ? request() : openSettings()
            } label: {
                Text(verbatim: PermissionCopy.actionTitle(permission, status: status))
            }
            // Nothing to do while it is allowed: the button stays for changing it.
            .controlSize(status == .granted ? .small : .regular)
            .disabled(isRequesting)
            .help(canRequest ? Text("Asks macOS for permission now.")
                  : Text("Opens Privacy & Security in System Settings."))
            .accessibilityLabel(Text(verbatim: PermissionCopy.actionAccessibilityLabel(permission, status: status)))
        }
    }
}

/// The status of a permission: icon and word, or a spinner while it is
/// read or requested.
struct PermissionStatusLabel: View {
    let status: PermissionStatus?
    var isRequesting = false

    var body: some View {
        if isRequesting || status == nil {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(verbatim: isRequesting ? String(localized: "Waiting for macOS…") : PermissionCopy.statusTitle(nil))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Label {
                Text(verbatim: PermissionCopy.statusTitle(status))
            } icon: {
                Image(systemName: PermissionCopy.statusImage(status))
            }
            .font(.callout)
            .foregroundStyle(PermissionCopy.statusColor(status))
        }
    }
}
