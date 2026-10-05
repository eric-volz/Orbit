import AppKit
import SwiftUI

/// What chat rows can trigger. Wired to AgentLoop / PanelState by RootView.
struct ChatActions {
    var resolveConfirmation: (UUID, ConfirmationDecision) -> Void = { _, _ in }
    var retry: () -> Void = {}
    /// Opens Settings on a tab.
    var openSettings: (SettingsTab) -> Void = { _ in }
    /// "Sign In…": Claude Code's sign-in, then the request again.
    var signIn: () -> Void = {}
    var cancelSignIn: () -> Void = {}
    /// "New Chat": the same as ⌘N. The request the chat could no longer
    /// answer goes into the new chat's input (`AgentLoop.requestForNewChat`).
    var newChat: () -> Void = {}
}

/// The chat: a scroll view that is as tall as its content (at most
/// `maxHeight`) and follows new content while the user is at the bottom.
struct ChatView: View {
    let items: [ChatItem]
    let isRunning: Bool
    /// "Sign In…" of the latest notice is running (`AgentLoop.isSigningIn`).
    var isSigningIn = false
    let conversationID: UUID
    let maxHeight: CGFloat
    /// See `ConfirmationCard.approveShortcutEnabled`.
    var approveShortcutEnabled = true
    /// Keyboard scrolling (Page Up/Down, Home/End) from the input field.
    var scroller: ChatScroller?
    let actions: ChatActions

