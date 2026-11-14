import Darwin
import Foundation
import NRVLCore
import SystemConfiguration

/// Reads this Mac's own network configuration. No special privileges or permissions needed.
public enum InterfaceReader {
    public static func interfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        let displayNames = hardwarePortNames()
        var byName: [String: NetworkInterface] = [:]
        var order: [String] = []

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            if byName[name] == nil {
                order.append(name)
                byName[name] = NetworkInterface(
                    name: name, displayName: displayNames[name],
                    isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0,
                    isPointToPoint: flags & IFF_POINTOPOINT != 0)
            }
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET where byName[name]?.ipv4 == nil:
                byName[name]?.ipv4 = ipv4String(address)
                byName[name]?.netmask = entry.pointee.ifa_netmask.map(ipv4String)
            case AF_INET6:
                let text = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { AddressText.ipv6(Array($0)) }
                }
                byName[name]?.ipv6.append(text)
            case AF_LINK:
                address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    guard link.pointee.sdl_alen == 6 else { return }
                    let start = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + Int(link.pointee.sdl_nlen)
                    let raw = UnsafeRawBufferPointer(start: UnsafeRawPointer(link).advanced(by: start), count: 6)
                    byName[name]?.mac = MACAddress(bytes: Array(raw))
                }
            default:
                break
            }
        }
        return order.compactMap { byName[$0] }
    }

    public static func configuration() -> NetworkConfiguration {
        guard let store = SCDynamicStoreCreate(nil, "NRVL Network" as CFString, nil, nil) else {
            return NetworkConfiguration()
        }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        return NetworkConfiguration(gateway: ipv4?["Router"] as? String,
                                    primaryInterface: ipv4?["PrimaryInterface"] as? String,
                                    dnsServers: dns?["ServerAddresses"] as? [String] ?? [])
    }

    private static func ipv4String(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin_addr) { AddressText.ipv4(Array($0)) }
        }
    }

    /// BSD name → the name System Settings shows ("Wi-Fi", "Ethernet", …).
    private static func hardwarePortNames() -> [String: String] {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = display
            }
        }
        return names
    }
}

enum AddressText {
    static func ipv4(_ bytes: [UInt8]) -> String { bytes.map(String.init).joined(separator: ".") }

    static func ipv6(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        // The kernel stores the interface index inside link-local addresses (bytes 2–3); it is not part of the address.
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { bytes[2] = 0; bytes[3] = 0 }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, bytes, &text, socklen_t(text.count))
        return String(cString: text)
    }
}
