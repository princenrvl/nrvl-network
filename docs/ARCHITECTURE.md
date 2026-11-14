# NRVL Network — Architecture

Status: **approved 2026-11-11; implemented through Phase 12.** Governing spec: `PROJECT_SPEC.md`.
Sections 1–9 are the approved design. **Section 10 records how the build differs from it.**
Decisions and their reasons live in `TECHNICAL_DECISIONS.md` (referenced as TD-n).

## 1. Guiding constraints

1. **A Mac is one host on the network, not the network.** Without a gateway integration the app can see: its own interfaces, its own traffic counters, its neighbours (ARP/NDP), what devices advertise (mDNS), and what answers probes/SNMP. Per-device bandwidth, VLANs, access control, QoS and firewall data exist **only** when an infrastructure adapter supplies them.
2. **No fabricated data.** Every displayed value carries a provenance. No source → the UI shows "unavailable" plus the reason, never a number.
3. **No attack techniques.** No ARP spoofing, deauth, interception. Administrative actions go only through a configured adapter's documented API.
4. **Capabilities are discovered, not assumed.** Each adapter reports what it can do on this specific hardware/firmware.

## 2. Layering

Spec §7 layers map to SwiftPM targets in one local package (`NRVLKit`) plus the app target. Dependencies point downward only; the compiler enforces it.

```
NRVLNetworkApp  (SwiftUI, Presentation: views + @Observable view models)
      │
NRVLServices    (application services, and the engines as sub-namespaces:
      │          AccessControl, QoS, Security, Notifications, Audit, Reports)
      ├──────────────┬───────────────┬──────────────┐
NRVLDiscovery   NRVLTelemetry   NRVLAdapters   NRVLPersistence
      └──────────────┴───────────────┴──────────────┘
                          NRVLCore  (domain models, protocols, errors — no I/O)
```

| Target | Responsibility | Key platform APIs |
|---|---|---|
| `NRVLCore` | Domain types (`Device`, `NetworkInterface`, `Subnet`, `Site`, `Alert`, `AuditEntry`), `Observed<T>` provenance, `CapabilitySet`, adapter protocols, error taxonomy | Foundation only |
| `NRVLPersistence` | SQLite schema, migrations, repositories, append-only audit table | GRDB (TD-3) |
| `NRVLDiscovery` | Interface enumeration, ARP + NDP table reads, subnet sweep, Bonjour browse, OUI lookup, reverse DNS, device-type inference | `getifaddrs`, `sysctl(PF_ROUTE)`, SystemConfiguration, Network.framework (`NWBrowser`, `NWPathMonitor`), CoreWLAN |
| `NRVLTelemetry` | Local interface throughput, gateway/internet latency, jitter, packet loss, uptime; later a NetFlow/IPFIX/sFlow UDP collector | `sysctl(NET_RT_IFLIST2)`, unprivileged ICMP datagram sockets, `NWListener` |
| `NRVLAdapters` | Adapter framework + UniFi, OpenWrt, MikroTik, pfSense, OPNsense, generic SNMP | `URLSession`, `NWConnection` (UDP for SNMP) |
| `NRVLServices` | Orchestration: merges discovery + adapter data into inventory, schedules polling, runs engines, raises alerts, writes audit log, builds reports | `UserNotifications`, `LocalAuthentication`, Security (Keychain), CryptoKit, PDFKit/CoreGraphics |
| `NRVLNetworkApp` | 13-section sidebar shell, design system, tables, topology canvas, charts | SwiftUI, Swift Charts |

Engines start as folders inside `NRVLServices`; one is promoted to its own target only if it grows a distinct dependency set (TD-2).

## 3. Core concepts

### 3.1 Provenance — confirmed vs inferred (spec §3B, §8)

```swift
struct Observed<Value: Sendable & Codable>: Sendable, Codable {
    var value: Value
    var source: DataSource      // .arp, .ndp, .mdns, .snmp, .adapter(id), .ouiRegistry, .heuristic, .user
    var confidence: Confidence  // .confirmed | .inferred
    var observedAt: Date
}
enum Freshness { case live, historical, estimated }   // rendered as a badge on every metric
```

Examples: MAC from ARP = confirmed. Manufacturer from OUI = confirmed for the vendor block, but a locally-administered (randomised) MAC is labelled "Private address" with no vendor. Device type guessed from mDNS service types/OUI = inferred. Connection type (wired/wireless) is **unknown** without an adapter.

Merge rule: user > adapter > direct protocol observation > heuristic; the losing values are kept so the UI can show all sources.

### 3.2 Adapter framework (spec §4)

