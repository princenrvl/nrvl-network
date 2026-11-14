import Foundation

public enum AdapterKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case snmp, unifi, openwrt, mikrotik, opnsense, pfsense

    public var id: Self { self }

    public var title: String {
        switch self {
        case .snmp: "SNMP device"
        case .unifi: "Ubiquiti UniFi"
        case .openwrt: "OpenWrt"
        case .mikrotik: "MikroTik RouterOS"
        case .opnsense: "OPNsense"
        case .pfsense: "pfSense"
        }
    }
}

/// Something an integration may or may not be able to do on a given device.
public enum Feature: String, Sendable, CaseIterable, Identifiable {
    case clientInventory, infrastructureDevices, networks, trafficStatistics
    case accessControl, qos, firewall, configurationBackup

    public var id: Self { self }

    public var title: String {
        switch self {
        case .clientInventory: "Client inventory"
        case .infrastructureDevices: "Switches and access points"
        case .networks: "Networks and VLANs"
        case .trafficStatistics: "Traffic statistics"
        case .accessControl: "Access control"
        case .qos: "QoS"
        case .firewall: "Firewall"
        case .configurationBackup: "Configuration backup"
        }
    }
}

public enum Support: Sendable, Equatable {
    case supported
    /// Can be read but not changed.
    case readOnly
    /// The reason is shown to the user.
    case unsupported(String)
}

public typealias CapabilitySet = [Feature: Support]

public enum AdapterError: Error, Equatable, LocalizedError {
    case unreachable(String)
    case timeout
    case authenticationFailed
    case permissionDenied(String)
    /// First contact with a certificate no public authority vouches for; the user must approve this fingerprint.
    case tlsUntrusted(fingerprint: String)
    /// The certificate differs from the one the user approved.
    case tlsChanged(fingerprint: String)
    case unsupported(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Cannot reach the device: \(why)"
        case .timeout: "The device did not answer in time."
        case .authenticationFailed: "The device rejected the credentials."
        case .permissionDenied(let what): "The account is not allowed to do this: \(what)"
        case .tlsUntrusted: "The device's certificate is not trusted yet."
        case .tlsChanged: "The device's certificate has changed since you approved it. Connection refused."
        case .unsupported(let what): "Not supported by this device: \(what)"
        case .protocolError(let why): "Unexpected answer from the device: \(why)"
        }
    }
}

/// A configured connection to infrastructure the user administers. Secrets live in the Keychain, never here.
public struct Integration: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: AdapterKind
    public var name: String
    public var host: String
    public var port: Int?
    public var username: String?
    /// SHA-256 of the certificate the user approved, hex.
    public var pinnedCertificate: String?
    /// Off = read-only. Changing the network through this integration requires turning this on.
    public var managementEnabled: Bool

    public init(id: Int64 = 0, kind: AdapterKind, name: String, host: String, port: Int? = nil, username: String? = nil,
                pinnedCertificate: String? = nil, managementEnabled: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.pinnedCertificate = pinnedCertificate
        self.managementEnabled = managementEnabled
    }
}

public struct AdapterIdentity: Sendable, Equatable {
    public var name: String
    public var model: String
    public var firmware: String?

    public init(name: String, model: String, firmware: String? = nil) {
        self.name = name
        self.model = model
        self.firmware = firmware
    }
}

public enum ConnectionType: String, Sendable, Codable {
    case wired, wireless
}

/// A network defined on the infrastructure (subnet, VLAN, DHCP scope).
public struct NetworkRecord: Sendable, Equatable, Identifiable {
    public var id: String { "\(name)/\(vlan ?? 0)/\(cidr ?? "")" }
    public var name: String
    public var vlan: Int?
    public var cidr: String?
    public var dhcpRange: String?

    public init(name: String, vlan: Int? = nil, cidr: String? = nil, dhcpRange: String? = nil) {
        self.name = name
        self.vlan = vlan
        self.cidr = cidr
        self.dhcpRange = dhcpRange
    }
}

/// A switch, access point or gateway managed by the infrastructure.
public struct InfrastructureDevice: Sendable, Equatable, Identifiable {
    public var id: String { mac?.description ?? name }
    public var name: String
    public var model: String?
    public var role: String
    public var mac: MACAddress?
    public var ipv4: String?
    public var firmware: String?
    /// MAC of the device this one is plugged into, when the infrastructure reports it.
    public var uplink: MACAddress?

    public init(name: String, model: String? = nil, role: String, mac: MACAddress? = nil, ipv4: String? = nil,
                firmware: String? = nil, uplink: MACAddress? = nil) {
        self.name = name
        self.model = model
        self.role = role
        self.mac = mac
        self.ipv4 = ipv4
        self.firmware = firmware
        self.uplink = uplink
    }
}
