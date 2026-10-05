#!/bin/bash
# Assembles, localizes and signs Orbit.app.
#
# Usage: Scripts/build-app.sh [debug|release] [--universal]
# Output: build/<config>/Orbit.app
#
#   --universal   build arm64 and x86_64 separately (--triple <arch>-apple-macosx14.0)
#                 and merge them with lipo; meant for release builds. If the x86_64
#                 build fails, the script stops (ORBIT_ALLOW_ARM64_ONLY=1 builds for
#                 arm64 only instead, and the summary says why).
#
# Environment:
#   ORBIT_SIGN_IDENTITY  codesign identity; default "-" (ad hoc). Use
#                        "Developer ID Application: Name (TEAMID)" for distribution
#                        (then run Scripts/notarize.sh), or "Orbit Development"
#                        (Scripts/create-dev-cert.sh) so macOS keeps privacy
#                        permissions across rebuilds.
#   ORBIT_BUNDLE_ID      bundle identifier (default io.github.eric-volz.Orbit)
#   ORBIT_VERSION        CFBundleShortVersionString (default 0.1.0)
#   ORBIT_BUILD          CFBundleVersion (default 1)
#   ORBIT_ALLOW_ARM64_ONLY=1  with --universal: continue without the x86_64 slice
#   ORBIT_TIMESTAMP      1/0: force/skip a secure timestamp (default: only for
#                        Developer ID / Apple Development identities)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() { echo "usage: $0 [debug|release] [--universal]" >&2; }
step() { echo "▸ $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

CONFIG=debug
UNIVERSAL=0
for argument in "$@"; do
    case "$argument" in
        debug|release) CONFIG="$argument" ;;
        --universal) UNIVERSAL=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 64 ;;
    esac
done

BUNDLE_ID="${ORBIT_BUNDLE_ID:-io.github.eric-volz.Orbit}"
VERSION="${ORBIT_VERSION:-0.1.0}"
BUILD_NUMBER="${ORBIT_BUILD:-1}"
IDENTITY="${ORBIT_SIGN_IDENTITY:--}"
SWIFTPM="$ROOT/Scripts/swiftpm.sh"
DEPLOYMENT_TARGET="14.0"

APP="$ROOT/build/$CONFIG/Orbit.app"
WORK="$ROOT/build/$CONFIG/.work"
rm -rf "$WORK"
mkdir -p "$WORK"
NOTES=()

# ── 1. Compile ───────────────────────────────────────────────────────────────
BINARIES=()
BIN_DIR=""
if [[ $UNIVERSAL == 1 ]]; then
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx$DEPLOYMENT_TARGET"
        step "Building Orbit ($CONFIG, $triple)"
        log="$WORK/build-$arch.log"
        if "$SWIFTPM" build -c "$CONFIG" --product Orbit --triple "$triple" 2>&1 | tee "$log"; then
            slice_dir="$("$SWIFTPM" build -c "$CONFIG" --triple "$triple" --show-bin-path)"
            BINARIES+=("$slice_dir/Orbit")
            [[ -n "$BIN_DIR" ]] || BIN_DIR="$slice_dir"
        elif [[ $arch == x86_64 && "${ORBIT_ALLOW_ARM64_ONLY:-}" == 1 ]]; then
            reason="$(grep -m1 -E 'error:' "$log" || tail -n 1 "$log")"
            warn "the x86_64 build failed, continuing with arm64 only (ORBIT_ALLOW_ARM64_ONLY=1): $reason"
            NOTES+=("x86_64 slice missing: cross-compiling failed: $reason (log: $log)")
        elif [[ $arch == x86_64 ]]; then
            reason="$(grep -m1 -E 'error:' "$log" || tail -n 1 "$log")"
            die "the x86_64 build failed: $reason (log: $log). Set ORBIT_ALLOW_ARM64_ONLY=1 to build for Apple silicon only."
        else
            die "the arm64 build failed (log: $log)"
        fi
    done
else
    step "Building Orbit ($CONFIG)"
    "$SWIFTPM" build -c "$CONFIG" --product Orbit
    BIN_DIR="$("$SWIFTPM" build -c "$CONFIG" --show-bin-path)"
    BINARIES+=("$BIN_DIR/Orbit")
