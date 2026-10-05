// OrbitStrings, the localization pipeline for a project without Xcode,
// extracts localizable literals from Swift sources into a String Catalog,
// checks it, and compiles it to .strings files for Orbit.app.
import Foundation

let usage = """
    Usage: OrbitStrings <command> [options]

      extract --sources <dir> --catalog <file.xcstrings> [--source-language en]
          Adds localizable literals found in the sources (Text("…"), Button("…"),
          .help("…"), String(localized: "…"), …) to the catalog. Keeps all
          translations; keys no longer used are marked stale. Idempotent.

      compile --catalog <file.xcstrings> --output <Resources dir> [--table <name>] [--languages de,en]
          Writes <lang>.lproj/<table>.strings (UTF-8). Source language: the
          translation or the key itself; other languages: translated entries only.

      lint [--sources <dir>] --catalog <file.xcstrings> [--languages en,de] [--strict]
          Errors: string interpolation inside a localized literal, format specifiers
          of a translation that differ from the key, en or em dashes in any text.
          Warnings: missing translations, literals missing from the catalog.
          --strict fails on warnings.

      untranslated --catalog <file.xcstrings> [--language de]
          Prints {"key": ""} for every untranslated key (input for translate).

      translate --catalog <file.xcstrings> --input <file.json|-> [--language de]
          Sets translations from a JSON object {"key": "translation"}.

      rekey --sources <dir> --map <file.json> [--all-literals] [--dry-run]
          Replaces localized literals by new keys from {"old key": "new key"}.
          Other literals that equal an old key are listed (--all-literals:
          replaced as well).

      self-test
          Runs the scanner and formatter checks.
    """

var arguments = CommandLine.arguments.dropFirst()
let command = arguments.popFirst() ?? "--help"

do {
    switch command {
    case "extract":
        try ExtractCommand.run(Options(arguments))
    case "compile":
        try CompileCommand.run(Options(arguments))
    case "lint":
        let passed = try LintCommand.run(Options(arguments, flags: ["strict"]))
        exit(passed ? 0 : 1)
    case "untranslated":
        try UntranslatedCommand.run(Options(arguments))
    case "translate":
        try TranslateCommand.run(Options(arguments))
    case "rekey":
        try RekeyCommand.run(Options(arguments, flags: ["all-literals", "dry-run"]))
    case "self-test":
        exit(SelfTest.run() ? 0 : 1)
    case "--help", "-h", "help":
        printOutput(usage)
    default:
        throw ToolError.usage("unknown command \(command)")
    }
} catch let error as ToolError {
    if case .usage = error {
        printError("OrbitStrings: \(error)\n\n\(usage)")
        exit(64)
    }
    printError("OrbitStrings: error: \(error)")
    exit(1)
} catch {
    printError("OrbitStrings: error: \(error)")
    exit(1)
}