```swift
protocol InfrastructureAdapter: Sendable {
    var descriptor: AdapterDescriptor { get }               // kind, host, site
    func authenticate() async throws -> AdapterIdentity     // model, firmware, permission level
    func capabilities() async throws -> CapabilitySet       // per-feature: .supported | .readOnly | .unsupported(reason)
    func infrastructureDevices() async throws -> [InfraDevice]
    func clients() async throws -> [ClientRecord]
    func networks() async throws -> [NetworkRecord]         // subnets, VLANs, DHCP ranges, static leases
    func trafficStatistics() async throws -> TrafficSnapshot
    func configurationSnapshot() async throws -> ConfigSnapshot
}
// Opt-in refinements — an adapter conforms only if the platform has a documented way to do it.
protocol AccessControlling: InfrastructureAdapter { func preview(_:) ; func apply(_:) ; func revert(_:) }
protocol QoSManaging:       InfrastructureAdapter { … policies, queue stats, preview/apply/revert }
protocol FirewallInspecting: InfrastructureAdapter { … rules, DNS policy (read; write where documented) }
```

- Two-level capability check: protocol conformance (what the platform can ever do) and runtime `CapabilitySet` (what this firmware + this account can do now). The UI disables a control and displays the `unsupported(reason)` string.
- Every mutating call returns a `ChangeRecord` (before-state, after-state, revert handle). The engine verifies by re-reading state; an unverified change is reported as **failed/unknown**, never as success.
- Every adapter request has a timeout and maps failures to `AdapterError` (`unreachable`, `authFailed`, `tlsUntrusted`, `timeout`, `permissionDenied`, `unsupported`, `protocolError`).
- Requests go only to hosts the user explicitly configured.

Planned adapter transports (to be re-verified against vendor documentation at the start of Phases 5–6):

| Adapter | Transport | Notes / dependency |
|---|---|---|
| UniFi | Official Network Integration API (API key), HTTPS | Needs a UniFi OS console / Network application version that exposes it; feature coverage decides what is read-only |
| OpenWrt | ubus JSON-RPC over HTTPS | Router needs `uhttpd-mod-ubus` + rpcd ACLs; QoS needs SQM or nft-qos installed |
| MikroTik | RouterOS REST API | RouterOS 7.1+ with `www-ssl` enabled |
| OPNsense | Official REST API (key/secret) | — |
| pfSense | REST API | Not built into pfSense CE — requires the REST API package (or Plus); otherwise SNMP read-only |
| Generic SNMP | SNMP v2c, then v3 (USM) | Read-only: interfaces, counters, ARP/bridge tables, LLDP for topology |

### 3.3 Inventory pipeline

```
ARP/NDP reader ─┐
Subnet sweep ───┤
Bonjour browser ┼─► DiscoveryEvent stream ─► InventoryService (actor) ─► SQLite ─► ValueObservation ─► view models
SNMP / adapters ┘         (AsyncStream)       merge by MAC, provenance,
                                              first/last seen, state
```

Device identity key = MAC address (per site). Devices seen only by IP (routed, off-subnet) are keyed by adapter-supplied ID.

### 3.4 Topology (spec §3D)

Edges are drawn only from evidence: adapter uplink data, LLDP/bridge-FDB via SNMP, or "is the default gateway of this Mac". Devices with no known uplink are placed in an explicit **"Attachment unknown"** group on the subnet — no invented links.

## 4. Persistence

SQLite via GRDB, one database per user at `~/Library/Application Support/NRVL Network/nrvl.sqlite`, WAL mode, versioned migrations.

Tables (every row has `site_id` for future multi-site, spec §7):
`site`, `device`, `device_observation` (per-source values), `device_tag`, `device_group`, `interface_snapshot`, `subnet`, `integration`, `metric_sample` (time series; rolled up 1 min → 1 h → 1 day), `device_traffic_sample`, `connection_event`, `alert`, `alert_rule`, `policy` (access/QoS), `change_record`, `config_backup`, `audit_log`.

- `audit_log` is append-only: `BEFORE UPDATE/DELETE` triggers `RAISE(ABORT)`, plus a SHA-256 hash chain (each row hashes the previous) so tampering is detectable.
- No secrets in SQLite. Credentials/API keys → Keychain. Config backups (may contain secrets) → AES-GCM encrypted files, key in Keychain.

## 5. Security model (spec §6)

