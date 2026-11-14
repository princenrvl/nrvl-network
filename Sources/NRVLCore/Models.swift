import Foundation

public struct Site: Sendable, Equatable, Identifiable {
    /// Created by migration v1; the only site until multi-site support lands.
    public static let defaultID: Int64 = 1

    public var id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AuditEntry: Sendable, Equatable, Identifiable {
    public enum Outcome: String, Sendable {
        case succeeded, failed
        /// The change was sent but could not be confirmed by re-reading state.
        case unverified
    }

    public var id: Int64
    public var siteID: Int64
    public var timestamp: Date
    public var actor: String
    public var action: String
    public var target: String
    public var detail: String
    public var outcome: Outcome

    public init(id: Int64, siteID: Int64, timestamp: Date, actor: String, action: String,
                target: String, detail: String, outcome: Outcome) {
        self.id = id
        self.siteID = siteID
        self.timestamp = timestamp
        self.actor = actor
        self.action = action
        self.target = target
        self.detail = detail
        self.outcome = outcome
    }
}

public struct NetworkInterface: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// BSD name, e.g. "en0".
    public var name: String
    /// System name, e.g. "Wi-Fi". Nil for interfaces macOS does not list as hardware ports.
    public var displayName: String?
    public var mac: MACAddress?
    // shortcut: only the first IPv4 address of an interface is kept; add a list when aliases need showing.
    public var ipv4: String?
    public var netmask: String?
    public var ipv6: [String] = []
    public var isUp: Bool
    public var isLoopback: Bool
    public var isPointToPoint: Bool

    public init(name: String, displayName: String? = nil, mac: MACAddress? = nil, ipv4: String? = nil,
                netmask: String? = nil, ipv6: [String] = [], isUp: Bool = true, isLoopback: Bool = false,
                isPointToPoint: Bool = false) {
        self.name = name
        self.displayName = displayName
        self.mac = mac
        self.ipv4 = ipv4
        self.netmask = netmask
        self.ipv6 = ipv6
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
    }

    public var subnet: IPv4Subnet? {
        guard let ipv4, let netmask else { return nil }
        return IPv4Subnet(address: ipv4, netmask: netmask)
    }
}

public struct NetworkConfiguration: Sendable, Equatable {
    public var gateway: String?
    public var primaryInterface: String?
    public var dnsServers: [String]

    public init(gateway: String? = nil, primaryInterface: String? = nil, dnsServers: [String] = []) {
        self.gateway = gateway
        self.primaryInterface = primaryInterface
        self.dnsServers = dnsServers
    }
}

/// One entry of this Mac's ARP (IPv4) or neighbour-discovery (IPv6) table.
public struct Neighbor: Sendable, Hashable {
    public var ip: String
    public var isIPv6: Bool
    public var mac: MACAddress
    public var interface: String

    public init(ip: String, isIPv6: Bool, mac: MACAddress, interface: String) {
        self.ip = ip
        self.isIPv6 = isIPv6
        self.mac = mac
        self.interface = interface
    }
}

/// What one scan learned about one device.
public struct DeviceSighting: Sendable, Equatable {
    public var mac: MACAddress
    public var ipv4: String?
    public var ipv6: [String]
    public var interface: String
    public var isThisMac: Bool
    public var hostname: String?
    /// Bonjour service types the device advertises, sorted.
    public var services: [String]
    public var model: String?
    // Known only from a router integration:
    public var connection: ConnectionType?
    public var ssid: String?
    /// Where the device is attached, e.g. "Office Switch port 5" or "Hall AP".
    public var uplink: String?
    public var vlan: Int?
    /// Integration that reported the fields above.
    public var integrationID: Int64?
    /// Lifetime byte totals the infrastructure has counted for this client (download, upload from the client's view).
    public var receivedBytes: UInt64?
    public var sentBytes: UInt64?
    public var isBlocked: Bool?

    public init(mac: MACAddress, ipv4: String? = nil, ipv6: [String] = [], interface: String = "",
                isThisMac: Bool = false, hostname: String? = nil, services: [String] = [], model: String? = nil,
                connection: ConnectionType? = nil, ssid: String? = nil, uplink: String? = nil, vlan: Int? = nil,
                integrationID: Int64? = nil, receivedBytes: UInt64? = nil, sentBytes: UInt64? = nil, isBlocked: Bool? = nil) {
        self.connection = connection
        self.ssid = ssid
        self.uplink = uplink
        self.vlan = vlan
        self.integrationID = integrationID
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.isBlocked = isBlocked
        self.mac = mac
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.interface = interface
        self.isThisMac = isThisMac
        self.hostname = hostname
        self.services = services
        self.model = model
    }
}

public struct Device: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var mac: MACAddress
    public var ipv4: String?
    public var ipv6: [String]
    public var hostname: String?
    public var interface: String
    public var isThisMac: Bool
    public var services: [String]
    public var model: String?
    public var customName: String?
    public var isTrusted: Bool
    public var tags: [String]
    public var group: String?
    public var connection: ConnectionType?
    public var ssid: String?
    public var uplink: String?
    public var vlan: Int?
    public var integrationID: Int64?
    public var isBlocked: Bool?
    public var firstSeen: Date
    public var lastSeen: Date

    public init(id: Int64, mac: MACAddress, ipv4: String? = nil, ipv6: [String] = [], hostname: String? = nil,
                interface: String, isThisMac: Bool = false, services: [String] = [], model: String? = nil,
                customName: String? = nil, isTrusted: Bool = false, tags: [String] = [], group: String? = nil,
                connection: ConnectionType? = nil, ssid: String? = nil, uplink: String? = nil, vlan: Int? = nil,
                integrationID: Int64? = nil, isBlocked: Bool? = nil, firstSeen: Date, lastSeen: Date) {
        self.connection = connection
        self.ssid = ssid
        self.uplink = uplink
        self.vlan = vlan
        self.integrationID = integrationID
        self.isBlocked = isBlocked
        self.id = id
        self.mac = mac
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.hostname = hostname
        self.interface = interface
        self.isThisMac = isThisMac
        self.services = services
        self.model = model
        self.customName = customName
        self.isTrusted = isTrusted
        self.tags = tags
        self.group = group
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}
