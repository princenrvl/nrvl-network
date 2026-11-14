#!/bin/bash
# Launches the built app, lets it run one scan cycle, and checks it is alive, migrated and not crashing.
# Usage: Scripts/smoke-test.sh [seconds, default 20]. Quits the app when done.
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/NRVL Network.app"
binary="NRVL Network.app/Contents/MacOS/NRVLNetwork"
db="$HOME/Library/Application Support/NRVL Network/nrvl.sqlite"
[[ -d "$app" ]] || { echo "FAIL: build the app first (Scripts/build-app.sh)"; exit 1; }

before="$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ci nrvl || true)"
pkill -f "$binary" 2>/dev/null || true
open "$app"
sleep "${1:-20}"

fail=0
pgrep -f "$binary" >/dev/null && echo "ok   app is running" || { echo "FAIL app is not running"; fail=1; }
expected="$(grep -c 'registerMigration(' Sources/NRVLPersistence/AppDatabase.swift)"
applied="$(sqlite3 "$db" 'SELECT COUNT(*) FROM grdb_migrations' 2>/dev/null || echo 0)"
[[ "$applied" == "$expected" ]] && echo "ok   $applied of $expected migrations applied" || { echo "FAIL $applied of $expected migrations applied"; fail=1; }
launches="$(sqlite3 "$db" "SELECT COUNT(*) FROM audit_log WHERE action = 'app.launch'" 2>/dev/null || echo 0)"
[[ "$launches" -ge 1 ]] && echo "ok   launch recorded in the audit log" || { echo "FAIL no launch in the audit log"; fail=1; }
this_mac="$(sqlite3 "$db" 'SELECT COUNT(*) FROM device WHERE is_this_mac = 1' 2>/dev/null || echo 0)"
[[ "$this_mac" -ge 1 ]] && echo "ok   a scan stored this Mac ($(sqlite3 "$db" 'SELECT COUNT(*) FROM device') devices known)" || { echo "FAIL no scan result stored"; fail=1; }
after="$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ci nrvl || true)"
[[ "$after" == "$before" ]] && echo "ok   no new crash report" || { echo "FAIL new crash report in ~/Library/Logs/DiagnosticReports"; fail=1; }

pkill -f "$binary" 2>/dev/null || true
exit $fail
