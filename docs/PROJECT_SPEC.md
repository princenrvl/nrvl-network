MASTER PRODUCT AND DEVELOPMENT SPECIFICATION
Project: NRVL NETWORK
Author: Prince NRVL
Native macOS and iOS Network Administration & Intelligence Platform

Your ROLE

Act as a Principal macOS Engineer, Network Architect, UI/UX Designer, Security Engineer and Senior Swift Developer.

Your mission is to design, architect and build a production-quality native macOS application for comprehensive monitoring, administration and management of networks that the user owns or is explicitly authorized to administer.

Do not build a superficial dashboard or a collection of mock screens. Build a functional network administration platform with real discovery, monitoring, integrations and administrative controls.

1. PRODUCT OBJECTIVE

Create a premium native macOS application that gives administrators complete visibility into their local network and supported network infrastructure.

The application must enable users to:

Discover connected devices.
Identify IP addresses, MAC addresses and manufacturers.
Understand network ranges, subnets and VLANs.
Monitor device activity and bandwidth.
Visualize network topology.
Manage device access.
Configure QoS and bandwidth policies.
Monitor network performance.
Identify suspicious or unexpected network changes.
Manage compatible routers, switches and access points.
Maintain historical records and administrative audit logs.
2. TECHNOLOGY STACK

Use:

Swift 6.
SwiftUI for the entire native interface.
MVVM or a clearly separated modular architecture.
SQLite for persistent local storage.
Swift Charts for analytics.
Network.framework for networking functionality.
NetworkExtension where appropriate and supported.
macOS Keychain for credentials and secrets.
Signed privileged helper only where genuinely necessary.
Apple's supported APIs and permissions.

Target modern macOS versions. Define the minimum supported macOS version based on the APIs selected.

The application must be a genuine macOS application, not Electron, a web wrapper or a browser-based dashboard.

3. CORE MODULES
A. Network Dashboard

Display:

Overall network health.
Internet connectivity.
Gateway status.
Total connected devices.
Wired and wireless device counts.
Upload/download throughput.
Network utilization.
Latency and packet loss.
Active alerts.
Top bandwidth-consuming devices.
Network uptime and historical performance.

Use real data. Never fabricate live statistics.

B. Device Discovery and Inventory

Discover devices using appropriate authorized methods, including:

Router and gateway APIs.
DHCP client information.
ARP and IPv6 neighbour information.
Subnet discovery.
Bonjour/mDNS.
SNMP where supported.
Network infrastructure telemetry.

For each device display:

Hostname.
MAC address.
IPv4 address.
IPv6 address.
Manufacturer.
Device type.
Connection type.
SSID where available.
Access point or switch.
VLAN.
Subnet.
First discovered.
Last seen.
Current connection state.
Download speed.
Upload speed.
Historical traffic.

Allow device renaming, tagging, grouping and trusted-device classification.

Clearly distinguish confirmed information from inferred information.

C. Network and Subnet Manager

Display:

Network interfaces.
Private and public IP information.
CIDR ranges.
Subnet masks.
Default gateways.
DHCP ranges.
DNS servers.
VLANs.
Static IP assignments.
Address conflicts.
IPv4 and IPv6 information.

Provide an interactive subnet visualization and IP allocation view.

D. Network Topology

Build an interactive topology map.

Visualize:

Internet → Gateway → Router → Switches → Access Points → Devices.

Support:

Device relationships.
Network segmentation.
VLAN visualization.
Link status.
Network hierarchy.
Device details on selection.

Do not invent relationships that cannot be established from available telemetry.

E. Traffic Monitoring

Provide real-time and historical traffic analytics.

Display:

Upload/download throughput.
Per-device bandwidth.
Application categories where supported.
Protocol distribution.
Destination IPs where available.
Port information.
Traffic history.
Top bandwidth consumers.
Unusual traffic patterns.

Use gateway telemetry, SNMP, flow exports or supported monitoring integrations for network-wide visibility.

Do not claim that a Mac can observe all traffic on a switched or wireless network merely through local packet capture.

F. Device Access Control

Implement administrative controls through supported gateway and infrastructure integrations.

Features:

Block device.
Unblock device.
Pause access.
Restore access.
Allowlist devices.
Quarantine supported devices.
Assign device groups.
Schedule access.
Apply group policies.

Before implementing any action, verify that the connected infrastructure supports it.

Do not use wireless deauthentication, ARP spoofing, unauthorized interception or other attack techniques to disconnect devices.

G. QoS and Bandwidth Management

Build a dedicated QoS Manager.

Support, where the gateway permits:

Per-device upload limits.
Per-device download limits.
Device prioritization.
Application-category prioritization.
Traffic shaping.
Bandwidth allocation.
Scheduling.
Gaming traffic prioritization.
Video conferencing prioritization.
Latency-sensitive traffic policies.
Queue statistics.
Latency, jitter and packet-loss monitoring.

Allow policy creation, modification, preview, activation and rollback.

H. Firewall and Security Center

Provide supported administrative capabilities:

Firewall rule visibility.
Access policies.
Network segmentation visibility.
DNS policy management.
New device alerts.
Duplicate IP detection.
Unexpected gateway configuration changes.
Suspicious DNS patterns.
Device inventory changes.
Security event history.

Never claim certainty where only an anomaly has been detected.

I. Monitoring and Alerts

Implement:

New device notifications.
Device disconnection notifications.
Gateway offline alerts.
Bandwidth threshold alerts.
Latency alerts.
Packet-loss alerts.
IP conflicts.
Network configuration changes.
Security-related alerts.

