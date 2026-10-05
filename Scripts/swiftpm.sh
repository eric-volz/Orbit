#!/bin/bash
# Runs `swift <command>` for this package, applying workarounds that are needed
# when only the Command Line Tools (no Xcode) are installed:
#
#  1. Stale PackageDescription interfaces: some CLT installs keep a 2024
#     `*.private.swiftinterface` next to a newer libPackageDescription.dylib, so
#     every Package.swift fails to link. We use a private copy without the stale
#     files via SWIFTPM_CUSTOM_LIBS_DIR.
#  2. `#Preview` blocks in dependencies need Xcode's PreviewsMacros plugin. We load
#     a no-op stand-in plugin (Scripts/toolchain/PreviewsMacrosStub.swift) at
#     compile time. Nothing of it ends up in the app.
#  3. Swift Testing ships in the CLT but outside the default search paths.
#
# With Xcode selected (xcode-select -p), no workaround is applied.
#
# Usage: Scripts/swiftpm.sh build [args]   Scripts/swiftpm.sh test [args]
#        Scripts/swiftpm.sh run <product> [args]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMMAND="${1:-build}"
shift || true

FIXES="${ORBIT_TOOLCHAIN_FIXES:-$ROOT/.build/toolchain-fixes}"
DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
EXTRA=()

if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
    CLT="$DEVELOPER_DIR_PATH"
    PM="$CLT/usr/lib/swift/pm"

    # 1. Stale PackageDescription interfaces.
    if grep -qs "public enum SwiftVersion" "$PM"/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface; then
        if [[ ! -d "$FIXES/pm/ManifestAPI" ]]; then
            mkdir -p "$FIXES/pm"
            cp -R "$PM/ManifestAPI" "$PM/PluginAPI" "$FIXES/pm/"
            find "$FIXES/pm" -name '*.private.swiftinterface' -delete
        fi
        export SWIFTPM_CUSTOM_LIBS_DIR="$FIXES/pm"
    fi

    # 2. PreviewsMacros stand-in.
    STUB_SOURCE="$ROOT/Scripts/toolchain/PreviewsMacrosStub.swift"
    STUB="$FIXES/PreviewsMacrosStub"
    if [[ ! -x "$STUB" || "$STUB_SOURCE" -nt "$STUB" ]]; then
        mkdir -p "$FIXES"
        swiftc -O "$STUB_SOURCE" -o "$STUB"
    fi
    EXTRA+=(-Xswiftc -Xfrontend -Xswiftc -load-plugin-executable
            -Xswiftc -Xfrontend -Xswiftc "$STUB#PreviewsMacros")

    # 3. Swift Testing (tests only; keeps CLT paths out of the app binary).
    if [[ "$COMMAND" == "test" ]]; then
        FRAMEWORKS="$CLT/Library/Developer/Frameworks"
        LIBS="$CLT/Library/Developer/usr/lib"
        if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
            EXTRA+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS"
                    -Xlinker -rpath -Xlinker "$FRAMEWORKS"
                    -Xlinker -rpath -Xlinker "$LIBS")
        fi
    fi
fi

if [[ "$COMMAND" == "run" ]]; then
    # `swift run <product> -- args`: build flags must precede the product name.
    exec swift run ${EXTRA[@]+"${EXTRA[@]}"} "$@"
fi
exec swift "$COMMAND" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
