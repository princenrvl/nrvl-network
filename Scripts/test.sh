#!/bin/bash
# Runs the test suite. With Command Line Tools only (no Xcode), SwiftPM does not find the
# Swift Testing macro plugin on its own, so point the compiler at it. Plain `swift test` works under Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$plugins" ]]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
