# Changelog

All notable changes to Orbit are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Orbit follows [Semantic Versioning](https://semver.org/).

## Unreleased

Nothing yet.

## 0.1.0 (2026-10-05)

The first open-source release of Orbit, a native macOS launcher with a built-in AI assistant that works with your
files, Mail, Notes, Calendar, Reminders, Photos and Shortcuts, uses the language model you choose, and asks before it
acts.

Documentation: <https://eric-volz.github.io/Orbit/>, including the
[known limitations](https://eric-volz.github.io/Orbit/known-limitations.html).

### Added

- **The panel**: a floating, Spotlight-style panel that opens from anywhere with a global shortcut (⌥ Space by
  default, configurable), plus a menu bar item with Open Orbit, New Chat, Settings… and Setup…; Orbit has no Dock
  icon.
- **Instant search**: apps, files and folders (through Spotlight) and contacts as you type, with fuzzy matching,
  launch-count ranking and ⌘1 to ⌘9; none of it is sent to a model.
- **The assistant**: a streaming chat with an agent that uses 25 tools across files, Mail, Notes, Contacts,
  Calendar, Reminders, Photos, apps, links, Shortcuts, the appearance, the volume and the frontmost app's selection.
- **Result cards** for files (with Quick Look, drag and drop and Show in Finder), mail, drafts and replies, notes,
  contacts, events, reminders and photos; all of them except contact cards work from the keyboard.
- **Confirmation cards**: Orbit waits for your OK on a card before it creates a note, an event or a reminder, runs a
  shortcut, changes the appearance or the volume, or opens a link you did not type; on most of these cards you can
  still edit the values first. Orbit never sends mail, and no tool deletes anything.
- **Three kinds of language model**: your Claude Pro or Max subscription through the locally installed Claude Code,
  the Anthropic API, or any OpenAI-compatible server such as Ollama, LM Studio or OpenAI, with a model that supports
  tool calling.
- **Context chips**: the Finder selection or the text selected in the app you came from, offered as context when the
  panel opens (never from password fields or password managers).
- **Privacy by design**: no server of its own and no telemetry; the chat shows what content was sent to the model;
  chats stay in a local database, API keys in the keychain, and logs never contain content.
- **Setup assistant**: choose a language model, check the shortcut and allow permissions one at a time; every step
  can be skipped. The Permissions tab in Settings shows the status of every permission, including three that are
  set only there.
- **Accessibility**: VoiceOver labels and announcements, keyboard control of almost everything, and support for
  Reduce Motion, Reduce Transparency, Increase Contrast and Differentiate Without Color.
- **Languages**: English and German, following the macOS language settings.
- **For contributors**: FakeLLMServer (a scripted stand-in for the Anthropic and OpenAI APIs), orbitctl (drives a
  debug build), OrbitStrings (String Catalog tooling) and a unit test suite that runs on mocks and invented data only.
