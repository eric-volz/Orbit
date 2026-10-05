import AppKit
import Testing
@testable import Orbit

@Suite("FileCardSelection")
struct FileCardSelectionTests {
    @Test func startsWithoutASelectionAndCollapsed() {
        let selection = FileCardSelection(count: 7)
        #expect(selection.index == nil)
        #expect(!selection.isExpanded)
        #expect(selection.isCollapsible)
        #expect(selection.visibleCount == 5)
        #expect(selection.hiddenCount == 2)
        #expect(!FileCardSelection(count: 5).isCollapsible)
        #expect(FileCardSelection(count: 3).visibleCount == 3)
        #expect(FileCardSelection(count: 0).visibleCount == 0)
    }

    @Test func arrowsStartAtTheFirstRowAndStopAtTheEnds() {
        var down = FileCardSelection(count: 3)
        down.moveDown()
        #expect(down.index == 0)
        down.moveDown()
        down.moveDown()
        down.moveDown()
        #expect(down.index == 2, "no wrap-around")

        var up = FileCardSelection(count: 3)
        up.moveUp()
        #expect(up.index == 0)
        up.moveUp()
        #expect(up.index == 0)
    }

    @Test func movingPastTheCollapsedRowsExpandsTheCard() {
        var selection = FileCardSelection(count: 7, index: 4)
        #expect(!selection.isExpanded)
        selection.moveDown()
        #expect(selection.index == 5)
        #expect(selection.isExpanded)
        #expect(selection.visibleCount == 7)
        #expect(selection.hiddenCount == 0)
    }

    @Test func selectingAHiddenRowExpandsAndIndexesAreClamped() {
        var selection = FileCardSelection(count: 7)
        selection.select(6)
        #expect(selection.index == 6)
        #expect(selection.isExpanded)
        selection.select(40)
        #expect(selection.index == 6)
        selection.select(-3)
        #expect(selection.index == 0)
        #expect(FileCardSelection(count: 7, index: 6).isExpanded)
    }

    @Test func collapsingMovesAHiddenSelectionToTheLastRowShown() {
        var selection = FileCardSelection(count: 8, index: 6)
        selection.toggleExpanded()
        #expect(!selection.isExpanded)
        #expect(selection.index == 4)
        selection.toggleExpanded()
        #expect(selection.isExpanded)
        #expect(selection.index == 4)

        var small = FileCardSelection(count: 3, index: 1)
        small.toggleExpanded()
        #expect(!small.isExpanded, "nothing to hide")
    }

    @Test func focusSelectsTheFirstRowOnlyWhenNothingIsSelected() {
        var selection = FileCardSelection(count: 4)
        selection.selectFirstIfNeeded()
        #expect(selection.index == 0)
        selection.select(2)
        selection.selectFirstIfNeeded()
        #expect(selection.index == 2)

        var empty = FileCardSelection(count: 0)
        empty.selectFirstIfNeeded()
        empty.moveDown()
        #expect(empty.index == nil)
    }

    @Test func anotherCountKeepsTheSelectionInRange() {
        var selection = FileCardSelection(count: 7, index: 6)
        selection.updateCount(3)
        #expect(selection.index == 2)
        selection.updateCount(0)
        #expect(selection.index == nil)
    }
}

@Suite("FileCardCoordinator")
@MainActor
struct FileCardCoordinatorTests {
    private let item = FileItem(path: "/Users/orbit-test/Documents/Rechnungen/Rechnung März.pdf", name: "Rechnung März.pdf",
                                contentType: "com.adobe.pdf", size: 2_300_000)

    @Test func opensAndRevealsThroughTheWorkspace() async {
        let workspace = MockWorkspace()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: workspace, pasteboard: nil)
        await coordinator.open(item)?.value
        await coordinator.reveal(item)?.value
        #expect(workspace.opened == [item.url])
        #expect(workspace.revealed == [item.url])
        #expect(coordinator.openFailure == nil)

