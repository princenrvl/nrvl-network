# Contributing to NRVL Network

Thank you for helping. Bug reports, hardware test reports, documentation fixes and code are all welcome.

## Ways to contribute

| | How |
|---|---|
| **Test on real hardware** | The most useful thing right now. The SNMP, UniFi and OpenWrt integrations have only run against simulated devices. Try one read-only and file a [hardware report](https://github.com/princenrvl/nrvl-network/issues/new?template=hardware_report.yml). |
| **Report a bug** | Use the [bug report](https://github.com/princenrvl/nrvl-network/issues/new?template=bug_report.yml) form. |
| **Suggest a feature** | Use the [feature request](https://github.com/princenrvl/nrvl-network/issues/new?template=feature_request.yml) form. |
| **Report a vulnerability** | Privately — see [SECURITY.md](SECURITY.md). Never in a public issue. |
| **Send code** | Read on. |

## Set up

Requirements: macOS 14+, Xcode 16+.

```bash
git clone https://github.com/princenrvl/nrvl-network.git
cd nrvl-network
swift test
Scripts/build-app.sh
```

Or open `NRVLNetwork.xcodeproj`. New files under `Sources/NRVLNetworkApp` appear in Xcode automatically.

## Ground rules

These come from the project's specification and are not negotiable:

1. **No fabricated data.** No sample numbers, no placeholder charts. If a value has no source, show that it is unavailable and why.
2. **No attack techniques.** Nothing that spoofs, intercepts, deauthenticates or captures. Control goes through a device's documented interface or it does not happen.
3. **Documented APIs only.** Do not fall back to undocumented or private vendor endpoints. If the official API cannot do something, report the capability as unsupported with the reason.
4. **Never report unverified success.** A change must be read back from the device. Otherwise the result is "unverified", not "succeeded".
5. **Secrets stay in the Keychain.** Never in the database, logs, exports, tests or commits.
6. **Treat everything from the network as untrusted input** — device names, SNMP replies, JSON from routers. Bounds-check, and never crash on malformed data.

## Code style

- Swift 6 language mode with strict concurrency. No `@unchecked Sendable` without a comment explaining what guards the state.
- Respect the layering in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): `NRVLCore` has no I/O; views hold no business logic.
- Keep it small. Prefer deleting code to adding it; no speculative abstractions or options.
- Comment *why*, not *what*. A known limit gets a comment in the form `// shortcut: <the limit>, <when to upgrade>`.
- User-facing text is plain language. Explain why something is unavailable.

## Tests

- New logic — a parser, a rule, an engine, anything touching security or data — needs a test that fails when it breaks.
- Adapters are tested against a simulated device in the test target (see `SimulatedOpenWrt`, `SimulatedAgent`). Build simulated replies from the vendor's published documentation and say so.
- **Never test disruptive actions against a network you are not authorised to administer.**

Run everything with `swift test`. Run `Scripts/smoke-test.sh` after `Scripts/build-app.sh` for a launch-level check.

## Adding an integration

1. Add a type conforming to `InfrastructureAdapter` in `Sources/NRVLAdapters`.
2. Conform to the optional protocols (`AccessControlling`, `LinkShaping`, `FirewallInspecting`, `ConfigurationExporting`) **only** where the platform documents a way to do it.
3. Return an honest `CapabilitySet`: probe the device; give a reason for everything unsupported.
4. Register it in `AdapterFactory`.
5. Add a simulated device and tests covering: a normal read, wrong credentials, a timeout or unreachable host, an unsupported capability, and — for write paths — a failed change.
6. Document sources and limits in [docs/TECHNICAL_DECISIONS.md](docs/TECHNICAL_DECISIONS.md), and state whether you ran it on real hardware.

## Pull requests

- One topic per pull request, branched from `main`.
- `swift test` passes; the app builds.
- Describe what changed, why, and how you tested it — including what you could **not** test.
- Update the docs your change affects. Architectural changes need an entry in `docs/TECHNICAL_DECISIONS.md`.

## Licence

By contributing you agree that your contribution is licensed under the [MIT Licence](LICENSE).
