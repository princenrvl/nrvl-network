import NRVLCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarSection.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) { StorageStatusBar(storage: model.storage) }
        } detail: {
            let section = model.selection ?? .overview
            Group {
                switch section {
                case .overview:
                    OverviewView(telemetry: model.telemetry, inventory: model.inventory, alerts: model.alerts)
                case .devices:
                    withInventory { DevicesView(model: $0) }
                case .topology:
                    withInventory { TopologyView(telemetry: model.telemetry, inventory: $0, openDevice: openDevice) }
                case .networks:
                    NetworksView(telemetry: model.telemetry, inventory: model.inventory, integrations: model.integrations, openDevice: openDevice)
                case .traffic:
                    if let traffic = model.traffic, let inventory = model.inventory {
                        TrafficView(model: traffic, inventory: inventory, integrations: model.integrations, telemetry: model.telemetry)
                    } else {
                        ProgressView()
                    }
                case .qos:
                    if let qos = model.qos { QoSView(model: qos, telemetry: model.telemetry) } else { ProgressView() }
                case .accessControl:
                    if let access = model.access { AccessControlView(model: access) } else { ProgressView() }
                case .firewall:
                    if let integrations = model.integrations { FirewallView(integrations: integrations) } else { ProgressView() }
                case .security:
                    if let alerts = model.alerts, let inventory = model.inventory {
                        SecurityView(alerts: alerts, inventory: inventory, integrations: model.integrations)
                    } else {
                        ProgressView()
                    }
                case .monitoring:
                    if let alerts = model.alerts { MonitoringView(model: alerts) } else { ProgressView() }
                case .reports:
                    if let reports = model.reports { ReportsView(model: reports) } else { ProgressView() }
                case .integrations:
                    if let integrations = model.integrations { IntegrationsView(model: integrations) } else { ProgressView() }
                case .settings:
                    SettingsView(model: model)
                }
            }
            .navigationTitle(section.title)
        }
    }
}

extension RootView {
    private func openDevice(_ id: Device.ID) {
        model.inventory?.selection = id
        model.selection = .devices
    }

    /// Sections that need the database show its state until it is ready.
    @ViewBuilder
    private func withInventory(@ViewBuilder _ content: (InventoryModel) -> some View) -> some View {
        if let inventory = model.inventory {
            content(inventory)
        } else if case .failed = model.storage {
            ContentUnavailableView("Inventory Unavailable", systemImage: "externaldrive.badge.xmark",
                                   description: Text("The database could not be opened. See Settings → Storage."))
        } else {
            ProgressView()
        }
    }
}

struct StorageStatusBar: View {
    let storage: AppModel.Storage

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: color)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var color: Color {
        switch storage {
        case .opening: .gray
        case .ready(_, _, nil): .green
        case .ready, .failed: .red
        }
    }

    private var text: String {
        switch storage {
        case .opening: "Opening database…"
        case .ready(_, _, nil): "Storage ready"
        case .ready(_, _, let broken?): "Audit log altered at entry \(broken)"
        case .failed: "Storage unavailable"
        }
    }
}