        // A file no app opens is reported (RootView explains it under the input).
        workspace.failOpening()
        await coordinator.open(item)?.value
        #expect(workspace.opened == [item.url])
        #expect(coordinator.openFailure?.reason == .cannotOpen)
        #expect(coordinator.openFailure?.name == item.name)
    }

    /// Cards stay in the chat for hours: a file moved or deleted since is
    /// reported instead of failing silently, and nothing is opened.
    @Test func aFileThatIsGoneIsReported() async {
        let workspace = MockWorkspace()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: workspace, pasteboard: nil)
        workspace.remove(item.url)
        await coordinator.open(item)?.value
        #expect(workspace.opened.isEmpty)
        #expect(workspace.revealed.isEmpty)
        let failure = coordinator.openFailure
        #expect(failure?.reason == .notFound)
        #expect(failure?.name == "Rechnung März.pdf")

        await coordinator.open(item)?.value
        #expect(coordinator.openFailure != failure, "every attempt is reported")
        #expect(InputHint.fileNotFound(name: "Rechnung März.pdf").text
                == "“Rechnung März.pdf” was not found. It may have been moved or deleted.")
        #expect(InputHint.cannotOpen(name: "Rechnung März.pdf").text == "“Rechnung März.pdf” could not be opened.")
    }

    @Test func theLiveWorkspaceChecksTheDisk() async throws {
        let folder = try TemporaryFolder("workspace-exists")
        defer { folder.remove() }
        let file = try folder.write("Rechnung.pdf", "%PDF-1.4")
        let workspace = LiveFileWorkspace()
        #expect(await workspace.itemExists(at: file))
        #expect(await workspace.itemExists(at: folder.url))
        try FileManager.default.removeItem(at: file)
        #expect(!(await workspace.itemExists(at: file)))
    }

    /// The row the keyboard selects is announced to VoiceOver through the coordinator.
    @Test func selectionsAreAnnouncedThroughTheAnnouncer() {
        let announcer = RecordingAnnouncer()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil, announcer: announcer)
        coordinator.announceSelection(of: item, priority: .high)
        #expect(announcer.announcements.count == 1)
        #expect(announcer.announcements.first?.hasPrefix("Rechnung März.pdf, ") == true)
        #expect(announcer.priorities == [.high])
        FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil).announceSelection(of: item, priority: .high)
    }

    /// Like the agent's open_file: what could run code is shown in Finder instead.
    @Test func programsAndScriptsAreShownInFinderInstead() async throws {
        let folder = try TemporaryFolder("card-open")
        defer { folder.remove() }
        let script = try folder.write("Rechnung.command", "#!/bin/sh\necho hallo\n")
        let app = try folder.makeFolder("Tool.app")
        let document = try folder.write("Rechnung.pdf", "%PDF-1.4")
        let workspace = MockWorkspace()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: workspace, pasteboard: nil)
        for url in [script, app, document] {
            await coordinator.open(FileItem(path: url.path, name: url.lastPathComponent))?.value
        }
        #expect(workspace.opened == [document])
        #expect(workspace.revealed == [script, app])

        #expect(FileCardFormat.opensInFinder(FileItem(path: script.path, name: "Rechnung.command")))
        #expect(FileCardFormat.opensInFinder(FileItem(path: "/Applications/Rechner.app", name: "Rechner",
                                                      contentType: "com.apple.application-bundle", isDirectory: true)))
        #expect(!FileCardFormat.opensInFinder(FileItem(path: document.path, name: "Rechnung.pdf", contentType: "com.adobe.pdf")))
        #expect(!FileCardFormat.opensInFinder(FileItem(path: folder.path, name: "Ordner", isDirectory: true)))
    }

    /// macOS opens a Finder alias's target: a card opens the target only when
    /// it passes the same checks, else it shows the alias in Finder.
    @Test func aliasesOpenTheirTargetOrAreShownInFinder() async throws {
        let folder = try TemporaryFolder("card-alias")
        defer { folder.remove() }
        let (document, scriptAlias, secretAlias, documentAlias) = try await Self.makeAliases(in: folder)
        let policy = FileAccessPolicy(homeDirectory: folder.path, orbitDataDirectory: folder.path + "/Library/Application Support/Orbit")
        let workspace = MockWorkspace()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: workspace, policy: policy, pasteboard: nil)
        for alias in [scriptAlias, secretAlias, documentAlias] {
            await coordinator.open(FileItem(path: alias.path, name: alias.lastPathComponent))?.value
        }
        #expect(workspace.opened.map(\.path) == [document.path], "the checked target is what opens")
        #expect(workspace.revealed.map(\.path) == [scriptAlias.path, secretAlias.path])

        // Without a policy to check the target, an alias is only shown in Finder.
        let unchecked = MockWorkspace()
        let withoutPolicy = FileCardCoordinator(quickLook: nil, workspace: unchecked, pasteboard: nil)
        await withoutPolicy.open(FileItem(path: documentAlias.path, name: "Plan"))?.value
        #expect(unchecked.opened.isEmpty)
        #expect(unchecked.revealed.map(\.path) == [documentAlias.path])
    }

    /// A document, and aliases to a script, a secret and the document, made
    /// off the main actor.
    nonisolated private static func makeAliases(in folder: TemporaryFolder) async throws
        -> (document: URL, scriptAlias: URL, secretAlias: URL, documentAlias: URL) {
        let script = try folder.write("Skripte/aufraeumen.command", "#!/bin/sh\necho hallo\n")
        let secret = try folder.write("Geheim/server.pem", "-----BEGIN PRIVATE KEY-----\n")
        let document = try folder.write("Dokumente/Plan.pdf", "%PDF-1.4")
        return (document,
                try FileSystemTricks.makeFinderAlias(to: script, at: folder.url.appendingPathComponent("Notizen")),
                try FileSystemTricks.makeFinderAlias(to: secret, at: folder.url.appendingPathComponent("Schlüssel")),
                try FileSystemTricks.makeFinderAlias(to: document, at: folder.url.appendingPathComponent("Plan")))
    }

    @Test func withoutServicesNothingHappens() {
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil)
        #expect(coordinator.open(item) == nil)
        #expect(coordinator.reveal(item) == nil)
        coordinator.copyPath(item)
    }

    @Test func copiesTheFullPath() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("vorher", forType: .string)
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: pasteboard)
        coordinator.copyPath(item)
        #expect(pasteboard.string(forType: .string) == item.path)
    }

    @Test func focusRequestsScrollTheCardIntoViewFirst() throws {
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil)
        let card = UUID()
        coordinator.focus(card: card)
        let request = try #require(coordinator.focusRequest)
        #expect(request.cardID == card)
        #expect(coordinator.scrollRequest?.target == .card(card))

        // Only the current request is cleared.
        coordinator.focus(card: card)
        coordinator.didTakeFocus(request)
        #expect(coordinator.focusRequest != nil)
        coordinator.didTakeFocus(try #require(coordinator.focusRequest))
        #expect(coordinator.focusRequest == nil)
    }

    @Test func tabMovesBetweenCardsInChatOrder() throws {
        let cards = [UUID(), UUID(), UUID()]
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil, cardIDs: { cards })
        #expect(coordinator.focusCard(nextTo: cards[0], backward: false))
        #expect(coordinator.focusRequest?.cardID == cards[1])
        #expect(coordinator.scrollRequest?.target == .card(cards[1]), "scrolled into view first")
        #expect(coordinator.focusCard(nextTo: cards[1], backward: true))
        #expect(coordinator.focusRequest?.cardID == cards[0])

        // At the ends the keyboard moves on as usual (e.g. to the input).
        let request = coordinator.focusRequest
        #expect(!coordinator.focusCard(nextTo: cards[2], backward: false))
        #expect(!coordinator.focusCard(nextTo: cards[0], backward: true))
        #expect(!coordinator.focusCard(nextTo: UUID(), backward: false))
        #expect(coordinator.focusRequest == request)
    }

    @Test func cardsWithRowsOrButtonsTakeTheKeyboard() {
        let files = [FileItem(path: "/a/b.pdf", name: "b.pdf")]
        let first = ChatItem(kind: .card(.files(files)))
        let empty = ChatItem(kind: .card(.files([])))
        let info = ChatItem(kind: .card(.info(InfoItem(title: "Completed", systemImage: "checkmark"))))
        let last = ChatItem(kind: .card(.files(files)))
        let items = [ChatItem(kind: .user(text: "Hallo", attachments: [])), first, empty, info, last]
        #expect(FileCardCoordinator.keyboardCardIDs(in: items) == [first.id, last.id])
    }

    /// A11Y-1: Tab reaches the latest card of any kind: mails, notes and a
    /// draft's buttons too; cards without anything to select are skipped.
    @Test func mailNoteAndDraftCardsTakeTheKeyboardToo() {
        let mails = ChatItem(kind: .card(.mails([MailItem(id: "mail:1::INBOX", sender: "Lisa", subject: "Projekt")])))
        let noMails = ChatItem(kind: .card(.mails([])))
        let notes = ChatItem(kind: .card(.notes([NoteItem(id: "x-coredata://n1", title: "Umzug")])))
        let contacts = ChatItem(kind: .card(.contacts([ContactItem(id: "c1", name: "Lisa", emails: ["lisa@example.com"], phones: [])])))
        let reply = ChatItem(kind: .card(.mailDraft(MailDraftItem(to: ["Lisa"], cc: [], subject: "Re: Projekt", body: "Passt.",
                                                                  isOpenInMail: true, reply: MailReplyInfo(toAll: false, isTextOnClipboard: true)))))
        let draft = ChatItem(kind: .card(.mailDraft(MailDraftItem(to: ["Lisa"], cc: [], subject: "Projekt", body: "Hallo",
                                                                  isOpenInMail: true, draftID: 7))))
        let oldDraft = ChatItem(kind: .card(.mailDraft(MailDraftItem(to: ["Lisa"], cc: [], subject: "Projekt", body: "Hallo",
                                                                     isOpenInMail: true))))
        let items = [mails, noMails, notes, contacts, reply, draft, oldDraft]
        #expect(FileCardCoordinator.keyboardCardIDs(in: items) == [mails.id, notes.id, reply.id, draft.id],
                "a draft saved before Orbit knew its window has no button")
    }

    @Test func everyScrollRequestIsNew() {
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: nil)
        let row = FileCardCoordinator.rowID(card: UUID(), index: 3)
        coordinator.scroll(to: .row(row))
        let first = coordinator.scrollRequest
        coordinator.scroll(to: .row(row))
        #expect(coordinator.scrollRequest?.target == .row(row))
        #expect(coordinator.scrollRequest != first, "the chat scrolls again to the same row")
        #expect(row.hasSuffix("-row-3"))
    }
}

