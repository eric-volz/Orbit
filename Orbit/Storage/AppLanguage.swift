import Foundation
import os

/// Orbit's interface language, and the locale its interface formats dates,
/// numbers, byte sizes, durations and lists with.
///
/// Orbit has no language setting of its own: it follows macOS. English is the
/// development language (the String Catalog's keys), German a translation.
/// macOS shows the language chosen for Orbit in System Settings > General >
/// Language & Region > Applications, otherwise the first of the user's
/// preferred languages that Orbit ships, otherwise English. Changes take
/// effect after a restart.
enum AppLanguage {
    /// The language of the String Catalog's keys.
    static let source = "en"
    /// The localizations Orbit ships (Config/Info.plist, CFBundleLocalizations).
    static let shipped = ["en", "de"]

    /// Call at launch, before any localized resource is loaded. Older versions
    /// set German as Orbit's own language on the first launch whenever German
    /// was one of the user's preferred languages, so a Mac running in English
    /// showed Orbit in German. This removes that setting once (only the exact
    /// value Orbit wrote); a language chosen in System Settings later is kept.
    static func removeLegacyGermanDefault(store: AppLanguageStore = .live) {
        guard store.hasLegacyMarker() else { return }
        store.removeLegacyMarker()
        if store.ownLanguages() == ["de"] {
            store.setOwnLanguages(nil)
        }
    }

    /// The language the interface shows ("en" or "de"): the localization
    /// macOS picked from the main bundle. Without Orbit's localizations in the
    /// bundle (tests) the texts are the catalog's English keys.
    static func interfaceLanguage(bundle: Bundle = .main) -> String {
        #if DEBUG
        if let override = overrideState.withLock({ $0 }) { return override.language }
        #endif
        guard bundle.localizations.contains(where: shipped.contains) else { return source }
        return bundle.preferredLocalizations.first(where: shipped.contains) ?? source
    }

    /// The locale of the interface's dates, times, numbers, byte sizes,
    /// durations and lists: in the interface language, never in another one.
    static var locale: Locale {
        #if DEBUG
        if let override = overrideState.withLock({ $0 }) { return override.locale }
        #endif
        return formattingLocale(language: interfaceLanguage(), current: .autoupdatingCurrent)
    }

    /// `current` (with all of the user's formats) when it speaks `language`, as
    /// macOS sets it up for an app's localization; otherwise `language` with the
    /// region and settings of `current`. So German texts get "Okt." and English
    /// texts "Oct" even when macOS runs in a language Orbit does not ship.
    static func formattingLocale(language: String, current: Locale) -> Locale {
        if current.language.languageCode?.identifier == language { return current }
        var components = Locale.Components(locale: current)
        let region = current.region
        components.languageComponents = Locale.Language.Components(languageCode: Locale.LanguageCode(language))
        if components.region == nil { components.region = region }
        return Locale(components: components)
    }

    #if DEBUG
    /// Tests: the interface language and locale instead of the main bundle's
    /// (the German snapshots). Process-wide, so only for tests that run alone.
    struct Override: Sendable, Equatable {
        var language: String
        var locale: Locale
    }

    private static let overrideState = OSAllocatedUnfairLock<Override?>(initialState: nil)

    static func setOverride(_ override: Override?) {
        overrideState.withLock { $0 = override }
    }
    #endif
}

/// Where the language choice lives. `live` uses Orbit's own defaults domain;
/// tests use an in-memory store (no files in ~/Library/Preferences).
struct AppLanguageStore: Sendable {
    /// `AppleLanguages` from Orbit's own domain only (nil = follow the system).
    var ownLanguages: @Sendable () -> [String]?
    var setOwnLanguages: @Sendable ([String]?) -> Void
    /// Whether an older Orbit ran its first-launch language step.
    var hasLegacyMarker: @Sendable () -> Bool
    var removeLegacyMarker: @Sendable () -> Void

    static let appleLanguagesKey = "AppleLanguages"
    /// Written by older versions on their first launch.
    static let legacyMarkerKey = "appLanguageInitialized"

    static var live: AppLanguageStore {
        AppLanguageStore(
            ownLanguages: {
                // The plain lookup would fall back to the global (system) value.
                UserDefaults.standard.persistentDomain(forName: AppPaths.bundleIdentifier)?[appleLanguagesKey] as? [String]
            },
            setOwnLanguages: { languages in
                if let languages {
                    UserDefaults.standard.set(languages, forKey: appleLanguagesKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
                }
            },
            hasLegacyMarker: {
                UserDefaults.standard.persistentDomain(forName: AppPaths.bundleIdentifier)?[legacyMarkerKey] != nil
            },
            removeLegacyMarker: { UserDefaults.standard.removeObject(forKey: legacyMarkerKey) }
        )
    }
}
