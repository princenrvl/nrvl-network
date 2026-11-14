import Foundation
import NRVLCore

/// Generic read-only adapter for anything that speaks SNMP v2c (managed switches, routers, access points).
/// Uses only standard MIBs: MIB-II system/interfaces/IP, IF-MIB and BRIDGE-MIB.
public struct SNMPAdapter: InfrastructureAdapter, InterfaceCounting {
    let client: SNMPClient

    private enum MIB {
        static let sysDescr: OID = "1.3.6.1.2.1.1.1.0"
        static let sysName: OID = "1.3.6.1.2.1.1.5.0"
        static let ifName: OID = "1.3.6.1.2.1.31.1.1.1.1"
        static let ifHCInOctets: OID = "1.3.6.1.2.1.31.1.1.1.6"
        static let ifHCOutOctets: OID = "1.3.6.1.2.1.31.1.1.1.10"
        /// ARP table: index is ifIndex + IPv4, value is the MAC.
        static let ipNetToMediaPhysAddress: OID = "1.3.6.1.2.1.4.22.1.2"
        /// Index is the IPv4 address, value is its mask.
        static let ipAdEntNetMask: OID = "1.3.6.1.2.1.4.20.1.3"
        /// Switch forwarding table: index is the MAC, value is the bridge port.
        static let dot1dTpFdbPort: OID = "1.3.6.1.2.1.17.4.3.1.2"
        static let dot1dBasePortIfIndex: OID = "1.3.6.1.2.1.17.1.4.1.2"
    }

    public func identify() async throws -> AdapterIdentity {
        let reply = try await client.get([MIB.sysName, MIB.sysDescr])
        guard reply.count == 2 else { throw AdapterError.protocolError("The device did not return its system description.") }
        return AdapterIdentity(name: Self.text(reply[0].value) ?? client.host, model: Self.text(reply[1].value) ?? "SNMP device")
    }

    public func capabilities() async throws -> CapabilitySet {
        let readOnlyProtocol = "SNMP is used read-only by NRVL Network."
        var set: CapabilitySet = [
            .infrastructureDevices: .readOnly,
            .accessControl: .unsupported(readOnlyProtocol),
            .qos: .unsupported(readOnlyProtocol),
            .firewall: .unsupported("Standard SNMP MIBs do not describe firewall rules."),
            .configurationBackup: .unsupported("Standard SNMP MIBs do not expose the configuration."),
        ]
        // Probe each optional table: many devices implement only part of the standard MIBs.
        set[.clientInventory] = try await probe(MIB.ipNetToMediaPhysAddress, missing: "This device does not publish an ARP table over SNMP.")
        set[.networks] = try await probe(MIB.ipAdEntNetMask, missing: "This device does not publish its IP addresses over SNMP.")
        set[.trafficStatistics] = try await probe(MIB.ifHCInOctets, missing: "This device does not publish 64-bit interface counters.")
        return set
    }

    private func probe(_ table: OID, missing: String) async throws -> Support {
        try await client.walk(table, limit: 1).isEmpty ? .unsupported(missing) : .readOnly
    }

    /// Clients from the device's ARP table, with the switch port each MAC was learned on when the device is a bridge.
    public func clients() async throws -> [DeviceSighting] {
        let name = try await identify().name
        let ports = try await portNames()
        var byMAC: [MACAddress: DeviceSighting] = [:]
        for row in try await client.walk(MIB.ipNetToMediaPhysAddress) {
            let index = row.oid.suffix(after: MIB.ipNetToMediaPhysAddress)
            guard index.count == 5, case .octets(let bytes) = row.value,
                  let mac = MACAddress(bytes: bytes), !mac.isMulticast else { continue }
            let ip = index.dropFirst().map(String.init).joined(separator: ".")
            byMAC[mac, default: DeviceSighting(mac: mac)].ipv4 = byMAC[mac]?.ipv4 ?? ip
        }
        for (mac, port) in ports {
            // A MAC seen only in the forwarding table still proves the device is attached there.
            byMAC[mac, default: DeviceSighting(mac: mac)].uplink = "\(name) port \(port)"
        }
        return byMAC.values.sorted { $0.mac.description < $1.mac.description }
    }

    /// MAC → interface name, from BRIDGE-MIB. Empty for devices that are not switches.
    private func portNames() async throws -> [MACAddress: String] {
        let forwarding = try await client.walk(MIB.dot1dTpFdbPort)
        guard !forwarding.isEmpty else { return [:] }
        let names = Dictionary(try await interfaceNames(), uniquingKeysWith: { first, _ in first })
        var interfaceOfPort: [UInt32: UInt32] = [:]
        for row in try await client.walk(MIB.dot1dBasePortIfIndex) {
            if let port = row.oid.arcs.last, case .integer(let index) = row.value { interfaceOfPort[port] = UInt32(clamping: index) }
        }
        var result: [MACAddress: String] = [:]
        for row in forwarding {
            let index = row.oid.suffix(after: MIB.dot1dTpFdbPort)
            guard index.count == 6, let mac = MACAddress(bytes: index.map { UInt8(clamping: $0) }), !mac.isMulticast,
                  case .integer(let port) = row.value, port > 0 else { continue }
            let interface = interfaceOfPort[UInt32(clamping: port)]
            result[mac] = interface.flatMap { names[$0] } ?? "\(port)"
        }
        return result
    }

    private func interfaceNames() async throws -> [(UInt32, String)] {
        try await client.walk(MIB.ifName).compactMap { row in
            guard let index = row.oid.arcs.last, let name = Self.text(row.value) else { return nil }
            return (index, name)
        }
    }

    public func infrastructureDevices() async throws -> [InfrastructureDevice] {
        let identity = try await identify()
        return [InfrastructureDevice(name: identity.name, model: identity.model, role: "SNMP device",
                                     ipv4: IPv4.parse(client.host) == nil ? nil : client.host)]
    }

    public func networks() async throws -> [NetworkRecord] {
        try await client.walk(MIB.ipAdEntNetMask).compactMap { row in
            let address = row.oid.suffix(after: MIB.ipAdEntNetMask).map(String.init).joined(separator: ".")
            guard case .ipAddress(let mask) = row.value, mask.count == 4,
                  let subnet = IPv4Subnet(address: address, netmask: mask.map(String.init).joined(separator: ".")),
                  subnet.prefixLength < 32, !address.hasPrefix("127.") else { return nil }
            return NetworkRecord(name: subnet.description, cidr: subnet.description)
        }
    }

    /// Total bytes per interface (in, out), for traffic graphs.
    public func interfaceCounters() async throws -> [String: (received: UInt64, sent: UInt64)] {
        let names = Dictionary(try await interfaceNames(), uniquingKeysWith: { first, _ in first })
        func column(_ oid: OID) async throws -> [UInt32: UInt64] {
            var values: [UInt32: UInt64] = [:]
            for row in try await client.walk(oid) {
                if let index = row.oid.arcs.last, case .unsigned(_, let count) = row.value { values[index] = count }
            }
            return values
        }
        let received = try await column(MIB.ifHCInOctets), sent = try await column(MIB.ifHCOutOctets)
        var result: [String: (received: UInt64, sent: UInt64)] = [:]
        for (index, name) in names {
            if let down = received[index], let up = sent[index] { result[name] = (down, up) }
        }
        return result
    }

    private static func text(_ value: BER.Value) -> String? {
        guard case .octets(let bytes) = value else { return nil }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
