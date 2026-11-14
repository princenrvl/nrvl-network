import Darwin
import Foundation

/// ICMP echo ("ping") from this Mac using an unprivileged datagram ICMP socket — no root, no raw socket.
public enum Pinger {
    /// Round-trip time in seconds, or nil if no reply arrived in time or the host is unreachable.
    public static func ping(_ ipv4: String, timeout: TimeInterval = 1) async -> TimeInterval? {
        // Blocking socket calls: keep them off Swift's cooperative threads.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: blockingPing(ipv4, timeout: timeout)) }
        }
    }

    static func blockingPing(_ ipv4: String, timeout: TimeInterval) -> TimeInterval? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ipv4, &address.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let sequence = UInt16.random(in: 0...UInt16.max)
        let packet = echoRequest(identifier: UInt16(truncatingIfNeeded: getpid()), sequence: sequence)
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> TimeInterval { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }

        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = timeout - elapsed()
            guard remaining > 0 else { return nil }
            var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1e6))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            // macOS hands back the IPv4 header too; skip it.
            let header = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
            guard count >= header + 8 else { continue }
            let isEchoReply = buffer[header] == 0
            let replySequence = UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7])
            if isEchoReply, replySequence == sequence { return elapsed() }
            // Someone else's reply (the socket sees all ICMP for this process): keep waiting.
        }
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                               UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        packet += Array("nrvl-network".utf8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// RFC 1071 Internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let low = index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0
            sum += UInt32(bytes[index]) << 8 | low
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// The most recent ping results for one target. A nil sample is a lost ping.
public struct PingWindow: Sendable, Equatable {
    public private(set) var samples: [TimeInterval?] = []
    public let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    public mutating func add(_ sample: TimeInterval?) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    private var replies: [TimeInterval] { samples.compactMap { $0 } }

    public var averageLatency: TimeInterval? {
        replies.isEmpty ? nil : replies.reduce(0, +) / Double(replies.count)
    }

    /// Mean difference between consecutive replies.
    public var jitter: TimeInterval? {
        guard replies.count >= 2 else { return nil }
        return zip(replies, replies.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(replies.count - 1)
    }

    /// 0…1; nil before the first sample.
    public var lossFraction: Double? {
        samples.isEmpty ? nil : Double(samples.count - replies.count) / Double(samples.count)
    }
}
