# NRVL Network — Installation and Configuration

Version 0.1.0. Requires macOS 14 or later, Apple silicon or Intel.

## 1. Install

### From the disk image
1. Download `NRVL-Network-0.1.0.dmg` from the [latest release](https://github.com/princenrvl/nrvl-network/releases/latest), or build it with `Scripts/package.sh`.
2. Open the image and drag **NRVL Network** to Applications.
3. A downloaded copy is **ad-hoc signed, not notarised**, so macOS refuses the first launch. Open System Settings → Privacy & Security and click **Open Anyway** next to the NRVL Network message. A copy you built yourself opens without this step.

### From source
| Goal | Command |
|---|---|
| Run the tests | `swift test` (or `Scripts/test.sh` on a Mac with only Command Line Tools) |
| Build the app | `Scripts/build-app.sh` → `build/NRVL Network.app` |
| Check a build | `Scripts/smoke-test.sh` |
| Work in Xcode | open `NRVLNetwork.xcodeproj`, scheme "NRVL Network" |

Needs Xcode 16 or later (built and tested with Xcode 27.2). The only third-party dependency, GRDB, is fetched by Swift Package Manager on the first build.

## 2. First launch
macOS will ask for:

| Prompt | Why | If you decline |
|---|---|---|
| **Local Network** | To look for devices on your subnets and ping the gateway | Devices shows only what this Mac has already talked to, with a banner explaining it |
| **Notifications** (on the first alert) | To post alerts | Alerts still appear under Monitoring |
| **Incoming connections** (only if you start the NetFlow listener) | To receive flow records from your router | No flow breakdowns |

Nothing else is requested. The app never asks for administrator rights and installs no helper.

## 3. What works without a router integration
- **Overview** — health, internet and gateway latency/jitter/loss, device counts, this Mac's throughput.
- **Devices** — every device this Mac can see on its own subnets: IP, MAC, manufacturer, Bonjour name/model/services, evidence-based type, history. Rename, tag, group, mark trusted.
- **Topology**, **Networks & Subnets** — default route, shared subnets, IP allocation, possible address conflicts.
- **Traffic Analytics** — stored history of this Mac's throughput and of latency/loss.
- **Security Center**, **Monitoring**, **Reports** — alerts, preferences, reports, CSV/PDF export, audit log.

A Mac cannot see or control other devices' traffic. Per-device traffic, connection type, SSID, VLANs, blocking and QoS need an integration.

## 4. Add an integration
Integrations → **Add Integration…**. Every integration starts **read-only**.

### SNMP device (switch, router, access point)
- Enable SNMP **v2c** on the device with a **read-only** community.
- Enter its address and the community string.
- Gives: clients from its ARP table, the switch port each device is on, subnets, interface traffic history.
- v2c sends the community string unencrypted. SNMP v3 is not supported yet.

### Ubiquiti UniFi
- In the UniFi console create an API key (Settings → Control Plane → Integrations).
- Enter the console address and the key; optionally the site name.
- Gives: clients (wired/wireless, the switch or AP each is attached to), infrastructure devices.
- **Read-only by design**: the official UniFi API has no documented blocking or QoS, and the app does not use the undocumented controller API.

### OpenWrt
- On the router: install `uhttpd-mod-ubus` and serve LuCI over **HTTPS**.
- Enter the address, user (`root` unless you created an rpcd account) and password.
- Gives: hosts, DHCP names, Wi-Fi clients with SSID, networks, firewall rules, configuration snapshots.
- With management enabled: block/unblock a device's internet access, and change SQM link shaping (needs `sqm-scripts` and an existing SQM queue).

### Certificate approval
Routers usually present a self-signed certificate. The first connection is refused and the integration shows the certificate's **SHA-256 fingerprint**. Compare it with the fingerprint shown on the router itself, then click **Trust This Certificate**. From then on only that certificate is accepted; if it changes, the connection is refused and a "certificate changed" alert is raised.

## 5. Making changes to the network
1. Access Control → **Enable Management…** for the integration (asks for Touch ID or your password).
2. Choose the action. A sheet shows what will change and on which device.
3. Authenticate. The app applies the change, reads the router back to confirm it, and writes the result to the audit log.

Results are reported as *done and confirmed*, *failed*, or *could not be confirmed* — never assumed.

| Action | Where | Undo |
|---|---|---|
| Block / pause a device | Access Control | Unblock (or wait for the pause to end) |
| Weekly access schedule | Access Control → Add Schedule… | Remove the schedule |
| Link shaping rates | QoS Manager → Change… | Roll Back to the previous values |
| Configuration snapshot | Reports → Back Up Now | — (read-only) |

Schedules are applied while the app is running, at each scan (about once a minute).

## 6. Signed, distributable build
Needs an Apple Developer Program membership.

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package.sh
```

```bash
xcrun notarytool submit build/NRVL-Network-0.1.0.dmg --keychain-profile <profile> --wait
```

```bash
xcrun stapler staple build/NRVL-Network-0.1.0.dmg
```

## 7. Where things are stored
| What | Where |
|---|---|
| Database (inventory, history, alerts, audit log) | `~/Library/Application Support/NRVL Network/nrvl.sqlite` |
| Encrypted configuration snapshots | `~/Library/Application Support/NRVL Network/Configuration Backups/` |
| Passwords, API keys, community strings, backup key | macOS Keychain, service `com.nrvl.network.integration` |

To remove everything: quit the app, delete the folder above, and delete the Keychain items of that service in Keychain Access.

## 8. Refresh the manufacturer list
```bash
Scripts/update-oui.sh
```
Downloads the public IEEE registry and rebuilds `Resources/oui.tsv`. Rebuild the app afterwards.

## 9. Troubleshooting
| Symptom | Cause and fix |
|---|---|
| Banner "Local Network access is off" | System Settings → Privacy & Security → Local Network → enable NRVL Network |
| macOS asks for Local Network again after a rebuild | Each ad-hoc build has a new signature; sign with a stable identity to avoid it |
| Many devices show "<manufacturer> device" | They announce no name over Bonjour and the router serves no reverse DNS; an OpenWrt or UniFi integration supplies names |
| Integration shows "certificate is not trusted yet" | Expected on first contact — see Certificate approval |
| SNMP integration times out | Wrong community string (v2c devices stay silent), SNMP disabled, or UDP 161 blocked |
| OpenWrt: "HTTP 404 from /ubus" | `uhttpd-mod-ubus` is not installed |
| A section says a feature is unsupported | The connected hardware has no documented way to do it; the text names the reason |
