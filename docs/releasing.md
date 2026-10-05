# Releasing

How to version, build, sign, notarize and publish Orbit. It covers the build configurations, the three signing
options (ad hoc, a local development certificate, Developer ID), the entitlements, notarization with
`Scripts/notarize.sh`, distribution, the release workflow on GitHub Actions, and a release checklist.

**On this page**

- [Overview](#overview)
- [Versioning](#versioning)
- [Build configurations](#build-configurations)
- [Code signing](#code-signing)
- [Entitlements](#entitlements)
- [Notarization](#notarization)
- [Distribution](#distribution)
- [Automated releases](#automated-releases)
- [Release checklist](#release-checklist)
- [Permissions and ad hoc builds](#permissions-and-ad-hoc-builds)

## Overview

> [!NOTE]
> **Current state: source only releases.** The project has no Developer ID yet, so its releases ship no app. The
> [release workflow](#automated-releases) publishes the notes, GitHub adds the source archives, and users build Orbit
> themselves as described in [Getting started](getting-started.md#building-from-source). Everything on this page
> about Developer ID signing and notarization applies once the project has a Developer ID; from then on, adding the
> [secrets](#secrets) to the repository is enough.

A public release with an app is a **universal** (Apple silicon and Intel) **release** build, signed with a **Developer ID
Application** certificate with the Hardened Runtime and a secure timestamp, **notarized** by Apple, with the
notarization ticket **stapled** to the app, and published as a zip on
[GitHub Releases](https://github.com/eric-volz/Orbit/releases).

```sh
# Once: store the notary credentials in the keychain (asks for an app-specific password).
xcrun notarytool store-credentials orbit-notary --apple-id you@example.com --team-id TEAMID

# Each release.
ORBIT_VERSION=0.1.0 ORBIT_BUILD=1 \
ORBIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  Scripts/build-app.sh release --universal
ORBIT_NOTARY_PROFILE=orbit-notary Scripts/notarize.sh    # notarize, staple, Gatekeeper check, zip
```

Everything is driven by two scripts: [`Scripts/build-app.sh`](../Scripts/build-app.sh) builds, assembles,
localizes and signs the app; [`Scripts/notarize.sh`](../Scripts/notarize.sh) notarizes it and writes the
distributable zip. There is no Xcode project. The toolchain and the other scripts are described in
[development.md](development.md).

Pushing a version tag such as `v0.1.0` runs the same scripts on GitHub Actions and publishes the release; see
[Automated releases](#automated-releases).

## Versioning

`build-app.sh` fills the placeholders in [`Config/Info.plist`](../Config/Info.plist) from environment variables
(there is no version number to edit in a file):

| Variable | Info.plist key | Default | Meaning |
|---|---|---|---|
| `ORBIT_VERSION` | `CFBundleShortVersionString` | `0.1.0` | The version users see. `notarize.sh` names the zip after it (`Orbit-<version>.zip`). |
| `ORBIT_BUILD` | `CFBundleVersion` | `1` | The build number. Increase it with every build you publish. The [release workflow](#automated-releases) uses the number of commits. |
| `ORBIT_BUNDLE_ID` | `CFBundleIdentifier` | `io.github.eric-volz.Orbit` | The bundle identifier. |

The script checks the result with `plutil -lint` and stops if any `$(…)` placeholder is left unsubstituted.

Keep `ORBIT_BUNDLE_ID` at its default for releases. The bundle identifier decides the settings domain
(the UserDefaults of `io.github.eric-volz.Orbit` by default), the keychain service for API keys (`<bundle id>.credentials`, with items labeled
"Orbit: <account>" in the login keychain), the unified logging subsystem and, together with the signature, the privacy permissions macOS has granted. A release with
another identifier is, for macOS, a different app: users would lose their settings, keys and permissions. (The chat
history folder `~/Library/Application Support/Orbit` does not depend on it.) Use other identifiers only for
development copies, for example `ORBIT_BUNDLE_ID=io.github.eric-volz.Orbit.dev`.

The version also shows when two copies meet: if another copy of Orbit is running when you open a new one, Orbit asks
"Another copy of Orbit is open (version 0.1.0). Quit it so this copy (version 0.2.0) can start?". A forgotten version bump
makes that dialog confusing, so bump `ORBIT_VERSION` for every release.

## Build configurations

```sh
Scripts/build-app.sh [debug|release] [--universal]
```

| Invocation | Output | Notes |
|---|---|---|
| `Scripts/build-app.sh debug` (default) | `build/debug/Orbit.app` | SwiftPM debug configuration, `Config/Orbit-Debug.entitlements` (allows a debugger to attach). DEBUG-only code such as the [debug environment overrides](development.md#debug-environment-overrides) and the `orbitctl` remote control is included. |
| `Scripts/build-app.sh release` | `build/release/Orbit.app` | Optimized, `Config/Orbit.entitlements`, no DEBUG code. Built for the Mac's own architecture only. |
| `Scripts/build-app.sh release --universal` | `build/release/Orbit.app` | Builds `arm64` and `x86_64` separately (`--triple arm64-apple-macosx14.0` and `--triple x86_64-apple-macosx14.0`) and merges them with `lipo`; the script checks that the result contains both architectures. Meant for release builds. |

The deployment target and `LSMinimumSystemVersion` are macOS 14.0.

**Universal builds and the arm64-only override.** On an Apple silicon Mac the `x86_64` slice is cross-compiled. If
that build fails, `--universal` stops with the first error line and the path of the build log. With
`ORBIT_ALLOW_ARM64_ONLY=1` the script continues with `arm64` only, prints a warning, and the summary ends with a
note saying why the slice is missing. Such a build is not universal, and `notarize.sh` refuses it, so use the
override only for local testing.

What else `build-app.sh` does, in order:

1. Compiles the app (one or two slices) and rewrites the KeyboardShortcuts resource bundle lookup in the executable
   so the bundle can live in `Contents/Resources`. It stops on unknown SwiftPM resource bundles.
2. Removes the build machine's paths from the executable, so that no user name or home path ends up in
   `Orbit.app`: the debug information moves into a dSYM next to the app (`build/<config>/Orbit.app.dSYM`, local
   only and never shipped), the executable loses its debug symbols (`strip -S`), and every remaining absolute build
   path in it is overwritten. If one is left, the build fails. All of this happens before signing.
3. Assembles `Orbit.app`, fills in `Info.plist`, lints and compiles the String Catalogs to
   `<lang>.lproj/*.strings` (see [localization.md](localization.md#how-the-build-compiles-the-catalogs)).
4. Checks the AppleScripts with `osacompile` and copies them as source. A script is only compiled when every app it
   addresses ships a scripting dictionary (Notes, Mail, Photos, Finder and System Events do), because compiling for
   an app without one would launch it. Copies the icon `Orbit/Resources/AppIcon.icns`.
5. Signs and verifies the app (see below).
6. Prints a summary: version and build, bundle ID, architectures, minimum macOS, signature and its flags,
   entitlements file, localizations (with the number of German translations, for example "de: 679 of 679
   strings translated"), icon, size and the location of the debug symbols (`Orbit.app.dSYM`, not shipped).

Intermediate files go to `build/<config>/.work`; the script deletes them unless the summary has a note (then the
build logs stay for a look).

## Code signing

`build-app.sh` signs with `codesign --force --options runtime --entitlements <file> --sign <identity>`, so every
build, including ad hoc ones, uses the **Hardened Runtime**. It then runs
`codesign --verify --strict --deep`. The identity comes from `ORBIT_SIGN_IDENTITY`:

| Identity | How | Use |
|---|---|---|
| Ad hoc (default, `-`) | Nothing to set up. | Trying Orbit on your own Mac. The signature changes with every build, so macOS forgets the privacy permissions after each rebuild. |
| `"Orbit Development"` | Create it once with `Scripts/create-dev-cert.sh`. | Day-to-day development and [manual QA](manual-qa.md): the permissions stay across rebuilds. Not for distribution. |
| `"Developer ID Application: Name (TEAMID)"` | A Developer ID Application certificate from your Apple Developer account, installed in the login keychain. | Releases, followed by `Scripts/notarize.sh`. |

**Secure timestamp.** `codesign` adds a secure timestamp (`--timestamp`) automatically for identities starting
with "Developer ID Application" or "Apple Development", and skips it (`--timestamp=none`) otherwise.
`ORBIT_TIMESTAMP=1` forces it and `ORBIT_TIMESTAMP=0` skips it. Notarization requires the timestamp.

**Gatekeeper preview.** For a Developer ID identity, `build-app.sh` also runs `spctl --assess`. Before notarization
it reports "Unnotarized Developer ID"; that is expected, and `notarize.sh` repeats the check after stapling.

### The development certificate

```sh
Scripts/create-dev-cert.sh                                        # once
ORBIT_SIGN_IDENTITY="Orbit Development" Scripts/build-app.sh debug
Scripts/create-dev-cert.sh --remove                               # delete it again
```

[`create-dev-cert.sh`](../Scripts/create-dev-cert.sh) creates a self-signed code-signing identity named "Orbit
Development" in your login keychain with the system LibreSSL (`/usr/bin/openssl`):

- an RSA 2048 key and a certificate valid for ten years (3,650 days), with the extended key usage "code signing"
  only;
- imported into `~/Library/Keychains/login.keychain-db`, with access for `/usr/bin/codesign`;
- not marked as trusted. `codesign` does not need that, and macOS's privacy database only compares the certificate
  hash in the designated requirement, so no system trust settings change. Untrusted self-signed identities show up
  in `security find-identity -p codesigning` as "matching", not "valid".

The certificate never leaves your Mac. If macOS asks on the first build whether `codesign` may use the key, choose
"Always Allow". Running the script again when the identity exists only prints how to use it. If a certificate with
that name exists without its private key, the script stops and asks you to run `--remove` first. `--remove`
deletes the certificate and its private key.

## Entitlements

There are two entitlements files. Both are used with the Hardened Runtime and **without the App Sandbox**.

| Entitlement | [`Orbit.entitlements`](../Config/Orbit.entitlements) (release) | [`Orbit-Debug.entitlements`](../Config/Orbit-Debug.entitlements) (debug) | Why |
|---|---|---|---|
| `com.apple.security.automation.apple-events` | ✓ | ✓ | Under the Hardened Runtime an app may send Apple Events only with this entitlement. Orbit controls Mail, Notes, Photos, Finder and System Events (search mail, open drafts, read and create notes, show a photo, read the Finder selection, switch Dark Mode). macOS still asks the user per target app (Automation). |
| `com.apple.security.personal-information.addressbook` | ✓ | ✓ | Access to Contacts (`search_contacts`, contacts in instant search). |
| `com.apple.security.personal-information.calendars` | ✓ | ✓ | Access to calendars and reminders through EventKit (`list_events`, `create_event`, `list_reminders`, `create_reminder`). |
| `com.apple.security.personal-information.photos-library` | ✓ | ✓ | Access to the Photos library through PhotoKit (`search_photos`). |
| `com.apple.security.get-task-allow` | | ✓ | Lets a debugger attach to debug builds. Notarization rejects it, which is one reason to notarize only release builds. |

Each of these only allows Orbit to *ask*: macOS shows its own prompt the first time, with the reasons from
`Info.plist` (`NSAppleEventsUsageDescription`, `NSContactsUsageDescription`, `NSCalendarsFullAccessUsageDescription`,
`NSRemindersFullAccessUsageDescription`, `NSPhotoLibraryUsageDescription`, the Desktop, Documents and Downloads
folder descriptions, and the older `NSCalendarsUsageDescription` and `NSRemindersUsageDescription`). Accessibility
and Full Disk Access need no entitlement; users grant them in System Settings. See
[permissions.md](permissions.md).

**Why there is no App Sandbox.** Orbit's job is to work with other apps and your files, which the sandbox is
designed to prevent. A sandboxed Orbit could not send Apple Events to arbitrary apps without temporary exception
entitlements, read another app's selected text through the Accessibility API, read files anywhere that Spotlight
finds them, or start the locally installed Claude Code and `/usr/bin/shortcuts` as child processes. Orbit relies
instead on the Hardened Runtime, macOS's privacy permissions, confirmation cards for every action with consequences,
and the rules described in [security-model.md](security-model.md).

The Hardened Runtime is used without exceptions: no JIT, no unsigned executable memory, no disabled library
validation. Claude Code runs as its own process with its own signature, so for that provider the network connection
to Anthropic is Claude Code's, not Orbit's.

## Notarization

### Prerequisites

1. A **Developer ID Application** certificate in your login keychain (Apple Developer account → Certificates →
   Developer ID Application).
2. A release build signed with it:

    ```sh
    ORBIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release --universal
    ```

3. Notary credentials stored once in the keychain, with an app-specific password from appleid.apple.com (or an App
   Store Connect API key):

    ```sh
    xcrun notarytool store-credentials orbit-notary \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
    ```

`notarytool` ships with the Command Line Tools and with Xcode 13 or later.

### Running it

```sh
ORBIT_NOTARY_PROFILE=orbit-notary Scripts/notarize.sh                  # build/release/Orbit.app
ORBIT_NOTARY_PROFILE=orbit-notary Scripts/notarize.sh path/to/Orbit.app
```

What [`notarize.sh`](../Scripts/notarize.sh) does, step by step:

1. **Checks the inputs.** The app exists (default `build/release/Orbit.app`), `ORBIT_NOTARY_PROFILE` is set, and
   `notarytool` is available.
2. **Checks the keychain** for a "Developer ID Application" signing identity.
3. **Refuses apps that are not universal.** The executable must contain both `arm64` and `x86_64`; otherwise it
   stops with "Orbit.app is not universal (…). Build it with: Scripts/build-app.sh release --universal". This keeps
   a thin build from being published by accident.
4. **Checks the signature:** signed by a "Developer ID Application" identity (not ad hoc, not "Orbit Development"),
   with the Hardened Runtime flag, with a secure timestamp, and valid under `codesign --verify --strict --deep`.
5. **Uploads** a zip of the app (made with `ditto -c -k --sequesterRsrc --keepParent` in a temporary folder) with
   `xcrun notarytool submit --keychain-profile <profile> --wait --timeout 30m`.
6. **On failure** (any status other than "Accepted"), prints the status, the JSON result and the notarization log
   (`notarytool log`), and stops.
7. **Staples** the ticket to the app (`xcrun stapler staple`) and validates it (`xcrun stapler validate`).
8. **Checks with Gatekeeper** (`spctl --assess --type execute -vv`).
9. **Writes the distributable zip** next to the app: `build/release/Orbit-<version>.zip`, again with `ditto`, so it
   contains the stapled app. The version is read from the app's `CFBundleShortVersionString`.

The temporary folder is deleted when the script ends.

## Distribution

The [release workflow](#automated-releases) does these steps for every pushed version tag. By hand:

1. **The archive.** Publish the zip that `notarize.sh` wrote (`build/release/Orbit-<version>.zip`). Do not zip
   the app yourself with Finder or `zip`; `ditto` keeps the extended attributes and the stapled ticket intact.
2. **A checksum.** Publish a SHA-256 checksum next to it:

    ```sh
    cd build/release
    shasum -a 256 Orbit-0.1.0.zip > Orbit-0.1.0.zip.sha256
    ```

    Users can check a download with `shasum -a 256 -c Orbit-0.1.0.zip.sha256`.

3. **GitHub Releases.** Create a release for the tag (for example `v0.1.0`) at
   <https://github.com/eric-volz/Orbit/releases>, paste the version's section of `CHANGELOG.md` as the notes, and attach
   the zip and the checksum file. With the GitHub CLI:

    ```sh
    gh release create v0.1.0 build/release/Orbit-0.1.0.zip build/release/Orbit-0.1.0.zip.sha256 \
      --title "Orbit 0.1.0" --notes-file release-notes.md
    ```

Users unpack the zip, move `Orbit.app` to `/Applications` and open it (see
[getting-started.md](getting-started.md)). Orbit has no update checks; users update by replacing the app.

**Repository presentation.** Once the repository is public, upload `docs/assets/social-preview.png` (1280 × 640) under
the repository's **Settings → General → Social preview**, so links to the project show Orbit's icon and tagline.
Enable **private vulnerability reporting** under **Settings → Security**, since [SECURITY.md](../SECURITY.md) asks
reporters to use it. Set **Settings → Pages → Build and deployment → Source** to **GitHub Actions**, so the docs
workflow publishes the documentation site (see [Documentation site](development.md#documentation-site)).

## Automated releases

[`.github/workflows/release.yml`](../.github/workflows/release.yml) publishes a release when you push a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Tags look like `v1.2.3`; a suffix such as `v1.3.0-beta.1` makes a prerelease. The workflow runs on a `macos-26`
runner with the newest stable Xcode (change `runs-on` when GitHub retires that image) and:

1. **Reads the version** from the tag (`ORBIT_VERSION` is the tag without the `v`) and sets `ORBIT_BUILD` to the
   number of commits, so a later tag gets a higher build number.
2. **Takes the release notes** from the `CHANGELOG.md` section whose heading starts with `## <version>`. A release
   without such a section stops here with an error; a prerelease without one gets notes that GitHub generates from
   the commits.
3. **Runs the unit tests** with `Scripts/swiftpm.sh test --no-parallel`. On the runner's three cores, parallel
   `@MainActor` suites starve one another and tests that wait for a result time out; one after another they pass.
   The runner uses English (United States) and UTC; [testing.md](testing.md#running-the-unit-tests) shows how to
   run the tests that way on your Mac. When tests fail, the run's page lists them in an annotation, which unlike
   the log needs no GitHub login.
4. **Builds** with `Scripts/build-app.sh release --universal`.
5. **With the signing secrets:** signs with the Developer ID certificate from a temporary keychain, runs
   `Scripts/notarize.sh` and writes the SHA-256 checksum. The `Orbit.app.dSYM` is kept as a workflow artifact for
   90 days, for symbolicating crash reports of that build.
6. **Creates the release** "Orbit <version>" with the notes, and with `Orbit-<version>.zip` and
   `Orbit-<version>.zip.sha256` when the build was signed. If the release exists already (a release created in
   GitHub's web interface pushes its tag, too), the workflow only uploads the files and leaves the notes alone.

Without the signing secrets (the current state) the workflow still tests and builds, but the release gets no app:
an ad hoc build is blocked by Gatekeeper after a download and loses its permissions with every update (see
[Permissions and ad hoc builds](#permissions-and-ad-hoc-builds)). Such a release has the source archives that GitHub
adds to every release, and the workflow appends an "Installing" section to its notes with the commands that build
exactly that tag.

To redo a release, delete it together with its tag (`gh release delete v0.1.0 --cleanup-tag`), fix what was wrong,
and push the tag again.

### Secrets

Add them under the repository's **Settings → Secrets and variables → Actions**. Set all five or none; with only some
of them the workflow stops.

| Secret | Content |
|---|---|
| `DEVELOPER_ID_CERTIFICATE` | The Developer ID Application certificate with its private key: export both from Keychain Access as a `.p12` file, then encode it with `base64 -i DeveloperID.p12 -o DeveloperID.txt` and paste the text. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you chose for the `.p12` export. |
| `NOTARY_KEY` | The contents of an App Store Connect API key file (`AuthKey_<key id>.p8`). Create the key in App Store Connect under **Users and Access → Integrations → App Store Connect API** with the Developer role; Apple lets you download the file only once. |
| `NOTARY_KEY_ID` | The ID of that key. |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the list of keys. |

The workflow stores the API key as the notary profile `orbit-notary` in the temporary keychain, so `notarize.sh`
runs unchanged, and deletes the keychain when the job ends.

## Release checklist

Copy this list into the release's tracking issue. For a source only release (no Developer ID), skip **Universal
build** and **Notarization**, do the smoke test with an app built from the tag as described in the release notes,
and publish by pushing the tag.

- [ ] **Version.** Choose the new `ORBIT_VERSION` and a higher `ORBIT_BUILD`. With the release workflow, the tag
  sets the version and the build number is the commit count.
- [ ] **CHANGELOG.md.** Add a section for the version with the user-visible changes; it becomes the release notes.
- [ ] **Unit tests.** `Scripts/swiftpm.sh test` passes.
- [ ] **Localization lint.** 0 errors and 0 warnings for both catalogs:

    ```sh
    Scripts/swiftpm.sh run OrbitStrings lint --sources Orbit --catalog Orbit/Resources/Localizable.xcstrings
    Scripts/swiftpm.sh run OrbitStrings lint --catalog Orbit/Resources/InfoPlist.xcstrings
    ```

- [ ] **Gated suites.** Run the opt-in suites that cover what changed since the last release (live Ollama, live
  Claude Code, Spotlight integration, UI window tests, UI snapshots); see [testing.md](testing.md#gated-suites).
  The window and snapshot suites take the keyboard focus, and the live Claude Code suite spends subscription quota.
- [ ] **Manual QA.** Run the [manual acceptance checks](manual-qa.md) on a build signed with the development
  certificate, at least for the areas that changed.
- [ ] **Universal build.** `ORBIT_VERSION=… ORBIT_BUILD=… ORBIT_SIGN_IDENTITY="Developer ID Application: …"
  Scripts/build-app.sh release --universal`. Check the summary: the version and build, the bundle ID
  `io.github.eric-volz.Orbit`, both architectures (`x86_64 arm64`), the Developer ID authority with the `runtime` flag,
  `Orbit.entitlements`, both localizations with every string translated (for example "de: 679 of 679 strings
  translated"), the icon, and no notes marked "!". The zip holds only `Orbit.app`; the `Orbit.app.dSYM` next to it
  stays on your Mac for debugging and symbolication.
- [ ] **Notarization.** `ORBIT_NOTARY_PROFILE=orbit-notary Scripts/notarize.sh` ends with "is notarized;
  distributable archive: …/Orbit-<version>.zip".
- [ ] **Smoke test on a clean Mac or a new user account**, from the zip, not from the build folder:
    - Download or copy the zip, unpack it, move `Orbit.app` to `/Applications` and open it: Gatekeeper opens it
      without a warning other than the usual "downloaded from the internet" question.
    - The setup opens; connect a provider, ask a question, run an instant search.
    - Allow one or two permissions and check that macOS shows Orbit's reasons in the interface language.
    - Turn on "Open at login", log out and in.
    - If you can, repeat on an Intel Mac: the `x86_64` slice is cross-compiled and is not exercised on Intel during
      development.
    - Optionally, open the new version while the previous one runs: Orbit asks which copy to keep and shows both
      versions.
- [ ] **Publish.** Tag the release, create it on GitHub Releases with the zip, its checksum and the changelog
  section, and check that the download link works. With the [release workflow](#automated-releases), pushing the
  tag does the universal build, the notarization and this step; run the smoke test with the zip from the release
  page afterwards.

## Permissions and ad hoc builds

macOS ties privacy permissions (Automation, Accessibility, Contacts, Calendars, Reminders, Photos, Full Disk
Access) to the app's code signature. What that means for each kind of build:

- **Ad hoc builds** (the default) get a new signature with every build, so they lose their privacy permissions on
  every rebuild and macOS asks again. For repeated testing, sign with the [development certificate](#the-development-certificate).
- **Development certificate builds** keep their permissions across rebuilds on the Mac that created the
  certificate. They are not meant for other Macs.
- **Developer ID builds** keep a stable designated requirement (bundle identifier and team), so users keep their
  permissions when they update to a newer release signed by the same team.
- **Do not distribute ad hoc or development builds.** They are not notarized, so Gatekeeper blocks them when they
  are downloaded; users would have to allow them in System Settings → Privacy & Security ("Open Anyway"), and every
  new build would lose its permissions again.
- **Launch at login** registers only a copy in `/Applications`; a copy elsewhere shows a note in Settings →
  General instead.
