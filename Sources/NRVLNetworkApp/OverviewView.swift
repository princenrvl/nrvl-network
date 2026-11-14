import Charts
import NRVLCore
import NRVLTelemetry
import SwiftUI

struct OverviewView: View {
    let telemetry: TelemetryModel
    let inventory: InventoryModel?
    var alerts: AlertsModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                healthCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)], spacing: 16) {
                    pingCard("Internet", symbol: "globe", target: TelemetryModel.internetTarget, window: telemetry.internet) {
                        if telemetry.internetChecks > 0 {
                            let share = Double(telemetry.internetReplies) / Double(telemetry.internetChecks)
                            metric("Reachable since \(telemetry.startedAt.formatted(date: .omitted, time: .shortened))",
                                   share.formatted(.percent.precision(.fractionLength(1))))
                        }
                    }
                    pingCard("Gateway", symbol: "wifi.router", target: telemetry.configuration.gateway, window: telemetry.gateway) {}
                    devicesCard
                    networkCard
                }
                throughputCard
                if let alerts {
                    Card("Active Alerts", symbol: "bell.badge", badge: Badge(text: "\(alerts.unacknowledged.count)", color: alerts.unacknowledged.isEmpty ? .green : .orange)) {
                        if alerts.unacknowledged.isEmpty { Text("No unacknowledged alerts.").foregroundStyle(.secondary) }
                        ForEach(alerts.unacknowledged.prefix(5)) { alert in
                            LabeledContent("\(alert.kind.title) — \(alert.subject)", value: alert.date.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }
                Text("Network-wide throughput and top bandwidth consumers need a router integration that reports per-client traffic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    // MARK: Cards

    private var healthCard: some View {
        let (title, detail, color): (String, String, Color) = switch telemetry.health {
        case .measuring: ("Measuring…", "Collecting the first samples.", .gray)
        case .healthy: ("Healthy", "Gateway and internet are answering with low loss.", .green)
        case .degraded(let why): ("Degraded", why, .orange)
        case .offline(let why): ("Offline", why, .red)
        }
        return Card {
            HStack(spacing: 12) {
                StatusDot(color: color).scaleEffect(1.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text(detail).foregroundStyle(.secondary)
                }
                Spacer()
                Freshness.live.badge
            }
        }
    }

    private func pingCard(_ title: String, symbol: String, target: String?, window: PingWindow,
                          @ViewBuilder extra: () -> some View) -> some View {
        Card(title, symbol: symbol, badge: target == nil ? nil : Freshness.live.badge) {
            if let target {
                metric("Address", target)
                metric("Latency", window.averageLatency.map(milliseconds) ?? "No reply")
                metric("Jitter", window.jitter.map(milliseconds) ?? "—")
                metric("Packet loss", window.lossFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                extra()
                Text("ICMP ping from this Mac, last \(window.samples.count) samples").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("This Mac has no default gateway.").foregroundStyle(.secondary)
            }
        }
    }

    private var devicesCard: some View {
        Card("Devices", symbol: "desktopcomputer", badge: inventory?.report == nil ? Freshness.historical.badge : Freshness.live.badge) {
            if let inventory {
                metric("Known", "\(inventory.devices.count)")
                metric("Online at last scan", inventory.onlineCount.map(String.init) ?? "Scanning…")
                metric("First seen in last 24 h", "\(inventory.recentlyDiscoveredCount)")
                let wired = inventory.devices.count { $0.connection == .wired }, wireless = inventory.devices.count { $0.connection == .wireless }
                if wired + wireless > 0 { metric("Wired / wireless (from integrations)", "\(wired) / \(wireless)") }
                Text("Devices this Mac can see on its own subnets").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Inventory unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    private var networkCard: some View {
        Card("This Mac's Connection", symbol: "network", badge: Confidence.confirmed.badge) {
            if let interface = telemetry.primaryInterface {
                metric("Interface", "\(interface.displayName ?? interface.name) (\(interface.name))")
                metric("IPv4", interface.ipv4 ?? "None")
                metric("Subnet", interface.subnet?.description ?? "—")
            } else {
                Text("No active network connection.").foregroundStyle(.secondary)
            }
            metric("DNS", telemetry.configuration.dnsServers.isEmpty ? "None" : telemetry.configuration.dnsServers.joined(separator: ", "))
        }
    }

    private var throughputCard: some View {
        Card("This Mac's Throughput", symbol: "arrow.up.arrow.down", badge: Freshness.live.badge) {
            if let latest = telemetry.throughput.last {
                HStack(spacing: 24) {
                    metric("Download", rate(latest.down))
                    metric("Upload", rate(latest.up))
                }
                Chart(telemetry.throughput) { point in
                    LineMark(x: .value("Time", point.id), y: .value("Bytes per second", point.down), series: .value("Direction", "Download"))
                        .foregroundStyle(by: .value("Direction", "Download"))
                    LineMark(x: .value("Time", point.id), y: .value("Bytes per second", point.up), series: .value("Direction", "Upload"))
                        .foregroundStyle(by: .value("Direction", "Upload"))
                }
                .chartForegroundStyleScale(["Download": Color.nrvlAccent, "Upload": Color.orange])
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let bytes = value.as(Double.self) { Text(rate(bytes)) } }
                    }
                }
                .frame(height: 160)
                Text("Traffic of this Mac's \(telemetry.configuration.primaryInterface ?? "primary") interface only, last 5 minutes. It is not the network's total.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Waiting for the second counter reading…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func metric(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit().textSelection(.enabled) }
    }

    private func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond).formatted(.byteCount(style: .binary)) + "/s"
    }
}

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var badge: Badge?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, badge: Badge? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Label(title, systemImage: symbol ?? "circle").font(.headline)
                    Spacer()
                    badge
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
