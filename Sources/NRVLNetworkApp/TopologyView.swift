import NRVLCore
import NRVLTelemetry
import SwiftUI

/// Draws only what this Mac can prove: its default route, and which devices share each of its subnets.
/// Which switch port or access point a device hangs off is unknown without a router integration, so
/// devices are grouped per subnet rather than wired to anything.
struct TopologyView: View {
    let telemetry: TelemetryModel
    let inventory: InventoryModel
    let openDevice: (Device.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                node("Internet", detail: TelemetryModel.internetTarget + " answers pings", symbol: "globe",
                     color: linkColor(telemetry.internet))
                link(telemetry.internet, label: "default route")
                gatewayNode
                ForEach(groups, id: \.interface) { group in
                    link(group.isPrimary ? telemetry.gateway : nil, label: "same subnet")
                    subnetGroup(group)
                }
                Text("Links shown: this Mac's default route and shared subnets. Switch ports, access points, VLANs and Wi-Fi associations need a router integration or SNMP/LLDP (Phases 5–6); until then nothing is drawn for them.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private struct SubnetGroup {
        let interface: String
        let title: String
        let isPrimary: Bool
        let rows: [InventoryModel.Row]
    }

    private var gatewayRow: InventoryModel.Row? {
        inventory.allRows.first { !$0.ipv4.isEmpty && $0.ipv4 == telemetry.configuration.gateway }
    }

    private var groups: [SubnetGroup] {
        let rows = inventory.allRows.filter { $0.id != gatewayRow?.id }
        return Dictionary(grouping: rows, by: \.interface).map { name, rows in
            let interface = telemetry.interfaces.first { $0.name == name }
            return SubnetGroup(interface: name,
                               title: "\(interface?.subnet?.description ?? "Subnet") · \(interface?.displayName ?? name)",
                               isPrimary: name == telemetry.configuration.primaryInterface,
                               rows: rows.sorted { $0.ipSort < $1.ipSort })
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.interface) < ($1.isPrimary ? 0 : 1, $1.interface) }
    }

    @ViewBuilder
    private var gatewayNode: some View {
        if let address = telemetry.configuration.gateway {
            node(gatewayRow?.name ?? "Gateway", detail: address, symbol: "wifi.router", color: linkColor(telemetry.gateway))
                .onTapGesture { if let id = gatewayRow?.id { openDevice(id) } }
                .help("This Mac's default gateway. Whether it is also the router, modem or firewall is not known from here.")
        } else {
            node("No Gateway", detail: "This Mac has no default route", symbol: "wifi.router", color: .red)
        }
    }

    private func subnetGroup(_ group: SubnetGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(group.title, systemImage: "rectangle.connected.to.line.below").font(.headline)
                Spacer()
                Badge(text: "Attachment unknown", color: .secondary)
                    .help("These devices share this subnet with this Mac. How each one is physically or wirelessly attached is not visible from here.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(group.rows) { row in
                    Button { openDevice(row.id) } label: { DeviceChip(row: row) }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private func node(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.6)))
        .contentShape(Rectangle())
    }

    /// A vertical link. With a ping window it is coloured by reachability and shows latency; without one it is neutral.
    private func link(_ window: PingWindow?, label: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(window.map(linkColor) ?? Color.secondary.opacity(0.5)).frame(width: 2, height: 34)
            Text(window?.averageLatency.map { "\(label) · \(String(format: "%.1f ms", $0 * 1000))" } ?? label)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func linkColor(_ window: PingWindow) -> Color {
        switch window.lossFraction {
        case nil: .gray
        case 1?: .red
        case let loss? where loss > 0.05: .orange
        default: .green
        }
    }
}

private struct DeviceChip: View {
    let row: InventoryModel.Row

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceSymbol(row.classification?.kind)).frame(width: 22)
                .foregroundStyle(row.device.isThisMac ? Color.nrvlAccent : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).foregroundStyle(row.nameIsInferred ? .secondary : .primary)
                Text(row.ipv4.isEmpty ? row.mac : row.ipv4).font(.caption2.monospaced()).foregroundStyle(.secondary)
                if let uplink = row.device.uplink {   // reported by an integration, so it is evidence
                    Text("↳ \(uplink)").font(.caption2).foregroundStyle(Color.nrvlAccent).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            StatusDot(color: row.isOnline == true ? .green : .gray)
        }
        .padding(8)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .help(row.classification.map { "\($0.kind) — \($0.basis)" } ?? "Type unknown")
    }
}
