import Darwin
import Foundation
import NRVLCore
import Testing
@testable import NRVLAdapters

// MARK: BER

@Test func berEncodesKnownVectors() {
    #expect(BER.encode(.oid(OID("1.3.6.1.2.1.1.1.0").arcs)) == [0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00])
    #expect(BER.encode(.oid([1, 3, 6, 1, 4, 1, 2680, 1])) == [0x06, 0x08, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x94, 0x78, 0x01])
    #expect(BER.encode(.integer(127)) == [0x02, 0x01, 0x7F])
    #expect(BER.encode(.integer(128)) == [0x02, 0x02, 0x00, 0x80])
    #expect(BER.encode(.integer(-1)) == [0x02, 0x01, 0xFF])
    #expect(BER.encode(.integer(-129)) == [0x02, 0x02, 0xFF, 0x7F])
    #expect(BER.encode(.unsigned(tag: 0x41, 0xFFFF_FFFF)) == [0x41, 0x05, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
    #expect(BER.encode(.octets([UInt8](repeating: 7, count: 200))).prefix(3) == [0x04, 0x81, 0xC8])
    #expect(BER.encode(.octets([UInt8](repeating: 7, count: 300))).prefix(4) == [0x04, 0x82, 0x01, 0x2C])
}

@Test func berRoundTrips() throws {
    let values: [BER.Value] = [
        .integer(0), .integer(-1), .integer(Int64(Int32.max)), .integer(-70_000),
        .octets(Array("public".utf8)), .null, .oid([1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 6, 4_294_967_295]),
        .ipAddress([192, 168, 1, 1]), .unsigned(tag: 0x46, UInt64.max), .unsigned(tag: 0x43, 0), .exception(0x82),
        .sequence(tag: 0xA2, [.integer(5), .sequence(tag: 0x30, [.octets([UInt8](repeating: 1, count: 400))])]),
    ]
    for value in values { #expect(try BER.decode(BER.encode(value)) == value) }
}

@Test func berRejectsMalformedInput() {
    let whole = BER.encode(.sequence(tag: 0x30, [.integer(1), .octets(Array("public".utf8)), .oid([1, 3, 6, 1])]))
    for length in 0..<whole.count {   // every truncation must throw, never crash
        #expect(throws: BER.Malformed.self) { try BER.decode(Array(whole.prefix(length))) }
    }
    #expect(throws: BER.Malformed.self) { try BER.decode([0x04, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]) }   // absurd length
    #expect(throws: BER.Malformed.self) { try BER.decode([0x99, 0x00]) }                           // unknown tag
    var nested: [UInt8] = [0x05, 0x00]
    for _ in 0..<20 { nested = [0x30, UInt8(nested.count)] + nested }
    #expect(throws: BER.Malformed.self) { try BER.decode(nested) }                                 // too deep
}

@Test func responseMustMatchTheRequest() throws {
    func response(id: Int64, status: Int64 = 0) -> [UInt8] {
        BER.encode(.sequence(tag: 0x30, [.integer(1), .octets([]), .sequence(tag: 0xA2, [
            .integer(id), .integer(status), .integer(0),
            .sequence(tag: 0x30, [.sequence(tag: 0x30, [.oid([1, 3, 6, 1]), .integer(9)])]),
        ])]))
    }
    #expect(try SNMPClient.parse(response(id: 42), expecting: 42).first?.value == .integer(9))
    #expect(throws: AdapterError.self) { try SNMPClient.parse(response(id: 41), expecting: 42) }
    #expect(throws: AdapterError.self) { try SNMPClient.parse(response(id: 42, status: 5), expecting: 42) }
    #expect(throws: AdapterError.self) { try SNMPClient.parse([0x30, 0x00], expecting: 42) }
}

// MARK: Simulated agent

/// A minimal SNMP agent on loopback serving a fixed table. Test-only: a simulated network device.
final class SimulatedAgent: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let table: [(oid: [UInt32], value: BER.Value)]
    let community: String

    init(community: String = "test-community", _ rows: [(String, BER.Value)]) {
        self.community = community
        table = rows.map { (OID(stringLiteral: $0.0).arcs, $0.1) }.sorted { $0.oid.lexicographicallyPrecedes($1.oid) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    deinit { close(fd) }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength) }
            }
            guard count > 0 else { return }
            guard case .sequence(_, let message)? = try? BER.decode(Array(buffer.prefix(count))), message.count == 3,
                  message[1] == .octets(Array(community.utf8)),   // wrong community: stay silent, like a real agent
                  case .sequence(let pdu, let fields) = message[2], fields.count == 4,
                  case .integer(let maxRepetitions) = fields[2], case .sequence(_, let requested) = fields[3] else { continue }

            var bindings: [BER.Value] = []
            for item in requested {
                guard case .sequence(_, let pair) = item, case .oid(let oid)? = pair.first else { continue }
                if pdu == 0xA0 {
                    let value = table.first { $0.oid == oid }?.value ?? .exception(0x80)
                    bindings.append(.sequence(tag: 0x30, [.oid(oid), value]))
                } else {
                    let next = table.filter { oid.lexicographicallyPrecedes($0.oid) }.prefix(Int(maxRepetitions))
                    if next.isEmpty { bindings.append(.sequence(tag: 0x30, [.oid(oid), .exception(0x82)])) }
                    bindings += next.map { .sequence(tag: 0x30, [.oid($0.oid), $0.value]) }
                }
            }
            let reply = BER.encode(.sequence(tag: 0x30, [message[0], message[1], .sequence(tag: 0xA2, [
                fields[0], .integer(0), .integer(0), .sequence(tag: 0x30, bindings),
            ])]))
            _ = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, peerLength) }
            }
        }
    }

    func client(community: String? = nil) -> SNMPClient {
        SNMPClient(host: "127.0.0.1", port: port, community: community ?? self.community, timeout: 0.3, retries: 0)
    }
}

