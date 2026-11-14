import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence

/// Where the engines get integrations and live adapters from. `IntegrationService` in the app; a fake in tests.
public protocol AdapterProviding: Sendable {
    func all() async throws -> [Integration]
    func adapter(for integration: Integration) async throws -> any InfrastructureAdapter
}

extension IntegrationService: AdapterProviding {}

/// Owns the configured integrations: stores them, keeps their secrets in the Keychain, polls them and reports their state.
public actor IntegrationService {
    public struct Status: Sendable, Equatable {
        public var error: AdapterError?
        public var identity: AdapterIdentity?
        public var capabilities: CapabilitySet = [:]
        public var networks: [NetworkRecord] = []
        public var devices: [InfrastructureDevice] = []
        /// Nil when the integration cannot report firewall rules.
        public var firewallRules: [FirewallRule]?
        public var clientCount = 0
        public var checkedAt: Date?

        public var isConnected: Bool { error == nil && identity != nil }
    }

    private let store: IntegrationStore
    private let metrics: MetricStore
    private var lastCounters: [String: (received: UInt64, sent: UInt64, at: Date)] = [:]
    private let audit: AuditLog
    private let credentials: CredentialStore
    private var statuses: [Integration.ID: Status] = [:]

    public init(database: AppDatabase, credentials: CredentialStore = CredentialStore()) {
        store = database.integrations
        metrics = database.metrics
        audit = database.audit
        self.credentials = credentials
    }

    public func all() async throws -> [Integration] { try await store.all() }
    public func status() -> [Integration.ID: Status] { statuses }

    /// Tries a connection without saving anything.
    public func test(_ integration: Integration, secret: Secret) async -> Result<AdapterIdentity, AdapterError> {
        do {
            return .success(try await AdapterFactory.make(integration, secret: secret).identify())
        } catch {
            return .failure(Self.adapterError(error))
        }
    }

    public func add(_ integration: Integration, secret: Secret) async throws -> Integration {
        let saved = try await store.save(integration)
        do {
            try credentials.set(secret, account: String(saved.id))
        } catch {
            try? await store.delete(id: saved.id)   // never keep an integration whose secret was not stored
            throw error
        }
        try await audit.append(action: "integration.add", target: "\(saved.kind.rawValue) \(saved.host)",
                               detail: "name=\(saved.name) management=off", outcome: .succeeded)
        return saved
    }

    public func remove(_ integration: Integration) async throws {
        try await store.delete(id: integration.id)
        try credentials.delete(account: String(integration.id))
        statuses[integration.id] = nil
        try await audit.append(action: "integration.remove", target: "\(integration.kind.rawValue) \(integration.host)", outcome: .succeeded)
    }

    /// Records that the user approved this certificate fingerprint for this integration.
    public func trust(fingerprint: String, for integration: Integration) async throws {
        var updated = integration
        updated.pinnedCertificate = fingerprint
        _ = try await store.save(updated)
        try await audit.append(action: "integration.trust-certificate", target: "\(integration.kind.rawValue) \(integration.host)",
                               detail: "sha256=\(fingerprint) previous=\(integration.pinnedCertificate ?? "none")", outcome: .succeeded)
    }

    public func setManagement(_ enabled: Bool, for integration: Integration) async throws {
        var updated = integration
        updated.managementEnabled = enabled
        _ = try await store.save(updated)
        try await audit.append(action: "integration.management", target: "\(integration.kind.rawValue) \(integration.host)",
                               detail: enabled ? "enabled" : "disabled", outcome: .succeeded)
    }

    /// A ready adapter for one integration, for the engines that act on it.
    public func adapter(for integration: Integration) throws -> any InfrastructureAdapter {
        guard let secret = try credentials.get(account: String(integration.id)) else {
            throw AdapterError.authenticationFailed
        }
        return try AdapterFactory.make(integration, secret: secret)
    }

    /// Polls every integration once and returns the clients they report. A failing integration never blocks the others.
    public func collect() async -> [DeviceSighting] {
        guard let integrations = try? await store.all() else { return [] }
        var sightings: [DeviceSighting] = []
        for integration in integrations {
            var status = Status(checkedAt: Date())
            do {
                let adapter = try adapter(for: integration)
                status.identity = try await adapter.identify()
                let capabilities = try await adapter.capabilities()
                status.capabilities = capabilities
                func supports(_ feature: Feature) -> Bool {
                    if case .unsupported = capabilities[feature] ?? .unsupported("") { return false }
                    return true
                }
                if supports(.networks) { status.networks = try await adapter.networks() }
                if supports(.infrastructureDevices) { status.devices = try await adapter.infrastructureDevices() }
                if supports(.firewall), let firewall = adapter as? any FirewallInspecting {
                    status.firewallRules = try await firewall.firewallRules()
                }
                if supports(.trafficStatistics), let counting = adapter as? any InterfaceCounting {
                    try await recordRates(try await counting.interfaceCounters(), integration: integration)
                }
                let clients = supports(.clientInventory) ? try await adapter.clients() : []
                status.clientCount = clients.count
                sightings += clients.map { client in
                    var client = client
                    client.integrationID = integration.id
                    return client
                }
            } catch {
                status.error = Self.adapterError(error)
            }
            statuses[integration.id] = status
        }
        return sightings
    }

    /// Stores bytes per second for each interface of the device as series "if.<integration id>.<interface>.rx" / ".tx".
    private func recordRates(_ counters: [String: (received: UInt64, sent: UInt64)], integration: Integration) async throws {
        let now = Date()
        var rates: [String: Double] = [:]
        for (name, counter) in counters {
            let key = "if.\(integration.id).\(name)"
            if let last = lastCounters[key], now.timeIntervalSince(last.at) > 1,
               counter.received >= last.received, counter.sent >= last.sent {   // skip counter resets
                let seconds = now.timeIntervalSince(last.at)
                rates[key + ".rx"] = Double(counter.received - last.received) / seconds
                rates[key + ".tx"] = Double(counter.sent - last.sent) / seconds
            }
            lastCounters[key] = (counter.received, counter.sent, now)
        }
        try await metrics.add(rates, at: now)
    }

    private static func adapterError(_ error: Error) -> AdapterError {
        error as? AdapterError ?? .protocolError(error.localizedDescription)
    }
}
