# Security model

How Orbit protects the user's data and Mac while a language model reads personal content and calls tools on it. This
page is for security reviewers and contributors: it describes the assets, the trust boundaries, the threats Orbit
defends against and the mitigations, with links to the code that implements them. For the user-facing summary see
[Privacy](privacy.md) and [Permissions](permissions.md); to report a vulnerability see
[SECURITY.md](../SECURITY.md).

**On this page**

- [Scope and assets](#scope-and-assets)
- [Trust boundaries](#trust-boundaries)
- [Untrusted content and prompt injection](#untrusted-content-and-prompt-injection)
- [Actions with consequences](#actions-with-consequences)
- [Link exfiltration](#link-exfiltration)
- [The file system](#the-file-system)
- [Secrets](#secrets)
- [AppleScript](#applescript)
- [Child processes](#child-processes)
- [The MCP bridge](#the-mcp-bridge)
- [Local data](#local-data)
- [Logging policy](#logging-policy)
- [Hardened Runtime and entitlements](#hardened-runtime-and-entitlements)
- [DEBUG-only automation](#debug-only-automation)
- [Residual risks and non-goals](#residual-risks-and-non-goals)

## Scope and assets

Orbit is a menu bar app that runs as the logged-in user, outside the App Sandbox. It sends the user's messages (and,
through tools, their files, mail, notes, contacts, calendar, reminders, photo metadata and screen selection) to a
language model, and executes the tool calls the model makes. The model is treated as **untrusted**: it may be wrong,
and it may be steered by content it reads.

**Assets**

| Asset | Examples | Main threat |
|---|---|---|
| Personal content | Files, mail, notes, contacts, events, reminders, photos, selected text | Disclosure beyond the chosen provider (exfiltration) |
| Secrets | API keys, the Claude sign-in, SSH/GPG keys, keychains, `.env` files, password-manager data, passwords on screen | Disclosure to the model or the network |
| Integrity of user data and the Mac | Sending mail, deleting or changing items, running code, changing settings | Unwanted actions triggered by injected instructions |
| The local network | Router admin pages, services on `localhost` | Requests forged through links the model opens |
| Orbit's own data | Chat history, settings, the MCP bridge token | Disclosure to other users or processes, leftovers after deletion |

**In scope:** Orbit's app code, its tools and AppleScripts, the MCP bridge, the child processes Orbit starts, its
storage and logging, and how it builds requests for the provider.

**Out of scope:** the language model provider's own handling of data, Claude Code's internals, macOS itself, and
attackers who already run code as the same user (see [Residual risks and non-goals](#residual-risks-and-non-goals)).

## Trust boundaries

```mermaid
flowchart LR
    subgraph Mac["The user's Mac"]
        App["Orbit app"]
        CC["Claude Code child process<br/>unmodified CLI"]
        Bridge["MCP loopback bridge<br/>127.0.0.1, random port, bearer token"]
        AE["Mail, Notes, Photos, Finder, System Events<br/>via Apple Events and osascript"]
        Kits["EventKit, PhotoKit, Contacts"]
        FS["File system and Spotlight"]
        Out["Browser and mail app"]
    end
    User["User"] --> App
    App -->|"spawn, stream-json on stdin and stdout"| CC
    CC -->|"tool calls"| Bridge
    Bridge -->|"same checks and cards as the agent loop"| App
    App -->|"fixed scripts, data as arguments"| AE
    App --> Kits
    App -->|"file access policy"| FS
    App -->|"link policy and confirmation"| Out
    App -->|"HTTPS: messages and tool results"| Provider["LLM provider<br/>Anthropic API or OpenAI-compatible"]
    CC -->|"HTTPS with Claude Code's own sign-in"| Anthropic["Anthropic"]
```

| Boundary | What crosses it | Trust |
|---|---|---|
| User → Orbit | Typed messages, confirmations, edits on cards | Trusted. Only the user's own message can make a link open without a card. |
| Orbit → provider | System prompt, history, tool results | The provider receives what the chat discloses; Orbit trusts it with that content but **not** its output. |
| Provider → Orbit | Answers and tool calls | Untrusted. Every call is validated against the tool's schema, checked by the tool, and confirmed by the user when it has consequences. |
| Orbit ↔ Claude Code | Messages over stdin and stdout; tool calls over the bridge | Claude Code is the user's own install; Orbit isolates it and treats its tool calls exactly like the model's. |
| Orbit → macOS apps and frameworks | Apple Events, EventKit, PhotoKit, Contacts | Gated by macOS permissions (TCC). Orbit sends only fixed, reviewed scripts. |
| Content → model | Mail, notes, files, events, names, selected text, window titles | Untrusted data, written by third parties. |
| Orbit → browser and mail app | `http`, `https` and `mailto` links | Network side effects; gated by the link policy and a card. |

## Untrusted content and prompt injection

Anyone who can put text in front of the model (a mail sender, a shared note or calendar invitation, a file, a web
page whose text the user selected, a window title) may try to give it instructions. Orbit cannot make injection
impossible; it makes injected text clearly marked as data, bounded in size, and unable to cause consequences without
the user.

- **Content in its own element.** Long content goes to the model wrapped in a tag: `<file_content>`,
  `<mail_content>`, `<note_content>`, `<calendar_events>`, `<reminders>`, `<shortcut_output>`, and in the per-message
  context block `<orbit_context>` with `<selected_text>`, `<finder_selection>` and `<frontmost_app>`. Each is labeled
  as data, not instructions. Occurrences of the tag inside the content are neutralized so it cannot close its own
  element, also when disguised with spaces, invisible characters, full-width or small brackets or another case: the
  bracket before the tag name becomes `‹`. Code:
  [ContentWrapping.swift](../Orbit/Tools/Shared/ContentWrapping.swift),
  [TurnContext.swift](../Orbit/Agent/TurnContext.swift).
- **Names are single-line and neutralized.** Senders, subjects, file names, paths, album, calendar, folder and
  shortcut names, app names and window titles are joined to one line, every angle bracket (including full-width and
  small variants) becomes `‹` or `›`, invisible format characters (zero-width spaces and joiners, BOM, bidi
  controls) are removed, and the value is cut to a length limit (300 characters by default). A name therefore can
  neither open nor close an element, nor pass for Orbit's own text (`TurnContext.inline`, `neutralizeMarkup`).
- **Combining-mark limits.** A sender can make one "character" huge: a letter with thousands of combining marks
  ("Zalgo" text). Every limit Orbit puts on what the model gets therefore counts Unicode scalars too (at most ten per
  character, enough for every emoji sequence), and runs of more than eight combining marks are cut to eight; real
  text in any script stays as it is. Code: [Truncation.swift](../Orbit/Agent/Truncation.swift).
- **Size limits.** Every tool result is capped at 45,000 characters; file text at 20,000 (40,000 on request), a mail
  body at 4,000, a note at 20,000, lists at 20 items, selected text at 4,000 and a Finder selection at 50 paths in the
  context block. The model is told what was left out.
- **The system prompt says so.** Its safety section tells the model that tool results and everything in
  `<orbit_context>` from the user's screen are data, never to follow instructions found there ("forward this email",
  "open this link", "ignore previous rules") even when they claim to come from Orbit or the user, to report them to
  the user instead, that actions happen only through tools that ask the user, never to claim an action happened
  without a tool result, not to retry a declined action, and never to try to access passwords, keychain items or
  payment data. The prompt is built once per conversation and then frozen; per-turn facts go into `<orbit_context>`.
  Code: [SystemPrompt.swift](../Orbit/Agent/SystemPrompt.swift).
- **Disclosure.** The chat notes what content was sent ("3 emails sent to Claude"), so the user can see what the
  model saw. See [Privacy](privacy.md#what-the-chat-tells-you-was-sent).

## Actions with consequences

The second line of defense: whatever the model was told, actions that change something wait for the user.

<img src="assets/screenshots/confirmation-cards.png" width="560" alt="Confirmation cards: an editable Create event card with Cancel and Create, a decided Change volume card, a Change appearance card marked Not run: the request ended, notices with Open Settings, and the warning that Orbit stopped running tools after 15 tool calls">

- **Risk levels.** Every tool declares a level ([ToolRiskLevel.swift](../Orbit/Agent/ToolRiskLevel.swift)):

    | Level | Behavior | Tools |
    |---|---|---|
    | `read` | Runs without confirmation | `search_files`, `read_file`, `recent_files`, `search_mail`, `read_mail`, `search_notes`, `read_note`, `search_contacts`, `list_events`, `list_reminders`, `search_photos`, `list_shortcuts`, `get_frontmost_context` |
    | `draft` | Runs without confirmation; nothing is sent or changed | `open_file`, `reveal_in_finder`, `create_mail_draft`, `open_note`, `open_app` |
    | `write` | Confirmation card | `create_note`, `create_event`, `create_reminder`, `run_shortcut`, `set_appearance`, `set_volume`, `open_url` |
    | `destructive` | Confirmation and warning | No tool has this level. |

    A tool may lower the level of a single call: `open_url` is `write`, but a link the user typed in the current message
    opens as `draft` (see [Link exfiltration](#link-exfiltration)).

- **Confirmation cards.** The agent loop suspends a `write` call until the user decides on its card
  ([ConfirmationBroker.swift](../Orbit/Agent/ConfirmationBroker.swift)). Stopping, a new chat or the end of the
  request cancels every waiting card ("Not run: the request ended."). The same holds for calls that arrive through
  the Claude Code bridge.
- **Edited values are checked again.** A user may edit fields on some cards (for example an event's time). The edited
  arguments are validated against the tool's JSON schema again and passed through the tool's own checks
  (`prepareForConfirmation`) before it runs; invalid edits are refused and nothing changes. Tool-private arguments
  (names starting with `_`, such as the typed link) can never be set by edits, and a link card cannot be edited at
  all. Code: [AgentLoop.swift](../Orbit/Agent/AgentLoop.swift), [Tool.swift](../Orbit/Agent/Tool.swift).
- **Orbit never sends mail.** `create_mail_draft` opens a draft in Mail for the user to send; for a reply, Mail's own
  reply window opens and the text goes to the clipboard. No script contains a send command (see
  [AppleScript](#applescript)).
- **No deletes.** No tool deletes, moves or changes existing mail, notes, events, reminders, photos or files. Events
  and reminders are only created; the file tools only read, open and reveal.
- **Limits per request.** At most 15 tool calls per user request (then Orbit stops: "Orbit stopped running tools
  after 15 tool calls…"), at most 3 `open_url` calls, and a 90-second deadline per tool call (longer for
  `run_shortcut`, whose own limit is 120 seconds). A call with side effects that times out or is interrupted is
  reported with an unknown result ("Timed out, result unknown", "Stopped, result unknown", "Result unknown"), so neither the user nor the model assumes it did not happen.

## Link exfiltration

Opening a link sends data off the Mac at once: the page loads, and its address can carry anything the model has
read. `open_url` is therefore the most important exfiltration channel and has the strictest policy. Code:
[OpenURLTool.swift](../Orbit/Tools/Apps/OpenURLTool.swift) (`LinkPolicy`),
[LinkOrigin.swift](../Orbit/Tools/Apps/LinkOrigin.swift) (`TypedLinks`, `LocalNetwork`, punycode).

<img src="assets/screenshots/link-confirmations.png" width="720" alt="Link confirmation cards: Open link for the look-alike domain apple.com (xn--80ak6aa92e.com) with the full link; Start a new email with To, Cc and the link; a refused call: Local network: only with a link from your message">

**Only `http`, `https` and `mailto`.** Everything else is refused with a message for the model: `file:`,
`javascript:`, `data:` and every app scheme (`shortcuts://`, `x-apple.systempreferences:`, …), because such links can
open files or make apps carry out actions. Also refused:

- links longer than 2,000 characters, counted in Unicode scalars (so accents and other combining marks each count, and
  the link that opens is never longer);
- links with spaces, line breaks, control or invisible characters;
- links with a user name or password before the host (`https://google.com@evil.example` goes to `evil.example`);
- `mailto` links with attachments (`attach=`, `attachment=`, `attachments=`), with a `#`, or with a parameter name
  that is not plain ASCII letters, digits and `-` (`bcc%20=`, `bcc%00=`, a Cyrillic "с"): a mail app might read such
  a name, or what follows a `#`, as a hidden copy the card does not show.

**The user's links and all others.**

- A link opens without a card only when the user typed or pasted it in the message of the **current** request, and
  then **as the user wrote it**. Only the spelling may differ: for "Open heise.de/news" the model may pass
  `https://www.heise.de/news/` (case, `www.`, a trailing slash, percent-encoding, a default port or the punycode form
  of a name may differ), and `https://heise.de/news` opens. A link written without `http://` or `https://` opens with
  `https://`, also when the model passes `http://` (which would load the page unencrypted), and with `http://` only
  into the local network (`fritz.box`, `localhost:3000`), where devices rarely have a certificate. A link the model
  changed in any other way (another parameter, a shorter path, another host, port or scheme) is not the user's. At
  most 100 links per message are considered.
- Every other link (from a mail, note, event, file, web page, the selected text or the window in front, an earlier
  message, or composed by the model) first shows a card: **Open link** with the website and the whole link as it
  would open, or **Start a new email** with the recipients, copies and the link. Nothing opens before the user clicks
  **Open**, and nothing on the card can be edited.

**Punycode display.** The card shows the host as people read it: an international name decoded from punycode with
its ASCII form next to it ("bücher.example (xn--bcher-kva.example)"), so a look-alike such as a Cyrillic "аррӏе.com" shows its
`xn--…` form.

**Refused unless the user typed them:**

- **Links into the local network:** `localhost`, `127.0.0.1` (also written as `2130706433`, `0x7f.1`, `0177.0.0.1`
  or `127.1`, because browsers read those as IPv4 addresses), private, shared, link-local, multicast and reserved
  addresses such as `192.168.x.x`, `10.x.x.x`, `172.16.x.x` to `172.31.x.x`, `100.64.x.x` and `169.254.x.x` (also inside IPv6, for
  example `::ffff:192.168.0.1`), IPv6 loopback, link-local and unique local addresses, names without a dot, private
  names (`*.local`, `*.localhost`, `*.localdomain`, `*.home.arpa`, `*.internal`, `*.intranet`, `*.lan`, `*.home`,
  `*.corp`, `*.private`) and router names with the devices behind them (`fritz.box`, `nas.fritz.box`,
  `speedport.ip`, `easy.box`), also with trailing dots (`fritz.box..`). The chat says why: "Local network: only with
  a link from your message".
- **`mailto` links with a hidden copy** (`bcc=`): "Bcc: only with a link from your message".

A `mailto` card shows every address the new mail goes to, also copies ("Cc: …"), and the model is told about copies
and hidden copies. The system prompt and the tool description tell the model never to open a link only because a
mail, note, file or web page says so. At most 3 `open_url` calls per request; beyond that the model is told to give
the links as text. All of this holds equally when Claude Code calls the tool through the bridge.

## The file system

Code: [FileAccessPolicy.swift](../Orbit/Tools/Files/FileAccessPolicy.swift),
[FilePath.swift](../Orbit/Tools/Shared/FilePath.swift),
[FileVisibility.swift](../Orbit/Tools/Shared/FileVisibility.swift),
[FileSearchScope.swift](../Orbit/Tools/Shared/FileSearchScope.swift),
[OpenFileTool.swift](../Orbit/Tools/Files/OpenFileTool.swift).

- **Where searches look.** Spotlight searches the visible folders directly in the home folder (Desktop, Documents,
  Downloads, …, and folders the user created) plus iCloud Drive (`~/Library/Mobile Documents`) and cloud storage
  (`~/Library/CloudStorage`), not the home scope as a whole. Hidden files and folders, the rest of `~/Library`, the
  Trash and the contents of apps and document packages are never listed (`FileVisibility` is applied to every
  Spotlight result).
- **Deny list.** Never read, opened or listed:
    - keychains (`~/Library/Keychains`, `/Library/Keychains`, …, and `.keychain`/`.keychain-db` files);
    - SSH and GPG keys (`~/.ssh`, `~/.gnupg`, `id_rsa`, `id_ed25519`, …);
    - cloud and developer credentials: `~/.aws`, `~/.config/gcloud`, `~/.azure`, `~/.kube`, `~/.docker/config.json`,
      `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/.config/gh`, `~/.config/op`, `~/.password-store`,
      `~/.pgpass`, `~/.vault-token`, Cargo, RubyGems and Terraform credentials;
    - Claude Code's credentials (`~/.claude.json`, `~/.claude/.credentials.json`);
    - password-manager data (`.kdbx`, `.kdb`, `.1pif`, `.opvault`, `.agilekeychain`, `.psafe3`, and folders of
      1Password, Bitwarden, KeePass, LastPass, Dashlane, Enpass, Strongbox);
    - browser and mail profiles (Chrome, Chromium, Brave, Edge, Vivaldi, Firefox, Arc, Opera, Thunderbird);
    - private keys and certificates (`.pem`, `.p12`, `.pfx`, `.p8`, `.ppk`, `.key`, `.keystore`, `.jks`);
    - `.env` files (`.env`, `.env.*`, `*.env`, `.envrc`);
    - anything in `~/Library` except iCloud Drive and cloud storage, and Orbit's own data folder.

    All rules ignore case (volumes usually do). `reveal_in_finder` may show items in `~/Library` and Orbit's data folder,
    since that discloses nothing to the model and changes nothing, but never secrets.

- **Keynote or private key?** A `.key` item counts as a Keynote document when it is a package, larger than 256 KB
  (256,000 bytes) or a ZIP file (checked by its first four bytes). A small `.key` file in iCloud Drive or cloud
  storage that is not downloaded is left out of search results instead of being downloaded to check it.
- **Symlinks and alternate spellings.** A path is checked as written first, without touching the disk, so a denied one
  is never opened. Then symlinks and other spellings are resolved (`FilePath.canonical`: the kernel's path of the
  item, without firmlink, `/.vol`, `/.nofollow` and `/.resolve` spellings), and the resolved path must pass too.
  System spellings themselves (`/System/Volumes/Data/…`, `/.vol/…`, `/.nofollow/…`, `/dev/fd/…`) are refused.
  Resolving opens only regular files and folders, for event notifications only, never dataless (not downloaded)
  items, pipes, devices or sockets.
- **Protected items are invisible.** Denied files are filtered out of search results, so not even their names reach
  the model. Paths are shown to the model single-line and neutralized; a path the model passes back in that form is
  matched to the file it showed, which is then checked like any other. Matching never lists a folder that is off
  limits, and a path matched to a protected item is "not found", like one matched to nothing, so a disguised path
  cannot tell whether a guessed file in a protected folder exists. Selected Finder items Orbit never shares are left
  out of the context chips; the model hears only their number.
- **Opening rules.** `open_file` opens documents and folders in their default app, never apps and other bundles
  (plug-ins, preference panes, screen savers, …), executables (including Unix executables with the x bit but no
  document type, `.jar`, `.exe`, `.dylib`, …), scripts (shell, Python, AppleScript, `.command`, `.tool`), Terminal
  settings and sessions (`.terminal`, `.term`), Automator workflows and actions, Shortcuts files, installer packages,
  configuration profiles or link files (`.webloc`, `.inetloc`, `.fileloc`, `.url`, which may point to a program). A
  Finder alias opens its target only if the target itself may be opened; then the target is what opens, so the file
  that was checked is the file that opens.
- **Opening apps.** `open_app` launches an installed app found by name in instant search's app index: an exact name
  wins, then the start of a name, then the start of words or initials ("vsc"). It opens only when exactly one app fits
  the best of these; several make the model ask the user, and matches inside a name or of scattered letters are only
  suggested, never opened. Code: [AppTools.swift](../Orbit/Tools/Apps/AppTools.swift).
- **Archives.** `.docx`/`.odt` files whose contents unpack to more than 50 MB are refused before they are unpacked.

## Secrets

- **API keys only in the keychain.** Generic-password items in the login keychain, service
  `io.github.eric-volz.Orbit.credentials`, accessible after first unlock, never in files, `UserDefaults` or logs. The settings
  never read a stored key into the UI; the field only accepts a new one. Code:
  [KeychainStore.swift](../Orbit/Storage/KeychainStore.swift).
- **Claude credentials are never read.** With the Claude subscription, Claude Code uses its own sign-in; signing in
  runs `claude auth login`, Anthropic's own browser flow. Of `claude auth status --json` Orbit reads only `loggedIn`,
  `authMethod` and `subscriptionType`, never the account's email or organization. Claude Code's credential files are
  on the file deny list, and `ANTHROPIC_*` variables are never passed to the CLI. Code:
  [ClaudeCodeAccountService.swift](../Orbit/LLM/ClaudeCode/ClaudeCodeAccountService.swift).
- **Password fields are never read.** Context capture checks the focused element's role and subrole for
  `AXSecureTextField` **before** any text is requested, and reads nothing while secure keyboard entry is on.
- **Password managers are excluded.** Nothing (no selection, no window title) is read from apps that keep passwords,
  recognized by the bundle identifiers their vendors ship (`FrontmostContextRules.passwordManagers`): Apple's
  Passwords and Keychain Access, 1Password, Bitwarden, KeePassXC, KeePassX, LastPass, Dashlane, Enpass, NordPass,
  Proton Pass, Keeper, RoboForm, MacPass, Strongbox, KeePassium, Secrets, Elpass, Bramble, SafeInCloud, JumpCloud
  Password Manager, KeeWeb, Buttercup, Swifty, QtPass and SecureSafe. Code:
  [FrontmostContext.swift](../Orbit/Tools/Apps/FrontmostContext.swift),
  [LiveFrontmostContext.swift](../Orbit/Tools/Apps/LiveFrontmostContext.swift).
- **Context capture is bounded.** It never reads from Orbit itself; Accessibility calls use a 0.25-second messaging
  timeout per element; selected text is read only up to 4,000 characters (`AXStringForRange`, never the whole
  selection); Finder delivers at most 20 paths and only while Finder is in front and Automation: Finder is already
  allowed (the status is read without asking, so opening the panel never brings up a prompt). A capture that takes
  longer than 0.3 seconds is dropped, as is one that ends after the user sent the message or closed the panel. Code:
  [ContextCapture.swift](../Orbit/App/ContextCapture.swift).

## AppleScript

Orbit controls Mail, Notes, Photos, Finder and System Events with 13 fixed scripts in
`Orbit/Resources/AppleScripts`. Code: [AppleScriptRunner.swift](../Orbit/Tools/Shared/AppleScriptRunner.swift).

- **Arguments only.** Every script takes its parameters only as items of `argv` (`on run argv`). User or model text is
  never spliced into script source, so an argument like `a"; do shell script "…` is just text. Arguments containing a
  NUL character are refused; all arguments together may not exceed 512 KB.
- **No content in scripts.** Tests check that every bundled script has its file and no other file is there, that each
  is ASCII, uses `on run argv`, never uses `do shell script`, `run script`, `load script`, `store script`,
  `osascript`, `display dialog`, `application id` or `property`, and talks only to its own app (System Events only in
  the one script allowed to). Every script compiles in the test suite without launching its app.
- **JSON output.** Scripts print JSON, which Orbit decodes; output that is not the expected JSON is an error. Output
  beyond 8 MB stops `osascript`.
- **Time limits.** Each script has its own timeout (20 to 70 seconds), always below the agent loop's 90-second tool
  deadline and at least 20 seconds for a first launch and the permission prompt; tests enforce both bounds.
- **Out of process.** Scripts run through `/usr/bin/osascript` as a child process (never in Orbit's process, never on
  the main thread) with its own process group, stdin from `/dev/null`, a minimal environment, and cancellation that
  stops it. Errors never carry script arguments; script error messages go to the model only, never to the log.
- **The scripts cannot send or delete.** Tests scan the sources: the Mail scripts contain no `send`, `delete`, `move`,
  `forward`, `redirect`, `bounce`, `duplicate`, `synchronize`, `import`, `save`, `close`, mailbox or rule creation, and
  set no message property; only the reply script uses `reply`, and only in Mail's visible reply window
  ([MailScriptTests.swift](../OrbitTests/Tools/Mail/MailScriptTests.swift)). The Photos script only looks up an item
  and shows it ([PhotosScriptTests.swift](../OrbitTests/Tools/Photos/PhotosScriptTests.swift)). The Finder script
  only reads the selection, and the appearance script only sets dark mode, with no GUI scripting
  ([SystemScriptTests.swift](../OrbitTests/Tools/System/SystemScriptTests.swift)). The Notes scripts search, read,
  open and create notes and contain no delete or move command, but no source check like the Mail one guards them
  yet.

## Child processes

Code: [ChildProcess.swift](../Orbit/Support/ChildProcess.swift),
[ClaudeCodeLaunch.swift](../Orbit/LLM/ClaudeCode/ClaudeCodeLaunch.swift),
[ClaudeCodeProcess.swift](../Orbit/LLM/ClaudeCode/ClaudeCodeProcess.swift),
[ClaudeCodeRuntime.swift](../Orbit/LLM/ClaudeCode/ClaudeCodeRuntime.swift).

- **Spawning.** Children start with `posix_spawn` in their own process group, so signals reach helpers they start.
  Only stdin, stdout and stderr are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`): no other descriptor of Orbit (the
  database, the bridge's sockets) leaks into a child. Signal dispositions are reset and nothing is masked.
- **Helpers** (`osascript`, `/usr/bin/shortcuts`) get a fixed `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) and only
  `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE` and `__CF_USER_TEXT_ENCODING`: no tokens, no debug
  variables.
- **Shortcuts.** `/usr/bin/shortcuts` runs in its own process group; listing may take 10 seconds, a run 120 seconds.
  On timeout or cancellation the whole group gets SIGTERM and, a second later, SIGKILL. The input goes in a file
  readable only by the user, the output into a private folder; both are deleted afterwards.
- **Claude Code isolation.** Orbit starts the locally installed, unmodified Claude Code as a plain chat engine in an
  empty working folder (`~/Library/Application Support/Orbit/ClaudeCode`) with:

    ```text
    -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
    --model=<validated model> [--effort <level>]
    --tools "" --disable-slash-commands --strict-mcp-config --setting-sources "" --no-session-persistence
    --settings {"crossSessionInbound":"refuse"} --system-prompt-file <file>
    --mcp-config <file> --allowedTools mcp__orbit__*
    ```

    So: no built-in tools, skills, slash commands, plugins, hooks, memory, settings files or saved sessions, no
    messages from other Claude Code sessions, and Orbit's bridge as the only MCP server. The environment sets
    `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS`, `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS`,
    `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` and
    `DISABLE_AUTOUPDATER`. The model name is validated (1 to 128 characters, a fixed character set) and bound with `=` so
    it cannot pass for a flag. When the CLI reports its configuration, Orbit checks it and logs a notice if built-in
    tools, skills, slash commands or memory show up anyway. Control requests from the CLI are refused (Orbit configures
    nothing that asks the host).

- **Environment allowlist.** Only `PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TMPDIR`, the proxy
  variables (`HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` in both cases) and `NODE_EXTRA_CA_CERTS` are passed on, never
  `ANTHROPIC_*` (API keys, base URLs) or `CLAUDE_CODE_*`/`CLAUDECODE` from Orbit's own environment.
- **Lifetime.** One process per chat. It is reused for follow-up questions and replaced when a request for another
  chat arrives, when the model, effort, system prompt, tools or executable change, and after a failed turn; it ends
  after 15 minutes without a request and when Orbit quits. Ending sends SIGTERM to the process group and SIGKILL after a grace period (2 seconds; 1 second when Orbit
  quits). A sign-in that still runs (`claude auth login`) ends when Orbit quits, too.
- **Locating the CLI.** Orbit runs the path set in Settings, else the Claude desktop app's copy (verified versions
  first), else the standard install locations, else `command -v claude` in the user's login shell. It trusts the
  user's own installation.

## The MCP bridge

With the Claude subscription, Claude Code runs the tool loop and calls Orbit's tools through a small MCP server Orbit
starts for each Claude Code process. Code:
[LoopbackHTTPServer.swift](../Orbit/LLM/ClaudeCode/MCPBridge/LoopbackHTTPServer.swift),
[OrbitMCPServer.swift](../Orbit/LLM/ClaudeCode/MCPBridge/OrbitMCPServer.swift),
[HTTPMessage.swift](../Orbit/LLM/ClaudeCode/MCPBridge/HTTPMessage.swift),
[ClaudeCodeSession.swift](../Orbit/LLM/ClaudeCode/ClaudeCodeSession.swift).

- **Loopback only.** Streamable HTTP on `127.0.0.1` (the listener accepts local connections only, requires the
  loopback interface and binds to the IPv4 loopback address) on a random port.
- **A bearer token per process.** 256 random bits from `SecRandomCopyBytes`, hex encoded, new for every process,
  compared in constant time. A request without it gets 401.
- **No browsers, no other hosts.** A request with an `Origin` header is refused (403), and the `Host` header must be
  `127.0.0.1:<port>` or `localhost:<port>` (403 otherwise), which defeats DNS rebinding. Only `POST` to `/mcp`
  without a query, with a JSON body, single JSON-RPC 2.0 messages (no batches).
- **Strict limits.** Headers at most 16 KB and 64 lines, bodies at most 4 MB, at most 32 connections, a 30-second
  deadline for an incomplete request, one request at a time per connection; a handler is cancelled when its client
  disconnects.
- **Same checks as the API providers.** `tools/list` returns the conversation's frozen tool definitions. `tools/call`
  runs through the agent loop of the request that is currently running: schema validation, the tools' checks,
  confirmation cards, status rows, disclosure and the 15-calls-per-request limit. Calls outside a running request get
  an error result ("No Orbit request is running, so the tool was not run."), and calls still pending when a request
  ends or is stopped are cancelled.
- **The configuration file is deleted after connecting.** The `--mcp-config` file holds the token. Orbit writes it
  (and the system prompt file) as new files readable only by the user (mode 0600, `O_EXCL | O_NOFOLLOW`) in a folder
  only the user can open (0700), deletes the configuration as soon as Claude Code has connected (its first
  authenticated `initialize`), and deletes both when the process ends and when Orbit quits. Leftovers of a process
  that did not end cleanly are removed after 10 minutes, the next time a process starts. The token never appears on a
  command line.
- **Long calls.** Tool calls may wait up to an hour for the user to decide on a card (`MCP_TOOL_TIMEOUT`); Claude
  Code is told not to move them to the background.

## Local data

- **File permissions.** Orbit's data folder `~/Library/Application Support/Orbit` is created with mode 0700 by the
  database. Temporary files (Claude Code's system prompt and bridge configuration, shortcut input, DEBUG automation
  files) are created through [PrivateFile.swift](../Orbit/Support/PrivateFile.swift): directories 0700, files 0600,
  created with `O_EXCL | O_NOFOLLOW`, never following a symlink and never replacing an existing file.
- **Secure delete.** Every database connection runs `PRAGMA secure_delete = ON`, so SQLite overwrites deleted content
  instead of leaving it in free pages. Deleting the history runs `DELETE`, `VACUUM` and a WAL checkpoint with
  truncation, and removes database copies moved aside as unreadable. This is best effort: SSDs and APFS may keep old
  blocks. Code: [Database.swift](../Orbit/Storage/Database.swift),
  [ConversationStore.swift](../Orbit/Storage/ConversationStore.swift).
- **Retention.** The 100 most recent chats are kept; older ones are deleted when a chat is saved.
- **Settings** in `UserDefaults` hold no secrets; instant search's launch counts store app paths and numbers only.
  Photo thumbnails are kept in memory only.

## Logging policy

Code: [Log.swift](../Orbit/Support/Log.swift). Unified logging under the subsystem `io.github.eric-volz.Orbit` records events,
counts, durations and error kinds, never user content: no prompts, answers, mail, notes, contacts, file names,
paths, file contents, search words, app names, links, shortcut names, selected text, window titles or API keys.
[Log.swift](../Orbit/Support/Log.swift) asks that anything derived from user input be marked `privacy: .private`;
in practice the call sites log no such values, and dynamic strings are private by default in unified logging. AppleScript errors are logged by kind only (their
messages may echo content), helper processes' stderr is never logged, and the tool runners log the command, outcome
and duration only.

## Hardened Runtime and entitlements

Every build is signed with the Hardened Runtime (`codesign --options runtime`) and these entitlements
([Orbit.entitlements](../Config/Orbit.entitlements)):

| Entitlement | Why |
|---|---|
| `com.apple.security.automation.apple-events` | Send Apple Events to Mail, Notes, Photos, Finder and System Events |
| `com.apple.security.personal-information.addressbook` | Contacts |
| `com.apple.security.personal-information.calendars` | Calendars and reminders |
| `com.apple.security.personal-information.photos-library` | Photos |

Debug builds additionally carry `com.apple.security.get-task-allow` so a debugger can attach
([Orbit-Debug.entitlements](../Config/Orbit-Debug.entitlements)); release builds do not. There is no entitlement
that weakens the Hardened Runtime (no JIT, unsigned executable memory, library-validation exceptions or DYLD
environment variables). [Info.plist](../Config/Info.plist) carries a usage description for every permission macOS
asks for.

**No App Sandbox.** Orbit controls other apps through Apple Events, starts the user's own Claude Code installation,
`/usr/bin/osascript` and `/usr/bin/shortcuts` as child processes, searches and reads files across the user's home
folder through Spotlight, and reads Mail's store through Spotlight when Full Disk Access is on. The App Sandbox would
block or confine each of these. Instead, Orbit relies on macOS's privacy permissions (TCC) for every protected
resource, on its own access policies (files, links, scripts) and on user confirmation for actions. Releases are
source only for now: users build Orbit themselves, signed ad hoc by default (or with their own development
certificate) and always with the Hardened Runtime. Once the project has a Developer ID, distributed builds will be
signed with it and notarized; see [Releasing](releasing.md).

## DEBUG-only automation

Debug builds contain a remote control for automated checks (`DevTools/orbitctl`,
[DebugAutomation.swift](../Orbit/App/DebugAutomation.swift)). It is off unless Orbit is launched with
`ORBIT_DEBUG_AUTOMATION=1`. Commands arrive as distributed notifications and must carry a per-launch token: 256
random bits that the app writes to `<data folder>/Automation/token` (mode 0600); commands without it are ignored.
Replies are written to files readable only by the user (`reply-<id>.json`); the reply notification carries only the
reply ID and a success flag, so no chat content is broadcast to other processes. Snapshots are written only as PNG
files in temporary folders or the data folder.

All of this, and the other debug switches (`ORBIT_DEBUG_PROVIDER`, `ORBIT_DEBUG_MODEL`, `ORBIT_DEBUG_BASE_URL`,
`ORBIT_DEBUG_EFFORT`, `ORBIT_DEBUG_API_KEY`, `ORBIT_DATA_DIR`, `ORBIT_DEBUG_FILE_SCOPE`,
`ORBIT_DEBUG_FAKE_PERSONAL_DATA`), is compiled only into DEBUG builds (`#if DEBUG`). **Release builds contain none of
it** and ignore these variables. See [Development](development.md).

## Residual risks and non-goals

- **Prompt injection is mitigated, not solved.** A model may still be misled into reading more than the user wanted
  (read-only tools run without confirmation) and into summarizing it in its answer. What it read goes only to the
  configured provider and is noted in the chat; anything with consequences needs the user's click. Users should read
  confirmation cards, especially link cards, before approving.
- **Read and draft tools run without asking.** The model can search and read mail, notes, files and the like, open a
  document, folder or app, reveal a file, open a note or open a draft in Mail without a card.
- **Links the user typed open at once.** A user who pastes a link into their message is trusted with it. A public
  name that resolves into the local network through DNS is not recognized as local; it gets the card like any other
  link from elsewhere.
- **Shortcuts are the user's code.** `run_shortcut` runs only shortcuts that exist under exactly that name and only
  after a card, but what a shortcut does is up to the shortcut.
- **The clipboard.** Reply text goes to the clipboard, where other apps and clipboard managers can read it.
- **The provider sees what the chat discloses.** Orbit cannot control how a provider stores or uses that content.
  With an OpenAI-compatible server over plain HTTP, content and key travel unencrypted (Settings warns).
- **Same-user attackers are out of scope.** Code running as the same user can read Orbit's database, the bridge
  configuration while it exists, and the keychain items it is allowed to; it can also drive the apps Orbit drives.
  Orbit does not try to defend against malware already running in the user's session.
- **Claude Code is trusted as installed.** Orbit runs whatever `claude` executable it finds (configured path, the
  Claude app's copy, standard locations or the login shell) and relies on Claude Code honoring the isolation flags;
  it logs a notice when it sees otherwise.
- **Deletion is best effort** on SSDs, APFS snapshots and backups.
- **Non-goals:** sandboxing the model's provider, hiding which tools exist from the model, protecting against a user
  who deliberately approves a harmful action, and defending against a compromised macOS.
