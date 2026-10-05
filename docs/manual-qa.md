# Manual acceptance checks

These checklists cover what only a real Mac with real data can show. Run them before a release, and after changes
to the area they cover. The automated tests never touch your calendars, reminders, photos, apps, shortcuts, sound
or other apps' selections; they run on mocks and invented fixtures (see [testing.md](testing.md)). The checks below
show the same behavior on your Mac with your own data, apps and permissions.

**On this page**

- [Preparation](#preparation)
- [Calendar and reminders](#calendar-and-reminders)
- [Photos](#photos)
- [Apps and links](#apps-and-links)
- [Shortcuts and Focus](#shortcuts-and-focus)
- [Appearance and volume](#appearance-and-volume)
- [Context chips and the frontmost app](#context-chips-and-the-frontmost-app)
- [Errors and notices](#errors-and-notices)
- [Launch at login](#launch-at-login)
- [Accessibility](#accessibility)
- [English and German interface](#english-and-german-interface)
- [Performance](#performance)
- [Reporting results](#reporting-results)

## Preparation

- **Use a build signed with the development certificate.** macOS ties privacy permissions to the code signature,
  and an ad hoc signature changes with every build, so an ad hoc build loses its permissions each time you rebuild.
  Create the "Orbit Development" identity once and sign with it, so permissions stay across rebuilds:

    ```sh
    Scripts/create-dev-cert.sh                                        # once
    ORBIT_SIGN_IDENTITY="Orbit Development" Scripts/build-app.sh debug
    ```

    See [releasing.md](releasing.md#code-signing) for the signing options. For the
    [launch at login](#launch-at-login) checks, copy the build to `/Applications` and open it from there.

- **Use data you are comfortable sending to your model.** Many checks ask about your real calendar, photos, files
  and selections. Whatever a question needs goes to the provider you configured (the chat notes what was sent). Use
  test calendars, a test note, harmless shortcuts and files you do not mind sharing, or a local model.
- **Providers.** Most checks work with any provider. Some need a specific one:
    - [Errors and notices](#errors-and-notices) uses Ollama (`http://localhost:11434/v1`, model `gpt-oss:20b`), an
      OpenAI-compatible server without a key, and the Claude subscription (Claude Code).
    - Some checks use **FakeLLMServer**, the scripted stand-in for both APIs, to trigger exact errors and tool calls
      (`#error 400 prompt is too long`, `#tool search_files {"query":"x"}`). See
      [development.md](development.md#fakellmserver) for how to start it and point a debug build at it.
- **VoiceOver basics** for the [accessibility](#accessibility) checks: ⌘F5 turns VoiceOver on and off. The
  VoiceOver modifier is Control-Option (VO); VO-→ and VO-← move between items, VO-Space activates one, VO-U opens
  the rotor (links, headings, form controls). Orbit's own keys (Tab, ↑/↓, Return, ⌘Return, ⌘.) work as usual
  while VoiceOver is on.
- **Note what you see.** Several checks ask you to note or report a result rather than expecting one (for example
  when a macOS app does not honor a link format). Those notes are useful even when everything else passes.

Example prompts are in English; Orbit answers in the language of your message, so you can ask in any language
the model understands.

## Calendar and reminders

1. **Update from an older build without these permissions.** At launch "Set Up Orbit" opens once with "New in
   Orbit" and only the new permission steps: Calendars, Reminders, Photos, Finder and Accessibility (see
   [Photos](#photos) and [Context chips](#context-chips-and-the-frontmost-app) below). There is no welcome, model
   or shortcut step; then "All Set". "Allow…" shows macOS's prompt for full access; allow both Calendars and
   Reminders. Quit and relaunch: the setup does not open again.
2. **"What do I have tomorrow?"** Compare with tomorrow in Calendar's day view. The answer must include:
    - all-day events (birthdays, holidays);
    - events over several days that include tomorrow;
    - recurring events;
    - invitations you declined ("Declined") and canceled events ("Canceled");
    - events of every account (iCloud, Exchange, Google, subscriptions);
    - the same times as Calendar.
3. **Time zones.** "What do I have on October 25?" (the 25-hour day on which daylight saving time ends in the EU in
   2026; in the US, use November 1) lists the late-evening events of that day and nothing that ends at midnight the
   day before. If you can, change the Mac's time zone and ask again.
4. **"Add a hairdresser appointment tomorrow at 3 pm."** The card shows Title, Start, End, Location, Notes and
   your default calendar by name, and nothing is in Calendar yet. Move "End" before "Start" and click "Create":
   the card says "Not run" and nothing is created. Ask again and confirm: the event appears in Calendar at the
   right time.
5. **"Add a vacation from October 12 to 16."** The card shows "Start" and "Last day" as days; in Calendar the
   all-day event covers exactly the 12th to the 16th. "… in the calendar Work" lands there; a holiday or subscribed
   calendar is refused, and the answer names the calendars that work.
6. **"Show in Calendar"** on a created event, and a click or Return on an event row: does Calendar show and select
   that event, and for a recurring event the right occurrence? If Calendar only opens, note it: the link format is
   then not honored.
7. **Reminders.** "What is on my shopping list?" matches Reminders. "Remind me tomorrow at 9 to call Lisa" →
   confirm → the reminder is in the default list with date and time and alerts at 9:00. "… tomorrow" without a time
   gives a date only. "Show in Reminders": does Reminders show that reminder?
8. **Add Only access.** In System Settings → Privacy & Security → Calendars, set Orbit to "Add Only":
    - Settings → Permissions shows "Add Only" with its note and "System Settings…".
    - "What do I have tomorrow?" ends with "Orbit does not have full access to your calendars." and "Open
      Settings".
    - Set it back to full access: it works again.
9. **Speed.** "What is on in November?" on a full calendar answers within a few seconds.
10. **Calendars that share a title.** If someone shares a calendar with you that has the title of one of yours
    (for example two "Personal" calendars in iCloud), or you have two lists of one name:
    - "What do I have tomorrow?" names them "Personal (iCloud)" and "Personal (iCloud 2)".
    - "Add … to Personal" shows your default (or the only writable) one on the card, and confirming creates the
      event there. Check in Calendar that it is in the calendar the card named.
    - The same for a reminder in a list that shares its name.
11. **Reminder dates on the card.** "Remind me tomorrow to take out the trash": the card proposes a day. Tick
    "With time" (9:00 appears), change it to 7:00 and confirm: the reminder alerts at 7:00. Ask again and click "No
    Date" ("Add Date" appears): the reminder is created without a due date. With VoiceOver, a decided event card
    reads its dates in your formats, for example "Start, Tuesday, October 6, 2026 at 10:00 AM", not
    "2026-10-06T10:00…".
12. **⌘Return and a waiting card.**
    - In a long chat, ask for an event, scroll up so its card is out of view and press ⌘Return with an empty
      input. The chat scrolls to the card, its "Title" field gets the keyboard, and a note under the input says "The
      action above is waiting for your confirmation: ⌘↩ runs it, ⌘. cancels it." Nothing is created.
    - ⌘Return again creates it, and the keyboard is back in the input.
    - Pressing ⌘Return right after a card appears either runs it or brings it into view, never nothing.
    - Let ⌘Return bring the card into view, click back into the input, scroll the card out of view and press
      ⌘Return: the card comes back into view again and nothing is created.

## Photos

1. **Setup step.** In the setup after an update (see [Calendar and reminders](#calendar-and-reminders), item 1) the
   Photos step says what Orbit does with your photos; there is no step for Automation: Photos. "Allow…" shows
   macOS's prompt; allow access to the whole library.
2. **By day and month.** "Show me my photos from <a day you know>" and "… from July 2025" (a month you know):
   compare with the days view in Photos.
    - The same photos and videos, newest first, none of the hidden ones.
    - The thumbnails match (portrait, landscape and panorama shapes).
    - Videos show their length, favorites a heart, Live Photos their badge.
3. **Filters and albums.** "My favorites from last summer", "Videos from the album <one of yours>", "my screenshots
   from today" and "Live Photos from <a day>": each matches Photos.
    - Standard albums work by their names in your language ("Favorites", "Screenshots", "Videos"; on a German Mac
      "Favoriten", "Bildschirmfotos", "Videos").
    - An album inside a folder and a shared album you name work.
    - A misspelled album name makes the agent list your albums instead of guessing.
4. **iCloud-only photos.** With "Optimize Mac Storage" on, search a range with photos that are only in iCloud:
   their tiles show a small version or a cloud, and Photos starts no download for them.
5. **Showing a photo in Photos.** Click a tile (and press Return on a tile selected with Tab and the arrow keys).
    - The first time, macOS asks whether "Orbit" may control "Photos": allow.
    - Does Photos come to the front and show that photo (or video)? If Photos only opens, note it: Photos'
      `spotlight` command does not take PhotoKit's identifier.
    - Then turn Orbit off under System Settings → Privacy & Security → Automation → Orbit → Photos. A click shows
      "Orbit is not allowed to control Photos, so it cannot show the photo. …" under the input and nothing opens.
      Settings → Permissions shows "Automation: Photos" as "Not allowed", while `search_photos` keeps working.
6. **Speed and memory.** "Show me 100 photos from <a year>" shows its grid within a few seconds. After several such
   searches, Orbit's memory in Activity Monitor stops growing (thumbnails are capped), and scrolling the chat stays
   smooth.
7. **No library access.** In System Settings → Privacy & Security → Photos, turn Orbit off. "Show me photos from
   yesterday" ends with "Orbit is not allowed to access your photos." and "Open Settings"; existing cards show
   placeholders. Turn it on again: it works again.

## Apps and links

1. **Opening apps.** "Open Calculator", "Launch Safari", "Open Visual Studio Code" (if installed) and "Open vsc":
   the app comes to the front and Orbit's panel closes. When two apps fit ("Open Saf" with Safari and Safari
   Technology Preview installed), nothing opens and the agent asks which one.
2. **Links you typed.** "Open apple.com" and "Open https://www.wikipedia.org": the page opens in your default
   browser at once (you typed it, so there is no confirmation card). apple.com opens as `https://apple.com`; the
   card afterwards shows the host. "Open https://bücher.example" shows "bücher.example (xn--bcher-kva.example)".
3. **mailto links you typed.** "Open the link mailto:lisa@example.com?subject=Test": your default mail app opens a
   new message to Lisa; nothing is sent. With `…?cc=max@example.com&bcc=erika@example.com` (typed by you, so it may
   have a Bcc) your link opens without a confirmation card, the info card afterwards also shows "Cc: …" and
   "Bcc: …", and the mail app's message has both.
4. **Refused links.** Ask the agent to open `file:///Applications`, `shortcuts://run-shortcut?name=…`,
   `x-apple.systempreferences:com.apple.preference.security` or `mailto:<your address>?bcc%20=<another of yours>`:
   it refuses and nothing opens.
5. **A link you did not type.** Put `https://example.com/?from=note` into a note and ask "Open the link from my
   note <its title>".
    - An "Open link" card shows "example.com" and the whole link; nothing opens before "Open", and "Cancel" opens
      nothing.
    - "Write Lisa (lisa@example.com) an email with the subject Test": if the agent uses a mailto link, the "Start a
      new email" card comes first.
6. **Local network.** "Open my router's page" without an address: if the agent tries `http://192.168.178.1` or
   `http://fritz.box`, it is refused without a card (the chat says "Local network: only with a link from your
   message") and nothing opens. "Open http://fritz.box" and "Open fritz.box" (typed) open `http://fritz.box`.
7. **Several links.** "Open https://example.com/a https://example.com/b https://example.com/c and
   https://example.com/d": three open, and the agent gives you the fourth as text.
8. **With the Claude subscription** (Claude Code) as provider, repeat 5 and 2: the card appears, and your own link
   opens at once, the same way.

## Shortcuts and Focus

1. **Listing.** "Which shortcuts do I have?" matches the Shortcuts app (names and folders); "… in the folder <one
   of yours>" lists only that folder.
2. **Running.** "Run <a harmless shortcut that shows a notification or returns text>": the card shows the exact
   name and an empty "Input"; nothing runs before "Run". After it, the shortcut ran once and its text output is in
   the answer. Check that `~/Library/Application Support/Orbit/ShortcutInput` is empty afterwards.
3. **Text input.** A shortcut that takes text input (for example one that shows "Shortcut Input"): "Run <it> with
   the text Hello". Edit the input on the card before confirming: the shortcut gets the edited text.
4. **Misspelled name.** "Run Weathr today": no card; the agent names similar shortcuts.
5. **Image output.** A shortcut that returns an image: the card says "Result: PNG image, …"; the agent gets no
   image.
6. **Stopping.** A shortcut that waits (a "Wait" action of 60 seconds): press Escape while it runs. The run stops
   ("Stopped, result unknown"). Note whether the shortcut's later actions still happen (macOS may finish actions it
   already started).
7. **Focus.** Create a shortcut "Do Not Disturb On" (action "Set Focus" → Do Not Disturb → On; see
   [tools.md](tools.md#switching-a-focus-or-do-not-disturb)). "Turn on Do Not Disturb" makes the agent look at your
   shortcuts first (without asking you whether one exists) and run it after the card; Control Center shows Do Not
   Disturb on.
8. **Emoji names.** A shortcut whose name starts with an emoji made of several characters (for example
   "🧑‍💻 Start Work" or "👨‍👩‍👧 …"): "Run Start Work" finds it and runs it after the card.

## Appearance and volume

1. **Dark Mode.** "Turn on Dark Mode": card "Change appearance" → "Switch".
    - The first time, macOS asks whether "Orbit" may control "System Events": allow.
    - macOS turns dark; "… on" again says it already was. "Light appearance" switches back.
    - If System Settings → Appearance was on "Auto", note whether macOS stays dark or switches back later.
2. **System Events denied.** Deny System Events in System Settings → Privacy & Security → Automation → Orbit:
   "Dark Mode on" ends with "Orbit is not allowed to control System Events." and "Open Settings"; Settings →
   Permissions shows "Automation: System Events" as "Not allowed".
3. **Setting the volume.** "Set the volume to 30": the card shows the level (editable), the current level
   ("Current") and your output device by name; after "Set", the menu bar's volume shows 30%.
    - Change the level on the card to 20 before confirming: 20%.
    - "Mute" mutes; "Volume to 40" while muted unmutes ("Sound: On" on the card).
4. **Louder and quieter.** "Louder" and "Quieter": a card at once (no question back) with about 15 points more or
   less than "Current".
    - Mute the output first: "Quieter" shows "Current: …% (muted)" and "Sound: Off", and the sound stays off after
      "Set".
    - "Louder" shows "Sound: On" and unmutes it.
5. **Devices with their own volume.** With Bluetooth headphones (or AirPlay, or a USB device with its own volume)
   at 50%: "Volume to 30": the card after "Set" says "Volume: 30%" and the agent says 30% (not 50%). "Mute" there
   says "Sound off".
6. **Output device changes.** Ask for "Volume to 100" with the Mac's speakers as output, but before you click
   "Set", connect headphones or AirPods (they become the output): nothing changes. The card says "Failed" and the
   agent says the output device changed. The same with the level edited on the card first ("Not run").
7. **Devices without volume control.** With an HDMI or digital output (a display's speakers, an audio interface
   without volume control) as output: "Volume to 30" ends without a card and the agent says the device cannot be
   changed.

## Context chips and the frontmost app

1. **Setup steps after an update** (see [Calendar and reminders](#calendar-and-reminders), item 1). The setup also
   shows "Finder" (Automation: Finder) and "Accessibility".
    - Their note says the selection is taken when the panel opens (and how to switch that off), and "Skip" says no
      tool is turned off.
    - Before you click "Allow…", Accessibility shows "Not asked yet", not a red "Not allowed".
    - "Allow…" for Finder shows macOS's prompt: allow.
    - For Accessibility, macOS's dialog leads to System Settings: switch Orbit on there and come back. Without
      clicking anything, the step shows "Allowed" and "Continue", and "All Set" lists it as "Allowed".
2. **Finder selection.** Select two PDFs in Finder and open Orbit with the shortcut.
    - Within a moment the chip "With selection: <first> and 1 more" appears above the input.
    - "Summarize the selected files" reads them. The chat notes "2 file names … sent".
    - Remove the chip with × before sending: the agent does not know the files.
    - Open Orbit again and press ⌫ in the empty input instead: the chip goes (VoiceOver: "Context removed: …").
    - Select a key file (for example a `.pem`) together with a normal file: the chip reads "With selection: <file> ·
      1 protected file left out", and the agent says one item was left out without naming it.
3. **Selected text.** Select a paragraph in TextEdit, Safari or Mail and open Orbit: the chip reads "With
   selection: “…” (App)". "Translate this into French" uses exactly that text. Select a whole long document (⌘A in
   a big text): the chip appears quickly and the agent says it got the start.
4. **Passwords.** Click into a password field (for example a login page in Safari, or System Settings' password
   prompt), select its dots and open Orbit: no chip. The same in the Passwords app or Keychain Access with a revealed
   password: no chip. Try any other password manager you use (Enpass, Proton Pass, NordPass, RoboForm, Strongbox,
   MacPass, Secrets, KeePassium, …): if one gives a chip, report its bundle identifier.
5. **No selection.** Open Orbit from Finder with nothing selected, from an app with nothing selected, and from
   Orbit's own Settings window: no chips.
    - Open Orbit, type a question, close it with Escape, select something else and open it again: the typed text
      and its chips stay (when you had chips).
    - Open the panel and send at once (within a fraction of a second): the message goes without chips.
6. **The frontmost window.** "What is in my current window?" (`get_frontmost_context`): the agent names the app
   and the window title and, with a selection, uses it; the chat notes "1 window title …".
7. **Turning chips off.** Settings → General → "Use the selection when opening" off: no chips anymore. Settings →
   Permissions still lists Accessibility and Automation: Finder while `get_frontmost_context` is on (Settings →
   Tools); switch both off and both disappear from Permissions.
8. **Accessibility revoked.** Turn Orbit off in System Settings → Privacy & Security → Accessibility: chips for
   selected text stop; "What is selected?" makes the agent say Orbit lacks "Accessibility". Finder chips keep
   working.
9. **Speed.** With Finder in front and two items selected, the chip appears within about a third of a second
   after the panel. If it never appears on your Mac (slow Finder), report it: the capture gives up after 0.3
   seconds.

## Errors and notices

The unit tests cover every error case with scripted providers; these checks show the notices on your Mac.

1. **Local server stopped.** OpenAI-compatible with Ollama (`http://localhost:11434/v1`, model `gpt-oss:20b`):
   quit Ollama and ask something. After a few seconds the notice reads "The server on this Mac (localhost:11434)
   cannot be reached. Start it (for example Ollama or LM Studio) and try again." with "Try Again" and "Open
   Settings". Start Ollama and press ⌘R: the answer comes without retyping. With VoiceOver on, the notice is read
   once.
2. **Model problems.** Set the model to one you have not pulled (for example `llama3`): "The model “llama3” is not
   installed on this Mac. …". If you have a model without tool support (for example `gemma3:4b`), the notice says
   that the model cannot use tools. Settings → Model → "Test Connection" shows the same texts for both (for tools
   it asks Ollama's model information, so the model is not loaded) and for a stopped Ollama; with `gpt-oss:20b` it
   says "Connection successful".
3. **Missing key.** OpenAI-compatible with `https://api.openai.com/v1` and no key: "No API key is set. Enter it in
   Settings." (not "The API key was rejected").
4. **Claude Code signed out.** If you can sign out of Claude Code for a moment (`claude auth logout` in Terminal):
   with the Claude subscription, a question ends with "Claude Code is not signed in. …" and "Sign In…".
    - Click it: the notice shows "Signing in through your browser…" and "Cancel", and the browser opens
      Anthropic's sign-in. After signing in, the question is answered without retyping.
    - "Cancel" instead leaves the notice as it was.
    - Quit Orbit (menu bar → "Quit Orbit") while "Signing in through your browser…" shows: `pgrep -fl "auth login"`
      in Terminal then finds nothing.
5. **Usage limit.** When the subscription's usage limit is reached (only if it happens anyway): the notice says when
   it resets, and no "You have used …% of your Claude usage limit" note of the same question stays above it.
6. **Conversation too long.** With FakeLLMServer, send `#error 400 prompt is too long`: the notice offers "New
   Chat".
    - Click it: a new chat starts with `#error 400 prompt is too long` in the input, not sent. Return sends it (it
      does not open an instant result).
    - Send it again and press ⌘N instead, and once more with "New Chat" in the menu bar menu: the same.
    - After a chat that ended with an answer, ⌘N starts with an empty input.

## Launch at login

Use a copy in `/Applications` (macOS registers only such a copy as a login item).

1. Settings → General → "Open at login" on. If macOS wants your approval, the note and "Open Login Items…"
   appear: allow Orbit there and come back; the note is gone.
2. Log out and in: Orbit starts.
3. Switch it off again: Orbit no longer starts at login.

For the VoiceOver side of this switch, see [Accessibility](#accessibility), item 4.

## Accessibility

The unit tests check the logic; only your Mac shows how VoiceOver and the display options feel. Background:
[accessibility.md](accessibility.md).

1. **VoiceOver** (⌘F5):
    - Open Orbit and type "Calc": the highlighted row and the result count are read; ↓ reads the next row.
    - Ask "What do I have tomorrow?": you hear "Found … events" and then the answer, with no words while it
      streams.
    - Ask for an event: "Confirmation needed: Create event. ⌘↩ runs the action, ⌘. cancels it." interrupts; ⌘.
      cancels.
    - Ask again and switch to another app with ⌘Tab while Orbit works: the card is read as "Confirmation needed:
      Create event. Open Orbit to run or cancel the action." (no keys). Open Orbit with the shortcut: it is read with
      its keys.
    - One request that replies to an email and creates an event: while Mail's reply window has the keyboard, the
      card is read without its keys (⌘↩ would reach Mail). Click into Orbit's panel (or press the shortcut): it is
      read with them, and ⌘↩ runs it.
    - With FakeLLMServer, switch "Search files" off in Settings → Tools during a chat, then send
      `#tool search_files {"query":"x"}`: you hear "Search files: Turned off in Settings".
    - Stop the provider (or send `#error 529` with FakeLLMServer): the error is read once; navigating to it reads
      "Error: …".
    - A long answer is read up to about 2,000 characters, then you hear "The full answer is in the chat."
2. **Without the mouse:**
    - Tab to a file card, ↓, ⇧⌘R shows the file in Finder, ⌥⌘C copies its path ("Path copied"). The row's context
      menu shows both keys.
    - In Settings, ⌘1 to ⌘5 switch the tabs.
    - With the French keyboard layout (System Settings → Keyboard → Text Input), ⌘ with the keys labeled 1, 2, 3
      (they type &, é, ") switches the tabs too, and in the panel opens the first, second and third instant result.
    - With Full Keyboard Access on, Tab reaches every button in Settings, the setup and the notices.
    - ⌃F8 reaches Orbit's menu bar item.
3. **Display settings.** In System Settings → Accessibility → Display, one at a time, with the panel open:
    - "Reduce motion": the panel grows to a chat without animating, and a note under the input (Return while an
      answer runs) does not slide the chat.
    - "Reduce transparency": the panel is opaque.
    - "Increase contrast": the panel, cards, chips and your messages have clear edges, and the selected row has an
      outline.
    - "Differentiate without color": the row with the keyboard is outlined, and an overdue reminder says "Overdue".
    - Each setting changes the open panel at once.
4. **Settings with VoiceOver:**
    - Settings → Model → "Test Connection": the result is read. Press it again with an empty model field: it is
      read again.
    - Settings → Permissions → "Allow…": after macOS's prompt you hear the new status. For Accessibility you hear
      where to turn Orbit on, and "Accessibility: Allowed" when you come back from System Settings with Orbit
      switched on.
    - Settings → General → "Open at login" in a copy outside `/Applications`: the reason is read as the switch flips
      back.

## English and German interface

The unit tests and snapshots render both languages with test support; only the real app shows how macOS applies
Orbit's language. How Orbit chooses its language is described in [localization.md](localization.md).

1. **The note in Settings.** Settings → General says: "Orbit follows the language of macOS: English or German,
   whichever comes first in your preferred languages, otherwise English. To choose a language just for Orbit, go to
   System Settings > General > Language & Region > Applications; it takes effect after Orbit restarts."
2. **Switch Orbit to the other language.** In System Settings → General → Language & Region → Applications, choose
   the language Orbit does not show now (English or German, "Deutsch") for Orbit. Add Orbit with + if it is not
   listed yet. Then quit Orbit ("Quit Orbit", in German "Orbit beenden") and open it again. Everything follows:
    - The panel: "Ask Orbit or search…" (German: "Frag Orbit oder suche …").
    - The menu bar menu: "Open Orbit", "New Chat", "Settings…", "Setup…", "Quit Orbit" (German: "Orbit öffnen",
      "Neuer Chat", "Einstellungen…", "Einrichtung…", "Orbit beenden").
    - Settings (all five tabs, including the note in General), the setup ("Setup…"), cards, confirmation cards
      ("Create event", "Cancel"; German: "Termin erstellen", "Abbrechen"), notices and status lines.
    - What VoiceOver reads: "Confirmation needed: Create event. ⌘↩ runs the action, ⌘. cancels it." (German:
      "Bestätigung nötig: Termin erstellen. ⌘↩ führt die Aktion aus, ⌘. bricht sie ab.").
    - Dates keep your region's formats: with the region Germany, English shows "Mon 5. Oct · 10:00" and German
      "Mo. 5. Okt. · 10:00".
3. **Answers follow the message.** Ask a question in English and one in German, for example "Was habe ich morgen?"
   ("What do I have tomorrow?"): each is answered in its own language. Chats from before keep the language they
   were written in.
4. **Switch back.** Choose the previous language for Orbit in that list, then quit and reopen Orbit: it shows that
   language again. Selecting Orbit and clicking − instead lets Orbit follow macOS: the first of English and German
   in your preferred languages, otherwise English.
5. **Optional: a fresh installation follows macOS.** Build a debug copy with its own bundle ID, so it has its own
   settings:

    ```sh
    ORBIT_BUNDLE_ID=io.github.eric-volz.Orbit.langtest Scripts/build-app.sh debug
    ```

    Start it (with the debug variables from [development.md](development.md#debug-environment-overrides), so the
    setup does not open by itself, or skip the setup). It shows the first of English and German in your preferred
    languages, and it writes no language setting of its own: `defaults read io.github.eric-volz.Orbit.langtest AppleLanguages`
    finds nothing. Quit it and run `defaults delete io.github.eric-volz.Orbit.langtest` afterwards.

6. **Optional: the setting older builds wrote is removed.** Older builds set German as Orbit's own language on their
   first launch when German was one of your preferred languages. With the `langtest` copy quit, simulate that:

    ```sh
    defaults write io.github.eric-volz.Orbit.langtest AppleLanguages -array de
    defaults write io.github.eric-volz.Orbit.langtest appLanguageInitialized -bool YES
    ```

    Start it: both keys are gone (`defaults read io.github.eric-volz.Orbit.langtest`), and Orbit follows macOS again. Without
    the `appLanguageInitialized` marker (a language you chose in System Settings), the German setting stays. Run
    `defaults delete io.github.eric-volz.Orbit.langtest` afterwards.

## Performance

These checks need the panel on screen. Background and targets: [performance.md](performance.md).

1. **Panel timing.** In Console, filter for `Panel appeared` and open Orbit with the shortcut a few times: "Panel
   appeared in N ms" stays near 50 ms or below.
2. **Memory and CPU.** In Activity Monitor → Orbit, memory levels off over 20 chats instead of growing with each,
   and with the panel closed CPU stays at 0% (also a minute later).
3. **Long chats.** In a long chat (30 answers), scrolling with the trackpad and Page Up/Down stays smooth; when a
   long answer finishes, the chat does not stutter.

## Reporting results

When a check fails, or a check asks you to note something, open an issue at
<https://github.com/eric-volz/Orbit/issues> with the section and item number, your macOS version, your Mac (Apple
silicon or Intel), the provider and model, and what you saw. Leave out personal content: describe the data
("a recurring event shared from an Exchange account") instead of pasting it. See
[CONTRIBUTING.md](../CONTRIBUTING.md) for how to contribute.
