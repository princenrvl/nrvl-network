# NRVL Network — Progress

Last updated: 2026-11-11

## Current state
**All 12 phases have been worked through.** The app builds, passes 60 automated tests and a launch smoke test, and all 13 sections are functional. Remaining gaps are listed under "Not done" and "Not verified" below — chiefly: nothing has been tried on real router hardware, and the UI has never been seen or clicked by the developer.

## Environment (inspected 2026-11-11)
| Item | Value |
|---|---|
| macOS | 27.2.1 |
| Swift | 6.4.2 |
| Xcode | 27.2 (27B52), selected with `xcode-select` |
| Dependencies | GRDB.swift 7.x (resolved by SwiftPM) |
| Git | Published at https://github.com/princenrvl/nrvl-network (MIT) |

## How to build, test, run
```bash
Scripts/test.sh          # unit tests
Scripts/build-app.sh     # → build/NRVL Network.app (ad-hoc signed)
Scripts/make-icon.sh     # regenerate Resources/AppIcon.{png,icns}
Scripts/update-oui.sh    # refresh the IEEE manufacturer registry
Scripts/package.sh       # universal app + build/NRVL-Network-<version>.dmg
Scripts/smoke-test.sh    # launch the build and check it is healthy
open NRVLNetwork.xcodeproj   # or: xcodebuild -project NRVLNetwork.xcodeproj -scheme "NRVL Network" build
```

## Phase status
| Phase | Status |
|---|---|
| 1 Architecture & setup | **Complete** |
| 2 Shell & design system | **Complete** |
| 3 Discovery & inventory | **Complete** |
| 4 Subnets & topology | **Complete** (UI not visually verified) |
| 5 Integration framework | **Complete** (SNMP unverified on hardware; no SNMP v3) |
| 6 UniFi & OpenWrt | **Implemented, unverified on hardware** |
| 7 Traffic monitoring | **Complete** (per-device traffic has no data source yet) |
| 8 Access control | **Complete** (only OpenWrt can block; unverified on hardware) |
| 9 QoS | **Partial by design**: link shaping via OpenWrt SQM; per-device QoS unsupported on available platforms |
| 10 Security & notifications | **Complete** (no DNS-query analysis) |
| 11 Reports & audit | **Complete** (MikroTik/OPNsense/pfSense adapters deferred) |
| 12 Testing, signing, packaging | **Partial**: tests, universal build, DMG, docs done; no XCUITest, no Developer ID signing/notarisation |

## Completed
### Planning
- Read `PROJECT_SPEC.md`; wrote `ARCHITECTURE.md`, `DEVELOPMENT_PLAN.md`, `TECHNICAL_DECISIONS.md`.

### Phase 1
- Swift package (Swift 6 mode, macOS 14+) with `NRVLCore`, `NRVLPersistence`, app target `NRVLNetwork`, test target.
- `NRVLCore`: provenance types (`Observed<T>`, `DataSource`, `Confidence`, `Freshness`), `Site`, `AuditEntry`.
- `NRVLPersistence`: SQLite database at `~/Library/Application Support/NRVL Network/nrvl.sqlite`, migration v1, append-only hash-chained audit log.
- App: minimal window that opens the real database, records `app.launch` in the audit log and reports chain status. No network features.
- App icon (script-generated), Info.plist, bundle + codesign script.

### Phase 2
- Sidebar shell with all 13 sections (Network / Administration / Operations / System groups).
- Unbuilt sections show what they will display, what they need and which phase delivers them — no sample data anywhere.
- Design system: accent colour, `Badge`, provenance and freshness badges, status dot.
- Go menu (⌘1–⌘9), Settings window (⌘,) and Settings section with real database path, audit entry count and chain status.
- `NRVLNetwork.xcodeproj` building the same sources.

### Phase 3, part 1 — device inventory
- `NRVLCore`: `MACAddress`, `IPv4Subnet`, `NetworkInterface`, `NetworkConfiguration`, `Neighbor`, `DeviceSighting`, `Device`.
- `NRVLDiscovery` (new): interface reader (addresses, MAC, hardware-port names), gateway/DNS reader, ARP + IPv6 neighbour table reader, subnet probe, IEEE manufacturer lookup (39,920 prefixes), reverse DNS.
- `NRVLPersistence`: migration `v2-devices`, `DeviceStore` (upsert that never erases known values, live observation).
- `NRVLServices` (new): `InventoryService` — scan, merge by MAC, background hostname resolution.
- Devices view: sortable table, search, detail inspector with source + Confirmed/Inferred labels, Scan Now (⌘R), automatic rescan every 60 s, rename, trusted mark, copy IP/MAC, Local Network permission banner.
- Review fixes: single-window scene, database busy timeout (TD-27).

