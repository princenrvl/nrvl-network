# NRVL Network — Development Plan

Phases follow [PROJECT_SPEC.md](PROJECT_SPEC.md) §9 exactly. Each phase ends with: builds clean under Swift 6 strict concurrency, tests pass, `PROGRESS.md` updated, decisions logged. A phase is not "done" while any deliverable is a placeholder.

"Needs" = external dependency that must exist to complete/verify the phase.

## Milestones

| | After phase | What works |
|---|---|---|
| M0 — Skeleton | 2 | Signed `.app` launches; 13-section shell; every section states honestly what it needs; database + audit log exist |
| **M1 — First working milestone** | 3 | **Real inventory of this network with no router integration**: interfaces, gateway, internet status, latency/loss, this Mac's throughput, devices (IP, MAC, vendor, hostname, mDNS services, first/last seen, online state) persisted and live-updating |
| M2 — Visibility | 4 | Subnet/IP-allocation view, evidence-based topology |
| M3 — Managed network | 6 | Live UniFi and/or OpenWrt integration: clients, VLANs, per-device traffic, connection type |
| M4 — Administration | 9 | Block/unblock, schedules, QoS with preview + rollback on capable hardware |
| M5 — Release | 12 | Alerts, reports, exports, docs, signed build |

## Phases

### Phase 1 — Architecture and project setup ✅
- `Package.swift` with `NRVLCore`, `NRVLPersistence`, the app target and a test target; Swift 6 mode. Remaining targets are added by the phase that first needs them (TD-19).
- `NRVLCore`: `Observed<T>` provenance, `Site`, `AuditEntry`. (`CapabilitySet` and the adapter error taxonomy moved to Phase 5, TD-19.)
- `NRVLPersistence`: GRDB, migration v1 (`site`, `audit_log`), append-only triggers and hash chain.
- `Scripts/build-app.sh` (bundle, Info.plist, ad-hoc hardened-runtime codesign), `Scripts/make-icon.sh` (icon → `.icns`), `Scripts/test.sh`.
- **Tests:** migration applies; audit rows cannot be updated/deleted; chain verifies; tampering detected.

### Phase 2 — App shell, navigation, design system ✅
- `NavigationSplitView` with all 13 sections in four groups; dark-first, cyan accent; confirmed/inferred and live/historical/estimated badges; "will show / needs / phase" view for unbuilt sections.
- Go menu with ⌘1–⌘9; Settings window (⌘,) and Settings section showing real storage and audit-chain status plus a legend for the data labels.
- `NRVLNetwork.xcodeproj` (TD-21). Search field moved to Phase 3 (TD-22).
- **Exit:** M0. No section shows sample data.

### Phase 3 — Local discovery and device inventory ✅
- Interfaces/gateway/DNS (getifaddrs, SystemConfiguration), `NWPathMonitor`.
- ARP + NDP table readers; subnet sweep (rate-limited, only on directly attached private subnets, user-initiated or scheduled); Bonjour browser; reverse DNS; OUI lookup; inferred device type.
- `InventoryService` merge + persistence; connection events (appeared/disappeared).
- Telemetry: this Mac's interface throughput, ICMP latency/jitter/loss to gateway and an internet target, uptime.
- UI: Overview (real values only), Devices table + detail inspector with search and filtering, rename/tag/group/trust.
- **Needs:** Local Network permission granted; IEEE OUI registry download.
- **Tests:** sysctl buffer parsers on captured fixtures, CIDR maths, merge rules; live read-only run on this network.
- **Exit:** M1.

### Phase 4 — Subnets and topology ✅
- Networks & Subnets: interfaces, CIDR, mask, gateway, DNS, public IP (opt-in external lookup), IPv4/IPv6, IP allocation grid, duplicate-IP detection (same IP, different MACs over time).
- Topology canvas: Internet → gateway → this subnet → devices; "attachment unknown" grouping; selection → detail.
- DHCP ranges, VLANs, static leases shown as "requires integration" until Phase 6.

### Phase 5 — Integration framework ✅ (SNMP unverified on hardware)
- Adapter protocols, capability model, `AdapterError`, polling scheduler with backoff, connection-status tracking.
- Keychain credential store; TLS trust-on-first-use pinning; Integrations UI (add, test, status, read-only default).
- Generic SNMP adapter (v2c read-only: system, interfaces, counters, ARP/bridge tables, LLDP).
- **Tests:** stubbed transport — bad credentials, timeout, TLS change, unsupported capability.
- **Needs:** vendor API docs re-verified before coding each adapter; an SNMP-enabled device for live verification.

### Phase 6 — UniFi and OpenWrt — implemented, unverified on hardware
- Read path for both: infrastructure devices, clients (wired/wireless, SSID, AP/switch port, VLAN), networks, DHCP, traffic counters, config snapshot.
- Inventory merge with adapter provenance; topology gains real uplinks.
- **Needs:** access to real UniFi and/or OpenWrt hardware with an admin-created API key / rpcd account. An adapter that cannot be run against real hardware is marked **"implemented, unverified on hardware"** in `PROGRESS.md`, never "complete".
- **Exit:** M3.

### Phase 7 — Traffic monitoring ✅
- Time-series storage + rollups; per-device bandwidth, top consumers, history charts (adapter/SNMP-sourced).
- NetFlow v5/v9/IPFIX collector (protocol distribution, destinations, ports) if the user has an exporter.
- Unusual-pattern flags (deviation from the device's own baseline) labelled as anomalies, not verdicts.

### Phase 8 — Access control ✅ (unverified on hardware)
- Engine: capability check → preview → local authentication → confirmation → apply → verify by re-read → audit → revert handle.
- Block/unblock, pause/restore, allowlist, quarantine (VLAN move where supported), groups, schedules, group policies.
- **Needs:** explicit authorisation and a designated test device before any live disruptive test.

### Phase 9 — QoS — link shaping only, see TD-45
- Policy model, create/modify/preview/activate/rollback; per-device limits, prioritisation, category rules, schedules; queue statistics.
- Mapped per platform (e.g. OpenWrt SQM/nft-qos, UniFi where the API allows, MikroTik queues); unsupported items shown explicitly.

### Phase 10 — Security and notifications ✅
- Firewall rule visibility, DNS policy, segmentation view (adapter-sourced).
- Detectors: new device, device gone, gateway offline, gateway MAC/config change, duplicate IP, thresholds (bandwidth/latency/loss), suspicious DNS (where DNS logs are available).
- `UserNotifications`, alert rules, preferences, history. Wording always "anomaly detected", with the evidence.

### Phase 11 — Reports, history, audit ✅ (three adapters deferred, TD-50)
- Daily/weekly/monthly reports, per-device consumption, uptime, QoS, security events; CSV and PDF export; audit-log viewer with chain verification; config backup/restore.
- MikroTik, OPNsense, pfSense adapters land here unless hardware availability moves them earlier.

### Phase 12 — Testing, optimisation, signing, packaging — partial, see PROGRESS.md
- Coverage of spec §10 matrix; performance profiling (large inventories, long histories); XCUITest suite; Xcode project; Developer ID signing + notarisation + DMG.
- Docs: installation & configuration guide, security & permissions.
- **Needs:** Xcode; Apple Developer ID for a notarised build.

## Working rules
- Before each major module: a short architecture + dependency note. After: build, test, fix, update `PROGRESS.md`.
- Architecture changes require a new `TECHNICAL_DECISIONS.md` entry first.
- A feature is recorded as complete only when exercised against a real data source.