    @State private var contentHeight: CGFloat = 0
    @State private var pinning = ScrollPinning()
    @Environment(FileCardCoordinator.self) private var fileCards: FileCardCoordinator?
    /// Learns the visible height, so a waiting confirmation card knows whether it is in view.
    @Environment(ConfirmationKeyboard.self) private var confirmationKeyboard: ConfirmationKeyboard?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy: rows scrolled out of view are not laid out again for every
                // streamed delta, so long chats stay fast.
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lastActionable = ChatLayout.lastActionableIndex(in: items)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ChatItemRow(
                            item: item,
                            isActionAvailable: !isRunning && index == lastActionable,
                            isSigningIn: isSigningIn && index == lastActionable,
                            approveShortcutEnabled: approveShortcutEnabled,
                            actions: actions
                        )
                        .equatable()
                        .padding(.top, ChatLayout.topSpacing(after: index > 0 ? items[index - 1].kind : nil, before: item.kind))
                        .id(item.id)
                    }
                    if ChatActivity.showsWaitingIndicator(items: items, isRunning: isRunning) {
                        TypingIndicator()
                            .padding(.top, items.isEmpty ? 0 : 10)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id(ChatView.bottomID)
                }
                .padding(.horizontal, Theme.contentInset)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .background(ScrollViewAccessor(scroller: scroller))
                .onGeometryChange(for: ContentGeometry.self) { geometry in
                    let frame = geometry.frame(in: .named(chatScrollSpace))
                    return ContentGeometry(height: frame.height, offset: -frame.minY)
                } action: { geometry in
                    contentHeight = geometry.height
                    let viewport = min(geometry.height, maxHeight)
                    if pinning.update(contentHeight: geometry.height, offset: geometry.offset, viewportHeight: viewport) {
                        proxy.scrollTo(ChatView.bottomID, anchor: .bottom)
                    }
                }
            }
            .coordinateSpace(.named(chatScrollSpace))
            .frame(height: max(0, min(contentHeight, maxHeight)))
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                confirmationKeyboard?.viewportHeight = height
            }
            .scrollDisabled(contentHeight <= maxHeight)
            .onChange(of: items.last?.id) {
                // A new message from the user always brings the chat back to the bottom.
                if case .user? = items.last?.kind {
                    pinning.pin()
                    proxy.scrollTo(ChatView.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: conversationID) {
                pinning = ScrollPinning()
            }
            // A file card or row the keyboard moved to.
            .onChange(of: fileCards?.scrollRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    // Rows that just appeared (an expanded card) are laid out first.
                    await Task.yield()
                    switch request.target {
                    case .card(let id): proxy.scrollTo(id)
                    case .row(let id): proxy.scrollTo(id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Chat"))
    }

    private static let bottomID = "chat-bottom"
}

/// The chat content's size and scroll offset, measured inside the scroll view.
private struct ContentGeometry: Equatable, Sendable {
    var height: CGFloat
    var offset: CGFloat
}

/// The coordinate space of the chat's scroll view: a row's frame in it is
/// relative to the visible part (confirmation cards use it to tell whether
/// they are in view).
let chatScrollSpace = "orbit.chat.scroll"

/// Decides when the chat follows new content ("sticks to the bottom").
///
/// The chat is pinned while the user is at (or near) the bottom. Scrolling up
/// unpins it; new content then no longer moves the view. Scrolling back down
/// to the bottom, or sending a message, pins it again.
struct ScrollPinning: Equatable {
    /// Distance from the bottom that still counts as "at the bottom".
    static let tolerance: CGFloat = 32

    private(set) var isPinned = true
    private var lastHeight: CGFloat?
    private var lastOffset: CGFloat?

    /// Feeds new geometry. Returns true when the view should scroll to the bottom.
    mutating func update(contentHeight: CGFloat, offset: CGFloat, viewportHeight: CGFloat) -> Bool {
        defer {
            lastHeight = contentHeight
            lastOffset = offset
        }
        let scrollableHeight = contentHeight - viewportHeight
        guard scrollableHeight > 0.5 else {
            // Everything is visible.
            isPinned = true
            return false
        }
        let distanceToBottom = scrollableHeight - offset
        if let lastOffset, abs(offset - lastOffset) > 0.5 {
            // The view scrolled (by the user, or by us): pinned if it ended at the bottom.
            isPinned = distanceToBottom <= Self.tolerance
        }
        let heightChanged = lastHeight.map { abs(contentHeight - $0) > 0.5 } ?? true
        return isPinned && heightChanged && distanceToBottom > 0.5
    }

    /// Follows new content again (e.g. after the user sent a message).
    mutating func pin() {
        isPinned = true
    }
}

/// Vertical rhythm of the chat: turns are clearly separated, consecutive
/// status lines sit close together.
enum ChatLayout {
    /// The row whose action (e.g. "Try Again") is offered: the last one,
    /// not counting disclosure notes that follow it.
    static func lastActionableIndex(in items: [ChatItem]) -> Int? {
        items.lastIndex { item in
            if case .disclosure = item.kind { return false }
            return true
        }
    }

    static func topSpacing(after previous: ChatItem.Kind?, before current: ChatItem.Kind) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous, current) {
        case (_, .user):
            return 22
        case (_, .disclosure):
            return 6
        case (.toolStatus, .toolStatus), (.toolStatus, .progress), (.progress, .toolStatus), (.progress, .progress):
            return 6
        default:
            return 12
        }
    }
}

/// Whether the chat shows the "Orbit is answering…" indicator at its end.
enum ChatActivity {
    /// While a request runs and nothing else shows progress: no streaming
    /// answer, no running tool and no confirmation waiting for the user.
    static func showsWaitingIndicator(items: [ChatItem], isRunning: Bool) -> Bool {
        guard isRunning else { return false }
        guard let last = items.last else { return true }
        switch last.kind {
        case .assistant(_, let isStreaming): return !isStreaming
        case .toolStatus(let status): return status.state != .running
        case .confirmation(let state): return state.status != .pending
        case .user, .progress, .card, .notice, .disclosure: return true
        }
    }
}

/// One chat row. Equatable (ignoring the action closures) so rows that did
/// not change are not re-rendered while an answer streams in.
struct ChatItemRow: View, Equatable {
    let item: ChatItem
    let isActionAvailable: Bool
    /// The sign-in of this row's notice is running.
    var isSigningIn = false
    var approveShortcutEnabled = true
    let actions: ChatActions

    nonisolated static func == (lhs: ChatItemRow, rhs: ChatItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isActionAvailable == rhs.isActionAvailable && lhs.isSigningIn == rhs.isSigningIn
            && lhs.approveShortcutEnabled == rhs.approveShortcutEnabled
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserMessageView(text: text, attachments: attachments)
        case .assistant(let text, let isStreaming):
            AssistantMessageView(text: text, isStreaming: isStreaming)
        case .progress(let text):
            ProgressNoteView(text: text)
        case .toolStatus(let status):
            ToolStatusRow(status: status)
        case .card(let card):
            ResultCardView(card: card, id: item.id)
        case .confirmation(let state):
            ConfirmationCard(state: state, approveShortcutEnabled: approveShortcutEnabled) { decision in
                actions.resolveConfirmation(state.request.id, decision)
            }
        case .notice(let notice):
            NoticeRow(notice: notice, isActionAvailable: isActionAvailable,
                      isSigningIn: isSigningIn && notice.actions.contains(.signIn)) { action in
                switch action {
                case .retry: actions.retry()
                case .signIn: actions.signIn()
                case .newChat: actions.newChat()
                case .openSettings, .openPermissionSettings: action.settingsTab.map(actions.openSettings)
                }
            } onCancelSignIn: {
                actions.cancelSignIn()
            }
        case .disclosure(let items, let providerName):
            DisclosureRow(items: items, providerName: providerName)
        }
    }
}

