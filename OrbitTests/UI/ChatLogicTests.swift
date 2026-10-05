import Foundation
import Testing
@testable import Orbit

@Suite("DisclosurePhrase")
struct DisclosurePhraseTests {
    @Test func singleKind() {
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 3)], providerName: "Claude")
                == "3 emails sent to Claude")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 1)], providerName: "Claude")
                == "1 email sent to Claude")
    }

    @Test func twoKindsAreJoinedWithAnd() {
        let items = [ContentDisclosure(kind: .fileContents, count: 1), ContentDisclosure(kind: .emails, count: 3)]
        #expect(DisclosurePhrase.text(for: items, providerName: "Claude") == "1 file and 3 emails sent to Claude")
    }

    @Test func manyKindsInDeclaredOrderAndMerged() {
        let items = [
            ContentDisclosure(kind: .notes, count: 2),
            ContentDisclosure(kind: .emails, count: 2),
            ContentDisclosure(kind: .fileNames, count: 12),
            ContentDisclosure(kind: .emails, count: 1),
        ]
        #expect(DisclosurePhrase.text(for: items, providerName: "das Sprachmodell")
                == "12 file names, 3 emails, and 2 notes sent to the language model")
    }

    @Test func nothingSent() {
        #expect(DisclosurePhrase.text(for: [], providerName: "Claude") == nil)
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .photos, count: 0)], providerName: "Claude") == nil)
    }

    @Test func missingProviderName() {
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .contacts, count: 1)], providerName: " ")
                == "1 contact sent to the provider")
    }

    @Test(arguments: [
        (ContentDisclosure.Kind.fileNames, "1 file name", "2 file names"),
        (.fileContents, "1 file", "2 files"),
        (.emails, "1 email", "2 emails"),
        (.notes, "1 note", "2 notes"),
        (.events, "1 event", "2 events"),
        (.reminders, "1 reminder", "2 reminders"),
        (.contacts, "1 contact", "2 contacts"),
        (.photos, "details of 1 photo", "details of 2 photos"),
        (.selection, "1 selected text", "2 selected texts"),
    ])
    func phrasesPerKind(kind: ContentDisclosure.Kind, singular: String, plural: String) {
        #expect(DisclosurePhrase.phrase(for: kind, count: 1) == singular)
        #expect(DisclosurePhrase.phrase(for: kind, count: 2) == plural)
    }

    @Test func everyKindHasAPhrase() {
        for kind in ContentDisclosure.Kind.allCases {
            #expect(!DisclosurePhrase.phrase(for: kind, count: 5).isEmpty)
        }
    }

    @Test func listJoining() {
        #expect(Phrases.list([]) == nil)
        #expect(Phrases.list(["a"]) == "a")
        #expect(Phrases.list(["a", "b"]) == "a and b")
        #expect(Phrases.list(["a", "b", "c"]) == "a, b, and c")
    }

    /// Lists follow the locale's rules, not a German pattern.
    @Test func listJoiningFollowsTheLocale() {
        #expect(Phrases.list(["a", "b"], locale: Locale(identifier: "en_US")) == "a and b")
        #expect(Phrases.list(["a", "b", "c"], locale: Locale(identifier: "en_US")) == "a, b, and c")
        #expect(Phrases.list(["a", "b", "c"], locale: Locale(identifier: "en_GB")) == "a, b and c")
        #expect(Phrases.list(["a", "b", "c"], locale: Locale(identifier: "de_DE")) == "a, b und c")
    }
}

/// Drives the pure `ScrollPinning` value (reference wrapper, so `#expect` can call it).
private final class PinningDriver {
    private var pinning = ScrollPinning()

    var isPinned: Bool { pinning.isPinned }

    @discardableResult
    func feed(_ contentHeight: CGFloat, _ offset: CGFloat, _ viewportHeight: CGFloat) -> Bool {
        pinning.update(contentHeight: contentHeight, offset: offset, viewportHeight: viewportHeight)
    }

    func pin() {
        pinning.pin()
    }
}

@Suite("ScrollPinning")
struct ScrollPinningTests {
    @Test func contentThatFitsNeverScrolls() {
        let pinning = PinningDriver()
        #expect(!pinning.feed(200, 0, 200))
        #expect(!pinning.feed(300, 0, 300))
        #expect(pinning.isPinned)
    }

