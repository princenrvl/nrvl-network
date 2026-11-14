import Foundation
import NRVLCore
import NRVLDiscovery
import NRVLPersistence

/// Runs discovery scans from this Mac and stores what they find.
public actor InventoryService {
    public struct ScanReport: Sendable, Equatable {
        /// Stamped on every device seen by this scan (`Device.lastSeen`).
        public var date: Date
        public var interfaces: [NetworkInterface]
        public var configuration: NetworkConfiguration
        /// Subnet (CIDR) → what the active probe did.
        public var sweeps: [String: SubnetSweep.Outcome]
        public var devicesSeen: Int
        /// IPv4 addresses currently claimed by more than one device. An anomaly, not proof of a fault.
        public var conflicts: [AddressConflict]
    }

    private let devices: DeviceStore
    private let integrations: IntegrationService?
    private let bonjour = BonjourBrowser()
    private var presence = PresenceTracker()
    private var conflicts = ConflictDetector()
    private var resolvedAddresses: Set<String> = []

    private let metrics: MetricStore?
    private var lastBytes: [MACAddress: (received: UInt64, sent: UInt64)] = [:]

    public init(devices: DeviceStore, integrations: IntegrationService? = nil, metrics: MetricStore? = nil) {
        self.devices = devices
        self.integrations = integrations
        self.metrics = metrics
    }

    public func scan() async throws -> ScanReport {
        bonjour.start()   // idempotent; keeps listening between scans
        let interfaces = InterfaceReader.interfaces()
        var sweeps: [String: SubnetSweep.Outcome] = [:]
        for interface in interfaces where Self.isLAN(interface) {
            if let subnet = interface.subnet, subnet.isPrivate {
                sweeps[subnet.description] = await SubnetSweep.probe(subnet)
            }
        }
        if !sweeps.isEmpty { try? await Task.sleep(for: .seconds(2)) }   // let hosts answer ARP

        let neighbors = NeighborTable.read()
        let local = Self.attach(
            await bonjour.snapshot(),
            to: Self.merge(interfaces: interfaces, neighbors: neighbors, thisMacName: Host.current().localizedName))
        let sightings = Self.layer(await integrations?.collect() ?? [], onto: local)
        let date = Date()
        let lan = Set(interfaces.filter(Self.isLAN).map(\.name))
        conflicts.observe(neighbors.filter { !$0.isIPv6 && lan.contains($0.interface) }, at: date)
        try await devices.record(sightings, events: presence.update(seen: Set(sightings.map(\.mac))), at: date)
        try await metrics?.addDeviceTraffic(trafficDeltas(sightings), at: date)
        resolveHostnames(of: sightings)

        return ScanReport(date: date, interfaces: interfaces, configuration: InterfaceReader.configuration(),
                          sweeps: sweeps, devicesSeen: sightings.count, conflicts: conflicts.current(at: date))
    }

    /// Bytes each device moved since the previous scan, for devices whose integration reports running totals.
    private func trafficDeltas(_ sightings: [DeviceSighting]) -> [(mac: MACAddress, received: UInt64, sent: UInt64)] {
        sightings.compactMap { sighting in
            guard let received = sighting.receivedBytes, let sent = sighting.sentBytes else { return nil }
            defer { lastBytes[sighting.mac] = (received, sent) }
            guard let last = lastBytes[sighting.mac], received >= last.received, sent >= last.sent else { return nil }
            return (sighting.mac, received - last.received, sent - last.sent)
        }
    }

    static func isLAN(_ interface: NetworkInterface) -> Bool {
        interface.isUp && !interface.isLoopback && !interface.isPointToPoint && interface.ipv4 != nil
    }

    /// One sighting per MAC address. Only interfaces carrying an IPv4 address count, which leaves out
    /// AirDrop/peer-to-peer interfaces whose "neighbours" are passing strangers.
    static func merge(interfaces: [NetworkInterface], neighbors: [Neighbor], thisMacName: String?) -> [DeviceSighting] {
        let lan = interfaces.filter(isLAN)
        let lanNames = Set(lan.map(\.name))
        var byMAC: [MACAddress: DeviceSighting] = [:]
        var order: [MACAddress] = []

        func sighting(_ mac: MACAddress, interface: String) -> DeviceSighting {
            if byMAC[mac] == nil { order.append(mac) }
            return byMAC[mac] ?? DeviceSighting(mac: mac, interface: interface)
        }

        for interface in lan {
            guard let mac = interface.mac else { continue }
            var entry = sighting(mac, interface: interface.name)
            entry.isThisMac = true
            entry.hostname = thisMacName
            entry.ipv4 = entry.ipv4 ?? interface.ipv4
            entry.ipv6 += interface.ipv6
            byMAC[mac] = entry
        }
        for neighbor in neighbors where lanNames.contains(neighbor.interface) {
            var entry = sighting(neighbor.mac, interface: neighbor.interface)
            if neighbor.isIPv6 {
                entry.ipv6.append(neighbor.ip)
            } else if entry.ipv4 == nil {
                // shortcut: one IPv4 per MAC; a proxy-ARP router answering for many addresses shows only the first.
                entry.ipv4 = neighbor.ip
            }
            byMAC[neighbor.mac] = entry
        }
        return order.compactMap { byMAC[$0] }.map { entry in
            var entry = entry
            // Routable addresses first, link-local (fe80::) last.
            entry.ipv6 = Array(Set(entry.ipv6)).sorted { ($0.hasPrefix("fe80") ? 1 : 0, $0) < ($1.hasPrefix("fe80") ? 1 : 0, $1) }
            return entry
        }
    }

    /// Adds what each device advertises over Bonjour, matched by IP address.
    static func attach(_ hosts: [BonjourHost], to sightings: [DeviceSighting]) -> [DeviceSighting] {
        let hosts = hosts.sorted { $0.hostname < $1.hostname }   // deterministic when two names share an address
        return sightings.map { sighting in
            var sighting = sighting
            let addresses = Set(sighting.ipv6 + [sighting.ipv4].compactMap { $0 })
            for host in hosts where !host.addresses.isDisjoint(with: addresses) {
                sighting.hostname = sighting.hostname ?? host.hostname
                sighting.services = Set(sighting.services).union(host.serviceTypes).sorted()
                sighting.model = sighting.model ?? host.model
            }
            return sighting
        }
    }

    /// Combines what integrations report with what this Mac saw, per MAC address. This Mac's own observations
    /// win for address and name; integrations are the only source for attachment details.
    static func layer(_ remote: [DeviceSighting], onto local: [DeviceSighting]) -> [DeviceSighting] {
        var result = local
        var position = Dictionary(local.enumerated().map { ($1.mac, $0) }, uniquingKeysWith: { first, _ in first })
        for client in remote {
            guard let index = position[client.mac] else {
                position[client.mac] = result.count
                result.append(client)
                continue
            }
            var merged = result[index]
            merged.ipv4 = merged.ipv4 ?? client.ipv4
            merged.hostname = merged.hostname ?? client.hostname
            merged.connection = client.connection ?? merged.connection
            merged.ssid = client.ssid ?? merged.ssid
            merged.uplink = client.uplink ?? merged.uplink
            merged.vlan = client.vlan ?? merged.vlan
            merged.isBlocked = client.isBlocked ?? merged.isBlocked
            merged.receivedBytes = client.receivedBytes ?? merged.receivedBytes
            merged.sentBytes = client.sentBytes ?? merged.sentBytes
            merged.integrationID = client.integrationID ?? merged.integrationID
            result[index] = merged
        }
        return result
    }

    /// Reverse-DNS each new address once per app run, in the background; results arrive through the store.
    private func resolveHostnames(of sightings: [DeviceSighting]) {
        let pending = sightings
            .filter { !$0.isThisMac && $0.hostname == nil }
            .compactMap { sighting in sighting.ipv4.map { (sighting.mac, $0) } }
            .filter { resolvedAddresses.insert($0.1).inserted }
        let devices = devices
        for (mac, ip) in pending {
            Task {
                if let name = await ReverseDNS.hostname(for: ip) {
                    try? await devices.setHostname(name, for: mac)
                }
            }
        }
    }
}