| Concern | Design |
|---|---|
| Privilege | App runs as the user. **No privileged helper in the initial design** — discovery and ICMP work unprivileged (TD-6). A helper is added only if a later, approved feature genuinely needs it. |
| Credentials | Keychain (`kSecClassGenericPassword`, this-device-only, not synced) |
| Transport | HTTPS only. Self-signed router certificates: user is shown the SHA-256 fingerprint and must explicitly trust it; it is then pinned. Validation is never globally disabled. A changed certificate blocks the integration and raises a security alert. |
| Sensitive actions | `LocalAuthentication` (Touch ID / account password) + a confirmation sheet showing the change preview, before any disruptive operation |
| Audit | Who (macOS user), what, target, before/after, result — written for every attempted action, including failures |
| Rollback | `ChangeRecord` revert handle + config snapshot taken before each change, where the adapter supports it |
| Read-only mode | Default for a new integration; management is an explicit opt-in per integration |
| macOS permissions | Local Network (discovery), Notifications, Location (only if the user wants the current SSID shown). Each requested at first use with an explanation. |

## 6. Concurrency

Swift 6 language mode, strict concurrency. Services are actors; view models are `@MainActor @Observable`; long-running producers expose `AsyncStream`. No blocking calls on the main actor. Polling intervals are per-source and back off on failure.

## 7. Presentation

`NavigationSplitView` with the 13 sidebar sections from spec §5; dark-first design system (colour, type, spacing tokens, status badges, freshness/provenance badges); `Table` for inventories; `Canvas`-based topology; Swift Charts for time series; commands menu + keyboard shortcuts; context menus; `.searchable` filtering; native notifications.

A section whose data source is not yet configured shows what is needed to enable it — never sample data.

## 8. Testing strategy (spec §10)

- **Unit** (Swift Testing): parsers (ARP/NDP sysctl buffers, SNMP BER, CIDR maths, OUI), merge rules, engines, migrations, audit immutability.
- **Integration**: each adapter against recorded real API responses served by a `URLProtocol` stub — test target only, never linked into the app. Failure cases: bad credentials, timeout, TLS mismatch, unsupported capability, failed change, rollback.
- **Live** (opt-in via environment variable): read-only checks against the user's authorised network; disruptive tests only with explicit per-run confirmation.
- **UI tests** (XCUITest): require full Xcode (see TD-1).

## 9. Repository layout

```
nrvl-network/
├── README.md  LICENSE  CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md  CHANGELOG.md
├── Package.swift                 # the seven targets + tests
├── NRVLNetwork.xcodeproj         # thin app target over the same sources (TD-21)
├── Sources/{NRVLCore,NRVLPersistence,NRVLDiscovery,NRVLTelemetry,NRVLAdapters,NRVLServices,NRVLNetworkApp}/
├── Tests/                        # one test target per area
├── Resources/                    # Info.plist, AppIcon, IEEE manufacturer registry
├── Scripts/                      # build-app, package, smoke-test, test, make-icon, update-oui
├── docs/                         # this file, decisions, progress, plan, spec, install and security guides
└── .github/                      # CI workflow, issue and pull-request templates
```

## 10. As built (2026-11-11)

Layering and dependency direction are as designed. Differences, each with its decision record:

| Design | As built | Record |
|---|---|---|
| Seven targets from day one | Same seven, created by the phase that first used them: `NRVLCore`, `NRVLPersistence`, `NRVLDiscovery`, `NRVLTelemetry`, `NRVLAdapters`, `NRVLServices`, app | TD-19 |
| Adapter returns `ClientRecord` | Adapters return `DeviceSighting`, the type local discovery produces; one merge path | TD-36 |
| `device_observation` table per source | Plain columns on `device`; integrations are authoritative for attachment fields | TD-25 |
| `metric_sample` with 1 min → 1 h → 1 day roll-ups | One-minute rows, aggregated on read, 90-day retention | TD-42 |
| `QoSManaging` per-device limits | `LinkShaping` (SQM queues); per-device QoS unsupported on available platforms | TD-45 |
| Engines as Services sub-namespaces | `AccessControlEngine`, `QoSEngine`, `IntegrationService`, `InventoryService`, `ReportBuilder`, `BackupService` in `NRVLServices`; alert rules are pure functions in `NRVLCore` and evaluated by the app's `AlertsModel` | TD-44, TD-46 |
| UniFi with management | Read-only: the official API documents no client blocking | TD-40 |
| Six adapters | Three: SNMP, UniFi, OpenWrt | TD-50 |
| `NWBrowser` for Bonjour | System DNS-SD API | TD-28 |
| Sandbox to be evaluated | Not sandboxed; Hardened Runtime | TD-5 |

Database migrations: `v1` (site, audit_log) · `v2-devices` · `v3-identity-and-history` · `v4-integrations` · `v5-history` · `v6-access-policies` · `v7-change-records` · `v8-alerts`.

Change pipeline used by both engines: capability check → management enabled → preview and confirmation (UI) → local authentication (UI) → apply through the adapter (router-side rollback on OpenWrt) → read back → audit → local state updated only if verified.
