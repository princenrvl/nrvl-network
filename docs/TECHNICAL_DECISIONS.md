# NRVL Network — Technical Decisions

Append-only decision log. Status values: Proposed → Accepted → Superseded (never deleted).
All entries below are **Proposed** until the plan is approved.

## TD-1 — Build system: SwiftPM first, Xcode project when Xcode is available
**Context.** The development Mac has Command Line Tools only (Swift 6.4.2, macOS 27.2.1); full Xcode is not installed. `xcodebuild`, asset-catalog compilation and XCUITest are unavailable.
**Decision.** All code lives in a SwiftPM package (modules per `ARCHITECTURE.md` §2). `Scripts/build-app.sh` assembles and code-signs a real `.app` bundle. When Xcode is installed, a thin `NRVLNetwork.xcodeproj` app target is added that depends on the same local package — no code moves.
**Consequence.** Spec §11 "complete Xcode project" and "UI tests" are blocked on installing Xcode. Everything else proceeds. The package also opens directly in Xcode.

## TD-2 — Modular layers as package targets
**Decision.** Seven targets (Core, Persistence, Discovery, Telemetry, Adapters, Services, App). The access-control, QoS, security, notification and audit engines are namespaces inside `NRVLServices` until one needs its own dependencies.
**Why.** Compiler-enforced layer boundaries without eleven near-empty targets.

## TD-3 — SQLite via GRDB.swift
**Decision.** Use GRDB (the only third-party dependency planned).
**Why.** Migrations, Swift 6-safe concurrent access and database observation (live UI updates without manual refresh, spec §8) would otherwise be several hundred lines of hand-written C-API wrapper to maintain.
**Alternative.** Raw `SQLite3` module — zero dependencies, more code. Switchable behind the repository protocols.

## TD-4 — Minimum macOS 14 (Sonoma)
**Why.** `@Observable`, `inspector`, mature `Table`/`NavigationSplitView`, Swift Charts, `SMAppService` (if a helper is ever needed). Nothing planned needs 15+.

## TD-5 — Distribution: Developer ID, Hardened Runtime, not App Store
**Why.** Reading the kernel ARP/NDP tables and ICMP sockets are at risk under App Sandbox; App Store review rules also restrict network-scanner behaviour. Sandbox compatibility will be measured in Phase 3 and enabled if nothing breaks.
**Dependency.** Notarised distribution needs an Apple Developer Program membership. Without it, builds are ad-hoc signed for local use.

## TD-6 — No privileged helper initially
**Decision.** Discovery uses unprivileged mechanisms: `sysctl` route-table reads for ARP/NDP, unprivileged ICMP datagram sockets for ping, UDP probes for sweep, `NWBrowser` for Bonjour.
**Why.** Spec §6: helper "only when necessary". Nothing in Phases 1–11 requires root. Raw packet capture (BPF) would, and is deliberately out of scope: it cannot see other devices' traffic on a switched/Wi-Fi network anyway (spec §3E).

## TD-7 — Per-device traffic, access control, QoS and firewall come only from adapters
**Decision.** These modules are functional only with a configured, capable integration (or a flow exporter for traffic). Without one they show a "requires integration" state listing what would enable them.
**Why.** Spec §3E/F/G and §12 — a Mac cannot observe or control other clients' traffic by legitimate means.

## TD-8 — Data provenance is part of the model
**Decision.** `Observed<T>` wraps every discovered attribute with source, confidence and timestamp; persisted per source in `device_observation`.
**Why.** Spec §3B "distinguish confirmed from inferred" and §8 "live, historical, estimated" must be answerable for every value, not decided ad hoc in views.

## TD-9 — Capability model: protocol conformance + runtime `CapabilitySet`
**Why.** Spec §4 — the same adapter differs by firmware, installed packages and account permissions. Unsupported features carry a human-readable reason.

## TD-10 — TLS: trust-on-first-use pinning with explicit user approval
**Why.** Routers almost always use self-signed certificates. Disabling validation violates spec §6; requiring public CAs makes the app unusable. Showing the fingerprint, pinning it, and alarming on change is the secure middle.

## TD-11 — Secrets in Keychain only; encrypted config backups
**Decision.** SQLite holds no secrets. Config backups are AES-GCM (CryptoKit) with a Keychain-held key. The database itself is not SQLCipher-encrypted (relies on FileVault + file permissions).
**Open.** If full-database encryption is required, swap to GRDB+SQLCipher — say so before Phase 3.

