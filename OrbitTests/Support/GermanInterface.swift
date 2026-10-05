import AppKit
import Foundation
import ObjectiveC
@testable import Orbit

/// Orbit's interface in German inside the test process, for checks of the
/// German texts and the German snapshots.
///
/// The test runner's main bundle has none of Orbit's localizations, so
/// `String(localized:)`, `NSLocalizedString` and SwiftUI's `Text("…")` return
/// the catalog's English keys. While `GermanInterface` runs a body, the main
/// bundle answers each of them with the German value of
/// `Orbit/Resources/Localizable.xcstrings` and reports German as its
/// localization. SwiftUI asks `localizedAttributedString(forKey:value:table:)`
/// (under an explicit `\.locale`, as in RootView, SettingsView and the
/// snapshots, `localizedAttributedStringForKey:value:table:localization:` with
/// that locale's language), `NSLocalizedString` asks
/// `localizedString(forKey:value:table:)` and `String(localized:)` the private
/// `_localizedStringForKey:value:table:localizations:` (seen on macOS 27;
/// `GermanInterfaceTests` fails when a macOS changes that). It answers on the
/// main thread only, so tests that run at the same time on other threads keep
/// the English keys. A key without a German value stays English, so a
/// snapshot shows what the catalog lacks.
@MainActor
enum GermanInterface {
    /// Runs `body` with the German interface. `formats` also makes dates,
    /// numbers and lists German (`AppLanguage.setOverride`). That is
    /// process-wide, so only for tests that run alone (the gated snapshots);
    /// without it, pass a locale to the formatters.
    static func run<T>(formats: Locale? = nil, _ body: () throws -> T) rethrows -> T {
        activate(formats: formats)
        defer { deactivate() }
        return try body()
    }

    static func run<T>(formats: Locale? = nil, _ body: () async throws -> T) async rethrows -> T {
        activate(formats: formats)
        defer { deactivate() }
        return try await body()
    }

    /// German values by key (translated entries only).
    static func strings() -> [String: String] {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = catalog["strings"] as? [String: Any] else { return [:] }
        var strings: [String: String] = [:]
        for (key, entry) in entries {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any]
            let unit = (localizations?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            guard let value = unit?["value"] as? String, !value.isEmpty,
                  ["translated", "needs_review"].contains(unit?["state"] as? String ?? "translated") else { continue }
            strings[key] = value
        }
        return strings
    }

    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Orbit/Resources/Localizable.xcstrings")

    private static var originalClass: AnyClass?
    private static var overridesFormats = false

    private static func activate(formats: Locale?) {
        precondition(originalClass == nil, "GermanInterface does not nest")
        GermanMainBundle.strings = strings()
        originalClass = object_getClass(Bundle.main)
        object_setClass(Bundle.main, GermanMainBundle.self)
        if let formats {
            AppLanguage.setOverride(AppLanguage.Override(language: "de", locale: formats))
            overridesFormats = true
        }
    }

    private static func deactivate() {
        if overridesFormats {
            AppLanguage.setOverride(nil)
            overridesFormats = false
        }
        if let originalClass {
            object_setClass(Bundle.main, originalClass)
        }
        originalClass = nil
        GermanMainBundle.strings = [:]
    }
}

/// The main bundle's class while `GermanInterface` runs (see there).
final class GermanMainBundle: Bundle, @unchecked Sendable {
    /// Written by `GermanInterface` on the main actor, read on the main thread only.
    nonisolated(unsafe) static var strings: [String: String] = [:]

    private static let privateLookup = NSSelectorFromString("_localizedStringForKey:value:table:localizations:")
    private typealias PrivateLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString

    /// The German value, only on the main thread and for Orbit's table.
    private static func german(_ key: String, table: String?) -> String? {
        guard Thread.isMainThread, table == nil || table == "Localizable" else { return nil }
        return strings[key]
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Self.german(key, table: tableName) ?? super.localizedString(forKey: key, value: value, table: tableName)
    }

    override func __localizedAttributedString(forKey key: String, value: String?, table tableName: String?) -> NSAttributedString {
        if let german = Self.german(key, table: tableName) { return NSAttributedString(string: german) }
        return super.__localizedAttributedString(forKey: key, value: value, table: tableName)
    }

    /// `String(localized:)`'s lookup (private API, so the original is called through its implementation).
    @objc(_localizedStringForKey:value:table:localizations:)
    func germanString(forKey key: NSString, value: NSString?, table: NSString?, localizations: AnyObject?) -> NSString {
        if let german = Self.german(key as String, table: table as String?) { return german as NSString }
        let original = unsafeBitCast(class_getMethodImplementation(Bundle.self, Self.privateLookup), to: PrivateLookup.self)
        return original(self, Self.privateLookup, key, value, table, localizations)
    }

    private static let attributedLookupForLocalization = NSSelectorFromString("localizedAttributedStringForKey:value:table:localization:")
    private typealias AttributedLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, NSString?) -> NSAttributedString

    /// SwiftUI's lookup for a view with an explicit `\.locale`: `localization`
    /// is that locale's language. German answers, another stays the original.
    @objc(localizedAttributedStringForKey:value:table:localization:)
    func germanAttributedString(forKey key: NSString, value: NSString?, table: NSString?, localization: NSString?) -> NSAttributedString {
        if localization == nil || localization?.hasPrefix("de") == true,
           let german = Self.german(key as String, table: table as String?) {
            return NSAttributedString(string: german)
        }
        let original = unsafeBitCast(class_getMethodImplementation(Bundle.self, Self.attributedLookupForLocalization),
                                     to: AttributedLookup.self)
        return original(self, Self.attributedLookupForLocalization, key, value, table, localization)
    }

    override var localizations: [String] {
        Thread.isMainThread ? AppLanguage.shipped : super.localizations
    }

    override var preferredLocalizations: [String] {
        Thread.isMainThread ? ["de"] : super.preferredLocalizations
    }
}

/// English dates, numbers and lists for the English snapshots. The interface
/// is English in the test process anyway; `AppLanguage.setOverride` pins the
/// locale. Process-wide, so only for tests that run alone.
@MainActor
enum EnglishFormats {
    static func run<T>(_ locale: Locale, _ body: () async throws -> T) async rethrows -> T {
        AppLanguage.setOverride(AppLanguage.Override(language: "en", locale: locale))
        defer { AppLanguage.setOverride(nil) }
        return try await body()
    }
}