### Phase 3, part 2 — names, types, history, telemetry, Overview
- Bonjour browser (system DNS-SD): hostnames, advertised service types and published model identifiers, matched to devices by address.
- Device type from evidence only, with its basis and a Confirmed/Inferred label (TD-29).
- Tags, group, and per-device connection history (discovered / appeared / disappeared).
- `NRVLTelemetry` (new): interface byte counters, unprivileged ICMP ping, rolling latency/jitter/loss.
- Overview: health with reason, internet and gateway latency/jitter/loss, device counts, this Mac's connection and DNS, live throughput chart.
- Migration `v3-identity-and-history`.

### Phase 4 — subnets and topology
- Networks & Subnets: interfaces, routing, DNS, opt-in public IP lookup (api.ipify.org, only on click), IP allocation grid, address-conflict detection (IP whose MAC flips back within 10 min).
- Topology: Internet → gateway → per-subnet device groups marked "attachment unknown"; only evidence-based links.
- An IPv4 address now moves to its new holder instead of staying on the old device.

### Phase 5 — integration framework
- `NRVLAdapters` (new): adapter protocols, capability model, `AdapterError`, SNMP v2c client (BER codec written in Swift, read-only), generic SNMP adapter (ARP table, bridge forwarding table → switch port, networks, 64-bit interface counters), HTTPS transport with certificate pinning.
- Migration `v4-integrations`; `IntegrationStore`; device columns for connection, SSID, uplink, VLAN, blocked.
- `CredentialStore` (Keychain), `IntegrationService` (add/test/remove/trust, polling), integration data layered into every scan; add/remove/trust written to the audit log.
- Integrations section: add sheet, connection test, status, capability table with reasons, certificate-fingerprint approval.
- Not done: SNMP v3, LLDP.
- **Unverified on hardware:** the SNMP adapter has only been run against the simulated agent in the test suite, never a real device.

### Phase 6 — UniFi and OpenWrt
- `UniFiAdapter`: official Integration API, read-only (clients with wired/wireless and uplink, infrastructure devices). Access control/QoS/traffic reported unsupported because the official API has none (TD-40).
- `OpenWrtAdapter`: ubus JSON-RPC; hosts, DHCP names, Wi-Fi associations with SSID, networks, firewall rules; block/unblock through a named firewall rule with the router's own apply-rollback (TD-41).
- Integrations UI: both platforms selectable, infrastructure list; Networks section shows integration-reported networks.
- **Both adapters have only been run against simulated devices in the test suite.**

### Phase 7 — traffic and history
- Telemetry stored once per minute (throughput, latency, loss); 90-day retention.
- SNMP interface throughput history per device interface.
- NetFlow v5 collector (opt-in) with protocol / port / destination / source breakdowns.
- Traffic Analytics section: range and source pickers, throughput and latency/loss charts, per-device usage, flow breakdowns.
- Not done: NetFlow v9/IPFIX, stored flow history, unusual-traffic detection (moved to Phase 10).

### Phase 8 — access control
- `AccessPolicy` (block, pause, weekly schedule; device or group), `AccessControlEngine` (capability check, apply, verify, audit, reconcile), protected targets, Touch ID/password before every change, management toggle per integration.
- Access Control section: integrations and their capability, device list with state, block/pause/unblock with preview, schedules.

### Phase 9 — QoS
- `LinkShaping` on OpenWrt SQM; `QoSEngine` with verified apply, change records and rollback.
- QoS Manager section: queues, change with before/after preview, roll back, live latency/jitter/loss, explicit list of unsupported QoS features.

### Phase 10 — security, alerts, notifications
- 13 alert kinds from edge-triggered rules; thresholds and switches; macOS notifications; alert history with acknowledge.
- Firewall (read-only rules per integration), Security Center (events with evidence, untrusted devices, connection security, what is and is not checked), Monitoring.

