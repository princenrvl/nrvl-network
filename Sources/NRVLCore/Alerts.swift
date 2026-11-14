import Foundation

public struct Alert: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Codable, Identifiable {
        case newDevice, deviceLeft, gatewayOffline, internetOffline, highLatency, packetLoss, bandwidth
        case addressConflict, gatewayChanged, dnsChanged, integrationDown, certificateChanged, firewallChanged

        public var id: Self { self }

        public var title: String {
            switch self {
            case .newDevice: "New device"
            case .deviceLeft: "Device disconnected"
            case .gatewayOffline: "Gateway not answering"
            case .internetOffline: "Internet unreachable"
            case .highLatency: "High latency"
            case .packetLoss: "Packet loss"
            case .bandwidth: "Bandwidth threshold"
            case .addressConflict: "Possible IP address conflict"
            case .gatewayChanged: "Gateway changed"
            case .dnsChanged: "DNS servers changed"
            case .integrationDown: "Integration not reachable"
            case .certificateChanged: "Router certificate changed"
            case .firewallChanged: "Firewall rules changed"
            }
        }

        /// Shown in Security Center as well as Monitoring.
        public var isSecurity: Bool {
            [.newDevice, .addressConflict, .gatewayChanged, .dnsChanged, .certificateChanged, .firewallChanged].contains(self)
        }

        public var severity: Severity {
            switch self {
            case .gatewayOffline, .internetOffline, .certificateChanged: .critical
            case .newDevice, .deviceLeft: .info
            default: .warning
            }
        }
    }

    public enum Severity: String, Sendable, Codable { case info, warning, critical }

    public var id: Int64 = 0
    public var kind: Kind
    /// What it is about (a device, an address, an integration). Used to avoid repeating the same alert.
    public var subject: String
    /// The evidence, in plain words. An alert reports an observation, never a verdict.
    public var detail: String
    public var date: Date
    public var acknowledged = false

    public init(id: Int64 = 0, kind: Kind, subject: String, detail: String, date: Date = Date(), acknowledged: Bool = false) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.detail = detail
        self.date = date
        self.acknowledged = acknowledged
    }
}

public struct AlertSettings: Sendable, Equatable, Codable {
    public var disabled: Set<Alert.Kind> = [.deviceLeft]
    public var notifications = true
    public var latencyMilliseconds = 150.0
    public var lossPercent = 5.0
    /// Megabits per second on this Mac's interface; 0 turns the check off.
    public var bandwidthMbps = 0.0

    public init() {}
}

/// Everything the alert rules look at, captured after one scan.
public struct NetworkSnapshot: Sendable, Equatable {
    public var gatewayAddress: String?
    public var gatewayMAC: MACAddress?
    public var dnsServers: [String] = []
    /// 0…1 over the last minute; nil when not measured.
    public var gatewayLoss: Double?
    public var internetLoss: Double?
    public var internetLatency: TimeInterval?
    /// Bytes per second, this Mac.
    public var throughput: Double?
    public var conflicts: [String] = []
    /// Integration name → error text, for integrations that failed their last poll.
    public var integrationErrors: [String: String] = [:]
    /// Integration name → fingerprint presented, when it differs from the approved one.
    public var certificateChanges: [String: String] = [:]
    /// Integration name → digest of its firewall rules.
    public var firewallDigests: [String: String] = [:]
    public var discovered: [String] = []
    public var disappeared: [String] = []

    public init() {}
}