    @Test func followsGrowingContentWhilePinned() {
        let pinning = PinningDriver()
        #expect(!pinning.feed(400, 0, 400))
        // Streaming text grows beyond the maximum height.
        #expect(pinning.feed(520, 0, 500))
        // Our scroll to the bottom lands.
        #expect(!pinning.feed(520, 20, 500))
        #expect(pinning.isPinned)
        #expect(pinning.feed(560, 20, 500))
    }

    @Test func firstMeasurementOfLongChatScrollsToBottom() {
        let pinning = PinningDriver()
        #expect(pinning.feed(2_000, 0, 500))
    }

    @Test func userScrollingUpStopsFollowing() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        #expect(!pinning.feed(1_000, 300, 500))
        #expect(!pinning.isPinned)
        #expect(!pinning.feed(1_200, 300, 500))
    }

    @Test func scrollingUpWhileContentGrowsStopsFollowing() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        #expect(!pinning.feed(1_040, 380, 500))
        #expect(!pinning.isPinned)
    }

    @Test func smallScrollWithinToleranceStaysPinned() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        #expect(!pinning.feed(1_000, 480, 500))
        #expect(pinning.isPinned)
        #expect(pinning.feed(1_100, 480, 500))
    }

    @Test func scrollingBackToBottomPinsAgain() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        pinning.feed(1_000, 100, 500)
        #expect(!pinning.isPinned)
        pinning.feed(1_000, 495, 500)
        #expect(pinning.isPinned)
        #expect(pinning.feed(1_100, 495, 500))
    }

    @Test func pinAfterSendingFollowsAgain() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        pinning.feed(1_000, 0, 500)
        #expect(!pinning.isPinned)
        pinning.pin()
        #expect(pinning.feed(1_080, 0, 500))
    }

    @Test func shrinkingContentKeepsPin() {
        let pinning = PinningDriver()
        pinning.feed(1_000, 500, 500)
        // A row got shorter; the scroll view clamps the offset.
        #expect(!pinning.feed(900, 400, 500))
        #expect(pinning.isPinned)
    }
}

@Suite("ChatActivity")
struct ChatActivityTests {
    private func item(_ kind: ChatItem.Kind) -> ChatItem {
        ChatItem(kind: kind)
    }

    @Test func noIndicatorWhenIdle() {
        #expect(!ChatActivity.showsWaitingIndicator(items: [item(.user(text: "Hi", attachments: []))], isRunning: false))
    }

    @Test func indicatorWhileWaitingForFirstToken() {
        #expect(ChatActivity.showsWaitingIndicator(items: [item(.user(text: "Hi", attachments: []))], isRunning: true))
        #expect(ChatActivity.showsWaitingIndicator(items: [], isRunning: true))
    }

    @Test func noIndicatorWhileSomethingElseShowsProgress() {
        let streaming = item(.assistant(text: "Hallo", isStreaming: true))
        #expect(!ChatActivity.showsWaitingIndicator(items: [streaming], isRunning: true))
        let tool = item(.toolStatus(ToolStatus(toolCallID: "1", toolName: "search_files", category: .files, text: "Suche …", state: .running)))
        #expect(!ChatActivity.showsWaitingIndicator(items: [tool], isRunning: true))
        let request = ConfirmationRequest(toolName: "create_event", riskLevel: .write, title: "Termin", message: "")
        let pending = item(.confirmation(ConfirmationState(request: request, status: .pending)))
        #expect(!ChatActivity.showsWaitingIndicator(items: [pending], isRunning: true))
    }

    @Test func indicatorBetweenSteps() {
        let finishedTool = item(.toolStatus(ToolStatus(toolCallID: "1", toolName: "search_files", category: .files, text: "3 Dateien", state: .succeeded)))
        #expect(ChatActivity.showsWaitingIndicator(items: [finishedTool], isRunning: true))
        let finishedAnswer = item(.assistant(text: "Done", isStreaming: false))
        #expect(ChatActivity.showsWaitingIndicator(items: [finishedAnswer], isRunning: true))
        #expect(ChatActivity.showsWaitingIndicator(items: [item(.progress(text: "Ich suche …"))], isRunning: true))
    }
}