## TD-12 — Append-only audit log enforced in the database
**Decision.** SQLite triggers reject UPDATE/DELETE on `audit_log`; rows are hash-chained.
**Limit.** A user with file access can still replace the whole file; the hash chain makes that detectable, not impossible. That is the meaning of "immutable-style" on a single-user Mac.

## TD-13 — SNMP implemented in Swift
**Decision.** Small BER codec + SNMP v2c GET/GETNEXT/GETBULK over `NWConnection`; v3 USM (SHA auth, AES priv) added after v2c is proven.
**Why.** No system SNMP library; net-snmp would be a C dependency to build, sign and ship. Read-only SNMP is a few PDU types.

## TD-14 — Sensitive-action authentication via LocalAuthentication
**Decision.** `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` before disruptive operations.
**Limit.** This proves the logged-in user's presence, not macOS admin-group membership. If strict admin-only is wanted, add an Authorization Services right — say so.

## TD-15 — iOS is out of scope for now
**Context.** The spec title says "macOS and iOS"; every requirement in the body is macOS.
**Decision.** Build macOS. Core/Persistence/Adapters/Services avoid AppKit so an iOS app can reuse them later. (iOS cannot read ARP tables at all, so it would be adapter-driven.) **Needs confirmation.**

## TD-16 — OUI manufacturer registry bundled, updatable
**Decision.** Ship the public IEEE MA-L/M/S registry compacted into a resource file; `Scripts/update-oui.sh` refreshes it. Lookups are offline.
**Dependency.** Requires downloading the registry from IEEE once during Phase 3 (will ask before downloading).

---
Phase 1 additions (2026-11-11). TD-1 to TD-16 are **Accepted** as of plan approval, with the defaults proposed for the unanswered questions (macOS only, GRDB, `com.nrvl.network`).

## TD-17 — No `@State` while building without Xcode — Accepted
**Context.** In the macOS 27 SDK, `@State` is a macro whose compiler plugin (`SwiftUIMacros`) ships only with Xcode. With Command Line Tools the app target fails to compile if any view uses `@State` (also `@Entry`, `#Preview`, `@Animatable`). Other wrappers (`@Binding`, `@Bindable`, `@Environment`, `@AppStorage`, `@FocusState`) are unaffected.
**Decision.** All view state lives in `@MainActor @Observable` view models (the `ObservationMacros` plugin is present), owned by the App or a parent model and passed down. This is the MVVM shape the architecture already called for.
**Revisit.** Once Xcode is installed, `@State` is allowed for purely local, throwaway view state.

## TD-18 — Tests run through `Scripts/test.sh` — Accepted
**Context.** Same root cause: SwiftPM under Command Line Tools does not locate the Swift Testing macro plugin, although it is installed.
**Decision.** `Scripts/test.sh` passes `-plugin-path` when the active toolchain is Command Line Tools and falls back to plain `swift test` under Xcode. `Package.swift` stays free of unsafe flags.

## TD-19 — Targets and tables are created by the phase that first uses them — Accepted
**Decision.** Phase 1 ships `NRVLCore`, `NRVLPersistence` and the app target, and migration v1 holds only `site` and `audit_log`. Discovery/Telemetry/Adapters/Services targets, `CapabilitySet`, the adapter error taxonomy and the remaining tables arrive with Phases 3 and 5 as new targets and new migrations.
**Why.** Types and schemas written before their first consumer are guesses. This narrows the Phase 1 scope listed in the original plan; the target architecture in `ARCHITECTURE.md` is unchanged.

---
Phase 2 additions (2026-11-11). Xcode 27.2 installed and selected.

## TD-20 — Supersedes TD-17 and TD-18: Xcode toolchain is now the baseline
**Decision.** `@State` is allowed again, used for view-owned state and for the App owning its root model. Shared state (sidebar selection, storage status) stays in `@Observable` models because menus and several views need it. Plain `swift test` works; `Scripts/test.sh` is kept as it handles both toolchains.

