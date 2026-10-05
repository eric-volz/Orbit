#!/bin/bash
# Notarizes and staples a Developer ID signed Orbit.app, then checks it with
# Gatekeeper and writes a distributable zip next to it.
#
# Usage: Scripts/notarize.sh [path/to/Orbit.app]      (default: build/release/Orbit.app)
#
# Prerequisites:
#   1. A "Developer ID Application" certificate in the login keychain, and the app
#      built with it:
#        ORBIT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#          Scripts/build-app.sh release --universal
#   2. Notary credentials stored once in the keychain (app-specific password from
#      appleid.apple.com, or an App Store Connect API key):
#        xcrun notarytool store-credentials orbit-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#      and ORBIT_NOTARY_PROFILE=orbit-notary in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/release/Orbit.app}"
PROFILE="${ORBIT_NOTARY_PROFILE:-}"

step() { echo "▸ $*"; }
die() { echo "error: $*" >&2; exit 1; }

[[ -d "$APP" ]] || die "$APP not found. Build it first: Scripts/build-app.sh release"
[[ -n "$PROFILE" ]] || die "ORBIT_NOTARY_PROFILE is not set (see the comment at the top of $0)"
xcrun --find notarytool > /dev/null 2>&1 || die "notarytool not found (it ships with the Command Line Tools or Xcode 13+)"

# Notarization only accepts Developer ID signatures with the Hardened Runtime
# and a secure timestamp.
if ! security find-identity -v -p codesigning | grep -q '"Developer ID Application: '; then
    die "no Developer ID Application identity in the keychain. Create one at developer.apple.com (Certificates → Developer ID Application) and install it."
fi
# Orbit supports Intel Macs too: never publish a thin build by accident.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Orbit" 2>/dev/null)" || die "cannot read the architectures of $APP"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] \
    || die "$(basename "$APP") is not universal ($ARCHS). Build it with: Scripts/build-app.sh release --universal"

SIGNATURE="$(codesign --display --verbose=2 "$APP" 2>&1)" || die "$APP is not signed"
AUTHORITY="$(echo "$SIGNATURE" | sed -n 's/^Authority=//p' | head -1)"
[[ "$AUTHORITY" == "Developer ID Application: "* ]] \
    || die "$(basename "$APP") is signed by '${AUTHORITY:-ad hoc}', not a Developer ID Application identity. Rebuild with ORBIT_SIGN_IDENTITY=\"Developer ID Application: …\" Scripts/build-app.sh release"
echo "$SIGNATURE" | grep -q 'flags=.*runtime' || die "the signature lacks the Hardened Runtime (codesign --options runtime)"
echo "$SIGNATURE" | grep -q '^Timestamp=' || die "the signature has no secure timestamp (codesign --timestamp)"
codesign --verify --strict --deep "$APP" || die "the signature is not valid"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/Orbit.zip"

step "Uploading $(basename "$APP") ($AUTHORITY)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait --timeout 30m \
    --output-format json > "$WORK/result.json" || true
STATUS="$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)"
SUBMISSION="$(plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || echo "")"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization status: $STATUS" >&2
    cat "$WORK/result.json" >&2 || true
    if [[ -n "$SUBMISSION" ]]; then
        echo "Log:" >&2
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
    fi
    die "notarization failed"
fi
echo "  accepted (submission $SUBMISSION)"

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Checking with Gatekeeper"
spctl --assess --type execute -vv "$APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DIST="$(dirname "$APP")/Orbit-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST"
echo "✓ $APP is notarized; distributable archive: $DIST"
