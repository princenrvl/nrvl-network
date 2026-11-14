import Foundation

/// The 13 sidebar sections, in PROJECT_SPEC.md §5 order.
enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, devices, topology, networks, traffic
    case qos, accessControl, firewall, security
    case monitoring, reports
    case integrations, settings

    var id: Self { self }

    enum Group: String, CaseIterable, Identifiable {
        case network = "Network", administration = "Administration", operations = "Operations", system = "System"
        var id: Self { self }
        var sections: [SidebarSection] { SidebarSection.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .overview, .devices, .topology, .networks, .traffic: .network
        case .qos, .accessControl, .firewall, .security: .administration
        case .monitoring, .reports: .operations
        case .integrations, .settings: .system
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .devices: "Devices"
        case .topology: "Topology"
        case .networks: "Networks & Subnets"
        case .traffic: "Traffic Analytics"
        case .qos: "QoS Manager"
        case .accessControl: "Access Control"
        case .firewall: "Firewall"
        case .security: "Security Center"
        case .monitoring: "Monitoring"
        case .reports: "Reports"
        case .integrations: "Integrations"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .devices: "desktopcomputer"
        case .topology: "point.3.connected.trianglepath.dotted"
        case .networks: "square.grid.3x3"
        case .traffic: "chart.xyaxis.line"
        case .qos: "speedometer"
        case .accessControl: "lock.shield"
        case .firewall: "flame"
        case .security: "exclamationmark.shield"
        case .monitoring: "bell.badge"
        case .reports: "doc.text"
        case .integrations: "cable.connector"
        case .settings: "gearshape"
        }
    }
}
