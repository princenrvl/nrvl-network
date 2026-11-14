import Darwin
import Foundation
import NRVLCore
import Testing
@testable import NRVLDiscovery
@testable import NRVLServices

// MARK: Core addresses

@Test func macAddressParsingAndFlags() {
    let mac = MACAddress(string: "A4:83:e7:1:2:ff")
    #expect(mac?.description == "a4:83:e7:01:02:ff")
    #expect(mac?.ouiKey == "A483E7")
    #expect(mac?.isLocallyAdministered == false)
    #expect(MACAddress(string: "da:11:22:33:44:55")?.isLocallyAdministered == true)   // randomised
    #expect(MACAddress(string: "01:00:5e:00:00:fb")?.isMulticast == true)
    #expect(MACAddress(string: "a4:83:e7:01:02") == nil)
    #expect(MACAddress(string: "a4:83:e7:01:02:zz") == nil)
    #expect(MACAddress(string: "a4:83:e7:01:02:fff") == nil)
}

@Test func subnetMaths() {
    let subnet = IPv4Subnet(address: "192.168.1.37", netmask: "255.255.255.0")
    #expect(subnet?.description == "192.168.1.0/24")
    #expect(subnet?.hostAddresses == IPv4.parse("192.168.1.1")!...IPv4.parse("192.168.1.254")!)
    #expect(subnet?.contains(IPv4.parse("192.168.1.200")!) == true)
    #expect(subnet?.contains(IPv4.parse("192.168.2.1")!) == false)
    #expect(subnet?.isPrivate == true)

    #expect(IPv4Subnet(address: "172.20.5.9", netmask: "255.255.252.0")?.description == "172.20.4.0/22")
    #expect(IPv4Subnet(address: "8.8.8.8", netmask: "255.255.255.0")?.isPrivate == false)
    #expect(IPv4Subnet(address: "172.32.0.1", netmask: "255.255.0.0")?.isPrivate == false)
    #expect(IPv4Subnet(address: "10.0.0.1", netmask: "255.255.255.254")?.hostAddresses == nil)   // /31
    #expect(IPv4Subnet(address: "10.0.0.1", netmask: "255.0.255.0") == nil)                      // not contiguous
    #expect(IPv4.parse("1.2.3") == nil)
    #expect(IPv4.parse("1.2.3.256") == nil)
}

// MARK: Neighbour table parser

/// Builds one routing-socket record the way the kernel lays it out.
private func record(family: Int32, ip: [UInt8], mac: [UInt8], addrs: Int32 = RTA_DST | RTA_GATEWAY) -> [UInt8] {
    let destination: [UInt8] = family == AF_INET
        ? [16, UInt8(AF_INET), 0, 0] + ip + [UInt8](repeating: 0, count: 8)
        : [28, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + ip + [0, 0, 0, 0]
    var link: [UInt8] = [20, UInt8(AF_LINK), 0, 0, 6, 0, UInt8(mac.count), 0] + mac
    link += [UInt8](repeating: 0, count: 20 - link.count)

    var header = rt_msghdr()
    header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + destination.count + link.count)
    header.rtm_addrs = addrs
    return withUnsafeBytes(of: header) { Array($0) } + destination + link
}

@Test func parsesIPv4AndIPv6Neighbours() {
    let linkLocalWithEmbeddedScope: [UInt8] = [0xFE, 0x80, 0x00, 0x0E] + [UInt8](repeating: 0, count: 11) + [0x01]
    let buffer =
        record(family: AF_INET, ip: [192, 168, 1, 1], mac: [0xA4, 0x83, 0xE7, 1, 2, 3])
        + record(family: AF_INET6, ip: linkLocalWithEmbeddedScope, mac: [0xA4, 0x83, 0xE7, 1, 2, 3])
        + record(family: AF_INET, ip: [192, 168, 1, 50], mac: [])                                // unresolved
        + record(family: AF_INET, ip: [224, 0, 0, 251], mac: [0x01, 0x00, 0x5E, 0, 0, 0xFB])     // multicast
        + record(family: AF_INET, ip: [192, 168, 1, 9], mac: [2, 2, 2, 2, 2, 2], addrs: RTA_DST) // no link address

    let neighbors = NeighborTable.parse(buffer)
    #expect(neighbors.map(\.ip) == ["192.168.1.1", "fe80::1"])
    #expect(neighbors.map(\.isIPv6) == [false, true])
    #expect(neighbors.allSatisfy { $0.mac.description == "a4:83:e7:01:02:03" })
}

