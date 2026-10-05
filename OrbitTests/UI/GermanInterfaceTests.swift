import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import Orbit

/// The German interface: while `GermanInterface` runs, every way Orbit looks
/// up a text answers in German (the German snapshots rely on it). Outside it
/// the test process shows the catalog's English keys, as Orbit does on an
/// English Mac. Synchronous on the main actor, so no other main-actor test
/// runs meanwhile.
@MainActor
@Suite("German interface")
struct GermanInterfaceTests {
    static let american = Locale(identifier: "en_US")
    static let german = Locale(identifier: "de_DE")
    /// English, but not the test process's own locale: for a view in that
    /// locale SwiftUI looks the text up as for a view without a locale, which
    /// `GermanInterface` answers in German (on a Mac set to en_US, such as the
    /// GitHub runner).
    static let otherEnglish = Locale(identifier: Locale.current.identifier == "en_US" ? "en_GB" : "en_US")

    @Test func everyLookupPathAnswersInGerman() {
        GermanInterface.run {
            #expect(String(localized: "Cancel") == "Abbrechen")
            #expect(String(format: String(localized: "Found %lld files"), 3) == "3 Dateien gefunden")
            #expect(NSLocalizedString("Cancel", comment: "") == "Abbrechen")
            #expect(Self.width(Text("Cancel")) == Self.width(Text(verbatim: "Abbrechen")))
            #expect(Self.width(Button("New Chat") {}) == Self.width(Button(action: {}) { Text(verbatim: "Neuer Chat") }))
            // RootView, SettingsView and the snapshots set `\.locale`: SwiftUI then asks for that
            // locale's language (`localizedAttributedStringForKey:value:table:localization:`).
            for identifier in ["de_DE", "de_CH", "de_DE@rg=uszzzz"] {
                let locale = Locale(identifier: identifier)
                #expect(Self.width(Text("Cancel").environment(\.locale, locale)) == Self.width(Text(verbatim: "Abbrechen")),
                        "\(identifier)")
                #expect(Self.width(Button("New Chat") {}.environment(\.locale, locale))
                        == Self.width(Button(action: {}) { Text(verbatim: "Neuer Chat") }), "\(identifier)")
            }
            // Another language is not made German.
            #expect(Self.width(Text("Cancel").environment(\.locale, Self.otherEnglish))
                    == Self.width(Text(verbatim: "Cancel")))
            #expect(AppLanguage.interfaceLanguage() == "de")
        }
        #expect(String(localized: "Cancel") == "Cancel")
        #expect(Self.width(Text("Cancel")) == Self.width(Text(verbatim: "Cancel")))
        #expect(Self.width(Text("Cancel").environment(\.locale, Self.german))
                == Self.width(Text(verbatim: "Cancel")))
        #expect(AppLanguage.interfaceLanguage() == "en")
    }

    /// Tests running on other threads meanwhile keep the English keys.
    @Test func otherThreadsKeepTheEnglishKeys() {
        let elsewhere = OSAllocatedUnfairLock(initialState: "")
        GermanInterface.run {
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                elsewhere.withLock { $0 = String(localized: "Cancel") }
                done.signal()
            }
            done.wait()
            #expect(String(localized: "Cancel") == "Abbrechen")
        }
        #expect(elsewhere.withLock { $0 } == "Cancel")
    }

    // MARK: Texts

    /// The note on sent content starts like a sentence, lists the content the
    /// locale's way and names generic recipients in the current language, also
    /// in chats saved before, which stored the German name.
    @Test func theNoteOnSentContentReadsNaturally() {
        let mixed = [ContentDisclosure(kind: .notes, count: 2), ContentDisclosure(kind: .emails, count: 3),
                     ContentDisclosure(kind: .fileContents, count: 1)]
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .photos, count: 30)], providerName: "Claude",
                                      locale: Self.american) == "Details of 30 photos sent to Claude")
        #expect(DisclosurePhrase.text(for: mixed, providerName: ProviderRecipient.localModel, locale: Self.american)
                == "1 file, 3 emails, and 2 notes sent to the local model")
        #expect(DisclosurePhrase.text(for: mixed, providerName: "das Sprachmodell", locale: Self.american)
                == "1 file, 3 emails, and 2 notes sent to the language model")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .shortcuts, count: 1)], providerName: " ",
                                      locale: Self.american) == "Name of 1 shortcut sent to the provider")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 1)], providerName: "ollama.example.com",
                                      locale: Self.american) == "1 email sent to ollama.example.com")
        GermanInterface.run {
            #expect(DisclosurePhrase.text(for: mixed, providerName: ProviderRecipient.localModel, locale: Self.german)
                    == "1 Datei, 3 E-Mails und 2 Notizen an das lokale Modell gesendet")
        }
    }

    /// The German note: plural forms, "und" without a comma, names of collections.
    @Test func theNoteOnSentContentReadsNaturallyInGerman() {
        GermanInterface.run {
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 3)], providerName: "Claude", locale: Self.german)
                    == "3 E-Mails an Claude gesendet")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 1)], providerName: "Claude", locale: Self.german)
                    == "1 E-Mail an Claude gesendet")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .contacts, count: 1)], providerName: " ", locale: Self.german)
                    == "1 Kontakt an den Anbieter gesendet")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .shortcuts, count: 5), ContentDisclosure(kind: .folderNames, count: 1),
                                                ContentDisclosure(kind: .albumNames, count: 3)], providerName: "Claude", locale: Self.german)
                    == "Namen von 5 Kurzbefehlen, Name von 1 Ordner und Namen von 3 Alben an Claude gesendet")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .reminderListNames, count: 1),
                                                ContentDisclosure(kind: .reminders, count: 3)], providerName: "Claude", locale: Self.german)
                    == "3 Erinnerungen und Name von 1 Erinnerungsliste an Claude gesendet")
            #expect(DisclosurePhrase.phrase(for: .photos, count: 2) == "Angaben zu 2 Fotos")
        }
    }

    /// The local model is stored by a neutral name, so the note shows it in the
    /// language Orbit has when the chat is shown, not when it was written.
    @Test func providersNameTheirRecipientNeutrally() throws {
        let local = try #require(URL(string: "http://localhost:11434/v1"))
        #expect(ProviderEndpoint.displayName(for: local) == ProviderRecipient.localModel)
        #expect(ProviderRecipient.shown(ProviderRecipient.localModel) == "the local model")
        GermanInterface.run {
            #expect(ProviderRecipient.shown(ProviderRecipient.localModel) == "das lokale Modell")
        }
    }

    /// The agent names Orbit's settings as the user sees them, so it can point
    /// there in the user's language.
    @Test func theAgentNamesSettingsAsTheUserSeesThem() {
        #expect(AgentLoop.ModelText.notInThisChat("search_files").contains("(\"Tools\" tab)"))
        #expect(AgentLoop.ModelText.disabledByUser("search_files").contains("(\"Tools\" tab)"))
        GermanInterface.run {
            #expect(AgentLoop.ModelText.notInThisChat("search_files").contains("(\"Werkzeuge\" tab)"))
        }
    }

    /// macOS calls the permission "Calendars" (Privacy & Security), the app and
    /// an event's calendar field "Calendar"; German says "Kalender" for both.
    @Test func calendarsPermissionAndCalendarFieldHaveTheirOwnNames() async throws {
        let tool = CalendarTest.tool(CreateEventTool.self, MockCalendarStore())
        let prepared = try await tool.prepareForConfirmation(ToolArguments([
            "title": "Dentist", "start": "2026-10-06T10:00", "end": "2026-10-06T11:00",
        ]))
        #expect(PermissionKind.calendars.displayName == "Calendars")
        #expect(PermissionCopy.headline(.calendars) == "Calendars")
        #expect(PermissionCopy.hint(.calendars, status: .denied)
                == "You can allow it in System Settings > Privacy & Security > Calendars.")
        #expect(tool.confirmationRequest(for: prepared).fields.last?.label == "Calendar")
        #expect(ToolCategory.calendar.displayName == "Calendar")
        GermanInterface.run {
            #expect(PermissionKind.calendars.displayName == "Kalender")
            #expect(tool.confirmationRequest(for: prepared).fields.last?.label == "Kalender")
        }
    }

    /// Settings > Privacy says who connects to the provider: with the Claude
    /// subscription Claude Code, not Orbit.
    @Test func thePrivacyNoteNamesWhoConnects() {
        #expect(PrivacySettingsView.networkText(provider: .claudeCode, host: "api.anthropic.com")
                == "With the Claude subscription, Claude Code connects to Anthropic. Orbit itself makes no connection to the internet.")
        #expect(PrivacySettingsView.networkText(provider: .openAICompatible, host: "localhost")
                == "Orbit’s only network connection is to the language model provider you set up (localhost).")
        GermanInterface.run {
            #expect(PrivacySettingsView.networkText(provider: .claudeCode, host: "api.anthropic.com").contains("Claude Code"))
            #expect(PrivacySettingsView.networkText(provider: .anthropic, host: "api.anthropic.com").hasSuffix("(api.anthropic.com)."))
        }
    }

    /// Settings, menus and status words use macOS's terms in both languages.
    @Test func macOSTerms() {
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Model", "Tools", "Permissions", "Privacy"])
        #expect(PermissionKind.fullDiskAccess.displayName == "Full Disk Access")
        #expect(PermissionKind.accessibility.displayName == "Accessibility")
        #expect(PermissionCopy.statusTitle(.writeOnly) == "Add Only")
        #expect(PermissionCopy.actionTitle(.contacts, status: .notDetermined) == "Allow…")
        #expect(LLMError.network(.offline).userMessage == "No internet connection.")
        #expect(LLMError.network(.cannotConnect).userMessage(for: .thisMac(address: "localhost:11434"))
                == "The server on this Mac (localhost:11434) cannot be reached. Start it (for example Ollama or LM Studio) and try again.")
        #expect(LLMError.modelNotFound(model: "llama3").userMessage == "The model “llama3” is not available. Choose a different model in Settings.")
        #expect(LLMError.rateLimited(retryAfter: 30).userMessage.hasPrefix("Too many requests in a short time. Please try again in "))
        #expect(NoticeRow.title(.signIn) == "Sign In…")
        #expect(NoticeRow.title(.newChat) == "New Chat")
        GermanInterface.run {
            #expect(SettingsTab.allCases.map(\.title) == ["Allgemein", "Modell", "Werkzeuge", "Berechtigungen", "Datenschutz"])
            #expect(PermissionKind.fullDiskAccess.displayName == "Festplattenvollzugriff")
            #expect(PermissionKind.accessibility.displayName == "Bedienungshilfen")
            #expect(PermissionCopy.statusTitle(.writeOnly) == "Nur hinzufügen")
            #expect(LLMError.network(.offline).userMessage == "Keine Internetverbindung.")
            #expect(LLMError.network(.cannotConnect).userMessage(for: .thisMac(address: "localhost:11434"))
                    == "Der Server auf diesem Mac (localhost:11434) ist nicht erreichbar. Starte ihn, z. B. Ollama oder LM Studio, und versuche es erneut.")
            #expect(NoticeRow.title(.signIn) == "Anmelden …")
            #expect(NoticeRow.title(.newChat) == "Neuer Chat")
        }
    }

    /// Text for the model is English whatever the interface's language, and the
    /// assistant answers in the language of the user's message. macOS gives
    /// Orbit the locale of its interface language with the user's region
    /// ("en_US@rg=dezzzz", "de_US@rg=dezzzz"): the prompt is the same for both.
    @Test func theSystemPromptDoesNotFollowTheInterface() throws {
        let now = try #require(FlexibleDate.parse("2026-09-28T21:30:00+02:00")).date
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let tools = [ToolAvailability(info: ToolInfo(name: "search_files", description: "", category: .files, riskLevel: .read,
                                                     requiredPermissions: []), unavailableReason: nil)]
        let build = { (locale: String) in
            SystemPrompt.build(now: now, timeZone: berlin, locale: Locale(identifier: locale), userName: nil, tools: tools)
        }
        let english = build("en_US@rg=dezzzz")
        let german = GermanInterface.run { build("de_US@rg=dezzzz") }
        #expect(german == english)
        #expect(english.contains("in the language of the user's latest message"))
    }

    /// The English snapshots' interface texts are English, checked without
    /// rendering: chip labels, status lines, notices and cards' texts.
    @Test func englishSnapshotTextsAreEnglish() {
        var texts = EnglishSampleData.attachments.map(\.label)
        let items = EnglishSampleData.conversation + EnglishSampleData.cards + EnglishSampleData.confirmations
            + EnglishSampleData.reminderDates + EnglishSampleData.linkConfirmations + EnglishSampleData.failedTurn
            + SampleData.errorNotices
        for item in items {
            switch item.kind {
            case .toolStatus(let status): texts.append(status.text)
            case .notice(let notice): texts.append(notice.message)
            case .card(.info(let info)): texts += [info.title, info.detail ?? ""]
            case .confirmation(let state):
                let request = state.request
                texts += [request.title, request.message, request.confirmLabel ?? ""] + request.fields.map(\.label)
            default: break
            }
        }
        #expect(texts.count > 30)
        for text in texts {
            #expect(text.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüÄÖÜß„")) == nil, "German: \(text)")
        }
        #expect(texts.contains("Found 3 files") && texts.contains("Create event") && texts.contains("Open link"))
    }

    static func width<V: View>(_ view: V) -> CGFloat {
        ImageRenderer(content: view.font(.system(size: 20)).fixedSize()).nsImage?.size.width ?? -1
    }
}