extension Notice.Action {
    /// The tab "Open Settings" opens: Model for the model's errors (a
    /// missing key, an unknown model), Permissions for a permission macOS
    /// refused; nil for the buttons that act on the chat.
    var settingsTab: SettingsTab? {
        switch self {
        case .retry, .signIn, .newChat: nil
        case .openSettings: .model
        case .openPermissionSettings: .permissions
        }
    }
}

/// Scrolls the chat from the keyboard. The chat's SwiftUI `ScrollView` is an
/// `NSScrollView` underneath; `ScrollViewAccessor` hands it over.
@MainActor
final class ChatScroller {
    weak var scrollView: NSScrollView?

    enum Target {
        case pageUp, pageDown, top, bottom
    }

    /// Returns false when there is nothing to scroll.
    @discardableResult
    func scroll(_ target: Target) -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        let origin = Self.origin(for: target, visible: visible, documentHeight: documentView.frame.height,
                                 isFlipped: documentView.isFlipped)
        guard abs(origin.y - visible.origin.y) > 0.5 else { return false }
        // Immediately (not animated): a quick second key press builds on the new position.
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    /// The new origin of the visible rect. A page is 90 % of the visible height,
    /// so a line of context stays in view.
    nonisolated static func origin(for target: Target, visible: CGRect, documentHeight: CGFloat, isFlipped: Bool) -> CGPoint {
        let maxY = max(0, documentHeight - visible.height)
        let page = visible.height * 0.9
        // In a flipped document, y grows toward the end of the chat.
        let towardEnd: CGFloat = isFlipped ? 1 : -1
        let y: CGFloat
        switch target {
        case .pageUp: y = visible.origin.y - towardEnd * page
        case .pageDown: y = visible.origin.y + towardEnd * page
        case .top: y = isFlipped ? 0 : maxY
        case .bottom: y = isFlipped ? maxY : 0
        }
        return CGPoint(x: visible.origin.x, y: min(max(y, 0), maxY))
    }
}

/// Finds the `NSScrollView` around its position in the view hierarchy.
private struct ScrollViewAccessor: NSViewRepresentable {
    let scroller: ChatScroller?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let scroller else { return }
        // The view joins the hierarchy after this call.
        DispatchQueue.main.async {
            scroller.scrollView = view.enclosingScrollView
        }
    }
}
