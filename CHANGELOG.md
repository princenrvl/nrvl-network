# Changelog

All notable changes to NRVL Network are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] — 2026-11-14

First public preview.

### Added
- **Device discovery and inventory** from this Mac alone: ARP and IPv6 neighbour tables, subnet probing, Bonjour names, models and services, IEEE manufacturer lookup, reverse DNS, evidence-based device types, connection history, renaming, tags, groups and trusted marks.
- **Overview** with health, latency, jitter and packet loss to the gateway and internet, and live throughput.
- **Topology** and **Networks & Subnets**: evidence-based map, IP allocation grid, address-conflict detection.
- **Traffic Analytics**: stored history, SNMP interface traffic, opt-in NetFlow v5 collector.
- **Integrations**: SNMP v2c (read-only), Ubiquiti UniFi via the official Integration API (read-only), OpenWrt via ubus. Per-device capability reporting, Keychain credentials, certificate pinning.
- **Access Control**: block, pause and weekly schedules through OpenWrt, with preview, authentication, verification and audit.
- **QoS Manager**: SQM link shaping on OpenWrt with before/after preview and rollback.
- **Firewall**, **Security Center** and **Monitoring**: read-only firewall rules, 13 alert types, thresholds, notifications.
- **Reports**: period reports, PDF and CSV export, hash-chained audit log viewer, encrypted configuration snapshots.
- Universal (Apple silicon + Intel) build, disk-image packaging, smoke test, installation and security guides.

### Known limitations
- Router integrations have been tested against simulated devices only — not yet on real hardware.
- The downloadable disk image is ad-hoc signed, not notarised: macOS asks you to approve it once under Privacy & Security.
- No UI tests. No MikroTik, OPNsense or pfSense adapters. No SNMP v3.
- Per-device traffic and per-device QoS are unavailable: none of the supported platforms documents them.

[Unreleased]: https://github.com/princenrvl/nrvl-network/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/princenrvl/nrvl-network/releases/tag/v0.1.0
