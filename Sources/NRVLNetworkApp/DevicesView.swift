import AppKit
import NRVLCore
import NRVLDiscovery
import NRVLPersistence
import SwiftUI

struct DevicesView: View {
    @Bindable var model: InventoryModel

    var body: some View {
        VStack(spacing: 0) {
            if model.localNetworkDenied {
                Banner(symbol: "lock.trianglebadge.exclamationmark", color: .orange,
                       text: "Local Network access is off for NRVL Network, so it cannot look for devices. Turn it on in System Settings → Privacy & Security → Local Network. Until then only devices this Mac has already talked to are listed.")
            }
            if let error = model.errorMessage {
                Banner(symbol: "xmark.octagon", color: .red, text: error)
            }
            table
            Divider()
            statusLine
        }
        .searchable(text: $model.searchText, prompt: "Name, IP, MAC, manufacturer, type, tag or group")
        .inspector(isPresented: $model.showInspector) {
            Group {
                if let row = model.selectedRow {
                    DeviceDetailView(row: row, events: model.selectedEvents)
                } else {
                    ContentUnavailableView("No Device Selected", systemImage: "desktopcomputer")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.scan() }
                } label: {
                    if model.isScanning { ProgressView().controlSize(.small) } else { Label("Scan Now", systemImage: "arrow.clockwise") }
                }
                .disabled(model.isScanning)
                .keyboardShortcut("r")
                .help("Scan the local network now (⌘R)")
            }
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                    .help("Show or hide device details")
            }
        }
        .alert(editTitle, isPresented: Binding(get: { model.editing != nil }, set: { if !$0 { model.editing = nil } })) {
            TextField(editTitle, text: $model.editText)
            Button("Save") { Task { await model.commitEdit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(editHint)
        }
    }

    private var editTitle: String {
        switch model.editing?.field {
        case .tags: "Tags"
        case .group: "Group"
        default: "Name"
        }
    }

    private var editHint: String {
        switch model.editing?.field {
        case .tags: "Separate tags with commas. Leave empty to remove all."
        case .group: "A device belongs to one group. Leave empty to remove it."
        default: "Leave empty to go back to the discovered name."
        }
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                StatusDot(color: row.isOnline == true ? .green : .gray)
                    .help(stateText(row))
            }
            .width(14)
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 4) {
                    Text(row.name).foregroundStyle(row.nameIsInferred ? .secondary : .primary)
                    if row.device.isTrusted {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.nrvlAccent).help("Trusted")
                    }
                }
            }
            TableColumn("Type", value: \.kind) { row in
                Text(row.kind).foregroundStyle(row.classification?.confidence == .inferred ? .secondary : .primary)
            }
            TableColumn("IP Address", value: \.ipSort) { row in Text(row.ipv4).monospaced() }
            TableColumn("MAC Address", value: \.mac) { row in Text(row.mac).monospaced() }
            TableColumn("Manufacturer", value: \.vendor)
            TableColumn("Connection", value: \.connection).width(80)
            TableColumn("Interface", value: \.interface).width(70)
            TableColumn("First Seen", value: \.firstSeen) { row in
                Text(row.firstSeen, format: .dateTime.day().month().hour().minute())
            }
            TableColumn("Last Seen", value: \.lastSeen) { row in
                Text(row.lastSeen, format: .dateTime.day().month().hour().minute().second())
            }
        }
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            if let device = model.devices.first(where: { ids.contains($0.id) }) {
                Button("Rename…") { model.beginEditing(.customName, of: device) }
                Button("Edit Tags…") { model.beginEditing(.tags, of: device) }
                Button("Set Group…") { model.beginEditing(.group, of: device) }
                Button(device.isTrusted ? "Remove Trusted Mark" : "Mark as Trusted") {
                    Task { await model.setTrusted(!device.isTrusted, device) }
                }
                Divider()
                if let ip = device.ipv4 { Button("Copy IP Address") { copy(ip) } }
                Button("Copy MAC Address") { copy(device.mac.description) }
            }
        }
        .overlay {
            if model.devices.isEmpty {
                ContentUnavailableView(model.isScanning ? "Scanning…" : "No Devices Found",
                                       systemImage: "desktopcomputer",
                                       description: Text("Devices appear here once this Mac sees them on its network."))
            } else if model.rows.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 12) {
            Text("\(model.devices.count) devices")
            if let online = model.onlineCount { Text("\(online) online") }
            if let report = model.report {
                Text("Last scan \(report.date, format: .dateTime.hour().minute().second())")
                ForEach(report.sweeps.keys.sorted(), id: \.self) { subnet in
                    Text("\(subnet): \(sweepText(report.sweeps[subnet]!))")
                }
            } else {
                Text("Showing stored records — first scan in progress")
            }
            Spacer()
            if !model.hasManufacturerRegistry { Text("Manufacturer registry not bundled in this build") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func stateText(_ row: InventoryModel.Row) -> String {
        switch row.isOnline {
        case true?: "Online: in this Mac's neighbour table at the last scan. A device that just left can still show for a few minutes."
        case false?: "Not seen at the last scan."
        case nil: "Stored record; not scanned yet in this session."
        }
    }

    private func sweepText(_ outcome: SubnetSweep.Outcome) -> String {
        switch outcome {
        case .probed(let hosts): "\(hosts) addresses probed"
        case .permissionDenied: "probe blocked"
        case .skippedTooLarge: "too large to probe, passive only"
        case .failed(let reason): "probe failed (\(reason))"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct DeviceDetailView: View {
    let row: InventoryModel.Row
    let events: [ConnectionEvent]

    var body: some View {
        let device = row.device
        Form {
            Section {
                field("Name", row.name) { row.nameIsInferred ? Confidence.inferred.badge : nil }
                field("State", row.isOnline == true ? "Online" : row.isOnline == false ? "Not seen at last scan" : "Not scanned yet") {
                    row.isOnline == nil ? Freshness.historical.badge : Freshness.live.badge
                }
                if let type = row.classification {
                    LabeledContent("Type") {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 6) { Text(type.kind); type.confidence.badge }
                            Text(type.basis).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    field("Type", "Unknown — no evidence") { nil }
                }
                if device.isTrusted { field("Trusted", "Yes — marked by you") { nil } }
                if let group = device.group { field("Group", group) { nil } }
                if !device.tags.isEmpty { field("Tags", device.tags.joined(separator: ", ")) { nil } }
            }
            Section("Addresses") {
                field("IPv4", device.ipv4 ?? "Not seen", source: device.ipv4 == nil ? nil : "ARP table")
                ForEach(device.ipv6, id: \.self) { field("IPv6", $0, source: device.isThisMac ? "This Mac" : "Neighbour discovery") }
                field("MAC", row.mac, source: device.isThisMac ? "This Mac" : "ARP / neighbour table")
                if device.mac.isLocallyAdministered {
                    Text("This is a private (randomised) address. It can change, and it has no manufacturer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if device.integrationID != nil {
                Section("From the router integration") {
                    if let connection = device.connection { field("Connection", connection.rawValue.capitalized, source: "Integration") }
                    if let ssid = device.ssid { field("SSID", ssid, source: "Integration") }
                    if let uplink = device.uplink { field("Attached to", uplink, source: "Integration") }
                    if let vlan = device.vlan { field("VLAN", String(vlan), source: "Integration") }
                    if let blocked = device.isBlocked { field("Access", blocked ? "Blocked" : "Allowed", source: "Integration") }
                }
            }
            Section("Identity") {
                field("Hostname", device.hostname ?? "None reported", source: device.hostname == nil ? nil : device.isThisMac ? "This Mac"
                          : device.hostname!.hasSuffix(".local") ? "Bonjour" : "Reverse DNS")
                if let model = device.model { field("Model", model, source: "Bonjour") }
                field("Manufacturer", row.vendor.isEmpty ? "Not in registry" : row.vendor,
                      source: row.vendor.isEmpty || device.mac.isLocallyAdministered ? nil : "IEEE registry")
            }
            if !device.services.isEmpty {
                Section("Advertised services") {
                    Text(device.services.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("History") {
                field("Interface", device.interface) { nil }
                field("First seen", device.firstSeen.formatted(date: .abbreviated, time: .shortened)) { nil }
                field("Last seen", device.lastSeen.formatted(date: .abbreviated, time: .standard)) { nil }
                ForEach(events, id: \.self.date) { event in
                    field(event.kind.rawValue.capitalized, event.date.formatted(date: .abbreviated, time: .standard)) { nil }
                }
            }
            Section {
                Text(device.integrationID == nil
                     ? "Connection type, SSID, access point, VLAN and per-device traffic are not knowable from this Mac alone. They need a router integration."
                     : "Fields the integration did not report are left out rather than guessed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A value read directly from the network: shown with its source and a Confirmed badge.
    private func field(_ label: String, _ value: String, source: String?) -> some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
                if let source {
                    HStack(spacing: 4) {
                        Text(source).font(.caption2).foregroundStyle(.secondary)
                        Confidence.confirmed.badge
                    }
                }
            }
        }
    }

    private func field(_ label: String, _ value: String, badge: () -> Badge?) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
                badge()
            }
        }
    }
}

struct Banner: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.18))
    }
}