@Test func truncatedBufferDoesNotCrash() {
    let whole = record(family: AF_INET, ip: [10, 0, 0, 1], mac: [0xA4, 0x83, 0xE7, 1, 2, 3])
    for length in 0..<whole.count {
        #expect(NeighborTable.parse(Array(whole.prefix(length))).isEmpty)
    }
    #expect(NeighborTable.parse(whole).count == 1)
}

@Test func liveTableReadReturnsWellFormedEntries() {
    // Reads the real kernel table; content depends on the network, shape must not.
    for neighbor in NeighborTable.read() {
        #expect(!neighbor.ip.isEmpty)
        #expect(!neighbor.mac.isMulticast)
    }
}

// MARK: Manufacturer lookup

@Test func manufacturerLookup() {
    let registry = OUIRegistry(tsv: "A483E7\tApple, Inc.\nDA1122\tShould Never Match\n")
    #expect(registry.vendor(for: MACAddress(string: "a4:83:e7:aa:bb:cc")!) == "Apple, Inc.")
    #expect(registry.vendor(for: MACAddress(string: "00:11:22:33:44:55")!) == nil)
    // Randomised addresses are not registered to anyone, even if the prefix collides.
    #expect(registry.vendor(for: MACAddress(string: "da:11:22:33:44:55")!) == nil)
}

// MARK: Merge

@Test func mergeBuildsOneSightingPerDevice() {
    let own = MACAddress(string: "a4:83:e7:00:00:01")!
    let router = MACAddress(string: "b0:be:76:00:00:02")!
    let stranger = MACAddress(string: "de:ad:be:ef:00:03")!

    let interfaces = [
        NetworkInterface(name: "lo0", ipv4: "127.0.0.1", netmask: "255.0.0.0", isLoopback: true),
        NetworkInterface(name: "en0", mac: own, ipv4: "192.168.1.5", netmask: "255.255.255.0", ipv6: ["fe80::5"]),
        NetworkInterface(name: "awdl0", mac: stranger, ipv6: ["fe80::99"]),   // no IPv4 → not a LAN interface
    ]
    let neighbors = [
        Neighbor(ip: "192.168.1.1", isIPv6: false, mac: router, interface: "en0"),
        Neighbor(ip: "192.168.1.254", isIPv6: false, mac: router, interface: "en0"),
        Neighbor(ip: "fe80::1", isIPv6: true, mac: router, interface: "en0"),
        Neighbor(ip: "2001:db8::1", isIPv6: true, mac: router, interface: "en0"),
        Neighbor(ip: "192.168.1.5", isIPv6: false, mac: own, interface: "en0"),   // the kernel lists our own address too
        Neighbor(ip: "fe80::77", isIPv6: true, mac: stranger, interface: "awdl0"),
    ]

    let sightings = InventoryService.merge(interfaces: interfaces, neighbors: neighbors, thisMacName: "Test Mac")
    #expect(sightings == [
        DeviceSighting(mac: own, ipv4: "192.168.1.5", ipv6: ["fe80::5"], interface: "en0", isThisMac: true, hostname: "Test Mac"),
        DeviceSighting(mac: router, ipv4: "192.168.1.1", ipv6: ["2001:db8::1", "fe80::1"], interface: "en0"),
    ])
}

// MARK: Bonjour attach, presence, classification

@Test func bonjourDataAttachesByAddress() {
    let printer = DeviceSighting(mac: MACAddress(string: "00:11:22:33:44:55")!, ipv4: "192.168.1.20", interface: "en0")
    let silent = DeviceSighting(mac: MACAddress(string: "00:11:22:33:44:66")!, ipv4: "192.168.1.21", interface: "en0")
    let own = DeviceSighting(mac: MACAddress(string: "00:11:22:33:44:77")!, ipv6: ["fe80::7"], interface: "en0",
                             isThisMac: true, hostname: "My Mac")
    let hosts = [
        BonjourHost(hostname: "Office-Printer.local", addresses: ["192.168.1.20"], serviceTypes: ["_ipp._tcp", "_http._tcp"]),
        BonjourHost(hostname: "my-mac.local", addresses: ["fe80::7"], serviceTypes: ["_ssh._tcp"], model: "MacBookPro18,3"),
        BonjourHost(hostname: "elsewhere.local", addresses: ["10.9.9.9"], serviceTypes: ["_smb._tcp"]),
    ]

    let result = InventoryService.attach(hosts, to: [printer, silent, own])
    #expect(result[0].hostname == "Office-Printer.local")
    #expect(result[0].services == ["_http._tcp", "_ipp._tcp"])
    #expect(result[1] == silent)
    #expect(result[2].hostname == "My Mac")            // an existing name is kept
    #expect(result[2].model == "MacBookPro18,3")
}

