import Darwin
import Foundation
import NRVLCore

/// Offline manufacturer lookup from the IEEE registry (Resources/oui.tsv, refreshed by Scripts/update-oui.sh).
public struct OUIRegistry: Sendable {
    private let vendors: [String: String]

    public init(tsv: String) {
        var vendors: [String: String] = [:]
        for line in tsv.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            if fields.count == 2 { vendors[String(fields[0])] = String(fields[1]) }
        }
        self.vendors = vendors
    }

    public init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(tsv: text)
    }

    public var count: Int { vendors.count }

    // shortcut: only 24-bit (MA-L) blocks are known; devices in subdivided MA-M/MA-S blocks return nil.
    public func vendor(for mac: MACAddress) -> String? {
        mac.isLocallyAdministered ? nil : vendors[mac.ouiKey]
    }
}

public enum ReverseDNS {
    /// The PTR name the configured resolver returns for an address, or nil. Never returns a numeric string.
    public static func hostname(for ip: String) async -> String? {
        // getnameinfo blocks (seconds on timeout), so keep it off Swift's cooperative threads.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: blockingLookup(ip)) }
        }
    }

    private static func blockingLookup(_ ip: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count),
                          nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: name)
    }
}
