import Darwin
import dnssd
import Foundation

/// What one device advertises over Bonjour (mDNS / DNS-SD).
public struct BonjourHost: Sendable, Equatable {
    /// e.g. "Living-Room.local"
    public var hostname: String
    public var addresses: Set<String> = []
    /// e.g. "_airplay._tcp"
    public var serviceTypes: Set<String> = []
    /// The model identifier some devices publish, e.g. "MacBookPro18,3".
    public var model: String?

    public init(hostname: String, addresses: Set<String> = [], serviceTypes: Set<String> = [], model: String? = nil) {
        self.hostname = hostname
        self.addresses = addresses
        self.serviceTypes = serviceTypes
        self.model = model
    }
}

/// Listens for Bonjour advertisements for as long as the app runs. It only reads what devices
/// broadcast about themselves and asks the system resolver for their addresses; it never connects to them.
///
/// Chain: list service types → list instances of each type → resolve instance to a hostname → look up its addresses.
public final class BonjourBrowser: @unchecked Sendable {
    // All mutable state is touched only on `queue`, which is also where DNS-SD delivers callbacks.
    private let queue = DispatchQueue(label: "com.nrvl.network.bonjour")
    private var connection: DNSServiceRef?
    private var browsedTypes: Set<String> = []
    private var seenInstances: Set<String> = []
    private var resolving: [DNSServiceRef: String] = [:]   // in-flight resolve → its service type
    private var queriedHosts: Set<String> = []
    private var hosts: [String: BonjourHost] = [:]

    // shortcut: fixed caps bound memory on very large networks; entries are never expired during a run.
    private static let maxTypes = 200, maxInstances = 4000

    public init() {}

    public func start() {
        queue.async { [self] in
            guard connection == nil else { return }
            var ref: DNSServiceRef?
            guard DNSServiceCreateConnection(&ref) == kDNSServiceErr_NoError, let ref else { return }
            connection = ref
            DNSServiceSetDispatchQueue(ref, queue)
            var browse: DNSServiceRef? = ref
            DNSServiceBrowse(&browse, shared, 0, "_services._dns-sd._udp", "local.", typeFound, context)
        }
    }

    public func snapshot() async -> [BonjourHost] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Array(self.hosts.values)) }
        }
    }

    private var shared: DNSServiceFlags { DNSServiceFlags(kDNSServiceFlagsShareConnection) }
    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    fileprivate func browse(type: String) {
        guard let connection, browsedTypes.count < Self.maxTypes, browsedTypes.insert(type).inserted else { return }
        var ref: DNSServiceRef? = connection
        DNSServiceBrowse(&ref, shared, 0, type, "local.", instanceFound, context)
    }

    fileprivate func resolve(name: String, type: String, domain: String, interface: UInt32) {
        guard let connection, seenInstances.count < Self.maxInstances,
              seenInstances.insert("\(interface)/\(name)/\(type)").inserted else { return }
        var ref: DNSServiceRef? = connection
        if DNSServiceResolve(&ref, shared, interface, name, type, domain, instanceResolved, context) == kDNSServiceErr_NoError,
           let ref {
            resolving[ref] = type.hasSuffix(".") ? String(type.dropLast()) : type
        }
    }

    fileprivate func resolved(_ ref: DNSServiceRef, host: String?, model: String?, interface: UInt32) {
        guard let type = resolving.removeValue(forKey: ref) else { return }
        DNSServiceRefDeallocate(ref)   // one answer is enough
        guard let host, let connection else { return }

        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        hosts[host, default: BonjourHost(hostname: name)].serviceTypes.insert(type)
        if let model { hosts[host]?.model = model }

        if queriedHosts.insert(host).inserted {
            var query: DNSServiceRef? = connection
            DNSServiceGetAddrInfo(&query, shared, interface, 0, host, addressFound, context)
        }
    }

    fileprivate func add(address: String, to host: String) {
        hosts[host]?.addresses.insert(address)
    }
}

private func browser(_ context: UnsafeMutableRawPointer?) -> BonjourBrowser? {
    context.map { Unmanaged<BonjourBrowser>.fromOpaque($0).takeUnretainedValue() }
}

private func isAdd(_ flags: DNSServiceFlags, _ error: DNSServiceErrorType) -> Bool {
    error == kDNSServiceErr_NoError && flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
}

/// Answer to the "which service types exist" query: name is "_airplay", regtype is "_tcp.local.".
private let typeFound: DNSServiceBrowseReply = { _, flags, _, error, name, regtype, _, context in
    guard isAdd(flags, error), let name, let regtype else { return }
    let proto = String(cString: regtype).split(separator: ".").first.map(String.init) ?? "_tcp"
    browser(context)?.browse(type: "\(String(cString: name)).\(proto)")
}

private let instanceFound: DNSServiceBrowseReply = { _, flags, interface, error, name, regtype, domain, context in
    guard isAdd(flags, error), let name, let regtype, let domain else { return }
    browser(context)?.resolve(name: String(cString: name), type: String(cString: regtype),
                              domain: String(cString: domain), interface: interface)
}

private let instanceResolved: DNSServiceResolveReply = { ref, _, interface, error, _, host, _, txtLength, txt, context in
    guard let ref else { return }
    var model: String?
    if error == kDNSServiceErr_NoError, let txt {
        var length: UInt8 = 0
        if let value = TXTRecordGetValuePtr(txtLength, txt, "model", &length), length > 0 {
            model = String(decoding: UnsafeRawBufferPointer(start: value, count: Int(length)), as: UTF8.self)
        }
    }
    browser(context)?.resolved(ref, host: error == kDNSServiceErr_NoError ? host.map { String(cString: $0) } : nil,
                               model: model, interface: interface)
}

private let addressFound: DNSServiceGetAddrInfoReply = { _, flags, _, error, host, address, _, context in
    guard isAdd(flags, error), let host, let address else { return }
    let text: String
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
        text = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin_addr) { AddressText.ipv4(Array($0)) }
        }
    case AF_INET6:
        text = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin6_addr) { AddressText.ipv6(Array($0)) }
        }
    default:
        return
    }
    browser(context)?.add(address: text, to: String(cString: host))
}
