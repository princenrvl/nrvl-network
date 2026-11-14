import CryptoKit
import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence
import Observation
import UserNotifications

/// Turns what the app observes into alerts after every scan, stores them, and posts notifications.
@MainActor @Observable
final class AlertsModel {
    private(set) var alerts: [Alert] = []
    var settings = AlertSettings() {
        didSet { if settings != oldValue { Task { try? await store.setSetting("alerts", to: settings) } } }
    }

    private let store: AlertStore
    private let devices: DeviceStore
    private let inventory: InventoryModel
    private let telemetry: TelemetryModel
    private let integrations: IntegrationsModel
    private var previous: NetworkSnapshot?
    private var lastEventCheck = Date()   // events from before this launch are history, not news

    init(database: AppDatabase, inventory: InventoryModel, telemetry: TelemetryModel, integrations: IntegrationsModel) {
        store = database.alerts
        devices = database.devices
        self.inventory = inventory
        self.telemetry = telemetry
        self.integrations = integrations
    }

    var unacknowledged: [Alert] { alerts.filter { !$0.acknowledged } }

    func load() async {
        if let saved = try? await store.setting("alerts", as: AlertSettings.self) { settings = saved }
        alerts = (try? await store.all()) ?? []
    }

    func acknowledge(_ id: Alert.ID?) async {
        try? await store.acknowledge(id: id)
        alerts = (try? await store.all()) ?? []
    }

    func evaluate() async {
        await integrations.refresh()
        let current = await snapshot()
        let raised = AlertRules.evaluate(previous: previous, current: current, settings: settings)
        previous = current
        guard !raised.isEmpty else { return }
        try? await store.add(raised)
        alerts = (try? await store.all()) ?? []
        if settings.notifications { raised.forEach(notify) }
    }

    private func snapshot() async -> NetworkSnapshot {
        var value = NetworkSnapshot()
        let configuration = inventory.report?.configuration ?? telemetry.configuration
        value.gatewayAddress = configuration.gateway
        value.gatewayMAC = inventory.devices.first { $0.ipv4 != nil && $0.ipv4 == configuration.gateway }?.mac
        value.dnsServers = configuration.dnsServers
        value.gatewayLoss = telemetry.gateway.lossFraction
        value.internetLoss = telemetry.internet.lossFraction
        value.internetLatency = telemetry.internet.averageLatency
        value.throughput = telemetry.throughput.last.map { $0.down + $0.up }
        value.conflicts = inventory.report?.conflicts.map(\.ip) ?? []

        for integration in integrations.integrations {
            guard let status = integrations.statuses[integration.id] else { continue }
            if let error = status.error {
                value.integrationErrors[integration.name] = error.localizedDescription
                if case .tlsChanged(let fingerprint) = error { value.certificateChanges[integration.name] = fingerprint }
            }
            if let rules = status.firewallRules {
                let text = rules.map { "\($0.id)|\($0.name)|\($0.action)|\($0.summary)|\($0.enabled)" }.joined(separator: "\n")
                value.firewallDigests[integration.name] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }

        let names = Dictionary(inventory.allRows.map { ($0.id, "\($0.name) (\($0.ipv4.isEmpty ? $0.mac : $0.ipv4))") }, uniquingKeysWith: { first, _ in first })
        let events = (try? await devices.events(after: lastEventCheck)) ?? []
        lastEventCheck = events.last?.event.date ?? lastEventCheck
        value.discovered = events.filter { $0.event.kind == .discovered }.compactMap { names[$0.device] }
        value.disappeared = events.filter { $0.event.kind == .disappeared }.compactMap { names[$0.device] }
        return value
    }

    private func notify(_ alert: Alert) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // not running as an app bundle
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = alert.kind.title
        content.body = alert.detail
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