fi

# SwiftPM without Xcode looks up a dependency's resource bundle next to the app
# (Orbit.app/<Package>_<Target>.bundle, where code signing allows no files) or at
# its absolute path in .build (which exists only on the build machine). So the
# bundle goes into Contents/Resources under a name of the same length, and the
# path literal in the executable is rewritten to point there, before signing.
# Only KeyboardShortcuts reads its bundle (recorder texts); GRDB's contains just
# a privacy manifest and is never loaded.
PATCHED_BUNDLE="KeyboardShortcuts_KeyboardShortcuts"
PATCHED_TARGET="Contents/Resources/KeyboardShortcut.bundle"
KNOWN_BUNDLES=" $PATCHED_BUNDLE GRDB_GRDB "
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] || continue
    name="$(basename "$bundle" .bundle)"
    [[ "$KNOWN_BUNDLES" == *" $name "* ]] || die "unknown SwiftPM resource bundle $name.bundle: teach Scripts/build-app.sh how to ship it"
done

patch_bundle_lookup() { # <executable>
    local from="$PATCHED_BUNDLE.bundle"
    (( ${#from} == ${#PATCHED_TARGET} )) || die "internal: replacement path must be ${#from} bytes long"
    # The literal is a NUL-terminated C string; the absolute build path that ends
    # with the same name is left to strip_build_paths. Exactly one match is expected.
    perl -0777 -i -pe 'BEGIN { ($from, $to) = splice(@ARGV, 0, 2) } $n = s/\x00\Q$from\E\x00/\x00$to\x00/g; END { $? = ($n == 1 ? 0 : 3) }' \
        "$from" "$PATCHED_TARGET" "$1" \
        || die "could not find the $PATCHED_BUNDLE resource lookup in $(basename "$1") (SwiftPM changed its accessor?)"
}

HAS_PATCHED_BUNDLE=0
[[ -d "$BIN_DIR/$PATCHED_BUNDLE.bundle" ]] && HAS_PATCHED_BUNDLE=1

EXECUTABLE="$WORK/Orbit"
slices=()
for binary in "${BINARIES[@]}"; do
    slice="$WORK/Orbit-$(lipo -archs "$binary")"
    cp "$binary" "$slice"
    (( HAS_PATCHED_BUNDLE )) && patch_bundle_lookup "$slice"
    slices+=("$slice")
done
if (( ${#slices[@]} > 1 )); then
    step "Merging ${#slices[@]} slices with lipo"
    lipo -create -output "$EXECUTABLE" "${slices[@]}"
    archs="$(lipo -archs "$EXECUTABLE")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || die "lipo produced '$archs', expected arm64 and x86_64"
else
    mv "${slices[0]}" "$EXECUTABLE"
fi

# Paths of the build machine end up in the executable: the debug map names every
# source and object file, and literals hold the resource bundles' build paths and
# dependencies' #file paths. They would publish the builder's user name. So the
# debug information moves into a dSYM next to the app (local only, debuggers find
# it there), the executable loses its debug symbols, and every remaining absolute
# path below the package is overwritten with slashes of the same length
# ("/Users/x/Orbit/.build/..." becomes "//////////////.build/...", which exists
# nowhere). All before signing.
DSYM="$ROOT/build/$CONFIG/Orbit.app.dSYM"
strip_build_paths() { # <executable>
    rm -rf "$DSYM"
    xcrun dsymutil "$1" -o "$DSYM" 2> "$WORK/dsymutil.log" \
        || { cat "$WORK/dsymutil.log" >&2; die "dsymutil failed"; }
    [[ -s "$WORK/dsymutil.log" ]] && NOTES+=("dsymutil reported warnings (log: $WORK/dsymutil.log)")
    strip -S "$1" 2> "$WORK/strip.log" || { cat "$WORK/strip.log" >&2; die "strip failed"; }
    perl -0777 -i -pe 'BEGIN { $root = shift @ARGV } s{\x00\Q$root\E(?=/)}{"\x00" . ("/" x length $root)}ge' "$ROOT" "$1"
    local leak
    for leak in "$ROOT/" ${HOME:+"$HOME/"}; do
        [[ "$leak" == "//" ]] && continue
        LC_ALL=C grep -qaF -- "$leak" "$1" \
            && die "$(basename "$1") still contains \"$leak\": $(LC_ALL=C grep -aoF -- "$leak" "$1" | wc -l | xargs) times (teach strip_build_paths where it comes from)"
    done
    return 0
}
step "Removing build paths (debug information goes to $(basename "$DSYM"))"
strip_build_paths "$EXECUTABLE"

# ── 2. Assemble ──────────────────────────────────────────────────────────────
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/Orbit"

# Info.plist with build settings substituted.
sed -e "s|\$(ORBIT_BUNDLE_ID)|$BUNDLE_ID|g" \
    -e "s|\$(ORBIT_VERSION)|$VERSION|g" \
    -e "s|\$(ORBIT_BUILD)|$BUILD_NUMBER|g" \
    "$ROOT/Config/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
if grep -q '\$(' "$APP/Contents/Info.plist"; then
    die "Info.plist still contains unsubstituted variables: $(grep -o '\$([A-Z_]*)' "$APP/Contents/Info.plist" | sort -u | tr '\n' ' ')"
fi
LANGUAGES="$(plutil -extract CFBundleLocalizations json -o - "$APP/Contents/Info.plist" | tr -d '[]"' | tr ',' ' ')"

# Localization: lint the catalogs, then compile them to <lang>.lproj/*.strings.
step "Localizing ($LANGUAGES)"
"$SWIFTPM" build --product OrbitStrings > "$WORK/orbitstrings-build.log" 2>&1 \
    || { cat "$WORK/orbitstrings-build.log" >&2; die "building OrbitStrings failed"; }
ORBIT_STRINGS="$("$SWIFTPM" build --show-bin-path)/OrbitStrings"
for catalog in Localizable InfoPlist; do
    [[ -f "$ROOT/Orbit/Resources/$catalog.xcstrings" ]] || die "Orbit/Resources/$catalog.xcstrings is missing"
done
"$ORBIT_STRINGS" lint --sources Orbit --catalog Orbit/Resources/Localizable.xcstrings \
    || die "localization lint failed (see errors above)"
"$ORBIT_STRINGS" lint --catalog Orbit/Resources/InfoPlist.xcstrings || die "InfoPlist.xcstrings lint failed"
language_list="$(echo "$LANGUAGES" | xargs | tr ' ' ',')"
for catalog in Localizable InfoPlist; do
    "$ORBIT_STRINGS" compile --catalog "Orbit/Resources/$catalog.xcstrings" --output "$APP/Contents/Resources" \
        --table "$catalog" --languages "$language_list" > /dev/null
done
plutil -lint -s "$APP"/Contents/Resources/*.lproj/*.strings

# Resources.
# AppleScripts ship as source (osascript runs them from there; a compiled .scpt
# would try to save its state back into the signed bundle). Each one is
# syntax-checked with osacompile first, but only when every app it targets
# ships a scripting dictionary (.sdef), because compiling a script for an app
# without one launches that app to ask for its terminology.
app_has_sdef() { # <app name>
    local name="$1" bundle
    # Finder and System Events live in CoreServices.
    for bundle in "/System/Applications/$name.app" "/Applications/$name.app" "/System/Library/CoreServices/$name.app"; do
        compgen -G "$bundle/Contents/Resources/*.sdef" > /dev/null && return 0
    done
    return 1
}
if compgen -G "$ROOT/Orbit/Resources/AppleScripts/*.applescript" > /dev/null; then
    step "Checking AppleScripts"
    mkdir -p "$APP/Contents/Resources/AppleScripts"
    for script in "$ROOT"/Orbit/Resources/AppleScripts/*.applescript; do
        name="$(basename "$script")"
        checkable=1
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue
            if ! app_has_sdef "$target"; then
                warn "$name targets \"$target\", which has no scripting dictionary here, so it was not compiled (syntax unchecked)"
                checkable=0
            fi
        done < <(grep -o 'application "[^"]*"' "$script" | sed 's/^application "//; s/"$//' | sort -u)
        if (( checkable )); then
            osacompile -o "$WORK/${name%.applescript}.scpt" "$script" 2> "$WORK/osacompile.log" \
                || die "$name does not compile: $(cat "$WORK/osacompile.log")"
        fi
        install -m 0644 "$script" "$APP/Contents/Resources/AppleScripts/$name"
    done
fi
if [[ -f "$ROOT/Orbit/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Orbit/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    warn "Orbit/Resources/AppIcon.icns is missing (swift Scripts/make-icon.swift creates it)"
fi
# KeyboardShortcuts' texts, limited to the app's languages so the recorder
# matches the rest of the UI.
if (( HAS_PATCHED_BUNDLE )); then
    BUNDLE_COPY="$APP/$PATCHED_TARGET"
    mkdir -p "$BUNDLE_COPY"
    cp "$BIN_DIR/$PATCHED_BUNDLE.bundle/Info.plist" "$BUNDLE_COPY/"
    for language in $LANGUAGES; do
        if [[ -d "$BIN_DIR/$PATCHED_BUNDLE.bundle/$language.lproj" ]]; then
            cp -R "$BIN_DIR/$PATCHED_BUNDLE.bundle/$language.lproj" "$BUNDLE_COPY/"
        fi
    done
fi

# ── 3. Sign ──────────────────────────────────────────────────────────────────
# Hardened Runtime; debug builds may additionally be attached to by a debugger.
if [[ "$CONFIG" == "debug" ]]; then
    ENTITLEMENTS="$ROOT/Config/Orbit-Debug.entitlements"
else
    ENTITLEMENTS="$ROOT/Config/Orbit.entitlements"
fi
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
case "${ORBIT_TIMESTAMP:-auto}" in
    1) SIGN_ARGS+=(--timestamp) ;;
    0) SIGN_ARGS+=(--timestamp=none) ;;
    *) if [[ "$IDENTITY" == "Developer ID Application"* || "$IDENTITY" == "Apple Development"* ]]; then
           SIGN_ARGS+=(--timestamp)
       else
           SIGN_ARGS+=(--timestamp=none)
       fi ;;
esac
step "Signing (${IDENTITY/#-/ad hoc})"
codesign "${SIGN_ARGS[@]}" "$APP"

step "Verifying"
codesign --verify --strict --deep --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    # Before notarization Gatekeeper reports "Unnotarized Developer ID"; notarize.sh
    # repeats this check after stapling.
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true
fi

# ── 4. Summary ───────────────────────────────────────────────────────────────
SIGNATURE="$(codesign --display --verbose=2 "$APP" 2>&1)"
authority="$(echo "$SIGNATURE" | sed -n 's/^Authority=//p' | head -1)"
flags="$(echo "$SIGNATURE" | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
lproj="$(cd "$APP/Contents/Resources" && ls -d ./*.lproj | sed 's|^\./||' | xargs)"
strings_count="$(grep -c '^"' "$APP/Contents/Resources/de.lproj/Localizable.strings" || true)"
keys_count="$(grep -c '^"' "$APP/Contents/Resources/en.lproj/Localizable.strings" || true)"
echo
echo "✓ $APP"
printf '  %-14s %s\n' \
    "Version" "$VERSION ($BUILD_NUMBER), $CONFIG" \
    "Bundle ID" "$BUNDLE_ID" \
    "Architectures" "$(lipo -archs "$APP/Contents/MacOS/Orbit")" \
    "Minimum macOS" "$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")" \
    "Signature" "${authority:-ad hoc}, flags $flags" \
    "Entitlements" "$(basename "$ENTITLEMENTS")" \
    "Localizations" "$lproj (de: $strings_count of $keys_count strings translated)" \
    "Icon" "$([[ -f "$APP/Contents/Resources/AppIcon.icns" ]] && echo AppIcon.icns || echo missing)" \
    "Size" "$(du -sh "$APP" | cut -f1 | xargs)" \
    "Debug symbols" "build/$CONFIG/$(basename "$DSYM") (not shipped)"
for note in ${NOTES[@]+"${NOTES[@]}"}; do
    echo "  ! $note"
done
# Keep the intermediate files (build logs) only when something needs a look.
(( ${#NOTES[@]} )) || rm -rf "$WORK"
