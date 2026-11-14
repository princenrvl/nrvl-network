import Darwin
import Foundation

/// One flow as exported by a router: who talked to whom, on which port, and how much.
public struct FlowRecord: Sendable, Equatable {
    public var source: String
    public var destination: String
    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var protocolNumber: UInt8
    public var packets: UInt32
    public var bytes: UInt32
}

public enum NetFlowV5 {
    /// Parses one export datagram. Anything that is not a well-formed v5 packet yields no records.
    public static func parse(_ datagram: [UInt8]) -> [FlowRecord] {
        let headerSize = 24, recordSize = 48
        guard datagram.count >= headerSize, datagram[0] == 0, datagram[1] == 5 else { return [] }
        let count = Int(datagram[2]) << 8 | Int(datagram[3])
        guard (1...30).contains(count), datagram.count >= headerSize + count * recordSize else { return [] }

        func u16(_ offset: Int) -> UInt16 { UInt16(datagram[offset]) << 8 | UInt16(datagram[offset + 1]) }
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(datagram[offset + $1]) } }
        func address(_ offset: Int) -> String { datagram[offset..<(offset + 4)].map(String.init).joined(separator: ".") }

        return (0..<count).map { index in
            let base = headerSize + index * recordSize
            return FlowRecord(source: address(base), destination: address(base + 4), sourcePort: u16(base + 32),
                              destinationPort: u16(base + 34), protocolNumber: datagram[base + 38],
                              packets: u32(base + 16), bytes: u32(base + 20))
        }
    }

    public static func protocolName(_ number: UInt8) -> String {
        [1: "ICMP", 2: "IGMP", 6: "TCP", 17: "UDP", 47: "GRE", 50: "ESP", 58: "ICMPv6"][number] ?? "Protocol \(number)"
    }
}

/// Running totals since the collector started.
public struct FlowSummary: Sendable, Equatable {
    public var since = Date()
    public var flows = 0
    public var totalBytes: UInt64 = 0
    public var exporters: Set<String> = []
    public var byProtocol: [String: UInt64] = [:]
    public var byDestinationPort: [UInt16: UInt64] = [:]
    public var byDestination: [String: UInt64] = [:]
    public var bySource: [String: UInt64] = [:]

    // shortcut: at most this many distinct keys per table; flows to further keys still count in the totals.
    static let maxKeys = 5_000

    mutating func add(_ record: FlowRecord, exporter: String) {
        flows += 1
        totalBytes += UInt64(record.bytes)
        exporters.insert(exporter)
        byProtocol[NetFlowV5.protocolName(record.protocolNumber), default: 0] += UInt64(record.bytes)
        func bump<Key: Hashable>(_ table: inout [Key: UInt64], _ key: Key) {
            if table[key] != nil || table.count < Self.maxKeys { table[key, default: 0] += UInt64(record.bytes) }
        }
        bump(&byDestinationPort, record.destinationPort)
        bump(&byDestination, record.destination)
        bump(&bySource, record.source)
    }
}

/// Listens for NetFlow v5 exports that a router is configured to send to this Mac.
/// It only receives; it never captures or intercepts traffic.
// shortcut: NetFlow v5 only (IPv4, fixed format). v9/IPFIX need template handling — add when an exporter requires it.
public final class FlowCollector: @unchecked Sendable {
    public static let defaultPort: UInt16 = 2055

    private let lock = NSLock()
    private var summary = FlowSummary()
    private var fd: Int32 = -1

    public init() {}

    public var isRunning: Bool { lock.withLock { fd >= 0 } }
    public func snapshot() -> FlowSummary { lock.withLock { summary } }

    public func start(port: UInt16 = FlowCollector.defaultPort) throws {
        guard !isRunning else { return }
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(socketFD)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        lock.withLock {
            fd = socketFD
            summary = FlowSummary()
        }
        Thread.detachNewThread { [self] in receive(socketFD) }
    }

    public func stop() {
        let socketFD = lock.withLock { () -> Int32 in
            defer { fd = -1 }
            return fd
        }
        if socketFD >= 0 { close(socketFD) }   // unblocks recvfrom, ending the thread
    }

    private func receive(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            let records = NetFlowV5.parse(Array(buffer.prefix(count)))
            guard !records.isEmpty else { continue }
            let exporter = withUnsafeBytes(of: peer.sin_addr) { $0.map(String.init).joined(separator: ".") }
            lock.withLock { for record in records { summary.add(record, exporter: exporter) } }
        }
    }
}