private let switchRows: [(String, BER.Value)] = [
    ("1.3.6.1.2.1.1.1.0", .octets(Array("Simulated 8-port switch".utf8))),
    ("1.3.6.1.2.1.1.5.0", .octets(Array("lab-switch".utf8))),
    // ARP: ifIndex 1, 192.168.1.20 and .21
    ("1.3.6.1.2.1.4.22.1.2.1.192.168.1.20", .octets([0xA4, 0x83, 0xE7, 0, 0, 0x20])),
    ("1.3.6.1.2.1.4.22.1.2.1.192.168.1.21", .octets([0xA4, 0x83, 0xE7, 0, 0, 0x21])),
    ("1.3.6.1.2.1.4.22.1.2.1.224.0.0.251", .octets([0x01, 0x00, 0x5E, 0, 0, 0xFB])),   // multicast: ignored
    // Addresses
    ("1.3.6.1.2.1.4.20.1.3.127.0.0.1", .ipAddress([255, 0, 0, 0])),
    ("1.3.6.1.2.1.4.20.1.3.192.168.1.2", .ipAddress([255, 255, 255, 0])),
    // Bridge: port 5 → ifIndex 105; forwarding table: …20 on port 5, …99 (no ARP entry) on port 7
    ("1.3.6.1.2.1.17.1.4.1.2.5", .integer(105)),
    ("1.3.6.1.2.1.17.4.3.1.2.164.131.231.0.0.32", .integer(5)),
    ("1.3.6.1.2.1.17.4.3.1.2.164.131.231.0.0.153", .integer(7)),
    ("1.3.6.1.2.1.31.1.1.1.1.105", .octets(Array("ge-0/0/5".utf8))),
    ("1.3.6.1.2.1.31.1.1.1.6.105", .unsigned(tag: 0x46, 5_000_000_000)),
    ("1.3.6.1.2.1.31.1.1.1.10.105", .unsigned(tag: 0x46, 1_000)),
]

