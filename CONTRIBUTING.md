# Contributing to Orbit

Thank you for your interest in Orbit! Bug reports, ideas, translations, documentation and code are all welcome.
This guide explains how to set up the project, how changes get in, and the principles every change has to keep.

**On this page**

- [Ways to contribute](#ways-to-contribute)
- [Development setup](#development-setup)
- [Workflow](#workflow)
- [Coding guidelines](#coding-guidelines)
- [Localization](#localization)
- [Tests](#tests)
- [Product principles](#product-principles)
- [Documentation](#documentation)
- [Pull request checklist](#pull-request-checklist)
- [Reporting bugs](#reporting-bugs)
- [Security issues](#security-issues)
- [Respectful conduct](#respectful-conduct)
- [License](#license)

## Ways to contribute

- **Report a bug** or a confusing behavior (see [Reporting bugs](#reporting-bugs)).
- **Suggest a feature** by opening an issue that describes the problem you want to solve.
- **Improve the documentation**: fix mistakes, clarify steps, add missing details.
- **Improve the translations**: Orbit ships in English and German; better wording is always welcome.
- **Fix a bug or build a feature**: look for open issues, or open one first for anything larger.
- **Test on your Mac**: run the [manual acceptance checks](docs/manual-qa.md) on a macOS version or Mac we have
  not covered yet and report what you find.

## Development setup

You need macOS 14 or later and either the Command Line Tools with Swift 6.x (`xcode-select --install`) or Xcode 16
or later.

```sh
git clone https://github.com/eric-volz/Orbit.git
cd Orbit
Scripts/swiftpm.sh build          # compile everything
Scripts/swiftpm.sh test           # run the unit tests
Scripts/build-app.sh debug        # build/debug/Orbit.app
open build/debug/Orbit.app
```

Use the scripts in `Scripts/` rather than calling `swift` directly. Everything else (the project layout, debug
builds, the developer tools, fake personal data for end-to-end runs) is described in
[docs/development.md](docs/development.md).

## Workflow

1. **Open an issue first for larger changes** (a new tool, a new provider, a change to the UI or to how data is
   handled), so we can agree on the approach before you invest time. Small fixes can go straight to a pull request.
2. **Fork the repository and create a branch** from the default branch with a descriptive name, such as
   `fix-calendar-all-day-events`.
3. **Keep pull requests small and focused**: one bug fix or one feature per pull request. Separate refactoring from
   behavior changes.
4. **Describe your change** in the pull request: what it does, why, how you tested it, and screenshots for visible
   changes.
5. **Respond to review.** Expect questions and requests for changes; they are part of keeping Orbit reliable and
   private.

## Coding guidelines

The full conventions are in [docs/development.md](docs/development.md#coding-conventions). In short:

- **Swift 6 with strict concurrency.** The code builds without warnings. UI and app state live on the main actor;
  slow work stays off it.
- **Services behind protocols.** Every access to the system (Spotlight, AppleScript, Contacts, EventKit, PhotoKit,
  permissions, …) goes through a protocol with a live implementation and a test stand-in. Tools never call system
  frameworks directly.
- **AppleScript**: parameters only through `argv`, never spliced into the script; JSON output; only apps with a
  scripting dictionary.
- **Logging never includes content**: no mail, notes, file contents, prompts, model output or keys. Log events,
  counts, durations and error kinds, and mark anything user-derived `privacy: .private`.
- **Follow the existing style** of the file you are editing, and document non-obvious decisions in comments.
- New tools follow [docs/agent.md](docs/agent.md#adding-a-new-tool).

## Localization

Every user-visible text must be available in **English and German**:

- Write user-visible text only through the String Catalogs (`Text("…")`, `Button("…")`, `.help("…")`,
  `String(localized: "…")`), never as a hard-coded string. The catalog's keys are the English text.
- Add a German translation for every new key.
- `OrbitStrings lint` must report **0 errors and 0 warnings**:

  ```sh
  Scripts/swiftpm.sh run OrbitStrings lint --sources Orbit --catalog Orbit/Resources/Localizable.xcstrings
  ```

- Use no en or em dashes in interface text (the lint fails on them) or in code, comments and documentation
  (`RepositoryTextTests` fails on them in `Orbit/`, `OrbitTests/`, `DevTools/`, `Scripts/`, `Config/`,
  `Package.swift`, `README.md` and `docs/`); rephrase with a comma, colon, period or parentheses.
- Text for the model (the system prompt, tool descriptions and results) stays English.

How the catalogs and `OrbitStrings` work is described in [docs/localization.md](docs/localization.md). If you are
not comfortable writing German, say so in the pull request and we will help with the translation.

## Tests

- **Run the unit tests** before you open a pull request: `Scripts/swiftpm.sh test`. They include
  `RepositoryTextTests`, which fails on any en or em dash in the sources, scripts, README and docs.
- **Add tests** for bug fixes and new behavior. Use the mocks and fakes in `OrbitTests/Support`.
- **Never use real personal data** in tests, fixtures, screenshots or logs: no real names, addresses, mail, files
  or accounts. Use invented data (`Erika Mustermann`, `example.com`).
- **Run the gated suites when relevant**: the live provider tests when you change a provider, the Spotlight
  integration tests when you change search, the UI window tests and snapshots when you change the UI. Note that
  the window tests take the keyboard focus while they run, and the live Claude Code tests spend subscription quota.

See [docs/testing.md](docs/testing.md) for the test layout, fixtures and the gated suites.

## Product principles

Every pull request must keep these principles. A change that weakens one of them will not be merged, however
useful it is otherwise.

- **No telemetry.** Orbit has no server of its own, no analytics, no crash reporting and no update checks. Its only
  network connection is the language model provider the user configured.
- **Local-first.** Instant search never leaves the Mac. Chats, settings and keys stay on the Mac (the database in
  Application Support, keys in the keychain).
- **Confirmation for consequential actions.** Every action with consequences (creating, changing, opening
  something on the user's behalf) waits for the user on a confirmation card.
- **Never send mail, never delete user data.** Orbit drafts mail for the user to review and send; it has no tool
  that sends mail or deletes the user's data.
- **Content reaches the model only as data.** Text from files, mail, notes and other apps is wrapped and marked as
  untrusted content, never treated as instructions, and the chat tells the user what was sent.
- **Minimal permissions.** Ask for a permission only when a feature needs it, explain why, and keep working when
  it is denied.
- **Accessibility and keyboard support.** Everything works with the keyboard alone and with VoiceOver; states are
  never told by color alone.

See [docs/privacy.md](docs/privacy.md) and [docs/security-model.md](docs/security-model.md) for the details.

## Documentation

Update the documentation in the same pull request as the change:

- user-facing behavior: the pages under [docs/](docs/) (user guide, tools, permissions, privacy, troubleshooting,
  known limitations);
- contributor-facing behavior: [docs/development.md](docs/development.md), [docs/testing.md](docs/testing.md),
  [docs/architecture.md](docs/architecture.md) and the other contributor pages;
- notable changes: `CHANGELOG.md`.

The pages in `docs/` also build the documentation website. Preview it with `mkdocs serve` and check it with
`mkdocs build --strict`; [Documentation site](docs/development.md#documentation-site) explains the setup and the few
Markdown rules that keep a page right on GitHub and on the site (for example four spaces of indentation in lists).

## Pull request checklist

- [ ] The change is focused, and larger changes were discussed in an issue first.
- [ ] `Scripts/swiftpm.sh build` succeeds without warnings.
- [ ] `Scripts/swiftpm.sh test` passes, and new behavior has tests.
- [ ] Relevant gated suites were run (and the pull request says which).
- [ ] Every new user-visible text is in the String Catalog with English and German, and `OrbitStrings lint`
      reports 0 errors and 0 warnings.
- [ ] No real personal data in code, tests, fixtures, screenshots or logs.
- [ ] Logging contains no user content.
- [ ] The [product principles](#product-principles) still hold.
- [ ] Keyboard and VoiceOver use still work for changed UI.
- [ ] The documentation is updated.

## Reporting bugs

Open an issue with:

- your **macOS version** and Mac (Apple silicon or Intel);
- the **Orbit version** ("About Orbit" in the Orbit menu while Settings is open, or Get Info on `Orbit.app`);
- the **provider and model** you use (Claude subscription, Anthropic API or an OpenAI-compatible server, and the
  model name);
- the **steps to reproduce**, what you expected and what happened instead;
- relevant **logs** from Console (subsystem `io.github.eric-volz.Orbit`). Orbit never logs the content of your mail, notes,
  files or chats, but check what you paste anyway and remove anything personal.

Please do not include personal content (mail, notes, file names, chat transcripts) in an issue. If a bug only
happens with specific content, describe its shape instead (for example "an email with a 20 MB PDF attachment").
See [docs/troubleshooting.md](docs/troubleshooting.md) for collecting logs.

## Security issues

Do not report security vulnerabilities in public issues. Follow [SECURITY.md](SECURITY.md) instead.

## Respectful conduct

Be kind and respectful. Assume good intentions, give constructive feedback on code rather than people, and welcome
newcomers. Harassment, insults and discriminatory language are not tolerated in issues, pull requests or any other
project space. Maintainers may remove content and block participants who do not respect this.

## License

By contributing to Orbit, you agree that your contributions are licensed under the project's
[LICENSE](LICENSE).