@Suite("ChatLayout")
struct ChatLayoutTests {
    private let user = ChatItem.Kind.user(text: "Hi", attachments: [])
    private let answer = ChatItem.Kind.assistant(text: "Hallo", isStreaming: false)
    private let status = ChatItem.Kind.toolStatus(ToolStatus(toolCallID: "1", toolName: "x", category: nil, text: "…", state: .succeeded))
    private let note = ChatItem.Kind.progress(text: "Ich suche …")
    private let footnote = ChatItem.Kind.disclosure(items: [], providerName: "Claude")

    @Test func spacing() {
        #expect(ChatLayout.topSpacing(after: nil, before: user) == 0)
        #expect(ChatLayout.topSpacing(after: answer, before: user) == 22)
        #expect(ChatLayout.topSpacing(after: status, before: status) == 6)
        #expect(ChatLayout.topSpacing(after: status, before: note) == 6)
        #expect(ChatLayout.topSpacing(after: note, before: status) == 6)
        #expect(ChatLayout.topSpacing(after: answer, before: footnote) == 6)
        #expect(ChatLayout.topSpacing(after: user, before: status) == 12)
        #expect(ChatLayout.topSpacing(after: status, before: answer) == 12)
    }
}

@Suite("Confirmation values")
struct ConfirmationValueTests {
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func formatsDateOnlyAndDateTime() throws {
        let parsed = try #require(ConfirmationDateValue.parse("2026-09-29T14:30", timeZone: berlin))
        #expect(!parsed.isDateOnly)
        #expect(ConfirmationDateValue.format(parsed.date, isDateOnly: false, timeZone: berlin) == "2026-09-29T14:30:00+02:00")
        #expect(ConfirmationDateValue.format(parsed.date, isDateOnly: true, timeZone: berlin) == "2026-09-29")
        let dateOnly = try #require(ConfirmationDateValue.parse("2026-12-24", timeZone: berlin))
        #expect(dateOnly.isDateOnly)
        #expect(ConfirmationDateValue.format(dateOnly.date, isDateOnly: true, timeZone: berlin) == "2026-12-24")
    }

    @Test func displayTextFormatsDatesForPeople() {
        let field = ConfirmationField(id: "start", label: "Start", value: "2026-09-29T14:30", kind: .dateTime)
        let text = ConfirmationDateValue.displayText(for: field, value: field.value, timeZone: berlin, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("29. September 2026"))
        #expect(text.contains("14:30"))
        let other = ConfirmationField(id: "title", label: "Titel", value: "Zahnarzt", kind: .text)
        #expect(ConfirmationDateValue.displayText(for: other, value: "Zahnarzt") == "Zahnarzt")
        let broken = ConfirmationField(id: "start", label: "Start", value: "morgen", kind: .dateTime)
        #expect(ConfirmationDateValue.displayText(for: broken, value: "morgen") == "morgen")
    }

    @Test func onlyChangedEditableFieldsAreReported() {
        let fields = [
            ConfirmationField(id: "title", label: "Titel", value: "Zahnarzt", kind: .text),
            ConfirmationField(id: "notes", label: "Notizen", value: "", kind: .multilineText),
            ConfirmationField(id: "calendar", label: "Kalender", value: "Privat", kind: .readOnly),
            ConfirmationField(id: "start", label: "Start", value: "2026-09-29T14:30", kind: .dateTime),
        ]
        let values = [
            "title": "Zahnarzt",
            "notes": "Karte mitnehmen",
            "calendar": "Arbeit",
            "start": "2026-09-29T14:30:00+02:00",
        ]
        #expect(ConfirmationEdits.changes(fields: fields, values: values, timeZone: berlin) == ["notes": "Karte mitnehmen"])
    }

    @Test func changedDateIsReported() {
        let fields = [ConfirmationField(id: "start", label: "Start", value: "2026-09-29T14:30", kind: .dateTime)]
        let edits = ConfirmationEdits.changes(fields: fields, values: ["start": "2026-09-29T15:00:00+02:00"], timeZone: berlin)
        #expect(edits == ["start": "2026-09-29T15:00:00+02:00"])
    }

    @Test func untouchedFieldsProduceNoEdits() {
        let fields = [ConfirmationField(id: "title", label: "Titel", value: "A", kind: .text)]
        #expect(ConfirmationEdits.changes(fields: fields, values: [:]).isEmpty)
    }

