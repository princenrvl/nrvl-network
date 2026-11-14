import Darwin
import NRVLCore

/// Reads the kernel's ARP (IPv4) and neighbour-discovery (IPv6) tables — the same data as `arp -a` and `ndp -a`.
/// Read-only and unprivileged. It only lists devices this Mac has exchanged packets with on its own subnets.
public enum NeighborTable {
    public static func read() -> [Neighbor] {
        parse(dump(family: AF_INET)) + parse(dump(family: AF_INET6))
    }

    static func dump(family: Int32) -> [UInt8] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 2   // the table can grow between the two calls
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size))
    }

    /// Each record is an `rt_msghdr`, then the destination sockaddr (the IP), then a `sockaddr_dl` (the MAC).
    static func parse(_ buffer: [UInt8]) -> [Neighbor] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var neighbors: [Neighbor] = []
        var offset = 0

        while offset + headerSize <= buffer.count {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let body = Array(buffer[(offset + headerSize)..<(offset + length)])
            offset += length

            guard header.rtm_addrs & (RTA_DST | RTA_GATEWAY) == RTA_DST | RTA_GATEWAY, body.count >= 2 else { continue }

            let ip: String
            switch Int32(body[1]) {   // sa_family
            case AF_INET where body.count >= 8: ip = AddressText.ipv4(Array(body[4..<8]))
            case AF_INET6 where body.count >= 24: ip = AddressText.ipv6(Array(body[8..<24]))
            default: continue
            }

            // sockaddr_dl: len, family, index(2), type, nameLength, addressLength, selectorLength, then name + address.
            let link = body.dropFirst(roundedUp(Int(body[0])))
            guard link.count >= 8, Int32(link[link.startIndex + 1]) == AF_LINK else { continue }
            let index = UInt32(link[link.startIndex + 2]) | UInt32(link[link.startIndex + 3]) << 8
            let macStart = link.startIndex + 8 + Int(link[link.startIndex + 5])
            guard link[link.startIndex + 6] == 6, macStart + 6 <= link.endIndex,   // 0 = not resolved yet
                  let mac = MACAddress(bytes: link[macStart..<(macStart + 6)]), !mac.isMulticast else { continue }

            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let interface = if_indextoname(index, &name) == nil ? "" : String(cString: name)
            neighbors.append(Neighbor(ip: ip, isIPv6: body[1] == UInt8(AF_INET6), mac: mac, interface: interface))
        }
        return neighbors
    }

    /// Routing-socket sockaddrs are padded to 4 bytes.
    private static func roundedUp(_ length: Int) -> Int { length == 0 ? 4 : (length + 3) & ~3 }
}
