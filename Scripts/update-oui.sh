#!/bin/bash
# Downloads the public IEEE MA-L (OUI) registry and compacts it to Resources/oui.tsv ("AABBCC<TAB>Vendor").
set -euo pipefail
cd "$(dirname "$0")/.."

csv="$(mktemp)"
trap 'rm -f "$csv"' EXIT
curl --fail --silent --show-error --location -A "oui-updater" -o "$csv" https://standards-oui.ieee.org/oui/oui.csv

python3 -I - "$csv" Resources/oui.tsv <<'EOF'
import csv, sys
rows = {}
with open(sys.argv[1], newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        prefix, name = row["Assignment"].strip().upper(), " ".join(row["Organization Name"].split())
        # "IEEE Registration Authority" marks blocks subdivided into MA-M/MA-S; the owner is not known from this file.
        if len(prefix) == 6 and name and name not in ("IEEE Registration Authority", "Private"):
            rows[prefix] = name
if len(rows) < 20000:
    sys.exit(f"refusing to write: only {len(rows)} entries parsed")
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for prefix in sorted(rows):
        out.write(f"{prefix}\t{rows[prefix]}\n")
print(f"Wrote {len(rows)} entries to {sys.argv[2]}")
EOF