## TD-21 — Xcode project is a thin app target over the local package — Accepted (completes TD-1)
**Decision.** `NRVLNetwork.xcodeproj` has one app target, "NRVL Network". It compiles `Sources/NRVLNetworkApp` through a file-system-synchronised group (new files appear automatically) and links the `NRVLCore`/`NRVLPersistence` library products from the package at the repository root. It uses the same `Resources/Info.plist` and `AppIcon.icns` as `Scripts/build-app.sh`.
**Consequence.** Two equivalent ways to build the same sources: Xcode (for running, debugging, UI tests, archiving) and `Scripts/build-app.sh` (scriptable, no IDE). The app module is `NRVLNetworkApp` in Xcode to avoid clashing with the package's `NRVLNetwork` executable target.

## TD-22 — Search field deferred to Phase 3
**Decision.** No `.searchable` field in the shell yet.
**Why.** Nothing exists to search until the Devices table ships; a search box that does nothing would be a non-functional control (spec §5 "every module must have a functional purpose").

---
Phase 3, part 1 additions (2026-11-11).

## TD-23 — Active discovery = one UDP datagram per host, private subnets up to /22 — Accepted
**Decision.** To make live hosts appear in the ARP table the app sends a 1-byte UDP datagram to the discard port (9) of every address on each directly attached RFC 1918 / link-local subnet, paced to about 1,600 packets per second, then reads the kernel ARP and IPv6 neighbour tables. Subnets larger than /22 and public ranges are never probed, only read passively.
**Why.** Unprivileged, uses no raw sockets, spoofs and intercepts nothing (spec §3F). It relies on normal kernel address resolution.
**Limits.** Finds only devices on this Mac's own subnets. Needs macOS Local Network permission; when macOS refuses the sends the UI says so and falls back to the passive table.

## TD-24 — "Online" means present in the neighbour table at the last scan — Accepted
**Decision.** A device is shown online if the most recent scan saw it. The UI states that a device which just left can linger for a few minutes (kernel cache), and shows "not scanned yet" for stored records before the first scan of a session.
**Why.** That is all a single host can truthfully know. Accurate association state needs a router integration (Phase 6).

## TD-25 — `device` table uses plain columns for now; per-source observations deferred — Accepted
**Decision.** Migration `v2-devices` stores one row per (site, MAC) with the current value of each attribute. The `device_observation` table from `ARCHITECTURE.md` §4 is added when a second source (router adapters, Phase 5–6) can disagree with the first. Until then each field has exactly one possible source, which the detail view names.
**Also.** Manufacturer is looked up at display time, not stored, so a registry refresh applies to old records.

## TD-26 — Manufacturer registry: IEEE MA-L only, bundled as `Resources/oui.tsv` — Accepted (refines TD-16)
**Decision.** 39,920 24-bit prefixes, refreshed by `Scripts/update-oui.sh`. Blocks subdivided into MA-M/MA-S return "not in registry"; randomised (locally administered) addresses are labelled "Private address" and never matched. The file is passed to `NRVLDiscovery` by URL from the app bundle, avoiding SwiftPM resource bundles in the hand-assembled app.

## TD-27 — Single-window app; database busy timeout — Accepted
**Decision.** The main scene is `Window`, not `WindowGroup`: selection and inventory are app-wide, and a second window would mirror the first. The on-disk database waits up to 5 s for another process's write lock instead of failing immediately. Scanning runs in an app-lifetime task, not a view task.

---
Phase 3, part 2 additions (2026-11-11).

## TD-28 — Bonjour through the system DNS-SD API, read-only — Accepted
**Decision.** `BonjourBrowser` uses `dnssd` (`DNSServiceBrowse` → `DNSServiceResolve` → `DNSServiceGetAddrInfo`) on one shared connection. It enumerates service types with the `_services._dns-sd._udp` meta-query, so it is not limited to a fixed list. Results are matched to devices by IP address.
**Why not `NWBrowser`.** It cannot run the meta-query and gives no address without opening a connection to the service; the app must not connect to devices it is only observing.
**Notes.** `Info.plist` declares common types in `NSBonjourServices` in case macOS enforces the list. A hostname ending in `.local` is labelled "Bonjour" in the UI; other names are "Reverse DNS". Names announced by the device take precedence over reverse DNS.

## TD-29 — Device type only from evidence — Accepted
**Decision.** `DeviceClassifier` returns a type only when (a) it is this Mac, (b) it is the default gateway, (c) it publishes a model identifier over Bonjour — all Confirmed — or (d) it advertises a telling service, marked Inferred with the service named as the basis. The manufacturer alone never produces a type; otherwise the type is "Unknown".

