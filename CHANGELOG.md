# Changelog

All notable changes to Orbit are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Orbit follows [Semantic Versioning](https://semver.org/).

## Unreleased

Nothing yet.

## 0.1.0 (first public release, not yet tagged)

The first open-source release of Orbit.

### Added

- **The panel**: a floating, Spotlight-style panel that opens from anywhere with a global shortcut (⌥ Space by
  default, configurable), plus a menu bar item with Open Orbit, New Chat, Settings… and Setup…; Orbit has no Dock
  icon.
- **Instant search**: apps, files and folders (through Spotlight) and contacts as you type, with fuzzy matching,
  launch-count ranking and ⌘1 to ⌘9; nothing of it is sent to a model.
- **The assistant**: a streaming chat with an agent that uses 25 tools across files, Mail, Notes, Contacts,
  Calendar, Reminders, Photos, apps, links, Shortcuts, the appearance, the volume and the frontmost app's selection.
- **Result cards** for files (with Quick Look, drag and drop and Show in Finder), mail, drafts and replies, notes,
  contacts, events, reminders and photos, all usable from the keyboard.
- **Confirmation cards**: creating notes, events and reminders, running shortcuts, changing the appearance or the
  volume and opening links that you did not type wait for your confirmation, with editable values.
- **Three kinds of language model**: your Claude subscription through the locally installed Claude Code, the
  Anthropic API, and any OpenAI-compatible server such as Ollama, LM Studio or OpenAI.
- **Context chips**: the Finder selection or the text selected in the app you came from, offered as context when the
  panel opens (never from password fields or password managers).
- **Privacy by design**: no server of its own and no telemetry; the chat shows what content was sent to the model;
  chats stay in a local database, API keys in the keychain, and logs never contain content.
- **Setup assistant** with one step per permission, and a Permissions tab that shows every permission's status.
- **Accessibility**: VoiceOver labels and announcements, complete keyboard control, and support for Reduce Motion,
  Reduce Transparency, Increase Contrast and Differentiate Without Color.
- **Languages**: English and German, following the macOS language settings.
- **Developer tools**: FakeLLMServer (a scripted stand-in for both model APIs), orbitctl (drives a debug build) and
  OrbitStrings (String Catalog tooling), plus a unit test suite that runs on mocks and invented data only.