@Test func presenceNeedsThreeMissesBeforeGone() {
    let a = MACAddress(string: "00:00:00:00:00:0a")!, b = MACAddress(string: "00:00:00:00:00:0b")!
    var tracker = PresenceTracker()
    func kinds(_ seen: Set<MACAddress>) -> [String] { tracker.update(seen: seen).map { "\($0.0.bytes[5]):\($0.1.rawValue)" } }

    #expect(kinds([a]).isEmpty)                    // baseline
    #expect(kinds([a, b]) == ["11:appeared"])
    #expect(kinds([b]).isEmpty)                    // a missed once
    #expect(kinds([b]).isEmpty)                    // twice
    #expect(kinds([a, b]).isEmpty)                 // back in time: no event, counter reset
    #expect(kinds([b]).isEmpty)
    #expect(kinds([b]).isEmpty)
    #expect(kinds([b]) == ["10:disappeared"])      // three in a row
    #expect(kinds([a, b]) == ["10:appeared"])
}

@Test func classificationStatesItsBasis() {
    func device(services: [String] = [], model: String? = nil, isThisMac: Bool = false) -> Device {
        Device(id: 1, mac: MACAddress(string: "00:11:22:33:44:55")!, interface: "en0", isThisMac: isThisMac,
               services: services, model: model, firstSeen: .distantPast, lastSeen: .distantPast)
    }
    #expect(DeviceClassifier.classify(device(), isGateway: false) == nil)   // no evidence, no guess
    #expect(DeviceClassifier.classify(device(), isGateway: true)?.kind == "Router / Gateway")
    #expect(DeviceClassifier.classify(device(isThisMac: true), isGateway: false)?.confidence == .confirmed)

    let laptop = DeviceClassifier.classify(device(services: ["_ssh._tcp"], model: "MacBookPro18,3"), isGateway: false)
    #expect(laptop?.kind == "Mac laptop")
    #expect(laptop?.confidence == .confirmed)

    let printer = DeviceClassifier.classify(device(services: ["_http._tcp", "_ipp._tcp"]), isGateway: false)
    #expect(printer?.kind == "Printer")
    #expect(printer?.confidence == .inferred)
    #expect(printer?.basis == "Advertises _ipp._tcp")
}

@Test func conflictNeedsTheAddressToFlipBack() {
    let a = MACAddress(string: "00:00:00:00:00:0a")!, b = MACAddress(string: "00:00:00:00:00:0b")!
    func neighbor(_ mac: MACAddress) -> [Neighbor] { [Neighbor(ip: "192.168.1.50", isIPv6: false, mac: mac, interface: "en0")] }
    let start = Date(timeIntervalSince1970: 0)
    var detector = ConflictDetector()

    detector.observe(neighbor(a), at: start)
    detector.observe(neighbor(b), at: start + 60)      // handed to another device: normal
    #expect(detector.current(at: start + 60).isEmpty)
    detector.observe(neighbor(a), at: start + 120)     // flipped back: two devices claim it
    #expect(detector.current(at: start + 120).map(\.macs) == [[a, b]])
    #expect(detector.current(at: start + 3_600).isEmpty)   // old flips age out
}

@Test func integrationDataLayersOntoLocalSightings() {
    let seen = MACAddress(string: "00:11:22:33:44:55")!, remoteOnly = MACAddress(string: "00:11:22:33:44:66")!
    let local = [DeviceSighting(mac: seen, ipv4: "192.168.1.20", interface: "en0", hostname: "printer.local")]
    let remote = [
        DeviceSighting(mac: seen, ipv4: "192.168.1.99", hostname: "dhcp-name", connection: .wireless, ssid: "Office",
                       uplink: "Hall AP", vlan: 20, integrationID: 3),
        DeviceSighting(mac: remoteOnly, ipv4: "10.0.5.7", connection: .wired, uplink: "Switch port 4", integrationID: 3),
    ]
    let result = InventoryService.layer(remote, onto: local)
    #expect(result.count == 2)
    #expect(result[0].ipv4 == "192.168.1.20" && result[0].hostname == "printer.local")   // this Mac's view wins
    #expect(result[0].ssid == "Office" && result[0].vlan == 20 && result[0].connection == .wireless)
    #expect(result[0].interface == "en0")
    #expect(result[1].mac == remoteOnly && result[1].interface.isEmpty)                  // other subnet: integration only
}

@Test func keychainStoresAndDeletesASecret() throws {
    let store = CredentialStore(service: "com.nrvl.network.tests")
    defer { try? store.delete(account: "unit") }
    try store.set("first", account: "unit")
    try store.set("second", account: "unit")           // update, not duplicate
    #expect(try store.get(account: "unit") == "second")
    try store.delete(account: "unit")
    #expect(try store.get(account: "unit") == nil)
    try store.delete(account: "unit")                   // deleting nothing is not an error
}
