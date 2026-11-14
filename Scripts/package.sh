#!/bin/bash
# Builds the app and wraps it in a disk image: build/NRVL-Network-<version>.dmg
# For a distributable build, set SIGN_IDENTITY to a Developer ID Application identity, then notarise:
#   xcrun notarytool submit build/NRVL-Network-<version>.dmg --keychain-profile <profile> --wait
#   xcrun stapler staple build/NRVL-Network-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
dmg="build/NRVL-Network-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "build/NRVL Network.app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "NRVL Network" -srcfolder "$staging" -format UDZO "$dmg"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"; fi
echo "Packaged $dmg"
[[ -n "${SIGN_IDENTITY:-}" ]] || echo "Ad-hoc signed: runs on this Mac; other Macs will refuse it until it is signed with a Developer ID and notarised."
