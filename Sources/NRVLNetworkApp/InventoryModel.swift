import Foundation
import NRVLCore
import NRVLDiscovery
import NRVLPersistence
import NRVLServices
import Observation

@MainActor @Observable
final class InventoryModel {
    /// A device prepared for display: every string the table sorts, searches and shows.
    struct Row: Identifiable, Hashable {
        let device: Device
        let name: String
        /// True when the name is only a guess from the manufacturer, not something the device reported.
        let nameIsInferred: Bool
        let ipv4: String
        let ipSort: UInt32
        let mac: String
        let vendor: String
        /// Nil when there is no evidence for a device type.
        let classification: DeviceClassification?
        /// Nil until a scan has completed in this session — the stored record alone cannot say.
        let isOnline: Bool?

        var id: Device.ID { device.id }
        var kind: String { classification?.kind ?? "" }
        var connection: String { device.connection?.rawValue.capitalized ?? "" }
        var interface: String { device.interface }
        var firstSeen: Date { device.firstSeen }
        var lastSeen: Date { device.lastSeen }
    }

    private(set) var devices: [Device] = []
    private(set) var report: InventoryService.ScanReport?
    private(set) var isScanning = false
    private(set) var errorMessage: String?

    var searchText = ""
    var selection: Device.ID? {
        didSet { Task { await loadEvents() } }
    }
    private(set) var selectedEvents: [ConnectionEvent] = []
    var sortOrder = [KeyPathComparator(\Row.ipSort)]
    var showInspector = true
    /// The text field being edited in the alert (name, tags or group), if any.
    var editing: (device: Device, field: DeviceStore.Field)?
    var editText = ""

    /// Runs after every completed scan (applies access schedules).
    var afterScan: (() async -> Void)?

    private let store: DeviceStore
    private let service: InventoryService
    private let registry: OUIRegistry?

    init(database: AppDatabase, registry: OUIRegistry?, integrations: IntegrationService? = nil) {
        store = database.devices
        service = InventoryService(devices: database.devices, integrations: integrations, metrics: database.metrics)
        self.registry = registry
    }

    var hasManufacturerRegistry: Bool { registry != nil }

    /// Every device, ignoring the Devices search field.
    var allRows: [Row] { devices.map(row) }

    var rows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows
            .filter { row in
                query.isEmpty || ([row.name, row.ipv4, row.mac, row.vendor, row.kind, row.device.hostname ?? "",
                                   row.device.group ?? "", row.connection, row.device.ssid ?? "", row.device.uplink ?? ""] + row.device.tags)
                    .contains { $0.lowercased().contains(query) }
            }
            .sorted(using: sortOrder)
    }

    var selectedRow: Row? { devices.first { $0.id == selection }.map(row) }

    var onlineCount: Int? {
        report == nil ? nil : devices.count { isOnline($0) == true }
    }

    var localNetworkDenied: Bool {
        report?.sweeps.values.contains(.permissionDenied) ?? false
    }

    /// Keeps the inventory live and rescans every minute. Runs for the life of the app.
    func run() async {
        async let observing: Void = observe()
        while !Task.isCancelled {
            await scan()
            try? await Task.sleep(for: .seconds(60))
        }
        await observing
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            report = try await service.scan()
            errorMessage = nil
            await afterScan?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var recentlyDiscoveredCount: Int {
        devices.count { $0.firstSeen > Date().addingTimeInterval(-86_400) }
    }

    func beginEditing(_ field: DeviceStore.Field, of device: Device) {
        switch field {
        case .customName: editText = device.customName ?? ""
        case .tags: editText = device.tags.joined(separator: ", ")
        case .group: editText = device.group ?? ""
        }
        editing = (device, field)
    }

    func commitEdit() async {
        guard let (device, field) = editing else { return }
        editing = nil
        await perform { try await self.store.set(field, to: self.editText, id: device.id) }
    }

    func setTrusted(_ trusted: Bool, _ device: Device) async {
        await perform { try await self.store.setTrusted(trusted, id: device.id) }
    }

    private func perform(_ change: () async throws -> Void) async {
        do { try await change() } catch { errorMessage = error.localizedDescription }
    }

    private func observe() async {
        do {
            for try await devices in store.updates() {
                self.devices = devices
                await loadEvents()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEvents() async {
        guard let selection else { return selectedEvents = [] }
        selectedEvents = (try? await store.events(for: selection)) ?? []
    }

    private func isOnline(_ device: Device) -> Bool? {
        // Stored times are rounded to the millisecond, hence the tolerance.
        report.map { device.lastSeen >= $0.date.addingTimeInterval(-1) }
    }

    private func row(_ device: Device) -> Row {
        let vendor = registry?.vendor(for: device.mac)
        let reported = device.customName ?? device.hostname ?? (device.isThisMac ? "This Mac" : nil)
        return Row(
            device: device,
            name: reported ?? vendor.map { "\($0) device" } ?? "Unknown device",
            nameIsInferred: reported == nil,
            ipv4: device.ipv4 ?? "",
            ipSort: device.ipv4.flatMap(IPv4.parse) ?? .max,
            mac: device.mac.description,
            vendor: vendor ?? (device.mac.isLocallyAdministered ? "Private address" : ""),
            classification: DeviceClassifier.classify(
                device, isGateway: device.ipv4 != nil && device.ipv4 == report?.configuration.gateway),
            isOnline: isOnline(device))
    }
}
