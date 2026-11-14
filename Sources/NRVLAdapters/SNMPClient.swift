import Darwin
import Foundation
import NRVLCore

/// SNMP v2c over UDP, read-only (GET and GETBULK). Never sends SET.
// shortcut: v2c only — the community string travels unencrypted. Add v3 (USM auth+priv) before using across untrusted links.
struct SNMPClient: Sendable {
    var host: String
    var port: UInt16 = 161
    var community: String
    var timeout: TimeInterval = 2
    var retries = 1

    typealias Binding = (oid: OID, value: BER.Value)

    func get(_ oids: [OID]) async throws -> [Binding] {
        try await exchange(pdu: 0xA0, oids: oids, second: 0, third: 0)
    }

    /// Every row under `root`, in order. Stops at the end of the subtree, at `limit`, or if the agent stops advancing.
    func walk(_ root: OID, limit: Int = 5_000) async throws -> [Binding] {
        var rows: [Binding] = []
        var cursor = root
        while rows.count < limit {
            let batch = try await exchange(pdu: 0xA5, oids: [cursor], second: 0, third: 25)   // non-repeaters 0, max-repetitions 25
            var advanced = false
            for binding in batch {
                guard binding.oid.isUnder(root), binding.value != .exception(0x82),
                      binding.oid.arcs.lexicographicallyPrecedes(cursor.arcs) == false, binding.oid != cursor else { return rows }
                rows.append(binding)
                cursor = binding.oid
                advanced = true
            }
            if !advanced { break }
        }
        return rows
    }

    private func exchange(pdu: UInt8, oids: [OID], second: Int64, third: Int64) async throws -> [Binding] {
        let requestID = Int64(Int32.random(in: 1...Int32.max))
        let message = BER.encode(.sequence(tag: 0x30, [
            .integer(1),   // version: v2c
            .octets(Array(community.utf8)),
            .sequence(tag: pdu, [
                .integer(requestID), .integer(second), .integer(third),
                .sequence(tag: 0x30, oids.map { .sequence(tag: 0x30, [.oid($0.arcs), .null]) }),
            ]),
        ]))
        let (host, port, timeout, retries) = (host, port, timeout, retries)
        let reply: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try Self.send(message, host: host, port: port, timeout: timeout, retries: retries) })
            }
        }
        return try Self.parse(reply, expecting: requestID)
    }

    static func parse(_ reply: [UInt8], expecting requestID: Int64) throws -> [Binding] {
        guard case .sequence(0x30, let message) = try? BER.decode(reply), message.count == 3,
              case .sequence(0xA2, let pdu) = message[2], pdu.count == 4,
              case .integer(let id) = pdu[0], case .integer(let status) = pdu[1],
              case .sequence(0x30, let bindings) = pdu[3] else {
            throw AdapterError.protocolError("The reply is not a valid SNMP response.")
        }
        guard id == requestID else { throw AdapterError.protocolError("The reply answers a different request.") }
        guard status == 0 else { throw AdapterError.protocolError("The device reported SNMP error \(status).") }
        return try bindings.map { binding in
            guard case .sequence(0x30, let pair) = binding, pair.count == 2, case .oid(let arcs) = pair[0] else {
                throw AdapterError.protocolError("The reply contains a malformed value.")
            }
            return (OID(arcs), pair[1])
        }
    }

    private static func send(_ message: [UInt8], host: String, port: UInt16, timeout: TimeInterval, retries: Int) throws -> [UInt8] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else {
            throw AdapterError.unreachable("The address \"\(host)\" could not be resolved.")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw AdapterError.unreachable(String(cString: strerror(errno))) }
        defer { close(fd) }
        // connect() on UDP makes the kernel drop datagrams from any other address.
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            throw AdapterError.unreachable(String(cString: strerror(errno)))
        }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 65_535)
        for _ in 0...retries {
            guard Darwin.send(fd, message, message.count, 0) == message.count else {
                throw AdapterError.unreachable(String(cString: strerror(errno)))
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 { return Array(buffer.prefix(count)) }
            if errno == ECONNREFUSED { throw AdapterError.unreachable("Nothing is listening for SNMP on \(host):\(port).") }
        }
        // A wrong community string looks exactly like silence: SNMP v2c agents do not answer it.
        throw AdapterError.timeout
    }
}
