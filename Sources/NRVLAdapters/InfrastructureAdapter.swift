import Foundation
import NRVLCore

/// What every integration can be asked. An adapter talks only to the host it was configured with,
/// uses the vendor's documented interface, and throws `AdapterError` — it never reports success it did not verify.
public protocol InfrastructureAdapter: Sendable {
    /// Proves the connection and credentials work and says what is on the other end.
    func identify() async throws -> AdapterIdentity
    /// What this particular device, firmware and account can do. Never assumed from the adapter kind alone.
    func capabilities() async throws -> CapabilitySet
    /// Client devices the infrastructure knows about.
    func clients() async throws -> [DeviceSighting]
    func infrastructureDevices() async throws -> [InfrastructureDevice]
    func networks() async throws -> [NetworkRecord]
}

/// Adopted only by adapters whose platform documents a way to block a client.
public protocol AccessControlling: InfrastructureAdapter {
    func setBlocked(_ blocked: Bool, mac: MACAddress) async throws
    /// Read back from the device, used to verify a change.
    func isBlocked(mac: MACAddress) async throws -> Bool
}

/// One traffic-shaping queue on a link of the device (on OpenWrt: an SQM queue, usually on the WAN interface).
public struct ShapingQueue: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var interface: String
    public var enabled: Bool
    /// Kilobits per second; 0 means that direction is not shaped.
    public var downloadKbps: Int
    public var uploadKbps: Int
    /// The queueing discipline in use, e.g. "cake". Informational.
    public var discipline: String?

    public init(id: String, interface: String, enabled: Bool, downloadKbps: Int, uploadKbps: Int, discipline: String? = nil) {
        self.id = id
        self.interface = interface
        self.enabled = enabled
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
        self.discipline = discipline
    }
}

/// Adopted only by adapters whose platform documents link-level traffic shaping.
public protocol LinkShaping: InfrastructureAdapter {
    func shapingQueues() async throws -> [ShapingQueue]
    /// Sets enabled state and rates of an existing queue. Never creates or deletes queues.
    func apply(_ queue: ShapingQueue) async throws
}

/// One firewall rule as the device describes it. Read-only.
public struct FirewallRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var action: String
    public var summary: String
    public var enabled: Bool

    public init(id: String, name: String, action: String, summary: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.action = action
        self.summary = summary
        self.enabled = enabled
    }
}

public protocol FirewallInspecting: InfrastructureAdapter {
    func firewallRules() async throws -> [FirewallRule]
}

public protocol ConfigurationExporting: InfrastructureAdapter {
    /// The device's configuration as it exports it. May contain secrets: callers must store it encrypted.
    func exportConfiguration() async throws -> Data
}

/// Adopted by adapters that can read total bytes per interface of the device itself (not per client).
public protocol InterfaceCounting: InfrastructureAdapter {
    func interfaceCounters() async throws -> [String: (received: UInt64, sent: UInt64)]
}

/// The secret for an integration: a password, API key or SNMP community string. Read from the Keychain at use.
public typealias Secret = String

public enum AdapterFactory {
    /// Kinds that have an adapter in this build.
    public static let available: Set<AdapterKind> = [.snmp, .unifi, .openwrt]

    public static func make(_ integration: Integration, secret: Secret) throws -> any InfrastructureAdapter {
        switch integration.kind {
        case .snmp:
            return SNMPAdapter(client: SNMPClient(host: integration.host, port: UInt16(clamping: integration.port ?? 161), community: secret))
        case .unifi:
            return UniFiAdapter(http: try http(integration), apiKey: secret, site: integration.username)
        case .openwrt:
            return OpenWrtAdapter(http: try http(integration), username: integration.username ?? "root", password: secret)
        default:
            throw AdapterError.unsupported("\(integration.kind.title) is not available in this build yet.")
        }
    }

    private static func http(_ integration: Integration) throws -> PinnedHTTP {
        try PinnedHTTP(host: integration.host, port: integration.port, pinnedCertificate: integration.pinnedCertificate)
    }
}
