import NRVLCore
import NRVLServices
import SwiftUI

struct NetworksView: View {
    let telemetry: TelemetryModel
    let inventory: InventoryModel?
    let integrations: IntegrationsModel?
    /// Jumps to the Devices section with this device selected.
    let openDevice: (Device.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                interfacesCard
                routingCard
                if let conflicts = inventory?.report?.conflicts, !conflicts.isEmpty { conflictsCard(conflicts) }
                ForEach(lanInterfaces) { allocationCard($0) }
                integrationNetworksCard
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var integrationNetworksCard: some View {
        let reported = (integrations?.integrations ?? []).flatMap { integration in
            (integrations?.statuses[integration.id]?.networks ?? []).map { (integration.name, $0) }
        }
        if reported.isEmpty {
            Text("DHCP ranges, VLANs and static IP assignments are held by the router. Networks appear here once an integration that reports them is connected.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Card("Networks Reported by Integrations", symbol: "rectangle.3.group", badge: Confidence.confirmed.badge) {
                ForEach(Array(reported.enumerated()), id: \.offset) { _, item in
                    LabeledContent("\(item.1.name) — \(item.0)") {
                        Text([item.1.cidr, item.1.vlan.map { "VLAN \($0)" }, item.1.dhcpRange.map { "DHCP \($0)" }]
                            .compactMap { $0 }.joined(separator: " · ")).monospaced()
                    }
                }
                Text("VLAN and DHCP details are shown only where the integration reports them.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var lanInterfaces: [NetworkInterface] {
        telemetry.interfaces.filter { $0.isUp && !$0.isLoopback && !$0.isPointToPoint && $0.subnet != nil }
    }

    private var interfacesCard: some View {
        Card("Interfaces of This Mac", symbol: "cable.connector", badge: Confidence.confirmed.badge) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["", "Interface", "IPv4", "Subnet", "Mask", "MAC", "IPv6"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(telemetry.interfaces.filter { !$0.isLoopback && ($0.ipv4 != nil || !$0.ipv6.isEmpty) }) { interface in
                    GridRow {
                        StatusDot(color: interface.isUp ? .green : .gray)
                        Text("\(interface.displayName ?? "—") (\(interface.name))")
                        Text(interface.ipv4 ?? "—").monospaced()
                        Text(interface.subnet?.description ?? "—").monospaced()
                        Text(interface.netmask ?? "—").monospaced()
                        Text(interface.mac?.description ?? "—").monospaced()
                        Text(interface.ipv6.isEmpty ? "—" : interface.ipv6.joined(separator: "\n")).monospaced().font(.caption)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private var routingCard: some View {
        Card("Routing and DNS", symbol: "arrow.triangle.branch", badge: Confidence.confirmed.badge) {
            LabeledContent("Default gateway", value: telemetry.configuration.gateway ?? "None")
            LabeledContent("Primary interface", value: telemetry.configuration.primaryInterface ?? "None")
            LabeledContent("DNS servers", value: telemetry.configuration.dnsServers.isEmpty ? "None" : telemetry.configuration.dnsServers.joined(separator: ", "))
            LabeledContent("Public IP address") {
                switch telemetry.publicIP {
                case .notRequested:
                    Button("Look Up") { Task { await telemetry.lookUpPublicIP() } }
                        .help("Asks api.ipify.org, an outside service, which address your network appears as. Nothing else is sent.")
                case .loading: ProgressView().controlSize(.small)
                case .known(let address): Text(address).monospaced().textSelection(.enabled)
                case .failed(let reason): Text(reason).foregroundStyle(.red)
                }
            }
        }
    }

    private func conflictsCard(_ conflicts: [AddressConflict]) -> some View {
        Card("Possible Address Conflicts", symbol: "exclamationmark.triangle", badge: Badge(text: "Anomaly", color: .orange)) {
            ForEach(conflicts) { conflict in
                LabeledContent(conflict.ip) { Text(conflict.macs.map(\.description).joined(separator: "  ↔  ")).monospaced() }
            }
            Text("These addresses switched back and forth between different devices in the last 10 minutes. That usually means two devices are configured with the same address, but a failover pair behaves the same way.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func allocationCard(_ interface: NetworkInterface) -> some View {
        if let subnet = interface.subnet {
            Card("IP Allocation — \(subnet.description) on \(interface.name)", symbol: "square.grid.3x3",
                 badge: inventory?.report == nil ? Freshness.historical.badge : Freshness.live.badge) {
                if let hosts = subnet.hostAddresses, hosts.count <= 1022, let inventory {
                    let byAddress = Dictionary(inventory.allRows.compactMap { row in IPv4.parse(row.ipv4).map { ($0, row) } },
                                               uniquingKeysWith: { first, _ in first })
                    let used = hosts.filter { byAddress[$0] != nil }.count
                    Text("\(used) of \(hosts.count) addresses seen in use").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 3)], spacing: 3) {
                        ForEach(Array(hosts), id: \.self) { address in
                            AddressCell(address: address, row: byAddress[address],
                                        isGateway: IPv4.string(address) == telemetry.configuration.gateway, open: openDevice)
                        }
                    }
                    HStack(spacing: 14) {
                        legend(.green, "Online"); legend(.gray, "Known, not seen at last scan")
                        legend(.nrvlAccent, "This Mac"); legend(.orange, "Gateway"); legend(.clear, "No device seen")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\"No device seen\" does not prove an address is free: a device that never talks to this Mac stays invisible.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("This subnet is too large to draw address by address.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4)))
                .frame(width: 12, height: 12)
            Text(text)
        }
    }
}

private struct AddressCell: View {
    let address: UInt32
    let row: InventoryModel.Row?
    let isGateway: Bool
    let open: (Device.ID) -> Void

    var body: some View {
        let color: Color = row == nil ? .clear
            : row!.device.isThisMac ? .nrvlAccent
            : isGateway ? .orange
            : row!.isOnline == true ? .green : .gray
        Text("\(address & 0xFF)")
            .font(.caption2.monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(color.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.25)))
            .foregroundStyle(row == nil ? .secondary : .primary)
            .help(row.map { "\(IPv4.string(address)) — \($0.name)" } ?? "\(IPv4.string(address)) — no device seen")
            .onTapGesture { if let row { open(row.id) } }
            .accessibilityLabel(row.map { "\(IPv4.string(address)), \($0.name)" } ?? "\(IPv4.string(address)), no device seen")
    }
}
