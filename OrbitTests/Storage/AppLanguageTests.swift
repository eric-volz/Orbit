import Foundation
import Testing
@testable import Orbit

@Suite("AppLanguage")
struct AppLanguageTests {
    /// In-memory stand-in for Orbit's defaults domain.
    final class MemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var languages: [String]?
        private var legacyMarker: Bool

        init(languages: [String]? = nil, legacyMarker: Bool = false) {
            self.languages = languages
            self.legacyMarker = legacyMarker
        }

        var store: AppLanguageStore {
            AppLanguageStore(
                ownLanguages: { self.lock.withLock { self.languages } },
                setOwnLanguages: { value in self.lock.withLock { self.languages = value } },
                hasLegacyMarker: { self.lock.withLock { self.legacyMarker } },
                removeLegacyMarker: { self.lock.withLock { self.legacyMarker = false } }
            )
        }
    }

    /// Older versions set German for Orbit on a Mac with German anywhere among
    /// its languages (an English Mac with German second got a German Orbit).
    /// That value goes once; macOS decides again.
    @Test func theLegacyGermanDefaultIsRemoved() {
        let memory = MemoryStore(languages: ["de"], legacyMarker: true)
        AppLanguage.removeLegacyGermanDefault(store: memory.store)
        #expect(memory.store.ownLanguages() == nil)
        #expect(!memory.store.hasLegacyMarker())
    }

    /// Only once: German chosen for Orbit in System Settings afterwards stays.
    @Test func aLaterChoiceOfGermanIsKept() {
        let memory = MemoryStore(languages: ["de"], legacyMarker: true)
        AppLanguage.removeLegacyGermanDefault(store: memory.store)
        memory.store.setOwnLanguages(["de"])
        AppLanguage.removeLegacyGermanDefault(store: memory.store)
        #expect(memory.store.ownLanguages() == ["de"])
    }

    /// Any value other than the one Orbit wrote is the user's choice.
    @Test(arguments: [["en-GB"], ["de-DE"], ["de", "en"], ["en"]])
    func otherPerAppLanguagesAreKept(languages: [String]) {
        let memory = MemoryStore(languages: languages, legacyMarker: true)
        AppLanguage.removeLegacyGermanDefault(store: memory.store)
        #expect(memory.store.ownLanguages() == languages)
        #expect(!memory.store.hasLegacyMarker())
    }

    /// A new installation has no marker: nothing is set or removed.
    @Test func newInstallationsChangeNothing() {
        let unset = MemoryStore()
        AppLanguage.removeLegacyGermanDefault(store: unset.store)
        #expect(unset.store.ownLanguages() == nil)
        let chosen = MemoryStore(languages: ["de"])
        AppLanguage.removeLegacyGermanDefault(store: chosen.store)
        #expect(chosen.store.ownLanguages() == ["de"])
    }

    /// What macOS picks from Orbit's localizations: the first preferred
    /// language Orbit ships. An English Mac with German second gets English.
    @Test(arguments: [
        (["en-US", "de-DE", "fr-DE"], "en"),
        (["en-DE"], "en"),
        (["de-DE", "en-US"], "de"),
        (["de-CH"], "de"),
        (["fr-FR", "de-DE"], "de"),
        (["fr-FR", "en-GB"], "en"),
    ])
    func macOSPicksTheFirstPreferredLanguageOrbitShips(preferences: [String], expected: String) {
        #expect(Bundle.preferredLocalizations(from: AppLanguage.shipped, forPreferences: preferences).first == expected)
    }

    @Test func englishIsTheSourceLanguage() {
        #expect(AppLanguage.source == "en")
        #expect(AppLanguage.shipped.first == "en")
    }

    // MARK: Interface language and formatting locale

    /// Without Orbit's localizations (the test runner's main bundle) the texts
    /// are the catalog's English keys, so the interface is English.
    @Test func aBundleWithoutLocalizationsShowsTheSourceLanguage() throws {
        let folder = try TemporaryFolder("app-language-bundle")
        defer { folder.remove() }
        let bundle = try #require(Bundle(path: folder.path))
        #expect(bundle.localizations.isEmpty)
        #expect(AppLanguage.interfaceLanguage(bundle: bundle) == "en")
    }

    /// A bundle with Orbit's localizations answers with the one macOS picks
    /// for the process: one of the two Orbit ships.
    @Test func aLocalizedBundleShowsItsPreferredLocalization() throws {
        let folder = try TemporaryFolder("app-language-localized")
        defer { folder.remove() }
        for language in ["de", "en"] {
            _ = try folder.write("Contents/Resources/\(language).lproj/Localizable.strings", "\"Cancel\" = \"Cancel\";\n")
        }
        _ = try folder.write("Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>io.github.eric-volz.Orbit.tests.language</string>
            <key>CFBundleDevelopmentRegion</key><string>en</string>
            <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
            </dict></plist>
            """)
        let bundle = try #require(Bundle(path: folder.path))
        #expect(Set(bundle.localizations).isSuperset(of: ["de", "en"]))
        let language = AppLanguage.interfaceLanguage(bundle: bundle)
        #expect(["de", "en"].contains(language))
        #expect(language == bundle.preferredLocalizations.first)
    }

    /// The user's locale stays as it is when it speaks the interface's language.
    @Test func theUsersLocaleIsKeptWhenItSpeaksTheInterfaceLanguage() {
        let current = Locale(identifier: "de_CH")
        #expect(AppLanguage.formattingLocale(language: "de", current: current) == current)
        let english = Locale(identifier: "en_US@rg=dezzzz")
        #expect(AppLanguage.formattingLocale(language: "en", current: english) == english)
    }

    /// A German interface never formats in another language, e.g. while the
    /// test process (or macOS) runs in English: words in German, the region's
    /// conventions kept. This is what made German cards read "Mon 5. Oct".
    @Test(arguments: [
        ("en_US@rg=dezzzz", "Mo. 5. Okt., 22:00", "1.234,5"),
        ("en_US", "Mo. 5. Okt., 10:00 PM", "1,234.5"),
        ("fr_FR", "Mo. 5. Okt., 22:00", "1 234,5"),
    ])
    func anotherLanguageGetsTheInterfaceLanguage(current: String, date: String, number: String) {
        let locale = AppLanguage.formattingLocale(language: "de", current: Locale(identifier: current))
        #expect(locale.language.languageCode?.identifier == "de")
        let style = Date.FormatStyle(locale: locale, calendar: Self.calendar, timeZone: Self.calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        #expect(CardFormattingTests.plain(Self.monday.formatted(style)) == date)
        #expect(CardFormattingTests.plain(1_234.5.formatted(.number.locale(locale))) == number)
    }

    @Test func anEnglishInterfaceOnAGermanSystemFormatsInEnglish() {
        let locale = AppLanguage.formattingLocale(language: "en", current: Locale(identifier: "de_DE"))
        #expect(locale.language.languageCode?.identifier == "en")
        #expect(locale.region?.identifier == "DE")
        let style = Date.FormatStyle(locale: locale, calendar: Self.calendar, timeZone: Self.calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        #expect(Self.monday.formatted(style).hasPrefix("Mon"))
    }

    /// The UI formats with the interface locale: in the test process English,
    /// whatever language the Mac runs in.
    @Test func theInterfaceLocaleFollowsTheInterfaceLanguage() {
        #expect(AppLanguage.interfaceLanguage() == "en")
        #expect(AppLanguage.locale.language.languageCode?.identifier == "en")
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// Monday, 5 October 2026, 22:00 in Berlin.
    static let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 22))!
}
