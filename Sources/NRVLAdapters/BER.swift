import Foundation

/// The subset of ASN.1 BER that SNMP uses. Decoding treats its input as hostile: every length is bounds-checked.
enum BER {
    indirect enum Value: Equatable, Sendable {
        case integer(Int64)
        case octets([UInt8])
        case null
        case oid([UInt32])
        /// SEQUENCE (0x30) or an SNMP PDU (0xA0…0xA5).
        case sequence(tag: UInt8, [Value])
        case ipAddress([UInt8])
        /// Counter32 0x41, Gauge32 0x42, TimeTicks 0x43, Counter64 0x46.
        case unsigned(tag: UInt8, UInt64)
        /// noSuchObject 0x80, noSuchInstance 0x81, endOfMibView 0x82.
        case exception(UInt8)
    }

    struct Malformed: Error {}

    // MARK: Encode

    static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .integer(let number):
            var bytes = withUnsafeBytes(of: number.bigEndian) { Array($0) }
            // Minimal two's complement: drop redundant leading 0x00 / 0xFF.
            while bytes.count > 1, (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
                bytes.removeFirst()
            }
            return tlv(0x02, bytes)
        case .octets(let bytes): return tlv(0x04, bytes)
        case .null: return [0x05, 0x00]
        case .oid(let arcs):
            guard arcs.count >= 2 else { return tlv(0x06, []) }
            var bytes = base128(arcs[0] * 40 + arcs[1])
            for arc in arcs.dropFirst(2) { bytes += base128(arc) }
            return tlv(0x06, bytes)
        case .sequence(let tag, let items): return tlv(tag, items.flatMap(encode))
        case .ipAddress(let bytes): return tlv(0x40, bytes)
        case .unsigned(let tag, let number):
            var bytes = withUnsafeBytes(of: number.bigEndian) { Array($0) }
            while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return tlv(tag, bytes)
        case .exception(let tag): return [tag, 0x00]
        }
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let length = content.count
        let header: [UInt8] = length < 0x80 ? [UInt8(length)]
            : length <= 0xFF ? [0x81, UInt8(length)]
            : [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        return [tag] + header + content
    }

    private static func base128(_ arc: UInt32) -> [UInt8] {
        var bytes = [UInt8(arc & 0x7F)]
        var rest = arc >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    // MARK: Decode

    static func decode(_ bytes: [UInt8]) throws -> Value {
        var slice = bytes[...]
        return try decode(&slice, depth: 0)
    }

    private static func decode(_ input: inout ArraySlice<UInt8>, depth: Int) throws -> Value {
        guard depth < 8, let tag = input.popFirst(), let first = input.popFirst() else { throw Malformed() }
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            guard (1...2).contains(count), input.count >= count else { throw Malformed() }   // SNMP fits in 64 KiB
            length = input.prefix(count).reduce(0) { $0 << 8 | Int($1) }
            input = input.dropFirst(count)
        }
        guard input.count >= length else { throw Malformed() }
        var content = input.prefix(length)
        input = input.dropFirst(length)

        switch tag {
        case 0x02:
            guard (1...8).contains(content.count) else { throw Malformed() }
            let negative = content.first! & 0x80 != 0
            return .integer(content.reduce(negative ? -1 : 0) { $0 << 8 | Int64($1) })
        case 0x04: return .octets(Array(content))
        case 0x05: return .null
        case 0x06:
            guard let head = content.popFirst() else { throw Malformed() }
            var arcs = [UInt32(head / 40), UInt32(head % 40)]
            var arc: UInt32 = 0
            for byte in content {
                guard arc >> 25 == 0 else { throw Malformed() }   // would overflow 32 bits
                arc = arc << 7 | UInt32(byte & 0x7F)
                if byte & 0x80 == 0 {
                    arcs.append(arc)
                    arc = 0
                }
            }
            return .oid(arcs)
        case 0x30, 0xA0...0xA8:
            var items: [Value] = []
            while !content.isEmpty { items.append(try decode(&content, depth: depth + 1)) }
            return .sequence(tag: tag, items)
        case 0x40: return .ipAddress(Array(content))
        case 0x41, 0x42, 0x43, 0x46:
            guard (1...9).contains(content.count) else { throw Malformed() }
            return .unsigned(tag: tag, content.reduce(0) { $0 << 8 | UInt64($1) })
        case 0x80, 0x81, 0x82: return .exception(tag)
        default: throw Malformed()
        }
    }
}

/// A dotted object identifier, e.g. "1.3.6.1.2.1.1.1.0".
struct OID: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    var arcs: [UInt32]

    init(_ arcs: [UInt32]) { self.arcs = arcs }
    init(stringLiteral value: String) { arcs = value.split(separator: ".").compactMap { UInt32($0) } }

    var description: String { arcs.map(String.init).joined(separator: ".") }
    func isUnder(_ root: OID) -> Bool { arcs.count > root.arcs.count && arcs.starts(with: root.arcs) }
    /// The arcs after `root` — the table index.
    func suffix(after root: OID) -> [UInt32] { Array(arcs.dropFirst(root.arcs.count)) }
}
