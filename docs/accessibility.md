# Accessibility

How Orbit works with VoiceOver, from the keyboard alone and with macOS's display settings, including exactly what
VoiceOver announces and what it deliberately leaves out, plus how this is tested and what is still missing.

**On this page**

- [VoiceOver](#voiceover)
- [Keyboard-only use](#keyboard-only-use)
- [Display settings](#display-settings)
- [How accessibility is tested](#how-accessibility-is-tested)
- [Known gaps](#known-gaps)

## VoiceOver

### Labels

Every control has a label, and a value or hint where it helps. Symbols are read as words, or hidden when the text
next to them already says it. Some examples:

- Search results are read as name, kind or folder, and ⌘ number: "Mail, Application, Command-1". The **Ask Orbit**
  row has the hint "Sends your input to Orbit".
- Your own messages are read as "You: …"; the typing dots as "Orbit is answering…".
- Tool status rows are read as their text with the state as value: Running, Completed, Failed or Canceled.
- Notices start with "Error:" or "Warning:" when you navigate to them; on screen, their symbol says it.
- A file card row reads its name, folder, date and size, and offers the actions **Open**, **Quick Look**, **Show in
  Finder** and **Copy Path**.
- A context chip is read as "Context: With selection: …" and offers the action **Remove**.
- Confirmation cards are read as "Confirmation: Create event" (or whatever they ask for). Dates on a decided card are
  read as the card shows them, for example "Tuesday, October 6, 2026 at 10:00 AM", never as
  "2026-10-06T10:00:00+02:00".
- Checklists in answers read "Completed" or "Not completed"; a code block's copy button is "Copy Code".
- Permission buttons name their permission ("Allow Automation: Mail", "Open System Settings for Contacts").
- States are never told by color alone: tool rows have ✓, ✗ or a dash symbol, notices have their own symbols, and
  permissions have a symbol and a word.

### What VoiceOver announces

While you type, the keyboard stays in the input field, so VoiceOver would not notice changes elsewhere in the panel.
Orbit tells it about them:

**Search and input**

- The row that ↑/↓ highlight ("Ask Orbit: “ma”", or "Mail, Application, Command-1").
- How many results a search found, once it is done ("No results", "1 result", "7 results").
- The context chips Orbit took ("Context added: With selection: Offer.pdf") and the chip ⌫ removed ("Context removed:
  …").
- The note under the input when something did not work (for example "“Offer.pdf” was not found. It may have been
  moved or deleted.").

**A request**

- Each tool's outcome: its result line ("Found 3 emails"); a failure with the tool's name ("Search mail: Timed out"),
  also a call Orbit did not run ("Search files: Turned off in Settings").
- A confirmation card that waits: "Confirmation needed: Create event. ⌘↩ runs the action, ⌘. cancels it." This
  announcement interrupts. While the panel is hidden, or while Mail's reply window has the keyboard Orbit handed it,
  those keys would reach another app, so it says "Confirmation needed: Create event. Open Orbit to run or cancel the
  action." instead, and the version with the keys follows as soon as the panel has the keyboard again: when it
  appears, or when you click into it or press the shortcut after the reply.
- Where a reply's text is, once its card is in view ("Reply opened in Mail: paste the text from the clipboard with
  ⌘V").
- The answer, once it is complete, as plain text without its Markdown (up to 2,000 characters, then "The full answer
  is in the chat.")
- Notices, once when they appear. An error interrupts what VoiceOver is saying; other notices wait.
- A request whose panel you closed is still announced.

**Cards**

- The row, tile or button that Tab and the arrow keys select on a card: a file's name, folder, date and size; a
  message's sender, subject, date and whether it is unread; a note's title, folder and date; an event's title, time,
  place, calendar and state ("Declined", "Canceled", "Repeats"); a reminder's due date, list and "Not completed",
  "Overdue" or "Completed"; a photo's kind, date (with the year when it is not this year), "Favorite" and "Only in
  iCloud".
- "Path copied" after ⌥⌘C on a file card.

**Settings and the setup window**

- The result of **Test Connection**: on every press, also when it is the same result again.
- macOS's answer to **Allow…** ("Contacts: Allowed"). For Accessibility, which you turn on in System Settings, Orbit
  announces where to do that, and "Accessibility: Allowed" once you come back with Orbit switched on.
- How **Sign In…** for Claude Code ended ("Connected to your Claude subscription (Max)", or why not).
- What **Open at login** shows next to the switch (approval needed, or why it failed).
- "Chat history deleted" (or why not).
- A recorded shortcut ("Keyboard shortcut: ⌥Space") or why it was refused.
- Each setup step's title with its position ("Keyboard Shortcut, step 3 of 12").

### What is deliberately not announced

- The streamed words of an answer and the running steps. Only outcomes and the complete answer are read.
- Text the model writes before or between tool calls.
- A missing permission twice: its notice says it, so the tool's failure line is not read as well.
- A reply in Mail twice: the panel says where its text is when Mail's window takes the keyboard, so the tool's own
  result line is not read.

## Keyboard-only use

Everything works without the mouse:

- **Panel:** the shortcut opens and closes it; ↑/↓ and Return (or ⌘1 to ⌘9) open instant results; ⌘Return asks Orbit;
  Escape stops an answer or closes the panel; ⌘N starts a new chat; Page Up/Down, Home/End and ⌘↑/⌘↓ scroll the
  chat; ⌫ in the empty input removes the last chip; ↑ in the empty input brings back a parked chat.
- **Cards:** Tab in the input reaches the latest card; Tab and Shift-Tab move between cards and back; ↑/↓ (←/→ on
  photo grids and draft buttons) select; Return opens; Space toggles Quick Look on file cards; ⇧⌘R shows a file in
  Finder; ⌥⌘C copies its path.
- **Confirmation cards:** ⌘Return brings a waiting card into view and gives its first field the keyboard (Tab moves
  between the fields); the next ⌘Return runs it; ⌘. cancels it.
- **Notices:** ⌘R tries again. **Settings:** ⌘1 to ⌘5 choose a tab. **Setup window:** Return and Escape.
- **Menu bar menu:** ⌃F8, then the arrow keys and Return.
- With **Full Keyboard Access**, Tab also reaches every button, switch and menu.

The complete list, including the notes on AZERTY and other layouts, is in [Keyboard shortcuts](keyboard-shortcuts.md).

## Display settings

Orbit follows the options in System Settings → Accessibility → Display, and applies a change to an open panel at
once:

| Setting | Effect in Orbit |
|---|---|
| **Reduce Motion** | The panel takes its new height at once instead of animating to it; the note under the input appears and goes without sliding the chat or the results below it; the typing dots stand still. |
| **Reduce Transparency** | The panel has an opaque background instead of the translucent material. |
| **Increase Contrast** | The panel, cards, tables, chips, your messages, notices, key caps, code blocks and the selected row get clear edges. |
| **Differentiate Without Color** | The row that has the keyboard is outlined, not only accent-colored; the selected photo of a grid that does not have the keyboard has a thinner ring; an overdue reminder says "Overdue" instead of being only red; the current step of the setup window is a wider dot than the others. |

## How accessibility is tested

The unit tests check labels, values, announcements and the display options as logic, without VoiceOver and
without windows. The opt-in window tests drive the panel with key events (for example ⇧⌘R on a file card), and the
opt-in snapshot tests render the panel's views with Increase Contrast and Differentiate Without Color
(`a11y-contrast-…`). How VoiceOver and the display options feel on a real Mac is part of the manual acceptance
checks. See [Testing](testing.md) and [Manual QA](manual-qa.md).

## Known gaps

- Links inside an answer are reached with VoiceOver's Links rotor, but not with Tab.
- Contact cards are not part of the cards' Tab order (Tab skips them); VoiceOver reads them and reaches their email
  links.
- A long, richly formatted answer (lists, tables) takes about 10 ms per 1,500 characters to build when it scrolls into
  view.
- Quick Look opens without the zoom animation from the row.

More limitations are listed in [Known limitations](known-limitations.md).
