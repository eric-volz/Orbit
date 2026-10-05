import Foundation
import Observation

/// What mail cards do on a click, the user's own action: a message opens in
/// Mail through its message:// link, "Show in Mail" brings a draft or reply
/// window Orbit opened to the front (through the same script permission as
/// the tools), and "Copy Text" puts a reply's text on the clipboard again.
/// Something that cannot be done becomes `failure`, which RootView explains
/// under the input. RootView creates it; cards without one (snapshots of single
/// views) open messages directly and show no draft buttons.
@MainActor
@Observable
final class MailCardActions {
    /// Something the user wanted that did not happen.
    struct Failure: Equatable, Sendable {
        enum Reason: Sendable {
            /// No app opened the message link.
            case messageNotOpened
            /// The draft window is no longer open (sent, saved and closed, or discarded).
            case draftClosed
            /// macOS does not let Orbit control Mail.
            case notPermitted
            /// Mail did not show the draft for another reason.
            case draftNotShown
            /// The reply's text could not be put on the clipboard.
            case textNotCopied
        }

        /// The message's subject (empty for drafts).
        var subject: String
        var reason: Reason
        /// Tells repeated failures apart.
        var count: Int
    }

    /// The latest failure.
    private(set) var failure: Failure?

    @ObservationIgnored private let mail: MailService
    @ObservationIgnored private let opener: any MessageLinkOpening
    @ObservationIgnored private let pasteboard: any PasteboardWriting

    init(mail: MailService, opener: any MessageLinkOpening, pasteboard: any PasteboardWriting = DisabledPasteboard()) {
        self.mail = mail
        self.opener = opener
        self.pasteboard = pasteboard
    }

    /// Whether a row can be opened (it has a Message-ID).
    nonisolated static func canOpen(_ item: MailItem) -> Bool {
        item.messageID.flatMap(MailLink.url(messageID:)) != nil
    }

    /// Opens the message in Mail (message:// link).
    @discardableResult
    func open(_ item: MailItem) -> Task<Void, Never> {
        let opener = opener
        let subject = item.subject
        return Task {
            guard let url = item.messageID.flatMap(MailLink.url(messageID:)) else { return }
            do {
                try await opener.open(url)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Opening a message from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report(subject, .messageNotOpened)
            }
        }
    }

    /// Whether a draft card offers "Show in Mail".
    nonisolated static func canShow(_ draft: MailDraftItem) -> Bool {
        draft.isOpenInMail && draft.draftID != nil
    }

    /// Brings the draft's window to the front in Mail (off the main actor).
    @discardableResult
    func showDraft(_ draft: MailDraftItem) -> Task<Void, Never> {
        let mail = mail
        return Task {
            guard let id = draft.draftID else { return }
            do {
                let shown = try await mail.showDraft(id: id)
                if !shown { report("", .draftClosed) }
            } catch AppleScriptError.notAuthorized {
                report("", .notPermitted)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Showing a draft from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report("", .draftNotShown)
            }
        }
    }

    /// Whether a draft card offers "Copy Text": a reply with text, which
    /// the user pastes into Mail's reply window.
    nonisolated static func canCopyText(_ draft: MailDraftItem) -> Bool {
        draft.reply != nil && !draft.body.isEmpty
    }

    /// Puts a reply's text on the clipboard (again); true when it is there.
    @discardableResult
    func copyText(_ draft: MailDraftItem) -> Task<Bool, Never> {
        let pasteboard = pasteboard
        let text = draft.body
        return Task {
            guard !text.isEmpty else { return false }
            if await pasteboard.write(text) { return true }
            Log.panel.error("Copying a reply's text from a card failed")
            report("", .textNotCopied)
            return false
        }
    }

    private func report(_ subject: String, _ reason: Failure.Reason) {
        failure = Failure(subject: subject, reason: reason, count: (failure?.count ?? 0) + 1)
    }
}
