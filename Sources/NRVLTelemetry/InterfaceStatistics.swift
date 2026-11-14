import Darwin

/// Total bytes an interface of this Mac has received and sent since it came up.
public struct InterfaceCounters: Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }

    /// Bytes per second between two readings; nil if the counters were reset in between.
    public func rate(since earlier: InterfaceCounters, seconds: Double) -> (down: Double, up: Double)? {
        guard seconds > 0, received >= earlier.received, sent >= earlier.sent else { return nil }
        return (Double(received - earlier.received) / seconds, Double(sent - earlier.sent) / seconds)
    }
}

/// Reads the kernel's 64-bit per-interface counters (what `netstat -ib` shows). This is this Mac's
/// own traffic only — it says nothing about other devices on the network.
public enum InterfaceStatistics {
    public static func read() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += size / 2
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [:] }

        var counters: [String: InterfaceCounters] = [:]
        var offset = 0
        // Every record starts with: length (2 bytes), version, type.
        while offset + 4 <= size {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length >= 4, offset + length <= size else { break }
            if Int32(buffer[offset + 3]) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                let message = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                    counters[String(cString: name)] = InterfaceCounters(received: message.ifm_data.ifi_ibytes,
                                                                        sent: message.ifm_data.ifi_obytes)
                }
            }
            offset += length
        }
        return counters
    }
}