## TD-30 — Connection history: session-scoped presence with a three-scan debounce — Accepted
**Decision.** Every device gets one `discovered` event at its first sighting. Within an app run, a device that enters the scan results gets `appeared`; one missing from three consecutive scans (about three minutes) gets `disappeared`. The first scan of a run only sets the baseline.
**Why.** A single missed ARP reply (sleeping phones) must not create noise, and the app cannot know what happened while it was not running — so it records nothing for that gap.

## TD-31 — Telemetry is live and in memory until Phase 7 — Accepted
**Decision.** `TelemetryModel` samples every 2 s: 64-bit byte counters of the primary interface (this Mac's traffic only), one ICMP echo to the gateway and one to `1.1.1.1`. It keeps 5 minutes of throughput and the last 30 pings per target (≈1 minute) for latency, jitter and loss. "Reachable since launch" counts internet replies over this run. Nothing is persisted yet; time-series storage and long-term uptime belong to Phase 7.
**Health rule.** Offline = no gateway, gateway silent, or internet check silent; Degraded = internet loss above 5 % or average latency above 150 ms; otherwise Healthy. The card states which condition applied.
**External dependency.** The internet check pings Cloudflare's public resolver. It is a fixed constant today and should become a setting.
**Mechanism.** Unprivileged ICMP datagram socket — confirms TD-6 (no helper needed).

## TD-32 — Tags and one group per device, stored on the device row — Accepted
**Decision.** `tags` (comma-separated, de-duplicated case-insensitively) and `group_name` columns, edited from the Devices context menu and searchable. A separate group table arrives when groups carry policies (Phase 8).

---
Phases 4–5 additions (2026-11-11).

## TD-33 — Topology draws only provable links — Accepted
**Decision.** Internet → default gateway (this Mac's default route, coloured by ping loss) → one group per attached subnet. Devices sit in the group marked "attachment unknown"; an uplink line of text appears on a device only when an integration reported it. No switch/AP hierarchy is invented.

## TD-34 — Address conflict = an IP whose MAC flips back — Accepted
**Decision.** `ConflictDetector` flags an IPv4 address when its ARP owner changes at least twice among the same MACs within 10 minutes. One change is treated as a normal DHCP hand-over. Shown as "possible conflict / anomaly" with the alternative explanation (failover pairs). Session-scoped.
**Related fix.** When a device is sighted with an IPv4 address, that address is removed from any other device that held it.

## TD-35 — Public IP lookup is opt-in — Accepted
**Decision.** The public address is fetched from `api.ipify.org` only when the user clicks "Look Up"; the reply is accepted only if it is shaped like an IP address. Nothing is sent automatically to third parties.

## TD-36 — Adapter framework as built — Accepted (implements TD-9)
**Decision.** `InfrastructureAdapter` (identify, capabilities, clients, infrastructureDevices, networks) plus opt-in protocols `AccessControlling`, `QoSManaging`, `FirewallInspecting`, `ConfigurationExporting`. Clients are returned as `DeviceSighting`, the same type local discovery produces, so one merge and one store path serve both. `CapabilitySet` maps each `Feature` to supported / read-only / unsupported(reason) and is probed per device, not assumed per kind.
**Scan integration.** `IntegrationService.collect()` runs inside every inventory scan, so local and integration data share one timestamp and one presence model. A failing integration is recorded in its status and never blocks the scan.
**Merge rule.** This Mac's observation wins for IPv4 and hostname; integrations are the sole authority for connection type, SSID, uplink, VLAN and blocked state (including clearing them).

## TD-37 — SNMP: v2c, read-only, standard MIBs — Accepted (narrows TD-13)
**Decision.** GET and GETBULK only; the client has no SET. MIB-II system/IP, IF-MIB and BRIDGE-MIB give identity, ARP clients, the switch port a MAC was learned on, subnets and 64-bit interface counters. The BER decoder bounds-checks every length and caps nesting depth because replies are untrusted input.
**Limits.** v2c sends the community string unencrypted — the UI says so and advises a read-only community. SNMP v3 is not implemented. LLDP is not read. Verified only against the simulated agent in the test suite; **unverified on hardware**.

## TD-38 — TLS pinning as built — Accepted (implements TD-10)
**Decision.** `PinnedHTTP` uses an ephemeral `URLSession`. With an approved fingerprint only that exact leaf certificate is accepted (even a publicly valid replacement is refused); without one only system-trusted certificates are accepted. A refused certificate surfaces its SHA-256 fingerprint so the UI can ask the user to compare and approve it; approval is written to the audit log. Requests to any host other than the configured one are refused.

## TD-39 — Secrets: Keychain item per integration — Accepted (implements TD-11)
**Decision.** Generic-password items under service `com.nrvl.network.integration`, account = integration id, accessible only when unlocked, this device only, not synchronised. If storing the secret fails the integration row is rolled back. Removing an integration deletes its secret and clears the device fields only it could know.

---
Phases 6–7 additions (2026-11-11).

## TD-40 — UniFi adapter: official Integration API only, therefore read-only — Accepted
**Sources checked.** Ubiquiti's developer site did not render for automated reading; field names come from a community OpenAPI transcription of the Integration v1 API (`tmcpro/unifi-network-api`), which is **not an official source**.
**Decision.** `UniFiAdapter` uses `/proxy/network/integration/v1` with the `X-API-Key` header: `/info`, `/sites`, `/sites/{id}/clients`, `/sites/{id}/devices`, paginated at 200. It reports clients (wired/wireless, IP, name, uplink device) and infrastructure devices.
**Finding.** The only documented client action is `AUTHORIZE_GUEST_ACCESS`. There is no documented block/unblock, rate limit, per-client traffic, SSID or VLAN field. The adapter therefore reports access control, QoS and traffic as *unsupported* with that reason. The widely used but undocumented controller API (`/proxy/network/api/s/…`) is deliberately not used (spec §4).
**Status.** Tested against a simulated console only. **Unverified on hardware.** Newer Network versions may add networks/firewall endpoints; re-check against a real console.

## TD-41 — OpenWrt adapter: ubus JSON-RPC, block via a named firewall rule with router-side rollback — Accepted
**Sources checked.** openwrt.org blocked automated reading. Method names and reply fields for `luci-rpc` (`getHostHints`, `getDHCPLeases`, `getWirelessDevices`) were confirmed from the LuCI source (`libs/rpcd-mod-luci/src/luci.c`) and its ACL file. The envelope, `session login`, `system board`, `iwinfo assoclist`, `network.interface dump` and `uci` argument shapes are from the long-standing ubus documentation as I know it and were **not re-confirmed** in this session.
**Decision.** Reads hosts, leases, Wi-Fi associations (the only clients whose connection type the router can state — wired is never assumed), interfaces and firewall rules. Blocking adds one rule named `nrvl-block-<mac>` (zone lan → wan, REJECT) via `uci add`, then `uci apply {rollback: true, timeout: 30}` and `uci confirm`, so the router reverts by itself if the change cuts the session. Unblock deletes only rules carrying that name. State is re-read from the router to verify.
**Limits.** Assumes default zone names `lan`/`wan` (marked `shortcut:`). Blocks internet access, not LAN access. Per-client traffic and QoS are reported unsupported.
**Status.** Tested against a stateful simulated router only. **Unverified on hardware** — the write path in particular must be tried on a non-critical router first.

## TD-42 — History: one-minute rows, aggregated on read — Accepted (replaces the roll-up plan in ARCHITECTURE §4)
**Decision.** `metric_sample` holds one averaged value per series per minute; charts aggregate with `GROUP BY` at read time; rows older than 90 days are pruned at launch. No roll-up tables until a chart is measurably slow.
**Series.** `mac.down/up` (this Mac), `internet.latency/loss`, `gateway.latency/loss`, and `if.<integration>.<interface>.rx/tx` for SNMP devices that publish 64-bit counters. `device_traffic` stores per-interval bytes per device when an integration reports per-client totals — **no adapter does today**, and the Traffic section says so.

## TD-43 — Flow visibility: NetFlow v5 collector, opt-in, session-scoped — Accepted
**Decision.** `FlowCollector` listens on UDP 2055 only after the user clicks Start, parses NetFlow v5 defensively, and keeps running totals by protocol, destination port, destination and source (capped at 5,000 keys each) for the session. v9/IPFIX and persistence of flow history are not implemented.
**Why.** Protocol/port/destination breakdowns exist only in flow exports; the app never captures traffic itself (spec §3E).

---
Phases 8–12 additions (2026-11-11).

## TD-44 — Access control = policies + reconciliation — Accepted
**Decision.** Blocking is expressed as stored `AccessPolicy` rows (block, timed pause, weekly schedule; per device or per group). After every scan `AccessControlEngine.reconcile` compares what the policies want with what the router reports and applies the difference. Manual block/unblock creates or clears a policy and applies immediately for a verified result.
**Safeguards.** Integration must have management enabled; adapter must conform to `AccessControlling` and report the capability; this Mac and the default gateway are refused; group policies skip trusted devices (the allowlist); every attempt — including refused ones — is audited; an unverified result does not change local state.
**Limits.** Schedules apply only while the app runs (about once a minute). Quarantine (VLAN move) has no documented mechanism on the supported platforms and is shown as unavailable. Only OpenWrt can block today.

## TD-45 — QoS = link shaping through SQM; per-device QoS reported unsupported — Accepted
**Finding.** `nft-qos` is no longer in the official OpenWrt package feeds, and UniFi's official API has no rate limiting, so no supported platform offers documented per-device limits or prioritisation.
**Decision.** `LinkShaping` reads SQM queues and changes only `enabled`/`download`/`upload` of an existing queue, via `uci set` + `apply {rollback}` + `confirm`. `QoSEngine` verifies by read-back and stores before/after in `change_record`; "Roll Back" re-applies the stored previous values. Per-device limits, prioritisation, category rules, scheduled QoS and queue statistics are listed in the UI as unsupported, with the reason.
**Replaces** the unused `QoSManaging`/`RateLimit` types sketched in Phase 5.

## TD-46 — Alerts are edge-triggered rules over a snapshot — Accepted
**Decision.** After every scan the app builds a `NetworkSnapshot` and `AlertRules.evaluate(previous:current:)` (pure, in Core) raises an alert when a condition begins. Covers new/left devices, gateway or internet unreachable, latency, loss, bandwidth (this Mac), address conflict, gateway MAC/address change, DNS change, integration down, certificate change, firewall-rule change. Thresholds and per-kind switches are stored as JSON in `setting`.
**Wording.** Each alert states the observation and its evidence and, for security kinds, the innocent explanation as well.
**Not done.** Suspicious DNS-query detection (no query-log source) and per-device traffic anomalies (no per-client traffic source).

## TD-47 — Reports are computed from stored data and state their coverage — Accepted
**Decision.** `ReportBuilder` derives a period report from the existing tables; `observedFraction` shows how much of the period the app was running, and uptime is "checks answered while observed". PDF export renders the same SwiftUI view shown on screen to one continuous page. CSV export follows RFC 4180 and prefixes formula-like cells with an apostrophe (device names are untrusted input).

## TD-48 — Configuration snapshots, encrypted; no automated restore — Accepted
**Decision.** `ConfigurationExporting` (OpenWrt: the main UCI configs as JSON) → AES-256-GCM file, key in the Keychain, mode 0600; decrypt-for-export requires authentication and is audited.
**Why no restore.** Writing a whole configuration back to a router is high-risk and unverifiable without hardware; snapshots serve comparison and manual restore. Rollback exists at the level of individual changes (TD-44, TD-45).

## TD-49 — Packaging — Accepted
**Decision.** `Scripts/build-app.sh` builds a universal (arm64 + x86_64) app and copies dependency resource bundles; `Scripts/package.sh` produces a DMG; `Scripts/smoke-test.sh` launches the build and checks process, migrations, audit entry, scan result and crash reports. Signing is ad-hoc unless `SIGN_IDENTITY` is supplied; notarisation commands are documented but not run (no credentials).

## TD-50 — Deferred, with reasons
| Item | Why deferred |
|---|---|
| MikroTik, OPNsense, pfSense adapters | No hardware and no verified API reference in this session; three more unverifiable adapters would add risk, not capability. The framework and UI already list them as "not in this build". |
| XCUITest target | UI automation is blocked by macOS privacy permissions in this environment, so a UI test target could not be run or verified. `smoke-test.sh` covers launch-level checks. |
| SNMP v3, LLDP, NetFlow v9/IPFIX | Need real devices to verify. |
| Multi-site UI | Every table carries `site_id`; only the default site is used. |
| Privileged helper | Still not needed (TD-6 held through all phases). |