/// Turns per-scan sightings into appeared/disappeared events for this app session.
struct PresenceTracker {
    /// A sleeping phone can miss a scan or two; only this many misses in a row count as gone.
    static let missesBeforeGone = 3

    private var present: Set<MACAddress>?
    private var misses: [MACAddress: Int] = [:]

    mutating func update(seen: Set<MACAddress>) -> [(MACAddress, ConnectionEvent.Kind)] {
        // The first scan only establishes who is here; what happened while the app was closed is unknown.
        guard var present else {
            self.present = seen
            return []
        }
        var events: [(MACAddress, ConnectionEvent.Kind)] = []
        for mac in seen {
            misses[mac] = nil
            if present.insert(mac).inserted { events.append((mac, .appeared)) }
        }
        for mac in present.subtracting(seen) {
            misses[mac, default: 0] += 1
            if misses[mac]! >= Self.missesBeforeGone {
                present.remove(mac)
                misses[mac] = nil
                events.append((mac, .disappeared))
            }
        }
        self.present = present
        return events.sorted { $0.0.description < $1.0.description }
    }
}

public struct AddressConflict: Sendable, Equatable, Identifiable {
    public var id: String { ip }
    public var ip: String
    public var macs: [MACAddress]
    public var lastChange: Date
}

/// Two devices fighting over one IPv4 address make this Mac's ARP entry flip between their MAC addresses.
/// One change is normal (DHCP handed the address to someone else); flipping back is not.
struct ConflictDetector {
    static let window: TimeInterval = 600
    static let changesToFlag = 2

    private var owner: [String: MACAddress] = [:]
    private var changes: [String: [(mac: MACAddress, at: Date)]] = [:]

    mutating func observe(_ neighbors: [Neighbor], at date: Date) {
        for neighbor in neighbors {
            if let previous = owner[neighbor.ip], previous != neighbor.mac {
                changes[neighbor.ip, default: [(previous, date)]].append((neighbor.mac, date))
            }
            owner[neighbor.ip] = neighbor.mac
        }
    }

    func current(at date: Date) -> [AddressConflict] {
        changes.compactMap { ip, history in
            let recent = history.filter { date.timeIntervalSince($0.at) <= Self.window }
            // First element is the original owner, so N changes means N+1 entries.
            guard recent.count > Self.changesToFlag, let last = recent.last else { return nil }
            let macs = Array(Set(recent.map(\.mac))).sorted { $0.description < $1.description }
            return macs.count > 1 ? AddressConflict(ip: ip, macs: macs, lastChange: last.at) : nil
        }
        .sorted { $0.ip < $1.ip }
    }
}
