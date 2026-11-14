#!/bin/bash
# Builds "build/NRVL Network.app" (Apple silicon + Intel) from the Swift package and code-signs it.
# Signs ad-hoc unless SIGN_IDENTITY is set, e.g. SIGN_IDENTITY="Developer ID Application: Name (TEAMID)".
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
products="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

app="build/NRVL Network.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/NRVLNetwork" "$app/Contents/MacOS/NRVLNetwork"
# Debug symbols embed the builder's absolute source paths (user name, folders); remove them from what is shipped.
strip -Sx "$app/Contents/MacOS/NRVLNetwork"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/oui.tsv "$app/Contents/Resources/"
# Resource bundles of dependencies (GRDB's privacy manifest).
find "$products" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$app/Contents/Resources/" \;

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
    codesign --force --options runtime --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built $app ($(lipo -archs "$app/Contents/MacOS/NRVLNetwork"))"
