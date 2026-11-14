import Foundation

public struct MACAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        self.bytes = Array(bytes)
    }

    /// Accepts "aa:bb:cc:dd:ee:ff", "AA-BB-…" and the unpadded form `arp` prints ("a:b:c:d:e:f").
    public init?(string: String) {
        let parts = string.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
            .map { $0.count <= 2 ? UInt8($0, radix: 16) : nil }
        guard parts.count == 6, !parts.contains(nil) else { return nil }
        bytes = parts.compactMap { $0 }
    }

    public var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Set on randomised "private" Wi-Fi addresses; such an address has no manufacturer.
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }
    public var isMulticast: Bool { bytes[0] & 0x01 != 0 }
    /// Key into the IEEE registry: first three bytes, upper-case hex.
    public var ouiKey: String { bytes.prefix(3).map { String(format: "%02X", $0) }.joined() }
}

public enum IPv4 {
    public static func parse(_ dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func string(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }
}

public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    public let network: UInt32
    public let prefixLength: Int

    public init?(address: String, netmask: String) {
        guard let ip = IPv4.parse(address), let mask = IPv4.parse(netmask),
              (~mask).leadingZeroBitCount == mask.nonzeroBitCount else { return nil }   // contiguous ones
        network = ip & mask
        prefixLength = mask.nonzeroBitCount
    }

    private var mask: UInt32 { prefixLength == 0 ? 0 : ~0 << (32 - UInt32(prefixLength)) }

    public func contains(_ ip: UInt32) -> Bool { ip & mask == network }

    /// Usable host addresses (excludes network and broadcast). Nil for /31 and /32.
    public var hostAddresses: ClosedRange<UInt32>? {
        prefixLength <= 30 ? (network + 1)...((network | ~mask) - 1) : nil
    }

    /// RFC 1918 and link-local ranges — the only ones the app actively probes.
    public var isPrivate: Bool {
        let a = network >> 24, b = network >> 16 & 0xFF
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    public var description: String { "\(IPv4.string(network))/\(prefixLength)" }
}
