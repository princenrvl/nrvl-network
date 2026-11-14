# NRVL Network — Security and Permissions

How the app protects your network, your credentials and its own records, and what it does not protect against.

## 1. Principles
- **Authorised networks only.** The app talks to devices on the subnets this Mac is attached to, and to infrastructure you configured explicitly. It never contacts a host an integration did not name.
- **No attack techniques.** No ARP spoofing, deauthentication, interception or packet capture. Devices are blocked only by asking a router through its documented interface.
- **Nothing is assumed.** Capabilities are probed per device. A change is reported as successful only after the router, read back, shows the requested state.
- **Least privilege.** The app runs as you. It has no privileged helper, never asks for an administrator password, and does not run anything as root.

## 2. macOS permissions
| Permission | Used for | Requested |
|---|---|---|
| Local Network | Device discovery (ARP probing, Bonjour), gateway ping | First scan |
| Notifications | Posting alerts | First alert, if notifications are enabled |
| Incoming connections (firewall prompt) | NetFlow listener on UDP 2055 | Only when you click Start Listening |
| Touch ID / account password | Confirming every change to the network | At each change |

Not requested: Location, Full Disk Access, Accessibility, Screen Recording, administrator rights.

The app is not sandboxed: it reads the kernel's ARP and neighbour tables, which App Sandbox does not reliably permit. It is built with the Hardened Runtime.

## 3. What the app sends on your network
| Traffic | Purpose | Notes |
|---|---|---|
| One 1-byte UDP datagram to port 9 of each address on attached private subnets up to /22 | Makes this Mac's kernel resolve live hosts | At most ~1,600 packets/s; once a minute. Public ranges and larger subnets are never probed |
| ICMP echo to the gateway and to 1.1.1.1 | Latency and loss | One each every 2 s |
| mDNS / DNS-SD queries, reverse DNS | Names, services, models | Through the system resolver; the app never connects to the devices found |
| SNMP v2c GET / GETBULK | Reading configured devices | Read-only; the client has no SET |
| HTTPS to configured UniFi consoles and OpenWrt routers | Reading, and for OpenWrt the changes you confirm | Pinned certificate, see §5 |
| HTTPS to api.ipify.org | Your public IP | Only when you click Look Up |

## 4. Credentials and stored data
- **Secrets** (passwords, API keys, SNMP community strings, the backup encryption key) are stored in the macOS Keychain: accessible only while the Mac is unlocked, this device only, not synchronised to iCloud. They are never written to the database, to logs or to exports.
- **The database** holds inventory, history, alerts, policies and the audit log, but no secrets. It is not separately encrypted; it relies on FileVault and your account's file permissions.
- **Configuration snapshots** contain router secrets (for example Wi-Fi keys), so they are encrypted with AES-256-GCM before being written, with file mode 0600. Decrypting one for export requires authentication and is recorded in the audit log. A file altered on disk fails to decrypt.
- **CSV exports** neutralise cells that a spreadsheet would run as a formula, because device names come from the network.

## 5. Transport security
- HTTPS only for UniFi and OpenWrt. Certificate validation is never switched off.
- A certificate the system does not already trust is refused until you approve its SHA-256 fingerprint. After approval, only that exact certificate is accepted — a different one is refused even if a public authority signed it — and a "certificate changed" alert is raised.
- Requests to any host other than the configured one are refused.
- **SNMP v2c is unencrypted.** The community string and all data cross the network in clear text. Use a read-only community on a network you trust. SNMP v3 is not implemented.

## 6. Controls on changes
Every change to the network goes through the same steps:

1. **Read-only by default.** A new integration cannot change anything until you enable management for it (authenticated, logged).
2. **Capability check.** If the device, firmware or account cannot do it, the control is unavailable and says why.
3. **Protected targets.** This Mac and the default gateway cannot be blocked.
4. **Preview and confirmation.** A sheet states what will change and where.
5. **Authentication.** Touch ID, Apple Watch or your account password. A Mac with no password set cannot make changes.
6. **Router-side rollback.** OpenWrt changes are applied with the router's own 30-second rollback and then confirmed, so a change that cuts the connection reverts by itself.
7. **Verification.** The router is read back. A mismatch is reported as "could not be confirmed", not as success.
8. **Audit.** The attempt is recorded whatever the result. If the audit record cannot be written, the change is reported as failed.

On OpenWrt the app touches only firewall rules it created (named `nrvl-block-<mac>`) and the enabled/download/upload values of existing SQM queues.

## 7. Audit log
Records who (macOS user, or the policy that triggered it), what, the target, before/after state and the outcome: app launches, integrations added/removed, certificates approved, management toggled, every block/unblock/shaping attempt, policies, backups created and decrypted.

- Updates and deletes are rejected by database triggers.
- Each entry is hash-chained to the previous one; Settings and Reports show whether the chain is intact.

## 8. Alerts are observations
Security Center reports what was observed and the evidence — a new device, an address that switches between devices, a gateway whose MAC changed, changed DNS servers or firewall rules. It names the innocent explanations alongside the suspicious ones and never states that an attack occurred.

## 9. Known limits
| Limit | Consequence |
|---|---|
| The audit chain cannot detect removal of the newest entries or replacement of the whole database file by someone with access to your account | It is tamper-evident against edits, not a remote write-once log |
| Authentication proves the logged-in user's presence, not membership of the admin group | Any user of this macOS account can make changes after authenticating |
| The database is not encrypted at rest by the app | Protect it with FileVault |
| SNMP v2c only | See §5 |
| "Online" reflects this Mac's neighbour table | A device that just left can show for a few minutes |
| UniFi and OpenWrt adapters have been run only against simulated devices | Try the OpenWrt write actions on a non-critical router first |
| Ad-hoc signed builds | No Developer ID or notarisation until a signing identity is supplied |
| Suspicious DNS-query detection | Not performed: no connected integration exposes a DNS query log |

## 10. Reporting a problem
Known issues are listed in [PROGRESS.md](PROGRESS.md). For a security problem, do not open a public issue — follow the [security policy](../SECURITY.md).
