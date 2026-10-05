# Testing

This page explains how Orbit is tested: running the unit tests, the layout of the test target, the mocks and
fixtures, the guarantees the unit tests keep, the opt-in ("gated") suites, and how to write a new test.

**On this page**

- [Running the unit tests](#running-the-unit-tests)
- [Framework](#framework)
- [Layout of OrbitTests](#layout-of-orbittests)
- [Mocks and fakes](#mocks-and-fakes)
- [Fixtures](#fixtures)
- [What the unit tests guarantee](#what-the-unit-tests-guarantee)
- [Gated suites](#gated-suites)
- [The interface language in tests](#the-interface-language-in-tests)
- [Writing a new test](#writing-a-new-test)
- [Manual acceptance checks](#manual-acceptance-checks)

## Running the unit tests

| Command | Runs |
|---|---|
| `Scripts/swiftpm.sh test` | all unit tests |
| `Scripts/swiftpm.sh test --filter AgentLoop` | only the tests whose name matches |
| `Scripts/swiftpm.sh test --no-parallel` | one test at a time, for slow machines and CI |

Swift Testing runs the tests in parallel. On a slow machine, such as a GitHub runner with three cores, the
`@MainActor` suites then starve one another: tests that wait a few seconds for a result time out, and the latency
tests miss their limits. Run them with `--no-parallel` there (the release workflow does); on a recent Mac the
parallel run takes a few seconds, the serial one about half a minute.

The tests must pass in every language, region and time zone. The GitHub runner uses English (United States) and
UTC, which a test written on a Mac set to another region may not expect. To run them that way on your Mac, build the
tests (the filter matches none, so nothing runs yet) and start the test runner with the runner's settings:

```sh
Scripts/swiftpm.sh test --filter NoSuchTest
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
TZ=UTC "$helper" --test-bundle-path .build/debug/OrbitPackageTests.xctest/Contents/MacOS/OrbitPackageTests \
    --testing-library swift-testing --no-parallel -AppleLocale en_US -AppleLanguages '(en-US)'
```

`-AppleLocale` and `-AppleLanguages` set the region and the languages of the test process; environment variables
such as `LANG` do not change them on macOS. Other settings are worth a run, too, for example `en_GB`, or `ja_JP`
with `TZ=Asia/Tokyo`. One gap is known: three date tests in `ChatLogicTests.swift` and `UIFormattingTests.swift`
assume the Gregorian calendar and fail in regions whose calendar is another, such as `ar_SA` or `th_TH`.

Always use [`Scripts/swiftpm.sh`](../Scripts/swiftpm.sh): with only the Command Line Tools installed, Swift Testing
lies outside the default search paths, and the wrapper adds them (see
[development.md](development.md#the-wrapper-scripts)).

The unit tests need no network, no model, no permissions and none of your data. The [gated suites](#gated-suites)
are skipped unless you turn them on.

## Framework

All tests use [Swift Testing](https://github.com/swiftlang/swift-testing) (`import Testing`, `@Suite`, `@Test`,
`#expect`, `#require`). XCTest is not used: it does not ship with the Command Line Tools, and Orbit must build and
test without Xcode.

- Suites that must not run concurrently with each other are marked `.serialized` (for example the AppleScript
  suites, which run one `osascript` or `osacompile` at a time, and all window tests).
- Gated suites use `.enabled(if:)` with an environment variable.
- Tests that touch main-actor state are marked `@MainActor`.

## Layout of OrbitTests

The test target mirrors the app's folders:

| Folder | What it tests |
|---|---|
| `Agent/` | The agent loop (streaming, tools, confirmations, permissions, links, errors and notices, history, provider-managed tools), the confirmation broker, the system prompt, truncation, turn context, disclosure, VoiceOver announcements. `AgentTestSupport.swift` has the `AgentHarness`. |
| `App/` | The app environment, chat parking, context capture, debug automation, the `Fake*Data` sources, the keyboard handoff, the panel's layout, Quick Look, the menus. |
| `ClaudeCode/` | The Claude subscription provider: locating Claude Code, launching and running it, the stream decoder, error classification, history, the account service, the loopback HTTP server and the MCP server. |
| `LLM/` | The Anthropic and OpenAI-compatible providers, encoding, SSE parsing, HTTP and retries, provider errors. |
| `Permissions/` | The permission manager, permission access, context permissions, the fake permissions of fake personal data. |
| `Search/` | The app index, file name search, the fuzzy matcher, instant search. |
| `Storage/` | The conversation store, the interface language. |
| `Tools/` | One folder per tool area (`Apps`, `Calendar`, `Contacts`, `Files`, `Mail`, `Notes`, `Photos`, `Reminders`, `System`) and `Shared/` (AppleScript files and runner, child processes, content wrapping, file paths, Spotlight predicates, the pasteboard). |
| `UI/` | Chat logic, Markdown, cards and their keyboard handling, confirmation cards, onboarding, Settings, the hotkey recorder, launch at login, accessibility display options, formatting, the German interface, and the gated window tests and snapshots. |
| `Support/` | [Mocks and fakes](#mocks-and-fakes) shared by all tests. |
| `Fixtures/` | [Invented test data](#fixtures). Excluded from the target's sources in `Package.swift`. |
| `FoundationTests.swift`, `LocalizationTests.swift` | Basic types (`JSONValue`, `JSONSchema`, `FlexibleDate`, `ToolRegistry`), and the String Catalog checks (the same rules as `OrbitStrings lint`). |

## Mocks and fakes

Every system service Orbit uses sits behind a protocol (see
[development.md](development.md#services-behind-protocols)), and [`OrbitTests/Support`](../OrbitTests/Support) has a
stand-in for each:

| File | Stand-ins |
|---|---|
| `MockLLMProvider.swift` | `MockLLMProvider`, which plays scripted steps (text, events, delays, tool calls, failures), `MockScript` (helpers: `answer`, `toolCalls`, `call`, `managedRun`), `AsyncGate` for ordering async steps. |
| `MockURLProtocol.swift` | `MockServer`, a scripted HTTP endpoint (JSON, SSE, failures) per `URLSession`, so provider tests can run in parallel. |
| `MockTools.swift` | `MockToolLog` and mock tools (search, slow, blocking, stuck, failing, long output, …) for agent loop tests. |
| `MockConversationStore.swift` | An in-memory chat history that records what the agent loop saves. |
| `MockFileServices.swift` | `MockSpotlight` (records every query, answers from a closure), `MockWorkspace`, `RecordingAnnouncer` (what VoiceOver would hear), `TemporaryFolder`. |
| `MockSearchServices.swift` | `FakeAppIndex`, `MockContactSearch`, `MockSearchOpener`, `InMemoryLaunchCounts`, `ManualClock`, `ScriptedFileSearch`. |
| `MockPersonalServices.swift` | `MockAppleScriptRunner` (records every run, answers from the test), `MockContactBook`, `SampleContacts`. |
| `MockMailServices.swift` | `MockMailSpotlight`, `RecordingPasteboard`, `RecordingKeyboardHandoff`, mail fixtures. |
| `MockCalendarServices.swift` | `MockCalendarStore` (calendars, events and reminders in memory, never EventKit), `RecordingCalendarAppOpener`. |
| `MockPhotoServices.swift` | `MockPhotoLibrary` (never PhotoKit), `MockPhotoThumbnails` (tiny pictures drawn by the test), `RecordingPhotosAppOpener`. |
| `MockSystemServices.swift` | `RecordingAppLauncher`, `MockShortcuts`, `MockAudioVolume`, `MockFrontmostContext`, `MockFrontmostApps`, `MockAccessibility`, `MockProcessRunner` (stands in for `/usr/bin/shortcuts`; its command lines are checked). |
| `MockPermissions.swift` | `MockPermissionAccess`: statuses and answers come from the test, every reading, request and opening of System Settings is recorded, and answers can be held back to test late arrivals. |
| `FakeQuickLookPanel.swift` | A Quick Look panel that only records what it was told. |
| `FileFixtures.swift` | Access to the committed file fixtures, and `SpotlightFixtures` for the Spotlight integration tests. |
| `FileSystemTricks.swift` | Other spellings of the same file (firmlinks, volfs, no-follow prefixes), Finder aliases and blocking items, for the security tests of the file tools; `FakeHome`. |
| `OffscreenKeyPanel.swift` | A borderless panel far off every screen that can become key, for tests that send key events. It refuses to be ordered front where a screen could show it. |
| `GermanInterface.swift` | `GermanInterface` and `EnglishFormats` (see [The interface language in tests](#the-interface-language-in-tests)). |

## Fixtures

[`OrbitTests/Fixtures`](../OrbitTests/Fixtures) holds invented data only: no real documents, keys, addresses or
people.

| Folder | Contents | Made by |
|---|---|---|
| `Files/` | Sample files for the file tools and instant search: invoices (`Rechnungen/`), documents in many formats and encodings (`Dokumente/`: PDF, DOCX, DOC, RTF, RTFD, ODT, HTML, CSV, Markdown, Latin-1 and UTF-16 text), an image, a binary file, secrets that must never be read (`Geheim/`), scripts and installers (`Skripte/`), an app bundle (`Programme/`), iWork files. | [`make-fixtures.sh`](../OrbitTests/Fixtures/Files/make-fixtures.sh), with the system's command line tools (`textutil`, `cupsfilter`, `zip`, `iconv`). |
| `Mail/` | Invented messages as `.emlx` files in the layout of Mail's store: `V10/<account>/<mailbox>.mbox/<store>/Data/Messages/<id>.emlx`, and "On My Mac" mailboxes under `V10/Mailboxes`. Two accounts, nested mailboxes, a Gmail-style "All Mail". Their dates are fixed (September 2026), so tests pass explicit date ranges. | [`make-fixtures.sh`](../OrbitTests/Fixtures/Mail/make-fixtures.sh). |
| `PersonalData/` | The JSON files for fake personal data (notes, mail, contacts, events, reminders, photos, shortcuts, frontmost apps, system). Used by the `Fake*Data` tests and by end-to-end runs. | By hand; see [development.md](development.md#fake-personal-data). |
| `AppleScripts/` | Test scripts that address no app: `echo-args`, `fail`, `results`, `slow`, `big`. They exercise the AppleScript runner with `osascript`. | By hand. |
| `FakeClaude/` | `claude`, a fake Claude Code executable (bash 3.2) for the Claude Code tests. It emulates `--version`, `auth status --json`, `auth login` and a streaming chat process, including tool calls through Orbit's MCP bridge, and never contacts Anthropic. Scenarios are chosen with `FAKE_CLAUDE_SCENARIO`, `FAKE_CLAUDE_AUTH` and `FAKE_CLAUDE_LOGIN`; `FAKE_CLAUDE_LOG_DIR` records each invocation. | By hand. |

Both `make-fixtures.sh` scripts write committed results; rerun them only to change the fixtures, and run
`prepare-dates.sh` afterwards.

### prepare-dates.sh

[`OrbitTests/Fixtures/Files/prepare-dates.sh`](../OrbitTests/Fixtures/Files/prepare-dates.sh) gives the file
fixtures dates relative to today and asks Spotlight to re-import them (`mdimport`). The
[Spotlight integration tests](#spotlight-integration) run it automatically; run it yourself before an end-to-end
run with `ORBIT_DEBUG_FILE_SCOPE`. It sets:

- everything (the scripts too): modified 90 days ago, outside `recent_files`' 30 days;
- `Rechnungen/*-2026-08.*`: last month (the 10th and the 15th), so the query "invoice, PDF, last month" finds
  exactly the two invoices from last month;
- `Rechnungen/Rechnung-Telekom-2026-06.pdf`: three months ago;
- `Dokumente/Notizen.md`: modified 2 days ago; `Dokumente/Protokoll.odt`: 5 days ago;
- `Dokumente/Angebot.docx`: last used yesterday (modified 90 days ago).

Spotlight picks the changes up within seconds; the tests wait for it.

## What the unit tests guarantee

The unit tests never touch your Mac's data, apps or settings:

- **No Apple Events to real apps.** The tests never send an Apple Event to Notes, Mail, Photos, Finder, System
  Events or any other app. `osascript` runs only on the test scripts in `Fixtures/AppleScripts`, which address no
  app.
- **Orbit's own scripts are checked without launching apps.** The tests compile every script in
  `Orbit/Resources/AppleScripts` with `osacompile` (Notes, Mail, Photos, Finder and System Events ship scripting
  dictionaries, so compiling never launches them, and the tests check that it did not), and run the parts of the
  scripts that do not talk to the app.
- **No personal frameworks.** Contacts, EventKit, PhotoKit, Core Audio and other apps' Accessibility are never
  touched, and `/usr/bin/shortcuts` is never run (beyond `shortcuts help`). Notes, mail, contacts, events,
  reminders, photos, shortcuts, output devices and other apps' selections are invented data in memory. No event
  store is ever created and no photo fetched; photo thumbnails are tiny pictures drawn by the test; a mock process
  runner stands in for the `shortcuts` command, and its command lines are checked.
- **Nothing opens or changes.** No app or link opens and no setting changes. The launch-at-login tests use a fake login item (`FakeLoginItem`): they never register or remove Orbit.
- **No real permissions.** Permission tests never read or request a real permission; a mock stands in for macOS.
  Only the Full Disk Access probe is tried, on temporary folders.
- **No keychain, no real settings, no real data folder.** Tests pass their own settings (for example the agent
  harness's in-memory `UserDefaults`), an in-memory key store and an in-memory or temporary chat history.

The [gated suites](#gated-suites) relax some of these rules on purpose, and say so.

## Gated suites

Some suites need a real model, the Spotlight index or real windows. They are skipped unless you set their
environment variable. Run each on its own, with its filter.

| Suite | Turn on with | Filter | Covers | Needs | Side effects |
|---|---|---|---|---|---|
| Live Ollama | `ORBIT_LIVE_TESTS=1` | `Live` (or `LiveOllamaTests`, `AgentLoopLiveTests`) | The real providers and the agent loop against a local model, through both of Ollama's APIs. | Ollama on `127.0.0.1:11434` with `gpt-oss:20b` | None beyond local model runs. |
| Live Claude Code | `ORBIT_CLAUDE_CODE_LIVE=1` | `LiveClaudeCode` | The real, locally installed Claude Code: streaming, a reused process, cancellation, a restarted process with history, a tool call through the MCP bridge. | Claude Code (or the Claude app) installed and signed in | Spends subscription quota: five short Haiku requests. |
| Spotlight integration | `ORBIT_SPOTLIGHT_TESTS=1` | `SpotlightIntegration` | The file tools, instant search and mail search against the real Spotlight index, scoped to the fixture folders. | A checkout that Spotlight indexes | Runs `prepare-dates.sh`, which changes the fixtures' dates and re-imports them. |
| UI window tests | `ORBIT_UI_TESTS=1` | `UIWindowTests` (or one suite, such as `CardKeyboard`) | The panel and cards driven with real key events: keyboard navigation, confirmation cards, onboarding, the hotkey recorder, Quick Look, the keyboard handoff to Mail. | A logged-in session you are not typing in | Takes the keyboard focus. |
| UI snapshots | `ORBIT_UI_SNAPSHOT_DIR=<folder>` | `UISnapshot` | PNG renders of the panel, chat, cards, onboarding and Settings, light and dark. | Same as the window tests | Takes the keyboard focus; writes PNG files to the folder. |

### Live Ollama

```sh
ORBIT_LIVE_TESTS=1 Scripts/swiftpm.sh test --filter Live
```

`LiveOllamaTests` checks both providers against Ollama's Anthropic-compatible API (`http://127.0.0.1:11434`, with
a dummy key) and its OpenAI-compatible API (`http://127.0.0.1:11434/v1`, without a key). `AgentLoopLiveTests` runs
the agent loop end to end on both, with a timeout of 240 seconds per test. `ORBIT_LIVE_MODEL` overrides the agent
loop tests' model (default `gpt-oss:20b`).

### Live Claude Code

```sh
ORBIT_CLAUDE_CODE_LIVE=1 Scripts/swiftpm.sh test --filter LiveClaudeCode
```

These tests run the real Claude Code on your signed-in subscription and spend its usage (five short Haiku
requests). They use only harmless test prompts and a test tool, and read nothing personal. They also check that
Claude Code starts without its own tools, skills, commands or memory and that nothing is left in its session
store. `ORBIT_LIVE_MODEL` overrides the model (default `haiku`).

### Spotlight integration

```sh
ORBIT_SPOTLIGHT_TESTS=1 Scripts/swiftpm.sh test --filter SpotlightIntegration
```

The Spotlight tests of the file tools, of instant search and of mail search query the real index, but only the
fixture folders `OrbitTests/Fixtures/Files` and `OrbitTests/Fixtures/Mail`, never your home folder or Mail's
messages. They need a checkout that Spotlight indexes (a copy under `/tmp` is not indexed), and they run
[`prepare-dates.sh`](#prepare-datessh) once per run and wait until the index shows its dates.

### UI window tests and UI snapshots

```sh
ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter UIWindowTests
ORBIT_UI_SNAPSHOT_DIR=/tmp/orbit-snapshots Scripts/swiftpm.sh test --filter UISnapshot
```

> [!WARNING]
> These suites make an offscreen panel the key window, so they take the keyboard focus from the app you are using.
> Run them when you are not typing, or your keystrokes may go to the tests (and the tests may fail).

- **Window tests** drive the panel with key events: the panel, the cards' keyboard handling (including ⇧⌘R on a
  file card), confirmation cards, the onboarding, the hotkey recorder, Quick Look and the handoff to Mail's reply
  window. Single suites can be run with their own filter, for example `CardKeyboard`, `FileCardKeyboard`,
  `PhotoCardKeyboard`, `CalendarCardKeyboard`, `ConfirmationCardWindow`, `OnboardingKeyboard`,
  `HotkeyRecorderEvents`, `RootViewKeyboard`, `PanelQuickLook` or `PanelHandoff`.
- **Snapshots** render the panel's views offscreen to `<name>-light.png` and `<name>-dark.png` in
  `ORBIT_UI_SNAPSHOT_DIR`: the panel states, instant search, the parked chat, chats with cards, confirmations and
  notices, every onboarding step, and Settings (including Settings → Permissions in all states).
    - Files without a prefix show the German interface with German sample data and German formats.
    - Files named `en-…` show the main views in English with English sample data and American formats.
    - Files named `a11y-contrast-…` render with Increase Contrast and Differentiate Without Color.

Both run on fakes for Spotlight, the app folders, Contacts, opening files, Quick Look and macOS's permissions, so
they never read your files, apps, contacts or permissions and never open a file or a preview. Their windows are
borderless panels far off screen (AppKit would move titled windows onto the screen), and the panel refuses to be
ordered front where a screen could show it. All suites under `UIWindowTests` are serialized, because concurrent
window tests would steal focus and events from each other.

## The interface language in tests

The test process runs without Orbit's app bundle, so it has none of Orbit's localizations: every lookup returns the
catalog's key, which is the English text. Tests therefore see the English interface, as Orbit looks on an English
Mac.

- [`GermanInterface`](../OrbitTests/Support/GermanInterface.swift) shows the German interface while a test body
  runs: the main bundle answers every lookup with the German value of `Orbit/Resources/Localizable.xcstrings`
  (`String(localized:)`, `NSLocalizedString`, and SwiftUI's `Text("…")` with and without an explicit locale). It
  answers on the main thread only and does not nest. With `formats:` it also makes dates, numbers and lists German;
  that override is process-wide, so use it only in tests that run alone (the gated snapshots).
- `EnglishFormats` pins English dates, numbers and lists (for the `en-…` snapshots).
- `GermanInterfaceTests`, a regular unit test, checks that every lookup path still answers in German while
  `GermanInterface` runs, so a macOS change to these lookups is caught.
- `LocalizationTests` checks the catalogs: valid structure, a German translation for every key, matching format
  specifiers, English typography (“curly quotes”, "Word…", "50%"), no en or em dashes, no interpolation in
  localized literals, and no German text in the sources outside the catalog.
- `RepositoryTextTests` scans the text files in `Orbit/`, `OrbitTests/`, `DevTools/`, `Scripts/`, `Config/`,
  `Package.swift`, `README.md` and `docs/` and fails on any en dash (U+2013) or em dash (U+2014). Data that needs
  the characters writes them as escapes (`"\u{2013}"`), so no file holds them literally.

See [localization.md](localization.md) for the rules behind these checks.

## Writing a new test

- **Use the stand-ins.** Build the object under test with mocks from `OrbitTests/Support`, never with live
  services. If a new feature needs a new system service, add a protocol, a live implementation and a mock (see
  [development.md](development.md#services-behind-protocols)).
- **Never use real personal data.** Use invented names (Erika Mustermann, Lisa Beispiel), `example.com`,
  `example.org` or `*.example` addresses, and files in a `TemporaryFolder` or the fixtures.
- **Agent loop tests** use `AgentHarness`, which wires an `AgentLoop` to a `MockLLMProvider`, an in-memory store,
  in-memory settings and a test clock. Script the model's turns with `MockScript` and check the chat items:

    ```swift
    @Test func runsTheTool() async throws {
        let log = MockToolLog()
        let call = MockScript.call("toolu_1", "search_files", ["query": "invoice"])
        let harness = AgentHarness(tools: [MockSearchFilesTool(log: log)], scripts: [
            MockScript.toolCalls([call], text: "Searching."),
            MockScript.answer("I found 2 invoices."),
        ])
        await harness.send("Find my invoices")
        #expect(log.arguments(of: "search_files").count == 1)
        #expect(harness.statuses.first?.state == .succeeded)
    }
    ```

- **Tool tests** build the tool's context from mocks (for example `AppToolContext` with a `FakeAppIndex` and a
  `RecordingAppLauncher`) and check both what the model receives and what the user sees (status text, cards), and
  what was recorded instead of being done.
- **Provider tests** use `MockServer` with scripted JSON or SSE responses.
- **Waiting.** Use `AsyncGate` to order asynchronous steps and `AgentHarness.eventually` for conditions that become
  true later. Avoid fixed sleeps.
- **Windows.** A test that needs real key events or a window belongs to `UIWindowTests`, uses `OffscreenKeyPanel`,
  and is gated with `ORBIT_UI_TESTS`.
- **Text.** Compare user-visible text against the English text (the catalog key). If you need the German text,
  run the check inside `GermanInterface.run { … }`.
- **Language, region and time zone.** Formatting without an explicit locale follows the Mac's region (Orbit's
  `AppLanguage.locale` takes it from macOS), so "2,3 MB", "a, b, and c" or the day of a date hold only on some
  Macs. Pass a locale (`locale: Locale(identifier: "en_US")`) and a time zone, or check only what holds everywhere,
  and run the suite [as on the runner](#running-the-unit-tests).

## Manual acceptance checks

Some behavior needs the real panel on screen, real apps or real permissions: the hotkey, the panel's timing,
VoiceOver, Mail's reply window, macOS's permission prompts. These are covered by the manual acceptance checks in
[manual-qa.md](manual-qa.md), which you run before a release.
