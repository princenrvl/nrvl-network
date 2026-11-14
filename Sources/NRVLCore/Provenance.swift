import Foundation

/// Where a displayed value came from.
public enum DataSource: Sendable, Codable, Hashable {
    case arp, ndp, mdns, snmp, reverseDNS, ouiRegistry, heuristic, user
    case adapter(id: Int64)
}

public enum Confidence: String, Sendable, Codable {
    case confirmed, inferred
}

public enum Freshness: String, Sendable, Codable {
    case live, historical, estimated
}

/// A discovered value together with its provenance. Views never show a value without one.
public struct Observed<Value: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
    public var value: Value
    public var source: DataSource
    public var confidence: Confidence
    public var observedAt: Date

    public init(_ value: Value, source: DataSource, confidence: Confidence, observedAt: Date = Date()) {
        self.value = value
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
    }
}