### Phase 11 — reports, exports, audit
- Period reports with coverage, PDF export, five CSV datasets, audit-log viewer with chain status, encrypted configuration snapshots.

### Phase 12 — packaging and documentation
- Universal app, DMG, smoke test; `INSTALL.md`, `SECURITY.md`.

### Not done
- MikroTik, OPNsense, pfSense adapters; SNMP v3; LLDP; NetFlow v9/IPFIX; XCUITest; Developer ID signing and notarisation; multi-site UI; quarantine; per-device QoS; DNS-query analysis; automated configuration restore. Reasons: TD-50.

## Test results
| Date | What | Result |
|---|---|---|
| 2026-11-11 | `Scripts/test.sh` — 4 unit tests (migration, chain intact, UPDATE/DELETE rejected, tamper detected) | 4/4 pass |
| 2026-11-11 | `swift build` debug + release, Swift 6 strict concurrency | Clean (only linker "search path not found" warnings from the Command Line Tools install) |
| 2026-11-11 | `codesign --verify --strict` on the bundle | Pass (ad-hoc, hardened runtime) |
| 2026-11-11 | Launch `build/NRVL Network.app` | Process runs; database created; `app.launch` row written with 64-char hash; external `sqlite3` `DELETE FROM audit_log` rejected ("audit_log is append-only") |
| 2026-11-11 | Under Xcode 27.2: plain `swift test` | 4/4 pass |
| 2026-11-11 | `xcodebuild -project NRVLNetwork.xcodeproj -scheme "NRVL Network" build` | BUILD SUCCEEDED; bundle has executable, Info.plist, icon; `codesign --verify --strict` passes |
| 2026-11-11 | Launch script-built Phase 2 app | Process runs; one 900×592 window on screen |
| 2026-11-11 | `swift test` after Phase 3 part 1 — 12 tests (adds MAC/subnet maths, neighbour-table parser incl. truncated input, manufacturer lookup, merge, device upsert) | 12/12 pass |
| 2026-11-11 | Script build + `xcodebuild` with the two new modules and `oui.tsv` | Both succeed |
| 2026-11-11 | Live scan on the development network (two interfaces) | 8 devices stored: 6 neighbours + this Mac's 2 ports. Set of neighbour MACs is identical to `arp -an` + `ndp -an` (0 missing, 0 extra). AirDrop interfaces correctly excluded. |
| 2026-11-11 | `swift test` after Phase 3 part 2 — 22 tests (adds Bonjour attach, presence debounce, classifier, events, tags, ICMP checksum/packet, ping statistics, throughput rate, live loopback ping, live counters) | 22/22 pass |
| 2026-11-11 | Script build + `xcodebuild` with `NRVLTelemetry` | Both succeed |
| 2026-11-11 | Live run, two scan cycles (80 s) | 11 devices; 8 named (6 by Bonjour, 2 are this Mac's ports); 6 with advertised services; 2 report a model; `discovered` events backfilled for all 11, 1 `appeared`. App idle at ~0 % CPU, 155 MB. No errors in the unified log. |
| 2026-11-11 | `swift test` after Phases 4–5 — 36 tests (adds conflict detector, address hand-over, BER vectors/round-trip/malformed input, SNMP walk and adapter against a simulated agent, wrong community/dead host, TLS policy, Keychain, integration layering and storage) | 36/36 pass |
| 2026-11-11 | Phase 4 script build + launch | Launches, no crash; UI not seen |

| 2026-11-11 | Phase 5 script build, `xcodebuild`, launch | Both builds succeed; app launches; migrations v1–v4 applied to the real database |
| 2026-11-11 | `swift test` after Phases 6–7 — 46 tests (adds UniFi pagination/mapping/failures, host-pinning refusal, OpenWrt read path, block/unblock round trip, expired session, read-only account, metric bucketing and pruning, per-device sums, NetFlow parsing, live collector on loopback) | 46/46 pass |
| 2026-11-11 | Phase 7 script build, `xcodebuild`, 75 s live run | Both builds succeed; one minute of history stored: gateway 0.8 ms / 0 % loss, internet 9.5 ms / 0 % loss, this Mac ≈2.8 kB/s down. In-app ICMP ping to gateway and internet now confirmed. |
| 2026-11-11 | `swift test`, final — 60 tests in 4 targets (adds access engine, schedules, QoS engine and rollback, OpenWrt SQM, alert rules, alert storage, report builder, CSV injection, encrypted backups) | 60/60 pass |
| 2026-11-11 | `xcodebuild` Debug, final sources | BUILD SUCCEEDED |
| 2026-11-11 | `Scripts/package.sh` | Universal app (x86_64 arm64), GRDB resource bundle included, DMG 7.4 MB, `hdiutil verify` passes |
| 2026-11-11 | `Scripts/smoke-test.sh` on the universal build | 5/5 checks: running, 8 of 8 migrations, launch audited, scan stored 14 devices, no crash report |

Bugs the tests caught during development: a lone newline in a CSV cell was not quoted (Swift treats CR-LF as one character); an IPv4 address stayed on its previous holder after being reassigned.

Not verified (Phases 8–12): no screen of the app has been seen or operated — layout, sheets, menus, charts, PDF rendering, save panels, the Touch ID prompt and notifications are untested by hand. Block/unblock, shaping and backups have run only against simulated routers. The Intel slice builds but was not run. Alerts were not observed firing live (the network stayed healthy).

Not verified (Phases 6–7): UniFi and OpenWrt against real hardware; Traffic Analytics screen not seen; NetFlow from a real exporter; SNMP interface history (needs a real SNMP device).

Not verified (Phases 4–5): Networks, Topology and Integrations screens not seen or driven. `PinnedHTTP` has no automated test against a live TLS server (only its decision rule is tested).

Not verified (Phase 3 part 2): the Overview cards, throughput chart and the new Devices columns/menus were not seen or driven. Live ping to the gateway and to 1.1.1.1 from inside the app was not observed (only the loopback ping in tests) — the Overview shows "No reply" if either is blocked. `disappeared` events were not observed live (needs a device to leave for three minutes).

Not verified (Phase 3 part 1): the Devices table, inspector, search, rename and trust UI were not seen or driven (same screen-access limit). Whether the Local Network prompt appeared and whether the active probe was allowed is unknown — the status line under the table reports it. Reverse DNS returned no names on this network (the router does not serve them); the code path is exercised but no positive result was observed.

Not verified (Phase 2): the shell's on-screen appearance, sidebar navigation, ⌘1–⌘9 and the Settings window were not exercised — screen capture and UI scripting are blocked by macOS privacy permissions for this session. No automated UI test covers them yet.

Not verified (Phase 1): the window's on-screen appearance and the icon as rendered in the Dock/Finder (checked by process, database and the source PNG only).

## Pending (next) — in suggested order
1. **Look at the app.** Click through all 13 sections; report anything that looks wrong.
2. **Try an integration on real hardware**, read-only first, then the OpenWrt write actions on a non-critical router.
3. Supply a Developer ID to sign and notarise.
4. Decide which deferred items (TD-50) matter.

## Open questions for the user
1. Which router/switch/AP hardware is available for real testing? (needed by Phase 5–6)
2. Apple Developer Program membership for Developer ID signing? (Phase 12)
3. iOS in scope? Assumed no (TD-15).

## Known issues / risks
- No UI tests yet; the shell has only been compiled and launched, not driven.
- The script-built app does not copy GRDB's resource bundle (privacy manifest only; the Xcode build does). Needed before distribution, not for running.
- Audit chain does not detect truncation of the newest rows or whole-file replacement (`shortcut:` comment in `AuditLog.swift`, TD-12).
- Adapter API details not yet verified against current vendor documentation.
- App Sandbox compatibility of ARP/NDP reads unverified (TD-5).
- Local Network permission outcome for the ad-hoc-signed app not observed; each rebuild changes the ad-hoc signature, so macOS may ask again after a rebuild.
- A Mac with two active ports on the same network appears as two "This Mac" rows (one per MAC address).
- Devices that neither advertise over Bonjour nor have a reverse-DNS name stay unnamed (shown as "<manufacturer> device", Inferred) until a router integration supplies DHCP names.
- Telemetry history is in memory only (TD-31); the internet check target is fixed at 1.1.1.1.
- Memory use is ~155 MB, mostly the manufacturer registry held as a dictionary; acceptable now, cheap to shrink later.
- `shortcut:` limits in code: one IPv4 per interface and per MAC, MA-L registry only, no active probe above /22, Bonjour caches never expire during a run.
