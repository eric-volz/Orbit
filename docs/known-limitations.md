# Known limitations

The features described in this documentation are complete as of version 0.1.0. This page lists what Orbit currently
cannot do, or does only in part, grouped by area. Behavior that only real data can confirm is covered by the
[manual acceptance checks](manual-qa.md).

**On this page**

- [Claude subscription](#claude-subscription)
- [Other providers and Test Connection](#other-providers-and-test-connection)
- [Links](#links)
- [Apps and system](#apps-and-system)
- [Selected text and context](#selected-text-and-context)
- [Photos](#photos)
- [Calendar and reminders](#calendar-and-reminders)
- [Permissions](#permissions)
- [Mail](#mail)
- [Notes](#notes)
- [Files](#files)
- [Instant search](#instant-search)
- [Language and localization](#language-and-localization)
- [Accessibility](#accessibility)
- [Builds](#builds)

## Claude subscription

- **The network connection is Claude Code's.** The Claude subscription provider runs Claude Code as a child process,
  so for this provider the connection to Anthropic is made by Claude Code, not by Orbit itself.
- **Reset time of the usage limit.** Orbit takes it from Claude Code's limit event for the request that was rejected;
  an earlier warning may be about another usage window and does not count. When Claude Code reports the limit only as
  text, Orbit reads a time of day ("resets 3pm (Europe/Berlin)") but not a date ("resets Oct 3"). The notice then
  says only that the limit has been reached.
- **Outdated Claude Code** is recognized only by its refusal of Orbit's command-line options.
- **Signing in.** **Sign In…** runs `claude auth login --claudeai`, which opens Anthropic's sign-in in your browser.
  If the browser does not open, sign in once with `claude auth login` in Terminal.

See [Choosing a language model](providers.md#claude-subscription-via-claude-code).

## Other providers and Test Connection

- **Test Connection** detects a model without tool support only on **Ollama**, because it asks Ollama's model
  information. With other OpenAI-compatible servers, the first request reports it.

## Links

- A link counts as **yours** only when it is in the message of the current request, exactly as you wrote it. A link
  from an earlier message gets a confirmation card, and so does one from your message after Orbit restarted and you
  clicked **Try Again**.
- A public name that points into your local network (through DNS) is not recognized as local: it gets the card like
  any other link from elsewhere.
- A link you wrote **without a scheme** opens with `https` (into the local network with `http`). For a site without
  HTTPS, write `http://` yourself.

See [Tools → open_url](tools.md#open_url).

## Apps and system

- **No Focus or Do Not Disturb tool.** macOS has no public way for apps to switch a Focus. A shortcut with the action
  **Set Focus** can; see [Tools → Switching a Focus or Do Not Disturb](tools.md#switching-a-focus-or-do-not-disturb).
- **Shortcuts** run through `/usr/bin/shortcuts`. Its output format (names with identifiers) and what Escape stops of a
  running shortcut are verified by hand; actions of a shortcut that macOS already started may still finish.
- **Appearance:** `set_appearance` switches between light and dark only, not to **Automatic**.
- **Volume:** `set_volume` changes only the current output device, and only the one its confirmation card named. On
  Bluetooth, AirPlay and USB devices the level read right after a change can lag, which is why Orbit reports the level
  it set.

## Selected text and context

- Selected text is read only from apps that expose it through Accessibility (many Electron apps and some Java apps
  do not) and only up to **4,000 characters**.
- The context chips give up when Finder or the app takes longer than **0.3 seconds** to answer.
- Password managers are recognized by the identifiers their vendors ship. One that Orbit does not know is read like
  any other app, though a password in a password field is still never read.

## Photos

- Photos are searched **by metadata only**. What a photo shows, where it was taken and who is in it are not searched
  yet.
- A click on a photo tile uses Photos' `spotlight` command with PhotoKit's identifier. That Photos then shows the photo
  is verified by hand; otherwise Photos only opens.
- There is no Quick Look preview of photos.
- Photos that are only in iCloud show a placeholder; Orbit never downloads them.
- Shared albums are searched only when you name them; smart albums you made in Photos are not searched at all.
- A search that has to check items one by one stops counting at **50,000** items.
- A photo edited while its card is shown keeps its old thumbnail until Orbit restarts or the thumbnail leaves the memory
  cache.

## Calendar and reminders

- **Show in Calendar** and **Show in Reminders** use the links macOS itself builds. That they select the item (and the
  right occurrence of a recurring event) is verified by hand; otherwise Calendar or Reminders only opens.
- Orbit **cannot edit, move, complete or delete** events and reminders, and it does not list attendees.
- Completed reminders are shown for the **last 30 days** only.
- A reminder created with a time gets an alert at that time. One with only a date relies on Reminders' own all-day
  notification.
- Recurring events are listed per occurrence, but Orbit **cannot create recurring events**.

## Permissions

- macOS reports Apple Events (Automation) permissions only for running apps. **Automation: Notes** therefore shows
  **Unknown** while Notes is closed, and **Allow…** or **Check…** starts Notes or Mail in the background to ask.
- The links into System Settings use the `x-apple.systempreferences:com.apple.preference.security?Privacy_…`
  addresses. If a future macOS ignores the page name, System Settings opens on its start page.
- **Full Disk Access** is detected through Mail's folder only (**Unknown** without it) and may need a restart of Orbit
  to take effect.

See [Permissions](permissions.md).

## Mail

- **Message text is searched only through Spotlight**, and there only at the start of words, not inside words. Without
  Spotlight (and always for unread-only searches and in Sent, Drafts, Junk and Trash), only subjects and senders are
  searched, so the assistant narrows by sender and time and reads candidates. See [Tools → search_mail](tools.md#search_mail).
- Searching all mailboxes without Spotlight can be slow on very large mailboxes. The search then reports the mailboxes
  it skipped, and a two-year search of every mailbox of a very large library can still return more than Orbit
  accepts; the assistant then narrows it.
- `mailbox: "all"` searches every mailbox except Trash, Junk, Drafts and Outbox, which are recognized by their usual
  names (in English, German and other common languages). With Spotlight, inboxes are recognized by name too.
- **Replies need one paste (⌘V):** Mail does not let scripts write into its reply window, so Orbit puts the text on the
  clipboard.
- The Mail scripts are checked by compiling them and by running their Mail-free parts. Their behavior against a real
  mail library, and their speed, is verified by hand.

## Notes

- Words are matched the way Notes compares text: inside words, ignoring case, but accents must match.
- A `folder` filter covers the notes directly in that folder, not those in its subfolders.
- `read_note` returns text without formatting (checklist states, colors and fonts are lost), and attachments only as
  placeholders.
- New notes are plain text.
- The **Recently Deleted** folder is recognized by its localized name (in English and in your languages).
- On very large libraries, a search with several words may look for the later words in titles only. See
  [Tools → search_notes](tools.md#search_notes).
- The Notes scripts are checked by compiling them and by running their app-independent parts. Their behavior against a
  real Notes library, and their speed with thousands of notes, is verified by hand.

## Files

- **The file tools depend on Spotlight.** Folders excluded from indexing (Spotlight's privacy settings) and volumes
  without an index are not searched, and new files appear once Spotlight has imported them (usually within seconds).
- Files lying directly in your home folder itself (not in a subfolder) are not searched.
- **Keywords match the beginning of words.** "rechnung" ("invoice") finds "Telekom-Rechnung.pdf" but not
  "Telekomrechnung.pdf", which matters for German compound words. Phrases are not supported. The same holds for files
  in instant search.
- `read_file` cannot read **Pages, Numbers and Keynote** documents saved by current iWork versions; only older files
  contain a readable preview (`QuickLook/Preview.pdf`). The model suggests opening them instead.
- `read_file` also cannot read Excel, PowerPoint and OpenDocument spreadsheets and presentations, EPUB, or scanned
  PDFs without a text layer (there is no OCR).
- macOS types TypeScript files (`.ts`) as MPEG-2 video, so `kind: code` misses them in searches; `read_file` still
  reads them.
- **File cards:** Quick Look opens without the zoom animation from the row. **Show in Finder** is ⇧⌘R, not ⌘R (⌘R
  retries a failed answer).

## Instant search

- Apps are found only in the folders instant search covers (see
  [User guide → What it searches](user-guide.md#what-it-searches)); for example, apps in
  `/System/Library/CoreServices/Applications` are not found, and nothing deeper than one level of subfolders.
- Localized app names are found only in Orbit's language, in the first three of your preferred languages and in English (so "Rechner" finds Calculator on an English Mac that also lists German, but a fourth language is not searched).
- The first search of Desktop, Documents or Downloads may bring up macOS's folder-access prompt for Orbit.

## Language and localization

- Orbit has **no language setting of its own**: System Settings chooses it (English or German, otherwise English; see
  [User guide → Language](user-guide.md#language)), and a change takes effect after a restart of Orbit.
- Chats keep the texts Orbit wrote into them (status lines, notices, cards) in the language Orbit had then. Only the
  note on what was sent follows a later change.
- For contributors: localizable strings are found by call patterns (`Text`, `Button`, `.help`, `String(localized:)`,
  …). Text passed to your own views needs `String(localized:)` or `LocalizedStringKey("…")` to be extracted. See
  [Localization](localization.md).

## Accessibility

- Links in an answer are reached with VoiceOver (its Links rotor) but not with Tab.
- A long, richly formatted answer (lists, tables) takes about 10 ms per 1,500 characters to build when it scrolls into
  view; selectable text costs half of that.

See [Accessibility](accessibility.md).

## Builds

- Universal builds cross-compile the Intel (x86_64) part; it is not exercised on an Intel Mac during development.
- Ad hoc builds lose their privacy permissions with every rebuild unless they are signed with the development
  certificate. See [Permissions → Code signing and permissions](permissions.md#code-signing-and-permissions).