    /// UX-5: on a decided card VoiceOver reads a date as the card shows it, never its ISO 8601 value.
    @Test func voiceOverReadsDatesAsTheCardShowsThem() {
        let german = Locale(identifier: "de_DE")
        let fields = [
            ConfirmationField(id: "start", label: "Start", value: "2026-10-06T10:00:00+02:00", kind: .dateTime),
            ConfirmationField(id: "end", label: "Last day", value: "2026-10-08", kind: .dateTime),
            ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true),
        ]
        for field in fields {
            let spoken = ConfirmationDateValue.accessibilityValue(for: field, value: field.value, timeZone: berlin, locale: german)
            #expect(spoken == ConfirmationDateValue.displayText(for: field, value: field.value, timeZone: berlin, locale: german))
            #expect(!spoken.contains("2026-10") && !spoken.isEmpty, "\(field.id): \(spoken)")
        }
        let start = ConfirmationDateValue.accessibilityValue(for: fields[0], value: fields[0].value, timeZone: berlin, locale: german)
        #expect(start.contains("6. Oktober 2026") && start.contains("10:00"))
        #expect(ConfirmationDateValue.accessibilityValue(for: fields[2], value: "", timeZone: berlin, locale: german) == "No Date")
        let title = ConfirmationField(id: "title", label: "Titel", value: "Friseur", kind: .text)
        #expect(ConfirmationDateValue.accessibilityValue(for: title, value: "Friseur") == "Friseur")
    }

    /// UX-4: what the controls of a reminder's due date leave on the card: "Add Date" (today, as a day),
    /// "With time" (9:00 that day, or the day alone again) and "No Date" (empty: no due date).
    @Test func anOptionalDateCanBeAddedSwitchedAndRemoved() throws {
        let evening = try #require(FlexibleDate.parse("2026-10-04T21:30:00+02:00")).date
        #expect(ConfirmationDateValue.added(now: evening, timeZone: berlin) == "2026-10-04")
        #expect(ConfirmationDateValue.switching("2026-10-05", toTime: true, timeZone: berlin) == "2026-10-05T09:00:00+02:00")
        #expect(ConfirmationDateValue.switching("2026-10-05T07:15:00+02:00", toTime: false, timeZone: berlin) == "2026-10-05")
        #expect(ConfirmationDateValue.switching("2026-10-05", toTime: false, timeZone: berlin) == "2026-10-05", "already a day")
        #expect(ConfirmationDateValue.switching("2026-10-05T07:15:00+02:00", toTime: true, timeZone: berlin)
            == "2026-10-05T07:15:00+02:00", "a time stays")
        #expect(ConfirmationDateValue.switching("2026-10-25", toTime: true, timeZone: berlin) == "2026-10-25T09:00:00+01:00",
                "the day winter time starts")
        #expect(ConfirmationDateValue.switching("morgen", toTime: true, timeZone: berlin) == nil)

        let due = ConfirmationField(id: "due", label: "Due", value: "2026-10-05", kind: .dateTime, isOptionalDate: true)
        #expect(ConfirmationEdits.changes(fields: [due], values: ["due": ""], timeZone: berlin) == ["due": ""])
        #expect(ConfirmationEdits.changes(fields: [due], values: ["due": "2026-10-05T09:00:00+02:00"], timeZone: berlin)
            == ["due": "2026-10-05T09:00:00+02:00"])
        let none = ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true)
        #expect(ConfirmationEdits.changes(fields: [none], values: ["due": "2026-10-04"], timeZone: berlin) == ["due": "2026-10-04"])
        #expect(ConfirmationDateValue.displayText(for: none, value: "") == "No Date")
        let start = ConfirmationField(id: "start", label: "Start", value: "", kind: .dateTime)
        #expect(ConfirmationDateValue.displayText(for: start, value: "") == "", "only an optional date reads \"Ohne Datum\"")
    }

    /// Chats saved before the option still decode.
    @Test func fieldsSavedBeforeTheDateOptionDecode() throws {
        let saved = #"{"id":"due","label":"Fällig","value":"2026-10-05","kind":"dateTime"}"#
        let field = try JSONDecoder().decode(ConfirmationField.self, from: Data(saved.utf8))
        #expect(field.isOptionalDate == nil && field.kind == .dateTime)
        let roundTrip = try JSONDecoder().decode(ConfirmationField.self, from: JSONEncoder().encode(
            ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true)))
        #expect(roundTrip.isOptionalDate == true)
    }
}
