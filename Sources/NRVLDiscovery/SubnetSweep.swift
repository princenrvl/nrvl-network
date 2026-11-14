import Darwin
import NRVLCore

/// Makes this Mac's kernel resolve every address of a directly attached subnet, so live hosts appear
/// in the ARP table. It sends one 1-byte UDP datagram per host to the discard port; nothing is spoofed,
/// intercepted or read back, and no raw sockets or privileges are used.
public enum SubnetSweep {
    public enum Outcome: Sendable, Equatable {
        case probed(hosts: Int)
        /// macOS refused every send — Local Network access is not granted to the app.
        case permissionDenied
        case skippedTooLarge
        case failed(String)
    }

    // shortcut: subnets larger than /22 (1022 hosts) are not probed, only read passively; raise with pacing if needed.
    static let smallestPrefix = 22

    public static func probe(_ subnet: IPv4Subnet) async -> Outcome {
        guard subnet.prefixLength >= smallestPrefix, let hosts = subnet.hostAddresses else { return .skippedTooLarge }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var sent = 0, refused = 0
        for (index, host) in hosts.enumerated() {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            address.sin_addr.s_addr = host.bigEndian

            var payload: UInt8 = 0
            let (result, code) = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    let result = sendto(fd, &payload, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    return (result, errno)
                }
            }
            if result == 1 { sent += 1 } else if code == EHOSTUNREACH || code == EPERM { refused += 1 }

            if index % 32 == 31 { try? await Task.sleep(for: .milliseconds(20)) }   // ≈1,600 packets/s at most
        }
        return sent == 0 && refused > 0 ? .permissionDenied : .probed(hosts: sent)
    }
}
