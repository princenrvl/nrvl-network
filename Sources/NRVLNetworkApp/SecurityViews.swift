import NRVLCore
import SwiftUI

private typealias Alert = NRVLCore.Alert   // SwiftUI has an unrelated, deprecated Alert

private func color(_ severity: Alert.Severity) -> Color {
    switch severity {
    case .info: .nrvlAccent
    case .warning: .orange
    case .critical: .red
    }
}

private struct AlertRow: View {
    let alert: Alert
    let acknowledge: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: color(alert.kind.severity)).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.kind.title) — \(alert.subject)").fontWeight(alert.acknowledged ? .regular : .semibold)
                Text(alert.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text(alert.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if !alert.acknowledged { Button("Acknowledge", action: acknowledge) }
        }
        .padding(.vertical, 3)
    }
}

struct MonitoringView: View {
    @Bindable var model: AlertsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("Alerts", symbol: "bell.badge", badge: Badge(text: "\(model.unacknowledged.count) new", color: model.unacknowledged.isEmpty ? .secondary : .orange)) {
                    if model.alerts.isEmpty {
                        Text("No alerts yet. Conditions are checked after every scan, about once a minute, while the app is running.").foregroundStyle(.secondary)
                    } else {
                        Button("Acknowledge All") { Task { await model.acknowledge(nil) } }.disabled(model.unacknowledged.isEmpty)
                        ForEach(model.alerts.prefix(200)) { alert in
                            AlertRow(alert: alert) { Task { await model.acknowledge(alert.id) } }
                        }
                    }
                }
                Card("Preferences", symbol: "slider.horizontal.3") {
                    Toggle("Show macOS notifications", isOn: $model.settings.notifications)
                    LabeledContent("Latency alert above") {
                        TextField("ms", value: $model.settings.latencyMilliseconds, format: .number).frame(width: 70); Text("ms")
                    }
                    LabeledContent("Packet-loss alert above") {
                        TextField("%", value: $model.settings.lossPercent, format: .number).frame(width: 70); Text("%")
                    }
                    LabeledContent("This Mac's bandwidth above") {
                        TextField("Mbit/s", value: $model.settings.bandwidthMbps, format: .number).frame(width: 70); Text("Mbit/s (0 = off)")
                    }
                    Divider()
                    ForEach(Alert.Kind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { !model.settings.disabled.contains(kind) },
                            set: { if $0 { model.settings.disabled.remove(kind) } else { model.settings.disabled.insert(kind) } }))
                    }
                    Text("An alert is raised when a condition begins, not repeatedly while it lasts. Per-device bandwidth alerts need a router integration that reports per-client traffic.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .task { await model.load() }
    }
}

struct SecurityView: View {
    let alerts: AlertsModel
    let inventory: InventoryModel
    let integrations: IntegrationsModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let events = alerts.alerts.filter(\.kind.isSecurity)
                Card("Security Events", symbol: "exclamationmark.shield", badge: Badge(text: "Observations, not verdicts", color: .secondary)) {
                    if events.isEmpty {
                        Text("Nothing recorded. Each entry here is something the app observed, with the evidence; it is up to you to decide whether it is expected.").foregroundStyle(.secondary)
                    }
                    ForEach(events.prefix(100)) { alert in
                        AlertRow(alert: alert) { Task { await alerts.acknowledge(alert.id) } }
                    }
                }
                let unknown = inventory.allRows.filter { !$0.device.isTrusted && !$0.device.isThisMac }
                Card("Devices Not Marked as Trusted", symbol: "questionmark.diamond", badge: Badge(text: "\(unknown.count)", color: unknown.isEmpty ? .green : .orange)) {
                    if unknown.isEmpty { Text("Every known device is marked as trusted.").foregroundStyle(.secondary) }
                    ForEach(unknown.prefix(50)) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.name)
                                Text([row.ipv4, row.mac, row.vendor].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("first seen \(row.firstSeen.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            Button("Trust") { Task { await inventory.setTrusted(true, row.device) } }
                        }
                    }
                    Text("\"Not trusted\" only means you have not marked it yet — it is not a finding.").font(.caption2).foregroundStyle(.secondary)
                }
                if let integrations, !integrations.integrations.isEmpty {
                    Card("Integration Connections", symbol: "lock") {
                        ForEach(integrations.integrations) { integration in
                            LabeledContent(integration.name) {
                                Text(integration.kind == .snmp ? "SNMP v2c — unencrypted" : integration.pinnedCertificate == nil ? "HTTPS — system-trusted certificate" : "HTTPS — certificate pinned")
                            }
                        }
                    }
                }
                Card("What Is Checked", symbol: "checklist") {
                    ForEach(Alert.Kind.allCases.filter(\.isSecurity)) { kind in
                        LabeledContent(kind.title) { Badge(text: alerts.settings.disabled.contains(kind) ? "Off" : "On", color: alerts.settings.disabled.contains(kind) ? .secondary : .green) }
                    }
                    LabeledContent("Suspicious DNS query patterns") { Badge(text: "Unavailable", color: .secondary) }
                    Text("Spotting unusual DNS queries needs the query log of your router or DNS server. None of the connected integrations exposes one, so this check is not performed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .task { await alerts.load() }
    }
}

struct FirewallView: View {
    let integrations: IntegrationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if integrations.integrations.isEmpty {
                    Card("Firewall", symbol: "flame") {
                        Text("Firewall rules live on your router. Add a router integration that can read them to see them here.").foregroundStyle(.secondary)
                    }
                }
                ForEach(integrations.integrations) { integration in
                    let status = integrations.statuses[integration.id]
                    Card("Firewall Rules — \(integration.name)", symbol: "flame", badge: Badge(text: "Read-only", color: .secondary)) {
                        if let rules = status?.firewallRules {
                            if rules.isEmpty { Text("The device reports no rules.").foregroundStyle(.secondary) }
                            ForEach(rules) { rule in
                                HStack(alignment: .firstTextBaseline) {
                                    Badge(text: rule.action, color: rule.action.uppercased() == "ACCEPT" ? .green : .red)
                                    VStack(alignment: .leading) {
                                        Text(rule.name).strikethrough(!rule.enabled)
                                        Text(rule.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !rule.enabled { Badge(text: "Disabled", color: .secondary) }
                                    if rule.name.hasPrefix("nrvl-block-") { Badge(text: "Created by NRVL Network", color: .nrvlAccent) }
                                }
                            }
                            Text("Shown as the device reports them, in its order. Rules are changed only through Access Control, which adds or removes its own clearly named block rules.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if case .unsupported(let why)? = status?.capabilities[.firewall] {
                            Text(why).foregroundStyle(.secondary)
                        } else {
                            Text(status?.error?.localizedDescription ?? "Not read yet — rules are fetched with the next scan.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
        .task { await integrations.refresh() }
    }
}