@Suite("File card rows")
struct FileRowFormattingTests {
    private let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private let german = Locale(identifier: "de_DE")

    @Test func sizesUseDecimalUnitsLikeFinder() {
        let file = FileItem(path: "/a/b.pdf", name: "b.pdf", size: 2_300_000)
        #expect(FileCardFormat.size(of: file, locale: german) == "2,3 MB")
        #expect(FileCardFormat.size(of: file, locale: Locale(identifier: "en_US")) == "2.3 MB")
        #expect(FileCardFormat.size(of: FileItem(path: "/a/c.txt", name: "c.txt", size: 17_000), locale: german) == "17 kB")
        #expect(FileCardFormat.size(of: FileItem(path: "/a/d", name: "d", size: 4_096, isDirectory: true), locale: german) == nil)
        #expect(FileCardFormat.size(of: FileItem(path: "/a/e", name: "e"), locale: german) == nil)
    }

    @Test func voiceOverReadsFolderDateAndSize() {
        let now = FlexibleDate.parse("2026-09-30T12:00:00+02:00")!.date
        let file = FileItem(path: "/Users/lisa/Documents/Rechnungen/Telekom.pdf", name: "Telekom.pdf",
                            modified: FlexibleDate.parse("2026-08-15T09:30:00+02:00")!.date, size: 2_300_000)
        let value = FileCardFormat.accessibilityValue(for: file, now: now, calendar: berlin, locale: german,
                                                      homeDirectory: "/Users/lisa")
        #expect(value == "~/Documents/Rechnungen, 15. Aug., 2,3 MB")

        let folder = FileItem(path: "/Users/lisa/Documents/Rechnungen", name: "Rechnungen", isDirectory: true)
        #expect(FileCardFormat.accessibilityValue(for: folder, now: now, calendar: berlin, locale: german,
                                                  homeDirectory: "/Users/lisa") == "~/Documents")
    }

    @Test func rowsDragOutAsFiles() throws {
        let folder = try TemporaryFolder("file-drag")
        defer { folder.remove() }
        let pdf = try folder.write("Rechnung.pdf", "%PDF-1.4")
        let directory = try folder.makeFolder("Belege")

        let file = FileDrag.itemProvider(for: FileItem(path: pdf.path, name: "Rechnung.pdf", contentType: "com.adobe.pdf"))
        #expect(file.registeredTypeIdentifiers.contains("public.file-url"))
        #expect(file.registeredTypeIdentifiers.contains("com.adobe.pdf"))

        let folderProvider = FileDrag.itemProvider(for: FileItem(path: directory.path, name: "Belege", isDirectory: true))
        #expect(folderProvider.registeredTypeIdentifiers.contains("public.file-url"))
        #expect(!folderProvider.registeredTypeIdentifiers.contains { $0.hasPrefix("dyn.") })
    }
}