@Test func walkStopsAtTheEndOfTheSubtree() async throws {
    // More rows than one GETBULK returns, followed by a neighbouring table that must not leak in.
    var rows: [(String, BER.Value)] = (1...60).map { ("1.3.6.1.2.1.31.1.1.1.1.\($0)", .octets(Array("if\($0)".utf8))) }
    rows.append(("1.3.6.1.2.1.31.1.1.1.2.1", .integer(1)))
    let agent = SimulatedAgent(rows)

    let walked = try await agent.client().walk("1.3.6.1.2.1.31.1.1.1.1")
    #expect(walked.count == 60)
    #expect(walked.last?.oid.description == "1.3.6.1.2.1.31.1.1.1.1.60")
    #expect(try await agent.client().walk("1.3.6.1.2.1.99").isEmpty)
    #expect(try await agent.client().walk("1.3.6.1.2.1.31.1.1.1.1", limit: 1).count >= 1)
}

@Test func adapterReadsASimulatedSwitch() async throws {
    let agent = SimulatedAgent(switchRows)
    let adapter = SNMPAdapter(client: agent.client())

    #expect(try await adapter.identify() == AdapterIdentity(name: "lab-switch", model: "Simulated 8-port switch"))

    let clients = try await adapter.clients()
    #expect(clients.map(\.mac.description) == ["a4:83:e7:00:00:20", "a4:83:e7:00:00:21", "a4:83:e7:00:00:99"])
    #expect(clients[0].ipv4 == "192.168.1.20")
    #expect(clients[0].uplink == "lab-switch port ge-0/0/5")   // port resolved to its interface name
    #expect(clients[1].uplink == nil)                           // in ARP but not in the forwarding table
    #expect(clients[2].ipv4 == nil && clients[2].uplink == "lab-switch port 7")

    #expect(try await adapter.networks() == [NetworkRecord(name: "192.168.1.0/24", cidr: "192.168.1.0/24")])
    let counters = try await adapter.interfaceCounters()
    #expect(counters["ge-0/0/5"]?.received == 5_000_000_000 && counters["ge-0/0/5"]?.sent == 1_000)

    let capabilities = try await adapter.capabilities()
    #expect(capabilities[.clientInventory] == .readOnly)
    #expect(capabilities[.trafficStatistics] == .readOnly)
    if case .unsupported = capabilities[.accessControl] {} else { Issue.record("SNMP must never claim access control") }
}

@Test func missingTablesAreReportedUnsupported() async throws {
    let agent = SimulatedAgent([("1.3.6.1.2.1.1.1.0", .octets(Array("Bare device".utf8))), ("1.3.6.1.2.1.1.5.0", .octets(Array("bare".utf8)))])
    let capabilities = try await SNMPAdapter(client: agent.client()).capabilities()
    for feature in [Feature.clientInventory, .networks, .trafficStatistics] {
        if case .unsupported = capabilities[feature] {} else { Issue.record("\(feature) should be unsupported") }
    }
}

@Test func wrongCommunityAndDeadHostFailCleanly() async {
    let agent = SimulatedAgent(switchRows)
    await #expect(throws: AdapterError.timeout) { try await SNMPAdapter(client: agent.client(community: "wrong")).identify() }
    let dead = SNMPClient(host: "127.0.0.1", port: 1, community: "x", timeout: 0.3, retries: 0)
    await #expect(throws: AdapterError.self) { try await SNMPAdapter(client: dead).identify() }
    let unresolvable = SNMPClient(host: "no such host.invalid", community: "x", timeout: 0.3, retries: 0)
    await #expect(throws: AdapterError.self) { try await SNMPAdapter(client: unresolvable).identify() }
}

// MARK: TLS policy

@Test func tlsPolicy() {
    #expect(TLSPolicy.accepts(pinned: "ABCD", presented: "abcd", systemTrusted: false))    // approved self-signed
    #expect(!TLSPolicy.accepts(pinned: "abcd", presented: "ffff", systemTrusted: true))    // changed, even if publicly valid
    #expect(TLSPolicy.accepts(pinned: nil, presented: "abcd", systemTrusted: true))        // public CA, first contact
    #expect(!TLSPolicy.accepts(pinned: nil, presented: "abcd", systemTrusted: false))      // self-signed, not yet approved
}