Support notification preferences and alert history.

J. Reports and History

Provide:

Daily network reports.
Weekly and monthly usage.
Per-device consumption.
Historical bandwidth graphs.
Device connection history.
Network uptime reports.
QoS policy reports.
Security event reports.

Support CSV and PDF exports.

4. HARDWARE INTEGRATION ARCHITECTURE

Create a modular adapter architecture.

Initial targets:

Ubiquiti UniFi.
OpenWrt.
MikroTik RouterOS.
pfSense.
OPNsense.
Generic SNMP-compatible infrastructure.

Each integration must implement a common interface for:

Authentication.
Device discovery.
Client inventory.
Network information.
Traffic statistics.
Access control.
QoS capabilities.
Firewall capabilities.
Configuration retrieval.
Supported administrative actions.

Do not assume every router supports every capability.

Display unsupported features explicitly.

Use official APIs and documented protocols wherever available. Never silently fall back to undocumented destructive operations.

5. NATIVE MACOS EXPERIENCE

Design a polished, professional macOS application.

Visual direction:

Dark-first interface.
Premium network operations center aesthetic.
Clean typography.
Native macOS interactions.
Sidebar navigation.
Resizable panels.
Detailed tables.
Interactive network maps.
Live charts.
Context menus.
Search and filtering.
Keyboard shortcuts.
Native notifications.

Sidebar:

Overview
Devices
Topology
Networks & Subnets
Traffic Analytics
QoS Manager
Access Control
Firewall
Security Center
Monitoring
Reports
Integrations
Settings

Every module must have a functional purpose.

Avoid decorative charts with fake data.

6. SECURITY AND PRIVILEGES

Security is a foundational requirement.

Request minimum necessary macOS permissions.
Use Keychain for credentials.
Encrypt sensitive locally stored information.
Never store router passwords in plain text.
Use a narrowly scoped privileged helper only when necessary.
Do not run the entire application as root.
Require administrator authentication for sensitive actions.
Provide confirmation before disruptive operations.
Maintain immutable-style, append-only audit records.
Record who performed an action, what changed and whether it succeeded.
Support configuration backups and rollback.
Restrict integrations to explicitly configured infrastructure.
Use secure transport and certificate validation.

All network administration must be restricted to authorized networks and infrastructure.

7. DATA ARCHITECTURE

Create separate layers:

Presentation.
Application services.
Network discovery.
Network telemetry.
Infrastructure adapters.
Access-control engine.
QoS engine.
Security engine.
Persistence.
Notifications.
Audit logging.

Use asynchronous operations and avoid blocking the main UI thread.

Provide graceful handling of unavailable devices, API failures, timeouts and permission errors.

Design the system to support multiple network sites in the future.

8. USER EXPERIENCE REQUIREMENTS

The application must:

Show real-time updates without unnecessary refreshes.
Clearly distinguish live, historical and estimated data.
Explain why an action is unavailable.
Preview configuration changes.
Require confirmation for disruptive operations.
Provide rollback wherever supported.
Show connection status for every integration.
Work in read-only mode when management permissions are unavailable.
Support offline access to historical records.
9. DEVELOPMENT PROCESS

Do not attempt to build the entire application in one untested step.

Follow these phases:

Phase 1: Product architecture and macOS project setup.

Phase 2: Native application shell, navigation and design system.

Phase 3: Local network discovery and device inventory.

Phase 4: Subnet and network topology visualization.

Phase 5: Router integration framework.

Phase 6: UniFi and OpenWrt integrations.

Phase 7: Traffic monitoring and analytics.

Phase 8: Access control and device administration.

Phase 9: QoS and bandwidth management.

Phase 10: Security monitoring and notifications.

Phase 11: Reporting, historical data and audit logs.

Phase 12: Testing, optimization, signing and packaging.

At every phase:

Write production-quality code.
Compile the application.
Test actual functionality.
Fix errors before moving forward.
Document architectural decisions.
Avoid placeholder implementations masquerading as completed features.
10. TESTING

Create unit tests, integration tests and UI tests.

Test against:

Simulated network environments.
Real authorized test networks.
Supported router integrations.
Disconnected gateways.
Incorrect credentials.
Missing permissions.
API timeouts.
Multiple subnets.
IPv4 and IPv6.
Unsupported hardware capabilities.
Failed configuration changes.
Rollback scenarios.

Never test disruptive actions against networks without explicit authorization.

11. REQUIRED DELIVERABLES

Deliver:

Complete macOS Xcode project.
Compilable Swift source code.
Native SwiftUI interface.
Documented architecture.
Router adapter framework.
Working network discovery.
Working device inventory.
Working dashboard.
Real network telemetry.
Supported administrative actions.
QoS implementation for compatible infrastructure.
SQLite database and migrations.
Automated test suite.
Installation and configuration guide.
Security and permissions documentation.
Signed distributable application when signing credentials are available.
12. IMPORTANT EXECUTION INSTRUCTIONS

Start by inspecting the available development environment.

First deliver a detailed architecture and a working application skeleton.

Then implement functionality incrementally.

Prioritize a working device inventory, accurate network visibility and real router integration over a large number of incomplete features.

Never fabricate functionality, telemetry or device information.

Never assume administrator privileges on macOS automatically grant control over the router or other network clients.

The final goal is a reliable, secure, premium-grade macOS Network Command Center that an administrator can genuinely use to understand and manage their authorized network.