public enum AlertRules {
    /// Alerts for what changed between two snapshots. Conditions alert when they begin, not on every scan while they last.
    public static func evaluate(previous: NetworkSnapshot?, current: NetworkSnapshot, settings: AlertSettings, at date: Date = Date()) -> [Alert] {
        var alerts: [Alert] = []
        func raise(_ kind: Alert.Kind, _ subject: String, _ detail: String) {
            if !settings.disabled.contains(kind) { alerts.append(Alert(kind: kind, subject: subject, detail: detail, date: date)) }
        }
        /// True when the condition holds now and did not hold (or was unknown) before.
        func began(_ now: Bool, _ before: Bool?) -> Bool { now && before != true }

        for name in current.discovered { raise(.newDevice, name, "\(name) was seen on the network for the first time.") }
        for name in current.disappeared { raise(.deviceLeft, name, "\(name) has not been seen for three scans in a row.") }

        if began(current.gatewayLoss == 1, previous.map { $0.gatewayLoss == 1 }) {
            raise(.gatewayOffline, current.gatewayAddress ?? "gateway", "The gateway \(current.gatewayAddress ?? "") answered none of the last pings from this Mac.")
        }
        // Only blame the internet when the gateway itself still answers.
        if began(current.internetLoss == 1 && current.gatewayLoss != 1, previous.map { $0.internetLoss == 1 && $0.gatewayLoss != 1 }) {
            raise(.internetOffline, "internet", "The gateway answers, but the internet check received no reply over the last minute.")
        }
        func lossy(_ snapshot: NetworkSnapshot) -> Bool {
            guard let loss = snapshot.internetLoss, loss < 1 else { return false }
            return loss * 100 > settings.lossPercent
        }
        if began(lossy(current), previous.map(lossy)) {
            raise(.packetLoss, "internet", "\(Int(((current.internetLoss ?? 0) * 100).rounded()))% of pings to the internet were lost over the last minute (threshold \(Int(settings.lossPercent))%).")
        }
        func slow(_ snapshot: NetworkSnapshot) -> Bool { (snapshot.internetLatency ?? 0) * 1000 > settings.latencyMilliseconds }
        if began(slow(current), previous.map(slow)) {
            raise(.highLatency, "internet", "Average ping time to the internet is \(Int((current.internetLatency ?? 0) * 1000)) ms (threshold \(Int(settings.latencyMilliseconds)) ms).")
        }
        func busy(_ snapshot: NetworkSnapshot) -> Bool {
            settings.bandwidthMbps > 0 && (snapshot.throughput ?? 0) * 8 / 1_000_000 > settings.bandwidthMbps
        }
        if began(busy(current), previous.map(busy)) {
            raise(.bandwidth, "this Mac", String(format: "This Mac is moving %.1f Mbit/s (threshold %.0f Mbit/s).", (current.throughput ?? 0) * 8 / 1_000_000, settings.bandwidthMbps))
        }

        for address in current.conflicts where previous?.conflicts.contains(address) != true {
            raise(.addressConflict, address, "\(address) switched back and forth between different devices. Two devices may be using the same address, or a failover pair shares it.")
        }
        if let previous {
            if let before = previous.gatewayAddress, let now = current.gatewayAddress, before != now {
                raise(.gatewayChanged, now, "This Mac's default gateway changed from \(before) to \(now). This is normal after joining a different network.")
            } else if let before = previous.gatewayMAC, let now = current.gatewayMAC, before != now {
                raise(.gatewayChanged, current.gatewayAddress ?? "gateway",
                      "The gateway address \(current.gatewayAddress ?? "") is now answered by a different device (\(now), previously \(before)). A replaced router explains this; so does another device impersonating the gateway.")
            }
            if !previous.dnsServers.isEmpty, !current.dnsServers.isEmpty, Set(previous.dnsServers) != Set(current.dnsServers) {
                raise(.dnsChanged, "DNS", "DNS servers changed from \(previous.dnsServers.joined(separator: ", ")) to \(current.dnsServers.joined(separator: ", ")).")
            }
            for (name, digest) in current.firewallDigests {
                if let before = previous.firewallDigests[name], before != digest {
                    raise(.firewallChanged, name, "The firewall rules reported by \(name) differ from the previous scan. If you did not change them, review them under Firewall.")
                }
            }
        }
        for (name, error) in current.integrationErrors where previous?.integrationErrors[name] == nil {
            raise(.integrationDown, name, "\(name) could not be polled: \(error)")
        }
        for (name, fingerprint) in current.certificateChanges where previous?.certificateChanges[name] != fingerprint {
            raise(.certificateChanged, name, "\(name) presented a certificate different from the one you approved (SHA-256 \(fingerprint)). The connection was refused. A firmware update or reset can cause this; so can interception.")
        }
        return alerts
    }
}
