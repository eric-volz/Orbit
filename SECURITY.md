# Security policy

Orbit reads personal data (files, mail, notes, contacts, calendars, photos) and lets a language model act on the
Mac through tools. We take reports about weaknesses in that design seriously. This page explains how to report a
vulnerability privately and what to expect.

## Supported versions

Only the **latest release** of Orbit receives security fixes. If you build from source, please check that the issue
still exists on the latest release or the current `main` branch before reporting it.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub's private vulnerability reporting:

**<https://github.com/eric-volz/Orbit/security/advisories/new>**

Only the maintainers can see the report. We will discuss it with you there and, once a fix is available, publish an
advisory, crediting you if you wish.

## What to include

- **What is affected:** the Orbit version (select `Orbit.app` in Finder and choose File → Get Info), the tag or commit
  you built it from (`git describe --tags --always` in your clone) and whether it is a release or a debug build, the
  macOS version, Apple silicon or Intel, and the language model provider you used (Claude subscription via Claude
  Code, Anthropic API, or an OpenAI-compatible server).
- **What the problem is** and what an attacker gains, for example reading a file Orbit should never read, opening a
  link without a confirmation card, running an action that should need confirmation, reaching the MCP bridge from
  another origin, or leaking data into the logs.
- **How to reproduce it:** steps, the prompt or the crafted content (a mail, note, file or web page) that triggers it,
  and what Orbit did. A minimal proof of concept helps most.
- **Logs**, if relevant: `log show --last 10m --predicate 'subsystem == "io.github.eric-volz.Orbit"'`.
- **Your suggestion** for a fix, if you have one.

Please use invented data in your report. Do not include real personal data, API keys, Claude credentials or other
secrets, yours or anyone else's.

## What to expect

Orbit is maintained by volunteers on a **best-effort basis**:

- We aim to acknowledge a report within a few days and to keep you informed while we investigate and fix it.
- We will coordinate the disclosure with you; please give us reasonable time to release a fix before you publish
  details.
- There is **no bug bounty**.

## Scope

**In scope**

- The Orbit app and its source code in this repository: the agent loop, tools and their access policies (files,
  links, AppleScripts), confirmation cards, context capture, storage, logging, the Claude Code integration and the MCP
  loopback bridge.
- Ways for untrusted content (mail, notes, files, web pages, window titles) to make Orbit act without the user's
  confirmation, read secrets, or send data anywhere other than the configured provider.
- Weaknesses in how Orbit stores chats, API keys and temporary files on disk.
- Release builds being signed, entitled or notarized in a way that weakens their protection.

**Out of scope**

- A language model giving wrong, unhelpful or manipulated answers that do not lead to an action without confirmation,
  a disclosure beyond the configured provider, or access Orbit's policies should prevent. (Prompt injection that only
  changes the wording of an answer is a known, residual risk.)
- Actions the user explicitly approved on a confirmation card, and links the user typed or pasted themselves.
- Attacks that require code already running as the same user, physical access to an unlocked Mac, or a compromised
  macOS.
- Vulnerabilities in third-party software Orbit uses or talks to: Claude Code, the language model providers, Ollama
  or LM Studio, macOS and its apps, KeyboardShortcuts or GRDB.swift. Please report those to their maintainers.
- Developer tools that never ship in the app (`FakeLLMServer`, `orbitctl`, `OrbitStrings`) and DEBUG-only features,
  unless they are reachable in a release build.

## More information

- [Security model](docs/security-model.md): assets, trust boundaries, threats and mitigations, residual risks.
- [Privacy](docs/privacy.md): what leaves the Mac, what is stored where, logs, deleting data.
- [Permissions](docs/permissions.md): every macOS permission Orbit uses.
